# Custom Modules

server-toolkit lets you add your own read-only diagnostic checks to
`info` without touching any built-in file. This page explains what a
custom module is, where it lives, how to turn it on, and — most
importantly — the trust model you're opting into.

## What is a custom module?

A small text file describing one command you want `info` to run and
report on, e.g. "check that my backup mount is present" or "count how
many stale lock files exist in /var/lib/myapp." server-toolkit doesn't
know or care what the command does — it just runs it, captures its
output and exit code, and shows both in the dashboard.

## Where modules live

- Default: `${XDG_CONFIG_HOME:-$HOME/.config}/server-toolkit/modules/`
- Same `TOOLKIT_CONFIG_DIR` override as the main config (see
  `docs/config.md`) — if you've overridden that, your modules directory
  moves with it.

server-toolkit never creates this directory or any file in it. You
create it yourself:

    mkdir -p ~/.config/server-toolkit/modules

Only files directly inside this one directory are considered — nothing
in a subdirectory is ever scanned.

## Enabling the feature

Custom modules are off by default — with no config at all, `info` never
even looks at the modules directory. Turn the feature on in the main
config file (`~/.config/server-toolkit/config`):

    CUSTOM_MODULES_ENABLED=true

Then each module also needs its own `ENABLED=true` (see below) — both
switches must be on for a module to actually run.

`server-toolkit tui` also discovers and runs your enabled custom
modules, on every refresh, using this exact same two-gate trust model
and the same timeout/output-capture mechanics described on this page —
`info` and `tui` share one discovery/execution path, nothing is
reimplemented for the TUI. See `docs/tui.md`'s "Custom modules" section
for how that plays out across the TUI's refresh cycle specifically.

## Module file format

One file per module, named `<name>.conf`, where `<name>` may only
contain letters, digits, `_` and `-` (no dots — so `..` can never be a
valid module name, closing off path-traversal-style names by
construction, not just by a blocklist). Same plain `KEY=VALUE` format as
the main config file (see `docs/config.md`'s Format section — comments,
quoting, and single-line-values-only all apply identically).

| Key | Type | Required | Default | Meaning |
|---|---|---|---|---|
| `ENABLED` | boolean | no | `false` | Whether this specific module runs at all. |
| `COMMAND` | string | yes (to do anything) | — | The shell command to run. See Trust model below. |
| `TIMEOUT` | positive_integer (seconds) | no | `CUSTOM_MODULE_TIMEOUT_DEFAULT` (see `docs/config.md`, default 5) | How long this module is allowed to run before being killed. |

A module with no `COMMAND` is reported as a problem in the dashboard
(WARN, see Result mapping below) rather than silently ignored or
crashing the rest of `info`. An invalid `TIMEOUT` is different: it's
silently replaced with `CUSTOM_MODULE_TIMEOUT_DEFAULT` and the module
runs anyway — there's no warning or indication that the value you wrote
was ignored, so double-check it if the module doesn't seem to be timing
out when you expect.

### Example (synthetic — adapt the command to your own system)

`~/.config/server-toolkit/modules/example-disk-check.conf`:

    ENABLED=true
    COMMAND=df -h /data | tail -n1
    TIMEOUT=3

## How timeout works

Each module runs as its own child process via
`timeout -k 1 "$TIMEOUT" bash -c "$COMMAND"`, with output captured to a
temporary file (not a live pipe) and stdin redirected from `/dev/null`.
The `-k 1` means: `timeout` sends SIGTERM at `TIMEOUT` seconds, then —
if the process is still alive one second later — an uncatchable SIGKILL.
A module that ignores SIGTERM entirely can therefore run for up to
`TIMEOUT + 1` seconds before being force-killed, not just `TIMEOUT`
seconds.

Capturing output via a temp file rather than a pipe is deliberate: it
means a module that backgrounds a process (e.g. `sleep 60 &`) can't hang
`info` waiting for that orphaned descendant to close a pipe's write end
— `info` only waits on the foreground `timeout`/`bash -c` process, and
returns as soon as it exits, leaving anything it detached to run out of
band.

A module that hangs is killed and reported as timed out without
blocking any other module or the rest of `info`. There's currently no
single overall cap on the whole dashboard's custom-module time — with
several modules enabled, `info`'s worst-case extra runtime is roughly
the sum of their individual timeouts (each up to `TIMEOUT + 1`s), so
keep that in mind if you enable many. A dashboard-wide timeout is a
natural future addition, not built yet.

## Result mapping

Each module's outcome maps to the same OK/WARN/ERROR vocabulary the rest
of `info` uses, based on the exit code of `timeout ... bash -c
"$COMMAND"`:

- Exit code `0` → OK, no alert.
- Exit code `124` (GNU `timeout`'s own "killed for running too long")
  or `137` (128+SIGKILL, the code left behind when `-k 1`'s escalation
  had to force-kill a SIGTERM-ignoring module) → ERROR, "timed out",
  with an alert. Both codes are treated as a timeout.
- Any other non-zero exit → WARN, with the exit code shown, and an
  alert. A verbose module that exits 0 but writes more than the 4096-byte
  output cap still reports OK — the cap only truncates what's displayed,
  it never turns success into a warning.
- Disabled (`ENABLED` not `true`), or unknown (invalid module name, or
  the module file doesn't exist / isn't readable) → reported inline,
  no alert, nothing is ever executed.
- Malformed (no `COMMAND` configured) → also WARN, with an alert, same
  as any other module that reports WARN — `info`'s alert dispatch fires
  on the WARN/ERROR status alone, with no exemption for *why* a module
  produced it. Nothing is executed in this case (there's no command to
  run), but it is not silent.

A module doesn't need to know about this vocabulary at all — just exit
0 when things are fine and non-zero when they aren't, the same
convention as any shell script or monitoring check. Note the one
inherent ambiguity: a module that happens to exit exactly `124` or `137`
on its own (rather than actually being killed) is indistinguishable from
a real timeout — this is a property of `timeout`'s exit-code protocol,
not something server-toolkit can resolve.

## Trust model — read this before writing a module

**A module's `COMMAND` is executed as a real shell command, on purpose.**
That is the entire point of this feature: to let you run whatever you
want from `info`. server-toolkit does not sandbox, restrict, or inspect
what you put there — it treats writing `COMMAND=<anything>` in a file
you own as your own deliberate choice, exactly as if you'd typed that
command yourself.

What server-toolkit *does* guarantee:

- Your module file is never treated as executable code while it's being
  *read* — discovering and parsing module files (to find their `ENABLED`/
  `COMMAND`/`TIMEOUT` values) never runs anything, no matter what those
  values say. Only the deliberate run step (both switches on) executes
  `COMMAND`.
- A module file must be owned by you and not writable by anyone else
  (group or other) — otherwise it's ignored, the same rule the main
  config file already follows.
- Your command runs in its own child process via
  `timeout -k 1 ... bash -c "$COMMAND"`, never `eval` and never
  server-toolkit's own running shell — it can't reach into `info`'s own
  variables or crash the rest of the dashboard. It also can't hang
  `info` indefinitely: even a module that backgrounds a process or
  ignores SIGTERM is bounded, by the file-based capture and the `-k 1`
  force-kill described above.
- Its displayed output is capped (currently 4096 bytes) so a runaway
  module can't make `info` show or hold unbounded output in memory.
  (The module's own process can still write more than that to its
  temporary output file before being read back and truncated — bounded
  by `TIMEOUT` and available disk, not by the byte cap in real time.)
- It never runs unless you've explicitly opted in twice: the global
  `CUSTOM_MODULES_ENABLED=true` switch, and that module's own
  `ENABLED=true`.

What it does **not** guarantee, because this feature is inherently
"run arbitrary commands the user configured":

- It does not validate, sandbox, or limit *what* your command can do —
  a module can read any file, make network calls, or modify anything
  your own user account can modify. It runs with exactly your
  permissions, nothing more and nothing less.
- It does not protect you from a module you wrote carelessly (e.g. one
  that deletes files) — that's the same risk as running any shell
  script yourself.

If you wouldn't type a command directly into your own shell, don't put
it in a module's `COMMAND`.

## For contributors

Discovery and parsing of module files (`lib/modules.sh`'s
`discover_modules`/`read_module_file`) never execute anything, by
design — only `run_module` does, and only after both `ENABLED` switches
are on. Keep it that way: any future change to this file that adds a
new way to read a module's fields must not introduce a path that runs
or evaluates their contents.
