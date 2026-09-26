# Security Policy

server-toolkit is a read-only diagnostics toolkit (see README.md's
"Safety / read-only philosophy" section for the exact guarantees and
its two documented, opt-in exceptions). Even so, it's the kind of tool
that gets run with a real user's permissions against real
infrastructure, so a bug that weakens its read-only guarantees, its
command-injection discipline, or its installer's path-safety checks is
treated as a security issue, not an ordinary bug.

## Reporting a vulnerability

Please open a GitHub issue on this repository. If the issue involves
details you'd rather not put in a public issue (e.g. a working
exploit), say so in the issue title/body without including those
details, and ask for a private channel - the maintainer (see this
repository's commit history and LICENSE for contact) will follow up.

There is no bug-bounty program and no guaranteed response time; this is
a small, independently-maintained project. Reports are still taken
seriously and credited in the fix's commit/changelog entry unless you
ask not to be.

## Scope

In scope: anything that lets a diagnostic command (`bin/*-info`,
`bin/server-toolkit`, `bin/tui`) do something other than read and
report - write/delete outside what's documented, execute
attacker-influenced input as shell code, escape the fixed command-name
dispatch, or let `install.sh`/`uninstall` operate on a path it didn't
itself create/verify. Also in scope: a custom-modules or configuration
bug that runs a command or reads a file it shouldn't, given the
documented trust model in `docs/modules.md`/`docs/config.md`.

Out of scope: the custom-modules feature doing exactly what its trust
model says it will do (running a command *you* configured) - that's
the feature working as documented, not a vulnerability. See
`docs/modules.md`.

## Disclosure

No fixed embargo period is promised, but the intent is to fix and
disclose promptly rather than sit on a report. Past fixes of this kind
are visible in this repository's own commit history (e.g. the storage-
info/installer/TUI hardening fixes from this project's own security
review process).
