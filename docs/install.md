# Install

    git clone <repo-url> server-toolkit
    cd server-toolkit
    bash install.sh install

Installs `server-toolkit` for the current user only - no root, no package
manager, no system-wide changes. `install.sh` is a single, separately
reviewable script that only ever copies and `chmod +x`s files; it never
sources or executes anything it copies.

## Requirements

- Linux with Bash and standard coreutils (`cp`, `mv`, `ln`, `mktemp`,
  `readlink`, `grep`, `sed`, `chmod`).
- `git`, to clone the repository.
- No root. No package manager. No new runtime dependency beyond what the
  rest of the toolkit already assumes.

## What install creates

| Path | What it is |
|---|---|
| `~/.local/share/server-toolkit-<version>/` | The actual installed copy of `bin/`, `lib/`, `docs/` for that version |
| `~/.local/share/server-toolkit` | A symlink to the current versioned directory above - never a real directory itself |
| `~/.local/bin/server-toolkit` | A small generated wrapper that `exec`s into the installed copy |

`~/.local/share` and `~/.local/bin` follow the `XDG_DATA_HOME`/
`TOOLKIT_BIN_DIR` overrides - set `XDG_DATA_HOME` and/or `TOOLKIT_BIN_DIR`
before running `install.sh` to install elsewhere.

Every real install directory carries a marker file
(`.server-toolkit-install`) recording a fixed sentinel line, the version,
and the install timestamp. `install.sh` checks this marker before it ever
deletes anything - see Uninstall below.

Config lives entirely outside the install tree (see Config preservation)
and is never touched by `install`, `update`, or a plain `uninstall`.

## PATH setup

`install.sh install` never modifies `~/.bashrc`, `~/.zshrc`, or
`~/.profile` unless you explicitly pass `--add-to-path`. By default it
just tells you whether `~/.local/bin` (or your `TOOLKIT_BIN_DIR`) is
already on `PATH`:

    PATH status:        /home/user/.local/bin is NOT on PATH.
                        Add this line to your shell startup file, or re-run with --add-to-path:
                          export PATH="/home/user/.local/bin:$PATH"

To add it yourself, put that `export PATH=...` line in your shell's
startup file and restart your shell (or `source` it).

To let `install.sh` do it instead:

    bash install.sh install --add-to-path

This appends a clearly-marked block (between `# >>> server-toolkit PATH
>>>` and `# <<< server-toolkit PATH <<<` comments) to the startup file
matching your `$SHELL` (`.bashrc` for bash, `.zshrc` for zsh, `.profile`
otherwise). It's idempotent - running it again detects the existing block
and leaves it alone rather than duplicating it. This is the only thing in
this whole sprint that ever touches a shell startup file, and only when
you ask for it.

## Update

    cd server-toolkit
    git pull
    bash install.sh update

`update` is the same operation as `install` - there's no separate code
path, and no remote-download logic. It stages the new copy fully into its
own new versioned directory, verifies it's real and executable, then does
a single atomic symlink swap (`ln -sfn`) to point `~/.local/share/
server-toolkit` at it. The stable `server-toolkit` path always points
either at the fully-old or the fully-new version - never a half-written
one. The previous versioned directory is removed only after the new one
is live, and only if it still carries a valid `server-toolkit` marker
file. Config is never touched.

Re-running `install` on an already-installed system behaves exactly like
`update` (it just prints `Updated` instead of `Installed`) - `install` and
`update` are aliases for the same operation.

## Uninstall

    bash install.sh uninstall

Removes the application files - the versioned install directory, the
`~/.local/share/server-toolkit` symlink, and the `~/.local/bin/
server-toolkit` wrapper. **Config is kept by default.** This is a
deliberate, safety-relevant default: uninstalling and reinstalling later
should not silently lose your `~/.config/server-toolkit/config` (see
`docs/config.md`).

To also remove config:

    bash install.sh uninstall --purge-config

Running `uninstall` when nothing is installed is not an error - it prints
a clear "nothing to do" message and exits 0.

Every deletion of a directory that might contain arbitrary staged content
(the versioned install directory, on both uninstall and update's old-version
cleanup) is gated by the marker-file check described above: it will never
`rm -rf` such a directory unless it carries a genuine, exact
`server-toolkit` marker line. The wrapper file removal on uninstall
(`~/.local/bin/server-toolkit`) is not marker-gated in this same sense -
it targets only the single fixed path this script itself generates, never
a directory that could hold unrelated content. See Troubleshooting below
for what happens if the marker check refuses a deletion.

## Config preservation

Config (`~/.config/server-toolkit/config`, or wherever `TOOLKIT_CONFIG_DIR`
points - see `docs/config.md`) lives completely outside the install tree
by design. `install`, `update`, and a plain `uninstall` never read, write,
or delete it. Only `uninstall --purge-config` removes it, and only then.

## Troubleshooting

**`server-toolkit: command not found` after install**

`~/.local/bin` (or your `TOOLKIT_BIN_DIR`) isn't on `PATH` yet. Re-run
`install.sh install` and check the "PATH status" line it prints, add the
`export PATH=...` line to your shell startup file yourself, or re-run
with `--add-to-path`.

**`install.sh: ... does not look like a server-toolkit installation
(missing or invalid .server-toolkit-install) - refusing to delete it.`**

The uninstaller's safety check found something at the expected install
path (e.g. `~/.local/share/server-toolkit`) that isn't a directory this
script created - most likely something else was manually placed there, or
the marker file was deleted or edited by hand. `install.sh` refuses to
delete anything it can't verify. Inspect the path yourself and remove it
manually if you're certain it's safe to do so.

**`install.sh: ... exists and is not a symlink managed by this installer
- refusing to overwrite it.`**

`~/.local/share/server-toolkit` is supposed to always be either absent or
a symlink to a versioned directory - never a real directory itself. If
`install` finds a real directory there instead, it refuses rather than
risk `ln -sfn` silently creating the new symlink *inside* it. Inspect
`~/.local/share/server-toolkit` yourself; if you're certain it's safe,
remove it manually and re-run `install.sh install`.
