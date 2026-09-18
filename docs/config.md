# Configuration

server-toolkit works with zero configuration. This page is for anyone who
wants to override one of the documented default values.

## Location

- Default: `${XDG_CONFIG_HOME:-$HOME/.config}/server-toolkit/config`
- Override the whole directory: set `TOOLKIT_CONFIG_DIR=/some/path`

The toolkit never creates this file or directory, and never writes to it.
If you want a config file, create it yourself:

    mkdir -p ~/.config/server-toolkit
    cat > ~/.config/server-toolkit/config <<'EOF'
    CONFIG_VERSION=1
    RAM_ALERT_PCT=80
    EOF

## Format

Plain `KEY=VALUE` lines, one setting per line. Lines starting with `#`
(after optional leading whitespace) are comments; blank lines are
ignored. A value may optionally be wrapped in matching single or double
quotes, which are stripped.

The parser never `source`s, `eval`s, or otherwise executes this file. A
value like `FOO=$(rm -rf /)` is stored and read back as that literal
text - it is never run.

## Currently recognized keys

| Key | Type | Default | Used by |
|---|---|---|---|
| `RAM_ALERT_PCT` | percentage (0-100) | 90 | `info` |

More settings (dashboard sections, refresh interval, top-N process
count, log lookback, etc.) will be wired up in future sprints - this
table only lists what's actually connected today, not a preview of
unimplemented options.

## Versioning

`CONFIG_VERSION` is optional. If present, it currently must be `1`. A
config declaring an unsupported version is ignored in its entirety -
every setting in that file falls back to its default, rather than being
partially applied.

## Safety

- The file is only ever read, never executed.
- It must be owned by the user running the toolkit and must not be
  writable by group or other, or it's ignored entirely (with a warning
  on stderr).
- An invalid value for a key's type falls back to that key's default
  (with a warning on stderr) instead of crashing or being half-applied.
- An unreadable file (permissions, or removed mid-read) also falls back
  to defaults with a warning, rather than failing the command using it.

## Adding a new config-backed setting (for contributors)

In the relevant `bin/*-info` script, after sourcing `lib/config.sh`:

    SOME_THRESHOLD="$(config_get SOME_THRESHOLD 42 positive_integer)"

`config_get KEY DEFAULT [TYPE] [ENUM_VALUES]` - `TYPE` is one of
`integer`, `positive_integer`, `percentage`, `boolean`, `enum`, `string`
(defaults to `string`). For `enum`, pass the allowed values
pipe-separated as the fourth argument:

    MODE="$(config_get MODE full enum "full|compact")"
