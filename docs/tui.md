# Terminal Dashboard (TUI)

    server-toolkit tui

A live-refreshing, keyboard-driven dashboard showing the same data
`info` shows, in a bordered, continuously-updating view. Pure Bash, no
extra dependency beyond what `info` and the other commands already use
(`tput`, `stty`, coreutils) - nothing new to install.

## Requirements

- A real interactive terminal. `server-toolkit tui` (and `bin/tui`
  directly) refuse to start if stdin or stdout isn't a TTY, with a clear
  message and a non-zero exit - never a raw error.
- Works over SSH exactly like any other interactive terminal program:
  a normal `ssh host` session followed by `server-toolkit tui` has a
  real TTY. It's only non-interactive invocations (piped input,
  `ssh host 'server-toolkit tui'` without `-t`, cron) that are refused.

## Keyboard controls

| Key | Action |
|---|---|
| `r` / `R` | Refresh now |
| `h` / `H` / `?` | Toggle the help screen |
| `q` / `Q` | Quit |
| Ctrl-C | Quit (same clean terminal restoration as `q`) |

Ctrl-C is handled separately from the `r`/`h`/`q` whitelist above - it's
a signal (`SIGINT`), caught by its own handler that restores the
terminal and exits, not a keypress routed through the same dispatch
table. Either way, the terminal is always left clean afterward.

## Refresh

The dashboard refreshes automatically every `TUI_REFRESH_INTERVAL`
seconds (default 5 - see Configuration below), or immediately when you
press `r`. Every refresh calls the same lightweight functions `info`
already calls - never a deep scan (no `storage-info`-style directory
walk, no `backup-info`-style discovery, no full journal breakdown), so
refreshing stays fast regardless of interval.

A terminal resize takes effect on the next refresh or keypress (up to
`TUI_REFRESH_INTERVAL` seconds later), not instantly - the dashboard
re-measures the terminal size on every render rather than reacting to
the resize signal directly, a deliberate simplicity/robustness tradeoff.
Below 70 columns, the dashboard switches to a single-column, unboxed
listing instead of the two-column layout.

## Configuration

`server-toolkit tui`'s help screen (`h`) shows the resolved config file
path, the active refresh interval, and whether custom modules are
currently enabled. Configuration is entirely **read-only** in the TUI -
there is no in-app way to edit settings. Set
`TUI_REFRESH_INTERVAL=<seconds>` in the main config file
(`~/.config/server-toolkit/config` by default - see `docs/config.md`)
to change the default 5-second interval.

## Custom modules

If `CUSTOM_MODULES_ENABLED=true` is set, the dashboard runs your
enabled custom modules on every refresh (the same discovery and
execution path `info` already uses - see `docs/modules.md`) and shows
any resulting warning/error as an alert, alongside the built-in
threshold alerts in the same ALERTS section. The exact same two-gate
trust model applies: nothing runs unless both
`CUSTOM_MODULES_ENABLED=true` (global) and that module's own
`ENABLED=true` are set, and every module still has its own timeout. A
slow or misbehaving module can add up to its own `TIMEOUT` seconds to a
single refresh cycle, but never hangs the dashboard indefinitely, and
never runs with fewer protections than it already has outside the TUI.

## Colors

Colors are used only to reinforce information already conveyed by text
and the existing ✓/⚠/✗ status glyphs, never as the only signal. Set
`NO_COLOR` (any non-empty value) to disable color entirely; color is
also automatically disabled when output isn't a real color-capable
terminal.

## Non-interactive/testing mode

`TUI_ONCE=1 server-toolkit tui` renders exactly one frame to plain
stdout and exits - it never enters raw input mode or the alternate
screen, so it's safe to run in a script or a pipe. This is what this
project's own test suite uses to verify the dashboard's real output
non-interactively; it's also handy for a quick one-off look without
starting the interactive loop.

## Security

Keyboard input is matched only against a small fixed whitelist of
single characters (`r`, `h`/`?`, `q`, everything else is ignored) -
never `eval`, never `bash -c`/`sh -c`, never used to build a command or
a path. The same discipline as `server-toolkit`'s own command
dispatcher (see `docs/cli.md`).
