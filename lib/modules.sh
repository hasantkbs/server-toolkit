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
