#!/usr/bin/env bash
# install.sh - install, update, or uninstall server-toolkit for the current
# user. No root required for the default path. Never modifies a shell
# startup file unless --add-to-path is explicitly given. Never executes any
# copied file during install/update - only cp/chmod, nothing sourced or run.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"

# Sentinel written into every real install so uninstall/update can verify a
# directory is actually a server-toolkit installation before ever deleting
# it - never trust a computed path alone.
ST_MARKER_FILE=".server-toolkit-install"
ST_MARKER_LINE="server-toolkit-install-v1"

# Holds the current staging directory path while st_do_install_or_update
# is running, so its EXIT trap can find it. Intentionally NOT a `local`
# inside that function: under `set -e`, a failing command triggers script
# termination directly rather than a normal function return, and by the
# time bash runs an EXIT trap after that, the failing function's `local`
# variables are already out of scope (verified empirically - a `local`
# read from an EXIT trap comes back unset even though the trap fires
# while still "inside" that function's call). A plain script-scoped
# variable survives past that point and is what the trap actually reads.
ST_STAGING_DIR=""

st_data_home() {
    printf '%s' "${XDG_DATA_HOME:-${HOME:-}/.local/share}"
}

st_bin_home() {
    printf '%s' "${TOOLKIT_BIN_DIR:-${HOME:-}/.local/bin}"
}

# The stable, symlinked install location - what the wrapper always execs
# into. Never itself a real directory; always either absent or a symlink to
# a versioned directory.
st_install_dir() {
    printf '%s/server-toolkit' "$(st_data_home)"
}

st_bin_path() {
    printf '%s/server-toolkit' "$(st_bin_home)"
}

# The config directory - mirrors lib/config.sh's own precedence exactly
# (TOOLKIT_CONFIG_DIR full override, else XDG_CONFIG_HOME, else
# ~/.config), without sourcing lib/config.sh itself (install.sh is
# deliberately standalone). Every place this script reads or deletes
# config must go through this, not a hardcoded XDG_CONFIG_HOME guess -
# otherwise a user with TOOLKIT_CONFIG_DIR set gets --purge-config
# silently missing the real config file.
st_config_dir() {
    printf '%s' "${TOOLKIT_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME:-}/.config}/server-toolkit}"
}

# Prints the version string from a given bin/server-toolkit file (the
# single source of truth already established by Sprint 13 - never
# duplicated here).
st_read_source_version() {
    local target="$1"
    grep -m1 '^TOOLKIT_VERSION=' "$target" | sed -E 's/^TOOLKIT_VERSION="([^"]*)"$/\1/'
}

# True (exit 0) iff $1 is a real, marker-verified server-toolkit install
# directory - the one check every deletion in this script must pass first.
st_is_verified_install() {
    local dir="$1"
    [[ -d "$dir" ]] || return 1
    [[ -f "${dir}/${ST_MARKER_FILE}" ]] || return 1
    # -x: the sentinel must be its own exact line, not merely a substring
    # of some other line (a file containing e.g. "not-really-<sentinel>"
    # must not verify).
    grep -qxF "$ST_MARKER_LINE" "${dir}/${ST_MARKER_FILE}" 2>/dev/null
}

# Copies $SCRIPT_DIR's bin/lib/docs into a new versioned directory, verifies
# the copy is real and executable, then atomically repoints the stable
# install-dir symlink at it. Removes the previous versioned directory only
# after the new one is live, and only if it passes st_is_verified_install
# (never touches a directory that isn't provably ours). Never touches
# config. Reports "Installed" or "Updated" depending on whether a prior
# install existed.
st_do_install_or_update() {
    local source_st="${SCRIPT_DIR}/bin/server-toolkit"
    if [[ ! -f "$source_st" ]]; then
        printf 'install.sh: %s not found - run this script from inside the server-toolkit repository.\n' "$source_st" >&2
        return 1
    fi

    local version
    version="$(st_read_source_version "$source_st")"
    if [[ -z "$version" ]]; then
        printf 'install.sh: could not determine the version from %s\n' "$source_st" >&2
        return 1
    fi
    # The version string ends up as a path component (versioned_dir below,
    # later passed to rm -rf). Restrict it to a safe charset so it can
    # never contain a path separator or a ".." traversal segment - never
    # trust TOOLKIT_VERSION's content just because it came from this
    # repository's own source file.
    if [[ ! "$version" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        printf 'install.sh: refusing to use an unsafe version string: %s\n' "$version" >&2
        return 1
    fi

    local data_home install_dir versioned_dir was_previously_installed=0
    data_home="$(st_data_home)"
    install_dir="$(st_install_dir)"
    versioned_dir="${data_home}/server-toolkit-${version}"

    # If something already exists at the stable install path that isn't a
    # symlink this installer manages, refuse rather than let a later
    # ln -sfn silently nest the new symlink inside it (which would leave
    # an unrecoverable broken state - see docs/install.md).
    if [[ -e "$install_dir" && ! -L "$install_dir" ]]; then
        printf 'install.sh: %s exists and is not a symlink managed by this installer - refusing to overwrite it. Remove it manually if you are sure, then re-run install.\n' "$install_dir" >&2
        return 1
    fi

    [[ -e "$install_dir" ]] && was_previously_installed=1

    mkdir -p "$data_home"

    # Stage into a throwaway sibling directory first (same filesystem as
    # the final target, so the later rename is a real rename, not a
    # cross-filesystem copy) - nothing under $data_home is touched until
    # staging fully succeeds.
    local staging_dir
    staging_dir="$(mktemp -d "${data_home}/.server-toolkit-staging.XXXXXX")"
    ST_STAGING_DIR="$staging_dir"
    # EXIT is required in addition to RETURN: under `set -e`, a failing
    # command (e.g. cp hitting an unreadable source file) aborts the whole
    # script via errexit rather than returning from this function, so a
    # RETURN-only trap never fires and the staging directory leaks. The
    # trap reads ST_STAGING_DIR (a script-scoped variable), not the local
    # $staging_dir - see the comment on ST_STAGING_DIR's declaration for
    # why a `local` doesn't survive to reach the trap in this case.
    trap '[[ -n "$ST_STAGING_DIR" ]] && rm -rf -- "$ST_STAGING_DIR"' EXIT RETURN

    mkdir -p "${staging_dir}/bin" "${staging_dir}/lib" "${staging_dir}/docs"
    cp -- "${SCRIPT_DIR}"/bin/* "${staging_dir}/bin/"
    cp -- "${SCRIPT_DIR}"/lib/*.sh "${staging_dir}/lib/"
    cp -- "${SCRIPT_DIR}"/docs/*.md "${staging_dir}/docs/"
    chmod +x "${staging_dir}"/bin/*
    printf '%s\nversion=%s\ninstalled_at=%s\n' "$ST_MARKER_LINE" "$version" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${staging_dir}/${ST_MARKER_FILE}"

    if [[ ! -x "${staging_dir}/bin/server-toolkit" ]]; then
        printf 'install.sh: staged copy is missing or not executable - aborting, nothing installed.\n' >&2
        return 1
    fi

    # If a versioned directory for this exact version already exists
    # (re-running install/update with no version change), replace it
    # cleanly rather than erroring - this is what makes reinstall
    # idempotent.
    rm -rf -- "$versioned_dir"
    mv -- "$staging_dir" "$versioned_dir"
    trap - EXIT RETURN
    ST_STAGING_DIR=""

    local previous_target=""
    if [[ -L "$install_dir" ]]; then
        previous_target="$(readlink -- "$install_dir")"
    fi

    # The atomic step: a single symlink replacement. Either the old or the
    # new tree is what "server-toolkit" (the stable path) points to at
    # every instant - there is no window where it points at a half-written
    # directory.
    ln -sfn -- "$versioned_dir" "$install_dir"

    # Clean up the previous versioned directory, but only if it's a
    # different, verified server-toolkit install - never touch it if this
    # is the very first install, and never touch it based on the path
    # alone.
    if [[ -n "$previous_target" && "$previous_target" != "$versioned_dir" ]]; then
        local previous_versioned_dir="$previous_target"
        [[ "$previous_versioned_dir" != /* ]] && previous_versioned_dir="${data_home}/${previous_versioned_dir}"
        if st_is_verified_install "$previous_versioned_dir"; then
            rm -rf -- "$previous_versioned_dir"
        fi
    fi

    if [[ "$was_previously_installed" -eq 1 ]]; then
        printf 'Updated server-toolkit to %s\n' "$version"
    else
        printf 'Installed server-toolkit %s\n' "$version"
    fi
    return 0
}

# The one thing that goes on PATH: a fixed-path exec, nothing dynamic, no
# argument interpretation beyond passing them straight through.
#
# The static header is written via a QUOTED heredoc (<<'WRAPPER') so
# nothing in it is ever expanded. The dynamic exec line is built
# separately with `printf %q`, which shell-quotes install_dir into a
# single, inert literal token - safe no matter what characters it
# contains ($, backticks, quotes, spaces). This matters because
# install_dir is derived from HOME/XDG_DATA_HOME/TOOLKIT_BIN_DIR: an
# UNQUOTED heredoc here would expand install_dir at write time and splice
# its literal characters into the wrapper file; if the exec line then
# wrapped that expansion in double quotes (as a normal exec target would
# need to be), any `$(...)`/backtick left over from a hostile
# HOME/XDG_DATA_HOME value at install time would become live shell syntax
# that re-executes on every future run of the installed wrapper.
# `printf %q` rules that out structurally - its output round-trips as an
# exact literal, never re-interpreted.
st_write_wrapper() {
    local bin_home bin_path install_dir
    bin_home="$(st_bin_home)"
    bin_path="$(st_bin_path)"
    install_dir="$(st_install_dir)"
    mkdir -p "$bin_home"
    {
        cat <<'WRAPPER'
#!/usr/bin/env bash
# Generated by server-toolkit's install.sh - do not edit by hand, it is
# overwritten on every install/update. Re-run install.sh to regenerate it.
WRAPPER
        printf 'exec %q "$@"\n' "${install_dir}/bin/server-toolkit"
    } > "$bin_path"
    chmod +x "$bin_path"
}

# True (exit 0) iff $1's directory is already on $PATH.
st_on_path() {
    local dir="$1"
    case ":${PATH}:" in
        *":${dir}:"*) return 0 ;;
        *) return 1 ;;
    esac
}

st_print_summary() {
    local install_dir bin_home bin_path config_path_display version
    install_dir="$(st_install_dir)"
    bin_home="$(st_bin_home)"
    bin_path="$(st_bin_path)"
    if [[ -f "${install_dir}/bin/server-toolkit" ]]; then
        version="$(st_read_source_version "${install_dir}/bin/server-toolkit")"
    else
        version="unknown"
    fi
    config_path_display="$(st_config_dir)/config"

    printf '\n'
    printf 'Installation path: %s\n' "$install_dir"
    printf 'Binary path:        %s\n' "$bin_path"
    printf 'Version:            %s\n' "$version"
    printf 'Config path:        %s (untouched by this script)\n' "$config_path_display"
    if st_on_path "$bin_home"; then
        printf 'PATH status:        %s is already on PATH - "server-toolkit" is ready to use.\n' "$bin_home"
    else
        printf 'PATH status:        %s is NOT on PATH.\n' "$bin_home"
        printf '                    Add this line to your shell startup file, or re-run with --add-to-path:\n'
        printf '                      export PATH="%s:$PATH"\n' "$bin_home"
    fi
    printf '\n'
}

# Removes the application files (the versioned directory the stable symlink
# points to, plus the symlink itself, plus the wrapper). Preserves config
# by default - only removes it if $1 is "purge".
st_do_uninstall() {
    local mode="${1:-keep}"
    local install_dir bin_path
    install_dir="$(st_install_dir)"
    bin_path="$(st_bin_path)"

    if [[ ! -e "$install_dir" && ! -e "$bin_path" ]]; then
        printf 'server-toolkit is not installed (nothing found at %s or %s) - nothing to do.\n' "$install_dir" "$bin_path"
        return 0
    fi

    local real_target="$install_dir"
    if [[ -L "$install_dir" ]]; then
        real_target="$(readlink -- "$install_dir")"
        [[ "$real_target" != /* ]] && real_target="$(st_data_home)/${real_target}"
    fi

    if [[ -e "$install_dir" ]]; then
        if st_is_verified_install "$real_target"; then
            rm -rf -- "$real_target"
            rm -f -- "$install_dir"
        else
            printf 'install.sh: %s does not look like a server-toolkit installation (missing or invalid %s) - refusing to delete it.\n' "$real_target" "$ST_MARKER_FILE" >&2
            printf 'If you are certain, remove it by hand.\n' >&2
            return 1
        fi
    fi

    [[ -e "$bin_path" ]] && rm -f -- "$bin_path"

    printf 'server-toolkit application files removed.\n'

    local config_dir
    config_dir="$(st_config_dir)"
    if [[ "$mode" == "purge" ]]; then
        # The config directory is never created by this toolkit (see
        # docs/config.md: "The toolkit never creates this file or
        # directory, and never writes to it"), so unlike the application
        # install directory there is no marker file to verify it's
        # "ours" before deleting. TOOLKIT_CONFIG_DIR is also a legitimate
        # full, unsuffixed override (see st_config_dir above) - a user
        # can point it at any directory, including one that predates
        # server-toolkit and holds unrelated content. So an unconditional
        # `rm -rf -- "$config_dir"` here would risk destroying an entire
        # directory tree this script never enumerated and can't attribute
        # to itself. Instead: only ever remove the specific
        # entries this toolkit itself defines and knows about (`config`,
        # `modules`), handling each as a symlink explicitly (removed as
        # the link itself, never followed/recursed into), and only remove
        # the directory shell afterward if that leaves it provably empty
        # - never a recursive delete of the directory itself.
        if [[ -d "$config_dir" ]]; then
            local purged=0
            if [[ -e "${config_dir}/config" || -L "${config_dir}/config" ]]; then
                rm -f -- "${config_dir}/config"
                purged=1
            fi
            if [[ -L "${config_dir}/modules" ]]; then
                rm -f -- "${config_dir}/modules"
                purged=1
            elif [[ -d "${config_dir}/modules" ]]; then
                rm -rf -- "${config_dir}/modules"
                purged=1
            fi
            if rmdir -- "$config_dir" 2>/dev/null; then
                printf 'Configuration removed: %s\n' "$config_dir"
            elif [[ "$purged" -eq 1 ]]; then
                printf 'Configuration removed: %s (directory left in place - it still contains other content)\n' "$config_dir"
            else
                printf 'No configuration found at %s - nothing to purge.\n' "$config_dir"
            fi
        else
            printf 'No configuration directory found at %s - nothing to purge.\n' "$config_dir"
        fi
    else
        if [[ -d "$config_dir" ]]; then
            printf 'Configuration preserved at %s (re-install to reuse it, or run: install.sh uninstall --purge-config)\n' "$config_dir"
        fi
    fi
}

# Which shell startup file to offer/append to - based on $SHELL, falling
# back to ~/.profile. Never touched unless the caller explicitly asked
# for --add-to-path.
st_shell_rc_path() {
    case "${SHELL:-}" in
        */zsh)  printf '%s/.zshrc' "${HOME:-}" ;;
        */bash) printf '%s/.bashrc' "${HOME:-}" ;;
        *)      printf '%s/.profile' "${HOME:-}" ;;
    esac
}

ST_PATH_BLOCK_START="# >>> server-toolkit PATH >>>"
ST_PATH_BLOCK_END="# <<< server-toolkit PATH <<<"

# Appends an idempotent, clearly-marked PATH export block to the detected
# shell rc file. Only ever called when --add-to-path was explicitly given.
st_add_to_path() {
    local bin_home rc_path
    bin_home="$(st_bin_home)"
    rc_path="$(st_shell_rc_path)"

    if [[ -f "$rc_path" ]] && grep -qF "$ST_PATH_BLOCK_START" "$rc_path" 2>/dev/null; then
        printf 'PATH already configured in %s - leaving it as-is.\n' "$rc_path"
        return 0
    fi

    {
        printf '\n%s\n' "$ST_PATH_BLOCK_START"
        printf 'export PATH="%s:$PATH"\n' "$bin_home"
        printf '%s\n' "$ST_PATH_BLOCK_END"
    } >> "$rc_path"
    printf 'Added %s to PATH in %s (restart your shell, or run: source %s)\n' "$bin_home" "$rc_path" "$rc_path"
}

st_print_usage() {
    cat <<'EOF'
install.sh - install, update, or uninstall server-toolkit (user-level, no root)

USAGE:
  install.sh install [--add-to-path]
  install.sh update  [--add-to-path]
  install.sh uninstall [--purge-config]
  install.sh --help

install and update are the same operation - both stage a fresh copy and
atomically swap it in; config is never touched by either. --add-to-path
is the only thing that ever modifies a shell startup file, and only when
you pass it explicitly. See docs/install.md for details.
EOF
}

st_main() {
    local verb="${1:-}"
    [[ $# -gt 0 ]] && shift

    case "$verb" in
        --help|-h|help|"")
            st_print_usage
            ;;
        install|update)
            local add_to_path=0
            for arg in "$@"; do
                case "$arg" in
                    --add-to-path) add_to_path=1 ;;
                    *)
                        printf 'install.sh: unknown option for %s: %s\n' "$verb" "$arg" >&2
                        return 1
                        ;;
                esac
            done
            st_do_install_or_update
            st_write_wrapper
            [[ "$add_to_path" -eq 1 ]] && st_add_to_path
            st_print_summary
            ;;
        uninstall)
            local purge=0
            for arg in "$@"; do
                case "$arg" in
                    --purge-config) purge=1 ;;
                    *)
                        printf 'install.sh: unknown option for uninstall: %s\n' "$arg" >&2
                        return 1
                        ;;
                esac
            done
            if [[ "$purge" -eq 1 ]]; then
                st_do_uninstall purge
            else
                st_do_uninstall keep
            fi
            ;;
        *)
            printf 'install.sh: unknown command: %s\n' "$verb" >&2
            st_print_usage >&2
            return 1
            ;;
    esac
}

# Only run when executed directly, not when sourced (tests source this file
# to call its functions in isolation).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    st_main "$@"
fi
