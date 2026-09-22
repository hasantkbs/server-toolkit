# CLI

server-toolkit's individual commands (`info`, `gpu-info`, `docker-info`, ...)
still work exactly as before, standalone. `bin/server-toolkit` is a single
entry point that dispatches to them under shorter, consistent names - a
thin layer, not a replacement.

## Usage

    server-toolkit [COMMAND] [ARGS]

Running with no command shows the `info` dashboard - the same as
`server-toolkit info`.

## Commands

| Command | Runs | Notes |
|---|---|---|
| `info` | `bin/info` | Default when no command is given |
| `gpu` | `bin/gpu-info` | |
| `docker` | `bin/docker-info` | |
| `network` | `bin/network-info` | |
| `storage` | `bin/storage-info` | |
| `services` | `bin/services-info` | |
| `security` | `bin/security-info` | |
| `process` | `bin/process-info` | |
| `logs` | `bin/logs-info` | |
| `backup` | `bin/backup-info` | |
| `tui` | `bin/tui` | Interactive terminal dashboard - see `docs/tui.md` |
| `modules` | (built into the dispatcher) | Lists discovered custom modules and enabled/disabled status - see below |
| `config` | (built into the dispatcher) | Shows config path/content - see below |
| `version` / `--version` / `-V` | (built into the dispatcher) | Prints the version string |
| `help` / `--help` / `-h` | (built into the dispatcher) | Prints this command list |

An unrecognized command (e.g. `server-toolkit banana`) prints a clear
error to stderr, points you at `help`, and exits with status 127 - never
a raw Bash error. An unrecognized *argument* to a known command (e.g.
`server-toolkit info extra`) is passed straight through to that command,
which currently ignores any arguments - a harmless, deterministic no-op.

## Command-specific help

    server-toolkit <command> --help
    server-toolkit <command> -h

Every command listed above accepts `--help`/`-h` and prints that
command's own usage text instead of running it - this never gathers any
real system data, it's static text. This works identically whether you
go through the dispatcher (`server-toolkit info --help`) or run the
standalone command directly (`./bin/info --help`, `./bin/tui --help`,
...) - both paths print the same usage text.

## `modules`

    server-toolkit modules

Shows every discovered custom module (see `docs/modules.md`) with its
`enabled`/`disabled` status and configured command. This is read-only
introspection: it never runs a module's `COMMAND`, no matter what the
module's own `ENABLED` field says. If custom modules aren't turned on
(`CUSTOM_MODULES_ENABLED=true` in the main config), it just says so.

## `config`

    server-toolkit config path
    server-toolkit config show

`path` prints the resolved config file path (honoring `TOOLKIT_CONFIG_DIR`
the same way every other command does - see `docs/config.md`). `show`
prints that file's content, or says there isn't one, or warns if the file
exists but has unsafe ownership/permissions and is therefore being
ignored. Both are read-only - there is no subcommand that edits the
config file.

## Security

Command resolution is a fixed, explicit mapping from a small set of
literal command names to a small set of literal target paths - never
`eval`, never `bash -c`/`sh -c` on anything derived from your input, and
never a path built by concatenating your input into a filename. Whatever
you type as the command is only ever compared against literal patterns
or printed back as plain text - it cannot be interpreted as shell code.

## Exit codes

The dispatcher propagates the underlying command's exit code exactly for
all 10 diagnostic commands (`info` exits 1 → `server-toolkit info` exits
1). An unrecognized command exits 127. A recognized command whose
underlying script is missing or not executable exits 1 with a clear
message, instead of a raw exec failure.

## Performance

Dispatching adds negligible overhead: for the 10 diagnostic commands, the
dispatcher `exec`s directly into the target script (replacing itself, not
forking a child), so `server-toolkit info` costs one `case` match plus one
file-existence check more than running `info` directly - not a second
process, not a shell re-parse.
