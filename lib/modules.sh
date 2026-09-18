#!/usr/bin/env bash
# modules.sh - discovery and safe reading of user-defined custom
# diagnostic modules (part of server-toolkit's Sprint 12 custom-module
# system). Execution lives in run_module() (added in a later change to
# this same file) - everything in THIS file only ever turns a module's
# *.conf file into plain strings. Nothing here executes a byte of it.
#
# TRUST BOUNDARY - read this before touching this file:
#   A module's COMMAND field is, by design, eventually run as an
#   arbitrary shell command - that's the entire point of this feature.
#   This file draws a hard line: discovery/parsing (below) never
#   executes anything, no matter what a module's fields say; only
#   run_module() ever does, and only after two explicit opt-ins
#   (CUSTOM_MODULES_ENABLED in the main config, and ENABLED=true in the
#   module's own file). See docs/modules.md for the user-facing model.
#
# Intended to be sourced after common.sh, status.sh, and config.sh (this
# file relies on config_dir/_config_parse_line/_config_permissions_safe
# from config.sh, and does not re-source it itself - same convention as
# every other lib/*.sh file in this repo).

# Only these characters may appear in a module name (the filename with
# its .conf suffix stripped). No "." at all, so ".." can never match -
# path traversal is rejected by the charset itself, not a separate check.
# No "/" or "\" either, for the same reason.
MODULE_NAME_RE='^[A-Za-z0-9_-]+$'

# Hard cap (bytes) on a module's captured combined stdout+stderr,
# enforced in run_module by piping through `head -c` - a real bound on
# what this process ever holds in memory, not a cosmetic display
# truncation like lib/logs.sh's truncate_text.
MODULE_OUTPUT_MAX_BYTES=4096

# Directory holding user-defined module *.conf files. Reuses config.sh's
# config_dir() - never a separate hardcoded path, and honors whatever
# TOOLKIT_CONFIG_DIR override config.sh already resolves. Purely a path
# computation - never touches the filesystem, never creates anything.
modules_dir() {
    printf '%s/modules' "$(config_dir)"
}

# True (exit 0) iff $1 is a safe module name.
module_name_valid() {
    [[ "${1:-}" =~ $MODULE_NAME_RE ]]
}

# ------------------------------------------------------------ discovery ---

# Prints the name of every valid module file under modules_dir, one per
# line, sorted. Bounded and non-recursive by construction: a single
# `find -maxdepth 1 -mindepth 1` over "*.conf" - never descends into
# subdirectories, never looks anywhere else. Deliberately does not
# restrict `find` to `-type f`, so a symlink named *.conf is still
# enumerated here; the per-candidate `[[ -f "$path" ]]` check below
# follows the symlink and accepts it if it resolves to a real file
# (rejects a broken symlink or one pointing at a directory) - actual
# trust (ownership/permissions) is decided later, in read_module_file.
# A filename whose derived name fails module_name_valid is skipped with
# a warning, not fatal - one bad filename never hides the rest.
#
# Two distinct files in this one directory can never produce the same
# derived name: the name is exactly the filename with the literal ".conf"
# suffix stripped, and no filesystem allows two directory entries with
# the identical name. (A module *file's own contents* CAN validly
# contain a duplicate KEY=VALUE line - that's covered by
# read_module_file reusing config.sh's existing last-occurrence-wins
# behavior, tested below - this is a different, real scenario.)
discover_modules() {
    local dir
    dir="$(modules_dir)"
    [[ -d "$dir" ]] || return 0

    local -a paths=()
    while IFS= read -r -d '' path; do
        paths+=("$path")
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -name '*.conf' -print0 2>/dev/null | sort -z)

    local path base name
    for path in "${paths[@]}"; do
        [[ -f "$path" ]] || continue
        base="$(basename -- "$path")"
        name="${base%.conf}"
        if ! module_name_valid "$name"; then
            printf 'server-toolkit: skipping module file with an invalid name: %s\n' "$base" >&2
            continue
        fi
        printf '%s\n' "$name"
    done
}

# -------------------------------------------------------- file reading ---

# Reads module file $1 into the caller's associative array (passed by
# name in $2 - e.g. `local -A fields=(); read_module_file "$path" fields`).
# Uses the exact same permission check and line parser as lib/config.sh
# (_config_permissions_safe, _config_parse_line): a module file not owned
# by the current user, or writable by group/other, is refused exactly
# like an unsafe main config file - and follows symlinks (via
# _config_permissions_safe's own `stat -L`) so a symlink to another
# user's file is rejected too. Never executes anything: this function's
# only job is turning file bytes into a plain associative array of
# strings, reusing config.sh's proven-safe parser rather than a second
# hand-rolled one. Returns 1 (array left empty) if the file doesn't
# exist, fails the permission check, or can't be read - callers treat
# that identically to "malformed module", never as a fatal error.
read_module_file() {
    local path="$1"
    local -n _read_module_out="$2"
    _read_module_out=()

    [[ -f "$path" ]] || return 1
    _config_permissions_safe "$path" || return 1

    local content
    content="$(cat -- "$path" 2>/dev/null)" || return 1

    local line parsed key value
    while IFS= read -r line; do
        parsed="$(_config_parse_line "$line")" || continue
        key="${parsed%%$'\t'*}"
        value="${parsed#*$'\t'}"
        _read_module_out["$key"]="$value"
    done <<<"$content"
    return 0
}

# ---------------------------------------------------------- global gate ---

# True (exit 0) iff the custom-module system is turned on at all. Default
# is off - with no config, info's runtime and output are unaffected by
# anything in this file: this is the one check that gates all of it.
modules_enabled() {
    [[ "$(config_get CUSTOM_MODULES_ENABLED false boolean)" == "true" ]]
}

# Per-module timeout (seconds) used when a module's own TIMEOUT field is
# absent or invalid. Configurable globally so a user with several slow
# modules doesn't have to repeat the same TIMEOUT= line in every file.
module_timeout_default() {
    config_get CUSTOM_MODULE_TIMEOUT_DEFAULT 5 positive_integer
}

# ------------------------------------------------------------ execution ---

# Runs one module by name. THE ONLY function in this codebase that ever
# executes a module's COMMAND field - see the trust-boundary comment at
# the top of this file. Prints exactly one line:
#   STATUS<TAB>MESSAGE<TAB>OUTPUT
# STATUS is one of lib/status.sh's STATUS_OK/STATUS_WARN/STATUS_ERROR/
# STATUS_UNKNOWN. OUTPUT has embedded newlines/tabs collapsed to spaces
# so it can never break this line-based contract. Never fails the caller
# (always returns 0, even when the module itself errors/times out/is
# unknown/disabled/malformed) - a bad module is a reportable condition,
# not a script-ending error, matching this codebase's established
# alerting pattern (compare lib/docker.sh, lib/services.sh).
#
# Execution itself: `timeout -k 1 "$timeout_secs" bash -c "$command"`,
# with stdout+stderr redirected to a temp file (not piped) and stdin
# from /dev/null. `bash -c` runs the command in a fresh child process -
# never inline-executed in place, never this shell - so it cannot mutate
# run_module's own variables/functions/shell options.
#
# Why a temp file, not a pipe: capturing via `$(cmd | head -c N)` hangs
# if the module backgrounds anything (`sleep 8 &`) - a command
# substitution's pipe only sees EOF once EVERY process holding its write
# end closes it, including an orphaned grandchild the module itself
# detached, so run_module would block for as long as that backgrounded
# process runs, no matter what TIMEOUT says. Redirecting to a real file
# and reading it back afterward has no such wait: bash's foreground wait
# tracks only the timeout/bash -c process itself, so a module that
# backgrounds work returns as soon as its own foreground script line
# finishes, leaving the background job to run out of band (detached, no
# longer this function's concern). The tradeoff: the file's own size
# isn't bounded in real time the way a live `head -c` pipe would be - a
# well-behaved-but-verbose module could write more than
# MODULE_OUTPUT_MAX_BYTES to disk before being read back and truncated
# here. That's judged acceptable: it's still bounded by TIMEOUT (and
# available disk), and the module is the user's own configured command,
# not untrusted input.
#
# `-k 1` (kill-after) handles a module that ignores SIGTERM: timeout
# sends SIGTERM at $timeout_secs, then SIGKILL one second later if the
# process is still alive - SIGKILL cannot be caught or ignored. Worst-
# case latency for such a module is timeout_secs + 1s, not unbounded.
#
# GNU timeout's own exit code 124 means "killed for running too long"
# and is treated as its own ERROR-level outcome, distinct from an
# ordinary non-zero exit (though a module that itself exits exactly 124
# on its own is indistinguishable from a real timeout - an inherent,
# accepted ambiguity of timeout's exit-code protocol). 137 (128+SIGKILL)
# is treated the same way: per GNU coreutils' own documented exit-status
# protocol, 137 means "COMMAND (or timeout itself) is sent the KILL(9)
# signal" - exactly what happens when `-k 1` escalates past an ignored
# SIGTERM, so a SIGTERM-ignoring module that had to be force-killed is
# still reported as a timeout, not silently downgraded to an ordinary
# non-zero-exit WARN (same inherent, accepted exit-code ambiguity as 124
# applies here too: a module that itself exits exactly 137 is
# indistinguishable from one that was actually SIGKILLed).
run_module() {
    local name="${1:-}"

    if ! module_name_valid "$name"; then
        printf '%s\t%s\t%s\n' "$STATUS_UNKNOWN" "invalid module name" ""
        return 0
    fi

    local path
    path="$(modules_dir)/${name}.conf"

    local -A fields=()
    if ! read_module_file "$path" fields; then
        printf '%s\t%s\t%s\n' "$STATUS_UNKNOWN" "module '${name}' not found or unreadable" ""
        return 0
    fi

    local enabled="${fields[ENABLED]:-}"
    if [[ "$enabled" != "true" ]]; then
        printf '%s\t%s\t%s\n' "$STATUS_OK" "module '${name}' is disabled" ""
        return 0
    fi

    local command="${fields[COMMAND]:-}"
    if [[ -z "$command" ]]; then
        printf '%s\t%s\t%s\n' "$STATUS_WARN" "module '${name}' has no COMMAND configured" ""
        return 0
    fi

    local timeout_secs="${fields[TIMEOUT]:-}"
    config_is_positive_integer "$timeout_secs" || timeout_secs="$(module_timeout_default)"

    local output="" rc=0 tmp_out=""
    tmp_out="$(mktemp 2>/dev/null)" || tmp_out=""

    if [[ -n "$tmp_out" ]]; then
        # Grouped with its own stderr redirected to /dev/null: a module
        # force-killed via -k's SIGKILL escalation is a normal, expected
        # outcome here, not a script error - without this, bash itself
        # (not the module) prints an unrelated "<pid> Killed <command>"
        # job-control notice to the *caller's* real stderr on every such
        # kill, which would otherwise leak into bin/info's own output.
        # The module's own stdout/stderr are unaffected (already fully
        # redirected into tmp_out above), so this only silences bash's
        # own notice.
        { timeout -k 1 "$timeout_secs" bash -c "$command" >"$tmp_out" 2>&1 </dev/null; rc=$?; } 2>/dev/null
        output="$(head -c "$MODULE_OUTPUT_MAX_BYTES" -- "$tmp_out" 2>/dev/null)"
        rm -f -- "$tmp_out"
    else
        # mktemp failed (should not happen in practice) - fall back to the
        # pipe-based capture. This path re-introduces the "a backgrounded
        # grandchild can block this specific call" caveat that the file-
        # based path above exists to avoid, and needs pipefail scoped to
        # its own subshell to read timeout's real exit code correctly.
        { output="$(set -o pipefail; timeout -k 1 "$timeout_secs" bash -c "$command" 2>&1 </dev/null | head -c "$MODULE_OUTPUT_MAX_BYTES")" || rc=$?; } 2>/dev/null
    fi

    output="${output//$'\n'/ }"
    output="${output//$'\t'/ }"

    if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
        printf '%s\t%s\t%s\n' "$STATUS_ERROR" "module '${name}' timed out after ${timeout_secs}s" "$output"
    elif [[ "$rc" -ne 0 ]]; then
        printf '%s\t%s\t%s\n' "$STATUS_WARN" "module '${name}' exited non-zero (${rc})" "$output"
    else
        printf '%s\t%s\t%s\n' "$STATUS_OK" "module '${name}' OK" "$output"
    fi
    return 0
}
