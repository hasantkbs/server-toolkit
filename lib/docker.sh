#!/usr/bin/env bash
# docker.sh - Docker data collection for `docker-info`
#
# Intended to be sourced after common.sh. All commands are single-shot and
# read-only: no per-container docker calls, no docker stats streaming, no
# mutating operations (prune/restart/rm/etc).
#
# shellcheck disable=SC2034 # DOCKER_* globals below are consumed by bin/docker-info

# True if the docker CLI exists and the daemon answers.
docker_available() {
    command_exists docker && docker info >/dev/null 2>&1
}

# Prints "running" or "unavailable".
get_docker_daemon_state() {
    if docker_available; then
        printf 'running'
    else
        printf 'unavailable'
    fi
}

# Prints the Docker Compose plugin version (e.g. "v5.4.0"), or empty if the
# plugin isn't installed.
get_compose_version() {
    safe_run docker compose version --short || printf ''
}

# Prints "images_total volumes_total" using docker system df, or "N/A N/A"
# if the daemon is unreachable.
get_docker_disk_counts() {
    local df_json
    if ! df_json="$(docker system df --format '{{json .}}' 2>/dev/null)"; then
        printf 'N/A N/A'
        return
    fi
    local images_total volumes_total
    images_total="$(jq -r 'select(.Type=="Images") | .TotalCount' <<<"$df_json" 2>/dev/null)"
    volumes_total="$(jq -r 'select(.Type=="Local Volumes") | .TotalCount' <<<"$df_json" 2>/dev/null)"
    printf '%s %s' "${images_total:-N/A}" "${volumes_total:-N/A}"
}

# One line per docker-system-df category: Type|Size|Reclaimable
get_docker_disk_usage_lines() {
    local df_json
    df_json="$(docker system df --format '{{json .}}' 2>/dev/null)" || return 1
    [[ -z "$df_json" ]] && return 1
    jq -r '[.Type, .Size, .Reclaimable] | join("|")' <<<"$df_json" 2>/dev/null
}

# Prints the total number of Docker networks (0 if none / unreachable).
get_docker_network_count() {
    local out
    out="$(docker network ls -q 2>/dev/null)" || { printf '0'; return; }
    [[ -z "$out" ]] && { printf '0'; return; }
    wc -l <<<"$out" | tr -d '[:space:]'
}

# One line per network: Name|Driver|ContainerCount
get_docker_network_lines() {
    local ids
    ids="$(docker network ls -q 2>/dev/null)" || return 1
    [[ -z "$ids" ]] && return 1
    # shellcheck disable=SC2086 # intentional word-splitting: network IDs, one arg each
    docker network inspect $ids --format '{{.Name}}|{{.Driver}}|{{len .Containers}}' 2>/dev/null
}

# One line per volume: Name|Driver
get_docker_volume_lines() {
    local out
    out="$(docker volume ls --format '{{.Name}}|{{.Driver}}' 2>/dev/null)" || return 1
    [[ -z "$out" ]] && return 1
    printf '%s\n' "$out"
}

# The N largest images by size: one line per image, "Repository:Tag|Size",
# largest first. Sizing comes straight from `docker images` (no filesystem
# scanning).
get_docker_largest_images() {
    local n="${1:-3}"
    local out
    out="$(docker images --format '{{.Repository}}:{{.Tag}}|{{.Size}}' 2>/dev/null)" || return 1
    [[ -z "$out" ]] && return 1

    while IFS='|' read -r repo size; do
        [[ -z "$repo" ]] && continue
        local bytes
        bytes="$(docker_size_to_bytes "$size")" || bytes=0
        printf '%s\t%s\t%s\n' "$bytes" "$repo" "$size"
    done <<<"$out" | sort -t $'\t' -k1,1 -rn | cut -f2- | awk -F'\t' -v n="$n" 'NR<=n'
}

# Converts a Docker-formatted size like "180MiB", "15.62GiB", "8.916GB" or
# "512B" to an integer byte count. Handles both the binary (Ki/Mi/Gi/Ti)
# units used by `docker stats` and the decimal (k/M/G/T) units used by
# `docker images` / `docker system df`. Prints nothing and returns 1 on
# unparseable input.
docker_size_to_bytes() {
    local raw="$1" num unit mult
    if [[ "$raw" =~ ^([0-9]+(\.[0-9]+)?)([A-Za-z]+)$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[3]}"
    else
        return 1
    fi
    case "$unit" in
        B) mult=1 ;;
        kB|KB) mult=1000 ;;
        KiB) mult=1024 ;;
        MB) mult=1000000 ;;
        MiB) mult=1048576 ;;
        GB) mult=1000000000 ;;
        GiB) mult=1073741824 ;;
        TB) mult=1000000000000 ;;
        TiB) mult=1099511627776 ;;
        *) return 1 ;;
    esac
    awk -v n="$num" -v m="$mult" 'BEGIN{printf "%.0f", n*m}'
}

# Normalizes a raw docker health string ("healthy", "unhealthy", "starting",
# "none", "" or anything unexpected) into one of our five states.
docker_normalize_health() {
    case "${1:-}" in
        healthy) printf 'healthy' ;;
        unhealthy) printf 'unhealthy' ;;
        starting) printf 'starting' ;;
        none|'') printf 'no-healthcheck' ;;
        *) printf 'unknown' ;;
    esac
}

# Populates the following globals describing every container (running or
# not); returns 1 if Docker is unavailable or there are no containers:
#   DOCKER_NAMES               ordered array of container names
#   DOCKER_STATUS[name]        e.g. "Up 2 hours"
#   DOCKER_HEALTH[name]        healthy | unhealthy | starting | no-healthcheck | unknown
#   DOCKER_RESTARTS[name]      integer restart count
#   DOCKER_CPU[name]           "1.2%" or "-" if not running
#   DOCKER_MEM[name]           "180MiB" or "-" if not running
#   DOCKER_MEMPCT[name]        "1.2%" or "-" if not running
#   DOCKER_TOTAL_CPU_PCT       sum of CPU% across containers with live stats
#   DOCKER_TOTAL_MEM_BYTES     sum of used memory (bytes) across live stats
collect_docker_containers() {
    DOCKER_NAMES=()
    declare -gA DOCKER_STATUS=() DOCKER_HEALTH=() DOCKER_RESTARTS=() \
        DOCKER_CPU=() DOCKER_MEM=() DOCKER_MEMPCT=()
    DOCKER_TOTAL_CPU_PCT=""
    DOCKER_TOTAL_MEM_BYTES=""

    local ps_lines
    ps_lines="$(docker ps -a --format '{{.Names}}|{{.Status}}' 2>/dev/null)" || return 1
    [[ -z "$ps_lines" ]] && return 1

    local name status
    while IFS='|' read -r name status; do
        [[ -z "$name" ]] && continue
        DOCKER_NAMES+=("$name")
        DOCKER_STATUS["$name"]="${status%% (*}"
        DOCKER_HEALTH["$name"]="no-healthcheck"
        DOCKER_RESTARTS["$name"]="0"
        DOCKER_CPU["$name"]="-"
        DOCKER_MEM["$name"]="-"
        DOCKER_MEMPCT["$name"]="-"
    done <<<"$ps_lines"

    local ids
    ids="$(docker ps -aq 2>/dev/null)"
    if [[ -n "$ids" ]]; then
        local inspect_lines iname restarts health
        # shellcheck disable=SC2086 # intentional word-splitting: container IDs, one arg each
        inspect_lines="$(docker inspect $ids \
            --format '{{.Name}}|{{.RestartCount}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
            2>/dev/null)" || inspect_lines=""
        while IFS='|' read -r iname restarts health; do
            [[ -z "$iname" ]] && continue
            iname="${iname#/}"
            DOCKER_RESTARTS["$iname"]="${restarts:-0}"
            DOCKER_HEALTH["$iname"]="$(docker_normalize_health "$health")"
        done <<<"$inspect_lines"
    fi

    local stats_lines
    stats_lines="$(docker stats --no-stream --format '{{.Name}}	{{.CPUPerc}}	{{.MemUsage}}	{{.MemPerc}}' 2>/dev/null)" || stats_lines=""
    if [[ -n "$stats_lines" ]]; then
        local sname cpu mem mempct
        while IFS=$'\t' read -r sname cpu mem mempct; do
            [[ -z "$sname" ]] && continue
            DOCKER_CPU["$sname"]="$cpu"
            DOCKER_MEM["$sname"]="${mem%% / *}"
            DOCKER_MEMPCT["$sname"]="$mempct"
        done <<<"$stats_lines"

        DOCKER_TOTAL_CPU_PCT="$(awk -F'\t' '{ c=$2; gsub("%","",c); sum+=c } END{ printf "%.1f", sum }' <<<"$stats_lines")"
        DOCKER_TOTAL_MEM_BYTES="$(awk -F'\t' '
            function tobytes(s,    n, u, mult) {
                match(s, /^[0-9.]+/)
                n = substr(s, RSTART, RLENGTH) + 0
                u = substr(s, RSTART + RLENGTH)
                if (u == "B") mult = 1
                else if (u == "KiB") mult = 1024
                else if (u == "MiB") mult = 1024 * 1024
                else if (u == "GiB") mult = 1024 * 1024 * 1024
                else if (u == "TiB") mult = 1024 * 1024 * 1024 * 1024
                else mult = 0
                return n * mult
            }
            {
                split($3, parts, " / ")
                sum += tobytes(parts[1])
            }
            END { printf "%.0f", sum }
        ' <<<"$stats_lines")"
    fi

    return 0
}
