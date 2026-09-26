# server-toolkit

A pure-Bash, read-only server diagnostics toolkit for Linux.

server-toolkit is a set of independent, single-purpose commands
(`info`, `gpu-info`, `docker-info`, `network-info`, `storage-info`,
`services-info`, `security-info`, `process-info`, `logs-info`,
`backup-info`), a unified dispatcher (`server-toolkit`) that gives them
short, consistent names, and an interactive terminal dashboard (`tui`)
that shows the same data live. It's for anyone who wants a quick, safe
look at a Linux server's health - RAM/CPU/disk pressure, Docker
container state, listening ports, running services, recent log errors,
backup presence, and more - without installing or configuring a
monitoring stack.

Every built-in diagnostic command is read-only by design - it inspects
the system, it never changes it. The two documented exceptions are the
installer (`install.sh`, which only ever copies its own tree into your
user-level install directories and, on `uninstall`, removes exactly
what it installed - see `docs/install.md`) and the opt-in custom-modules
feature, which runs a command *you* wrote and is off by default (see
Custom modules below).

## Core features

- **Read-only by design** - no diagnostic command writes to, modifies,
  or deletes anything on the system it's diagnosing (see Safety below;
  the installer and the opt-in custom-modules feature are the two
  documented exceptions, both described there).
- **Zero required runtime dependencies** beyond Bash (4.3 or newer -
  the codebase uses namerefs, `local -n`/`declare -n`) and standard
  coreutils, plus whatever each individual command is checking (e.g.
  `docker`, `systemctl`) - and every command degrades gracefully, with a
  clear message, when one of those isn't present rather than failing
  with a raw error.
- **A shared alert contract** - every command reports findings as
  `OK`/`WARN`/`ERROR`/`UNKNOWN`, not a subjective score (see Alerts
  below).
- **An optional configuration layer** - override a handful of documented
  defaults (e.g. the RAM alert threshold) in a plain-text config file
  that is only ever read, never executed.
- **An optional custom-modules system** - add your own checks (any
  shell command you write) to the dashboard without touching any
  built-in file, gated behind an explicit opt-in trust model.
- **An interactive TUI** - a live-refreshing, keyboard-driven dashboard
  over the same data `info` shows.
- **A user-level installer** - no root, no package manager, no
  system-wide changes.

## Safety / read-only philosophy

No command in this toolkit uses `eval`, and none passes anything derived
from dynamic input to `bash -c`/`sh -c` - this discipline is documented
and enforced consistently across every `bin/*` command's own security
notes and in `docs/cli.md`'s Security section. Command dispatch is
always a fixed, literal mapping - never a constructed path, never
interpreted shell code.

There is exactly one explicit, opt-in exception to "never run dynamic
input": **custom modules**, where the entire point of the feature is to
run a command *you* configured, as if you'd typed it yourself. That
feature has its own two-gate trust model (a global switch and a
per-module switch, both off by default) and its own careful timeout/
output-capture handling - see `docs/modules.md`'s Trust model section
for the full explanation rather than a re-statement here.

## Installation

    git clone <repo-url> server-toolkit
    cd server-toolkit
    bash install.sh install

Installs for the current user only - no root, no package manager, no
system-wide changes. Full detail (what gets created, PATH setup, update,
uninstall, troubleshooting) is in `docs/install.md`.

## Quick start

After installing (and making sure `~/.local/bin` is on your `PATH` - the
installer tells you if it isn't):

    server-toolkit info

produces a fast, single-shot dashboard, grouped into sections (`SERVER`,
`SYSTEM`, and - depending on what's actually present on the host -
`GPU`, `NETWORK`, `DOCKER`, `SERVICES`, `SECURITY`, `ALERTS`), each a
plain `key   value` list under a header. It looks roughly like this
(illustrative example with synthetic values - the exact sections and
values on your host will differ):

    SERVER
    ────────────────────────────────────────────────────────────
    hostname            example-host
    OS                  Ubuntu 24.04 LTS
    kernel              6.8.0-generic
    uptime              4d 19h 22m
    load                0.70, 0.62, 0.61

    SYSTEM
    ────────────────────────────────────────────────────────────
    CPU                 Example CPU Model (8c/16t)
    RAM                 5GiB / 15GiB (35%)
    SWAP                1GiB / 3GiB (32%)
    DISK                134GiB / 499GiB (29%)

    ALERTS
    ────────────────────────────────────────────────────────────
    ⚠ Swap usage is 32% (example)

For a live, continuously-updating view of the same kind of data instead
of a single snapshot, use the interactive dashboard:

    server-toolkit tui

## CLI commands

    server-toolkit [COMMAND] [ARGS]

Running with no command shows the `info` dashboard. Full command table,
security notes, and exit-code behavior are in `docs/cli.md` - summary:

| Command | What it does |
|---|---|
| `info` | Fast system dashboard (default) |
| `gpu` | GPU diagnostics |
| `docker` | Docker diagnostics |
| `network` | Network diagnostics |
| `storage` | Storage diagnostics |
| `services` | Service diagnostics |
| `security` | Security diagnostics |
| `process` | Process diagnostics |
| `logs` | Journal/log diagnostics |
| `backup` | Backup discovery |
| `tui` | Interactive terminal dashboard |
| `modules` | List discovered custom modules |
| `config` | Show resolved config path/content |
| `version` | Show version |
| `help` | Show help |

Every one of the diagnostic commands above also works as a standalone
binary (`info`, `gpu-info`, `docker-info`, ...) - the dispatcher is a
thin layer over them, not a replacement, and both keep working.

### Command help

    server-toolkit <command> --help
    server-toolkit <command> -h

Every command supports its own `--help`/`-h`, whether invoked through
the dispatcher or directly as a standalone binary (`./bin/info --help`,
`./bin/tui --help`, ...). See `docs/cli.md`.

The version string itself (`server-toolkit version` / `server-toolkit
--version`) is intentionally not repeated here - run one of those
commands to see it.

## TUI

    server-toolkit tui

A live-refreshing, keyboard-driven dashboard over the same data `info`
shows - `r` to refresh now, `h`/`?` to toggle help, `q` or Ctrl-C to
quit. Requires a real interactive terminal (works fine over SSH). Its
help screen shows the resolved config path and refresh interval, but the
TUI itself is strictly read-only - there is no in-app way to edit
settings. Full detail in `docs/tui.md`.

## Configuration

Optional. server-toolkit works with zero configuration. To override a
documented default, create `~/.config/server-toolkit/config` with plain
`KEY=VALUE` lines:

    RAM_ALERT_PCT=80

The file is only ever read, never executed - no `source`, no `eval`.
Full key reference, permission requirements, and how to add a new
config-backed setting are in `docs/config.md`.

## Custom modules

Optional and off by default. Custom modules let you add your own
checks (any shell command you write - not necessarily read-only) to
`info`/`tui`'s dashboard, without touching any built-in file. They're gated by a
two-gate trust model - a global `CUSTOM_MODULES_ENABLED=true` switch and
each module's own `ENABLED=true` - and every module runs with a bounded
timeout. The governing rule: **if you wouldn't type a command directly
into your own shell, don't put it in a module.** Full format, trust
model, and timeout mechanics in `docs/modules.md`.

## Alerts

Every command that reports findings uses the same small vocabulary
(defined once, in `lib/status.sh`, and shared by `info` and `tui`):

- `OK` - checked, nothing wrong.
- `WARN` - checked, an objective threshold or condition was exceeded.
- `ERROR` - checked, a hard failure (e.g. a required daemon is down).
- `UNKNOWN` - could not be checked (tool/permission/data unavailable) -
  never treated as a problem on its own.

These are objective thresholds (a disk/RAM/swap percentage, a CPU
threshold, a process exit code, ...), not a subjective "health score."

## Architecture

- `bin/*-info` - independent, standalone diagnostic commands.
- `lib/*.sh` - shared helpers `bin/` scripts source (`common.sh`
  everywhere; the rest are domain-specific, e.g. `lib/status.sh` for the
  alert contract, `lib/config.sh` for the config engine, `lib/modules.sh`
  for custom modules).
- `bin/server-toolkit` - a thin dispatcher that `exec`s straight into the
  standalone commands under shorter names; it does not duplicate their
  logic.
- `bin/tui` - the interactive layer, built on the exact same `lib/*.sh`
  data-gathering functions and the shared `lib/status.sh` alert contract
  as `info` and the rest, so the dispatcher/TUI/standalone commands
  reuse the same underlying checks rather than each reimplementing how
  data is gathered. This isn't total: a handful of presentation-specific
  values - `bin/tui`'s own alert thresholds (disk/swap/CPU percentages,
  log lookback window) - are intentionally duplicated rather than
  shared, by design, and are kept in sync with `bin/info` by hand (see
  `bin/tui`'s own comment above those constants).

## Privacy

No telemetry, no phone-home, no analytics. The only outbound network
activity any built-in command performs is `network-info`'s own DNS/
connectivity probe - a single `ping` to `1.1.1.1` (Cloudflare's public
resolver) to check basic internet reachability - nothing else leaves
the machine. If you enable custom modules, their commands run with your
own user permissions, can do anything a command you typed yourself
could do (including network access), and are entirely your own
responsibility - see `docs/modules.md`.

## Performance

`info` is designed to be fast: a single-shot dashboard built only from
bounded, cheap calls. Deeper, more expensive operations
(`storage-info`'s directory walks, `logs-info`'s fuller journal
breakdown, `backup-info`'s discovery) are deliberately kept as separate
commands, not folded into `info`'s fast path. The TUI follows the same
rule on every refresh - it calls the same lightweight functions `info`
does and never triggers a deep scan.

## Testing

    bash tests/test.sh
    bash tests/test-install.sh

Both suites are mock/stub-based smoke tests - they don't depend on real
host state (`tests/test.sh` stubs things like `free`/`df`/`docker`
output where needed; `tests/test-install.sh` runs in isolated, temporary
`HOME`/`PATH` sandboxes) - and both are run before every merge. As of
this sprint: `tests/test.sh` is 503/503 and `tests/test-install.sh` is
31/31, both fully passing - check the suites themselves for the current
numbers, since these will grow as the toolkit does.

## Troubleshooting

For install-specific problems (`command not found` after install, a
refused uninstall/update, PATH setup), see `docs/install.md`'s own
Troubleshooting section.

A command reporting a tool as unavailable (e.g. `docker-info` saying
Docker isn't installed, or a security check saying it lacks permission
to read something) is expected graceful degradation, not a bug - every
command is designed to say so clearly rather than fail with a raw error.

## Development

To add a new config-backed setting, see `docs/config.md`'s "Adding a new
config-backed setting" section. To understand the custom-module
discovery/execution split (and the rule that discovery must never
execute anything), see `docs/modules.md`'s "For contributors" section.

## Contributing

The codebase is organized as independent `bin/*-info` commands over
shared `lib/*.sh` helpers (see Architecture above) - a new diagnostic
command typically means one new `bin/` script plus whatever helpers it
needs from `lib/`, following the existing OK/WARN/ERROR/UNKNOWN alert
contract. Read-only is a hard requirement for every diagnostic command;
the only sanctioned exception to "never run dynamic/user-derived input"
is the custom-modules feature, and it's exempted deliberately and
narrowly (see Safety above). Changes are expected to keep `tests/test.sh`
and `tests/test-install.sh` fully green - see Testing above, and the
"For contributors"/"Adding a new config-backed setting" sections linked
under Development for the two extension points that already have
written guidance.

## License

MIT License, see `LICENSE`.
