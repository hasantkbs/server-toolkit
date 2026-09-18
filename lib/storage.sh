#!/usr/bin/env bash
# storage.sh - filesystem/disk data collection for `storage-info`
#
# Intended to be sourced after common.sh (and lib/docker.sh for the Docker
# storage section). All directory-scanning helpers are depth-limited,
# time-bounded, stay on one filesystem (-x / -xdev), never follow symlinks,
# and tolerate permission-denied subpaths instead of failing outright.

# fstypes to exclude from the FILESYSTEM/INODES sections: virtual/pseudo
# filesystems that don't represent real storage.
STORAGE_EXCLUDE_FSTYPES=" tmpfs devtmpfs efivarfs squashfs overlay proc sysfs cgroup cgroup2 devpts mqueue tracefs debugfs pstore bpf autofs ramfs "

storage_fstype_excluded() {
    [[ "$STORAGE_EXCLUDE_FSTYPES" == *" $1 "* ]]
}

# One line per real (non-pseudo) mounted filesystem:
# mount|fstype|size_bytes|used_bytes|avail_bytes|pcent
get_filesystem_lines() {
    command_exists df || return 1
    local raw
    raw="$(df -B1 --output=target,fstype,size,used,avail,pcent 2>/dev/null | tail -n +2)" || true
    [[ -z "$raw" ]] && return 1

    local mount fstype size used avail pcent
    while read -r mount fstype size used avail pcent; do
        [[ -z "$mount" ]] && continue
        storage_fstype_excluded "$fstype" && continue
        printf '%s|%s|%s|%s|%s|%s\n' "$mount" "$fstype" "$size" "$used" "$avail" "$pcent"
    done <<<"$raw"
}

# One line per real (non-pseudo) mounted filesystem: mount|ipcent
# ipcent is "N/A" for filesystems without inodes (e.g. vfat).
get_inode_lines() {
    command_exists df || return 1
    local raw
    raw="$(df --output=target,fstype,ipcent 2>/dev/null | tail -n +2)" || true
    [[ -z "$raw" ]] && return 1

    local mount fstype ipcent
    while read -r mount fstype ipcent; do
        [[ -z "$mount" ]] && continue
        storage_fstype_excluded "$fstype" && continue
        [[ "$ipcent" == "-" ]] && ipcent="N/A"
        printf '%s|%s\n' "$mount" "$ipcent"
    done <<<"$raw"
}

# Total size in bytes of one directory subtree (stays on one filesystem,
# time-bounded). Prints nothing and returns 1 if the path doesn't exist.
# Tolerates permission-denied subpaths (du's own nonzero exit is ignored;
# whatever it managed to total is what we report).
get_dir_total_bytes() {
    local dir="$1" timeout_secs="${2:-10}"
    [[ -d "$dir" ]] || return 1
    command_exists du || return 1
    local out
    if command_exists timeout; then
        out="$(timeout "$timeout_secs" du -xsb -- "$dir" 2>/dev/null)" || true
    else
        out="$(du -xsb -- "$dir" 2>/dev/null)" || true
    fi
    [[ -z "$out" ]] && return 1
    awk -F'\t' '{print $1}' <<<"$out"
}

# Raw `du -xb --max-depth=N` output (bytes<TAB>path lines) for one directory,
# time-bounded. depth=0 yields a single line (the directory's own total).
# Prints nothing and returns 1 if the path doesn't exist.
get_dir_sizes_at_depth() {
    local dir="$1" depth="${2:-1}" timeout_secs="${3:-10}"
    [[ -d "$dir" ]] || return 1
    command_exists du || return 1
    local out
    if command_exists timeout; then
        out="$(timeout "$timeout_secs" du -xb --max-depth="$depth" -- "$dir" 2>/dev/null)" || true
    else
        out="$(du -xb --max-depth="$depth" -- "$dir" 2>/dev/null)" || true
    fi
    [[ -z "$out" ]] && return 1
    printf '%s\n' "$out"
}

# Files at or above min_size (e.g. "500M") under one directory: bytes<TAB>path
# lines, largest first. Bounded depth, stays on one filesystem, never
# follows symlinks, time-bounded. Prints nothing and returns 1 if the path
# doesn't exist or nothing qualifies.
get_large_files_in() {
    local dir="$1" min_size="${2:-500M}" timeout_secs="${3:-15}"
    [[ -d "$dir" ]] || return 1
    command_exists find || return 1
    local out
    if command_exists timeout; then
        out="$(timeout "$timeout_secs" find "$dir" -xdev -maxdepth 10 -type f -size "+${min_size}" -printf '%s\t%p\n' 2>/dev/null)" || true
    else
        out="$(find "$dir" -xdev -maxdepth 10 -type f -size "+${min_size}" -printf '%s\t%p\n' 2>/dev/null)" || true
    fi
    [[ -z "$out" ]] && return 1
    sort -t $'\t' -k1,1 -rn <<<"$out"
}

# One line per whole-disk block device: device|read_bytes|write_bytes.
# These are cumulative kernel counters since boot, not an instantaneous
# rate. Partitions, loop/ram/dm devices and optical drives are excluded to
# keep this to physical disks.
get_diskstats_lines() {
    [[ -r /proc/diskstats ]] || return 1
    local out
    out="$(awk '
        $3 ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$/ {
            print $3"|"($6*512)"|"($10*512)
        }
    ' /proc/diskstats)"
    [[ -z "$out" ]] && return 1
    printf '%s\n' "$out"
}
