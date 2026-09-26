# Changelog

server-toolkit has no tagged releases yet (still pre-1.0, version
strings carry a `-dev` suffix - see `bin/server-toolkit`'s
`TOOLKIT_VERSION`). This changelog summarizes what shipped, grouped by
feature area, rather than by version number.

## Diagnostic commands

- `info` - fast, single-shot system dashboard (RAM/CPU/disk/load,
  grouped sections), plus a v2 rewrite adding the shared alert
  contract described below.
- `gpu-info` - GPU diagnostics (`nvidia-smi`-based, graceful when
  absent).
- `docker-info` - container state and Docker disk usage.
- `network-info` - listening ports, default route/interface, basic
  connectivity check.
- `storage-info` - filesystem/inode usage, large-file discovery,
  Docker storage breakdown.
- `services-info` - systemd unit status summary.
- `security-info` - SSH exposure, firewall (ufw) status, fail2ban,
  recent auth failures.
- `process-info` - process overview, high-CPU/high-memory offenders.
- `logs-info` - journal error/warning summary.
- `backup-info` - backup-presence discovery (cron entries, systemd
  timers, common backup paths).

## Shared infrastructure

- A common alert vocabulary (`OK`/`WARN`/`ERROR`/`UNKNOWN`) shared by
  every command via `lib/status.sh`, so findings are objective
  thresholds, not a subjective score.
- An optional configuration engine (`~/.config/server-toolkit/config`)
  to override documented defaults (e.g. the RAM alert threshold),
  read-only and never `source`d/`eval`'d.
- An optional custom-modules system to add your own checks to the
  dashboard, gated behind an explicit two-gate opt-in trust model
  (global switch + per-module switch, both off by default).

## CLI and interactive dashboard

- `server-toolkit` - a single dispatcher giving every command a short,
  consistent name (`server-toolkit info`, `gpu`, `docker`, ...), plus
  `modules`/`config`/`version`/`help` subcommands. Standalone commands
  keep working unchanged alongside it.
- `server-toolkit tui` (`bin/tui`) - a live-refreshing, keyboard-driven
  terminal dashboard over the same diagnostic data, strictly read-only.

## Installation

- `install.sh` - a user-level install/update/uninstall system (no
  root, no package manager). Versioned install directories with an
  atomic symlink swap on update; config is always preserved unless
  `uninstall --purge-config` is used explicitly.

## Hardening

- A security review pass fixed a remote-code-execution-shaped bug in
  `storage-info`'s large-file ranking, an argument-injection risk in
  the installer's generated wrapper, an over-broad deletion path in
  `uninstall --purge-config`, and a hang risk in the CLI/TUI's
  dispatch path - all four confirmed fixed with regression tests.
- A subsequent privacy/release-hygiene pass removed internal
  planning documents from the tracked tree, fixed public-documentation
  wording to match actual behavior, reconciled two independently
  drifting version constants into one, and improved test fixture
  isolation.
