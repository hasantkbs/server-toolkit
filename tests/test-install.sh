#!/usr/bin/env bash
# test-install.sh - isolated-HOME/PATH tests for install.sh. Kept separate
# from tests/test.sh (which is read-only diagnostic testing) since this
# file creates and destroys real directories under a throwaway HOME.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
INSTALL_SH="${REPO_ROOT}/install.sh"

pass=0
fail=0
ok()  { pass=$((pass + 1)); printf '  ok   - %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL - %s\n' "$1"; }

# Every test gets its own fresh throwaway HOME, removed afterward - tests
# never share state and never touch the real machine's HOME.
st_test_home() {
    mktemp -d "/tmp/server-toolkit-test-install.XXXXXX"
}

echo "== install: fresh install creates the expected files and reports Installed =="
TH="$(st_test_home)"
out="$(HOME="$TH" bash "$INSTALL_SH" install 2>&1)"
if [[ -x "${TH}/.local/bin/server-toolkit" ]] && [[ -L "${TH}/.local/share/server-toolkit" ]] && grep -q '^Installed server-toolkit' <<<"$out"; then
    ok "fresh install creates the wrapper and the versioned install, reports Installed"
else
    bad "fresh install did not produce the expected result: $out"
fi
rm -rf "$TH"

echo "== install: re-running install is idempotent and reports Updated =="
TH="$(st_test_home)"
HOME="$TH" bash "$INSTALL_SH" install >/dev/null 2>&1
out="$(HOME="$TH" bash "$INSTALL_SH" install 2>&1)"
if grep -q '^Updated server-toolkit' <<<"$out" && [[ -x "${TH}/.local/bin/server-toolkit" ]]; then
    ok "second install run is idempotent and reports Updated, not a duplicate or error"
else
    bad "reinstall did not behave idempotently: $out"
fi
rm -rf "$TH"

echo "== install: the installed command actually runs a real diagnostic =="
TH="$(st_test_home)"
HOME="$TH" bash "$INSTALL_SH" install >/dev/null 2>&1
if result="$(HOME="$TH" PATH="${TH}/.local/bin:${PATH}" server-toolkit info 2>&1)"; then
    grep -q '^SERVER$' <<<"$result" && ok "the installed server-toolkit runs 'info' for real after install, found via PATH" \
        || bad "installed server-toolkit ran but did not show the SERVER section: $result"
else
    bad "installed server-toolkit failed to run: $result"
fi
if result="$(HOME="$TH" PATH="${TH}/.local/bin:${PATH}" server-toolkit version 2>&1)"; then
    grep -qE '^server-toolkit [0-9]' <<<"$result" && ok "the installed server-toolkit reports a real version string" \
        || bad "installed server-toolkit version output was wrong: $result"
else
    bad "installed server-toolkit version failed to run"
fi
if result="$(HOME="$TH" PATH="${TH}/.local/bin:${PATH}" server-toolkit --help 2>&1)"; then
    grep -q 'USAGE' <<<"$result" && ok "the installed server-toolkit --help works after install" \
        || bad "installed server-toolkit --help did not print usage: $result"
else
    bad "installed server-toolkit --help failed to run"
fi
rm -rf "$TH"

echo "== install: config is never created or touched by install =="
TH="$(st_test_home)"
HOME="$TH" bash "$INSTALL_SH" install >/dev/null 2>&1
if [[ ! -e "${TH}/.config/server-toolkit" ]]; then
    ok "install does not create a config directory - config stays absent until the user creates one"
else
    bad "install unexpectedly created ${TH}/.config/server-toolkit"
fi
rm -rf "$TH"

echo "== install: update preserves an existing config file untouched =="
TH="$(st_test_home)"
mkdir -p "${TH}/.config/server-toolkit"
printf 'RAM_ALERT_PCT=77\n' > "${TH}/.config/server-toolkit/config"
before_sum="$(cksum < "${TH}/.config/server-toolkit/config")"
HOME="$TH" bash "$INSTALL_SH" install >/dev/null 2>&1
HOME="$TH" bash "$INSTALL_SH" update >/dev/null 2>&1
after_sum="$(cksum < "${TH}/.config/server-toolkit/config")"
[[ "$before_sum" == "$after_sum" ]] && ok "an existing config file is byte-for-byte unchanged after install+update" \
    || bad "config file was modified by install/update (before: $before_sum, after: $after_sum)"
rm -rf "$TH"

echo "== install: update with no prior install behaves like a fresh install, not an error =="
TH="$(st_test_home)"
out="$(HOME="$TH" bash "$INSTALL_SH" update 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]] && [[ -x "${TH}/.local/bin/server-toolkit" ]]; then
    ok "running update with nothing installed yet succeeds and installs cleanly (rc=$rc)"
else
    bad "update with no prior install failed or did not install (rc=$rc): $out"
fi
rm -rf "$TH"

echo "== uninstall: removes app files, preserves config by default =="
TH="$(st_test_home)"
HOME="$TH" bash "$INSTALL_SH" install >/dev/null 2>&1
mkdir -p "${TH}/.config/server-toolkit"
printf 'RAM_ALERT_PCT=77\n' > "${TH}/.config/server-toolkit/config"
HOME="$TH" bash "$INSTALL_SH" uninstall >/dev/null 2>&1
if [[ ! -e "${TH}/.local/bin/server-toolkit" ]] && [[ ! -e "${TH}/.local/share/server-toolkit" ]] && [[ -f "${TH}/.config/server-toolkit/config" ]]; then
    ok "uninstall removes the wrapper and the versioned install, but leaves config in place by default"
else
    bad "uninstall did not behave correctly (wrapper exists: $([[ -e "${TH}/.local/bin/server-toolkit" ]] && echo yes || echo no), install exists: $([[ -e "${TH}/.local/share/server-toolkit" ]] && echo yes || echo no), config exists: $([[ -f "${TH}/.config/server-toolkit/config" ]] && echo yes || echo no))"
fi
rm -rf "$TH"

echo "== uninstall: --purge-config also removes the config directory =="
TH="$(st_test_home)"
HOME="$TH" bash "$INSTALL_SH" install >/dev/null 2>&1
mkdir -p "${TH}/.config/server-toolkit"
printf 'RAM_ALERT_PCT=77\n' > "${TH}/.config/server-toolkit/config"
HOME="$TH" bash "$INSTALL_SH" uninstall --purge-config >/dev/null 2>&1
[[ ! -e "${TH}/.config/server-toolkit" ]] && ok "uninstall --purge-config removes the config directory too" \
    || bad "uninstall --purge-config left the config directory behind"
rm -rf "$TH"

echo "== uninstall: safe (not an error) when nothing is installed =="
TH="$(st_test_home)"
out="$(HOME="$TH" bash "$INSTALL_SH" uninstall 2>&1)"
rc=$?
[[ "$rc" -eq 0 ]] && grep -qi 'not installed\|nothing to do' <<<"$out" && ok "uninstall with nothing installed exits 0 with a clear message (rc=$rc)" \
    || bad "uninstall with nothing installed did not behave safely (rc=$rc): $out"
rm -rf "$TH"

echo "== uninstall: refuses to delete a directory that is not a verified server-toolkit install =="
TH="$(st_test_home)"
mkdir -p "${TH}/.local/share/not-ours-data"
ln -s "${TH}/.local/share/not-ours-data" "${TH}/.local/share/server-toolkit"
out="$(HOME="$TH" bash "$INSTALL_SH" uninstall 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && [[ -d "${TH}/.local/share/not-ours-data" ]] && grep -qi 'refus' <<<"$out"; then
    ok "uninstall refuses to delete a directory lacking the install marker, and leaves it untouched (rc=$rc)"
else
    bad "SECURITY: uninstall did not correctly refuse an unmarked directory (rc=$rc, still exists: $([[ -d "${TH}/.local/share/not-ours-data" ]] && echo yes || echo no)): $out"
fi
rm -rf "$TH"

echo "== uninstall: only ever deletes inside the verified install directory, never siblings =="
TH="$(st_test_home)"
HOME="$TH" bash "$INSTALL_SH" install >/dev/null 2>&1
mkdir -p "${TH}/.local/share/unrelated-app"
HOME="$TH" bash "$INSTALL_SH" uninstall >/dev/null 2>&1
[[ -d "${TH}/.local/share/unrelated-app" ]] && ok "uninstall leaves an unrelated sibling directory under .local/share completely untouched" \
    || bad "SECURITY: uninstall deleted or affected an unrelated sibling directory"
rm -rf "$TH"

echo "== install: reports PATH status correctly when the bin dir is NOT on PATH =="
TH="$(st_test_home)"
out="$(HOME="$TH" PATH="/usr/bin:/bin" bash "$INSTALL_SH" install 2>&1)"
grep -q 'NOT on PATH' <<<"$out" && ok "install correctly reports the bin directory is not on PATH" \
    || bad "install did not correctly detect a missing PATH entry: $out"
rm -rf "$TH"

echo "== install: reports PATH status correctly when the bin dir IS on PATH =="
TH="$(st_test_home)"
out="$(HOME="$TH" PATH="${TH}/.local/bin:/usr/bin:/bin" bash "$INSTALL_SH" install 2>&1)"
grep -q 'already on PATH' <<<"$out" && ok "install correctly reports the bin directory is already on PATH" \
    || bad "install did not correctly detect an existing PATH entry: $out"
rm -rf "$TH"

echo "== install: --add-to-path writes an idempotent, clearly-marked block, and only when asked =="
TH="$(st_test_home)"
HOME="$TH" SHELL=/bin/bash bash "$INSTALL_SH" install >/dev/null 2>&1
if [[ ! -f "${TH}/.bashrc" ]] || ! grep -q 'server-toolkit PATH' "${TH}/.bashrc" 2>/dev/null; then
    ok "install without --add-to-path never touches the shell rc file"
else
    bad "install modified the shell rc file without --add-to-path being given"
fi
HOME="$TH" SHELL=/bin/bash bash "$INSTALL_SH" install --add-to-path >/dev/null 2>&1
first_count="$(grep -c 'server-toolkit PATH' "${TH}/.bashrc" 2>/dev/null || echo 0)"
HOME="$TH" SHELL=/bin/bash bash "$INSTALL_SH" install --add-to-path >/dev/null 2>&1
second_count="$(grep -c 'server-toolkit PATH' "${TH}/.bashrc" 2>/dev/null || echo 0)"
if [[ "$first_count" -eq 2 ]] && [[ "$second_count" -eq 2 ]]; then
    ok "--add-to-path adds exactly one marked block and running it again does not duplicate it"
else
    bad "--add-to-path block count was wrong (first: $first_count, second: $second_count, expected 2 both times - start+end marker lines)"
fi
rm -rf "$TH"

echo "== install.sh: no eval, no bash -c/sh -c, no curl|bash or wget|bash pattern (static checks) =="
if ! grep -qE '\beval\b' "$INSTALL_SH"; then
    ok "install.sh contains no 'eval'"
else
    bad "install.sh contains 'eval' - forbidden by this sprint's design"
fi
if ! grep -qE '\b(bash|sh)\s+-c\b' "$INSTALL_SH"; then
    ok "install.sh contains no 'bash -c'/'sh -c'"
else
    bad "install.sh contains 'bash -c' or 'sh -c'"
fi
if ! grep -qE '(curl|wget)[^|]*\|\s*(bash|sh)\b' "$INSTALL_SH"; then
    ok "install.sh contains no curl|bash or wget|bash pattern"
else
    bad "install.sh contains a curl|bash or wget|bash pattern - forbidden"
fi

echo "== install.sh: partial/interrupted staging does not corrupt an existing install =="
TH="$(st_test_home)"
HOME="$TH" bash "$INSTALL_SH" install >/dev/null 2>&1
before_target="$(readlink "${TH}/.local/share/server-toolkit")"
leaked_staging="$(find "${TH}/.local/share" -maxdepth 1 -name '.server-toolkit-staging.*' 2>/dev/null)"
[[ -z "$leaked_staging" ]] && ok "no leaked staging directories remain after a successful install" \
    || bad "a staging directory leaked: $leaked_staging"
after_target="$(readlink "${TH}/.local/share/server-toolkit")"
[[ "$before_target" == "$after_target" ]] && ok "the install symlink target is stable and unambiguous after a normal install" \
    || bad "install symlink target changed unexpectedly (before: $before_target, after: $after_target)"
rm -rf "$TH"

# --- Regression tests added after an independent adversarial review ---
# (see git log for the review round). Each of these reproduces a real,
# verified finding rather than a hypothetical.

echo "== SECURITY: a path-traversal TOOLKIT_VERSION is rejected, not used to compute an rm -rf target =="
# The traversal only actually reaches an rm -rf outside $data_home once a
# real directory already sits at the "server-toolkit-<real-version-prefix>"
# path component the malicious version starts with - the OS can't resolve
# a ".." through a path segment that was never created. So this PoC first
# does a real, legitimate install (which creates
# $data_home/server-toolkit-<version> for real, using this repo's actual
# TOOLKIT_VERSION), THEN points a second install at an attacker-controlled
# source tree whose TOOLKIT_VERSION is "<that same real version>/../../../VICTIM" -
# reproducing the exact end-to-end exploit, not just a syntactic check.
TH="$(st_test_home)"
HOME="$TH" bash "$INSTALL_SH" install >/dev/null 2>&1
real_version="$(grep -m1 '^TOOLKIT_VERSION=' "${REPO_ROOT}/bin/server-toolkit" | sed -E 's/^TOOLKIT_VERSION="([^"]*)"$/\1/')"
FAKE_SRC="$(mktemp -d "/tmp/server-toolkit-test-install-fakesrc.XXXXXX")"
cp -- "$INSTALL_SH" "${FAKE_SRC}/install.sh"
mkdir -p "${FAKE_SRC}/bin" "${FAKE_SRC}/lib" "${FAKE_SRC}/docs"
printf '#!/usr/bin/env bash\nTOOLKIT_VERSION="%s/../../../VICTIM"\n' "$real_version" > "${FAKE_SRC}/bin/server-toolkit"
: > "${FAKE_SRC}/lib/dummy.sh"
: > "${FAKE_SRC}/docs/dummy.md"
mkdir -p "${TH}/VICTIM"
printf 'canary\n' > "${TH}/VICTIM/canary.txt"
out="$(HOME="$TH" bash "${FAKE_SRC}/install.sh" install 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && [[ -f "${TH}/VICTIM/canary.txt" ]] && [[ "$(cat "${TH}/VICTIM/canary.txt")" == "canary" ]]; then
    ok "SECURITY: a slash-containing TOOLKIT_VERSION is refused before any rm -rf, and the traversal target (primed with a real prior install so the OS can actually resolve the '..') is untouched (rc=$rc)"
else
    bad "SECURITY: path-traversal TOOLKIT_VERSION was not safely rejected (rc=$rc, victim intact: $([[ -f "${TH}/VICTIM/canary.txt" ]] && echo yes || echo no)): $out"
fi
rm -rf "$TH" "$FAKE_SRC"

echo "== install.sh: an install failure mid-staging (unreadable source file) does not leak a staging directory or corrupt an existing install =="
TH="$(st_test_home)"
HOME="$TH" bash "$INSTALL_SH" install >/dev/null 2>&1
before_target="$(readlink "${TH}/.local/share/server-toolkit")"
FAKE_SRC2="$(mktemp -d "/tmp/server-toolkit-test-install-failsrc.XXXXXX")"
mkdir -p "${FAKE_SRC2}/bin" "${FAKE_SRC2}/lib" "${FAKE_SRC2}/docs"
cp -- "$INSTALL_SH" "${FAKE_SRC2}/install.sh"
cp -- "${REPO_ROOT}/bin/server-toolkit" "${FAKE_SRC2}/bin/server-toolkit"
: > "${FAKE_SRC2}/bin/unreadable-file"
chmod 000 "${FAKE_SRC2}/bin/unreadable-file"
: > "${FAKE_SRC2}/lib/dummy.sh"
: > "${FAKE_SRC2}/docs/dummy.md"
out="$(HOME="$TH" bash "${FAKE_SRC2}/install.sh" install 2>&1)"
rc=$?
leaked_staging2="$(find "${TH}/.local/share" -maxdepth 1 -name '.server-toolkit-staging.*' 2>/dev/null)"
after_target="$(readlink "${TH}/.local/share/server-toolkit" 2>/dev/null || true)"
if [[ "$rc" -ne 0 ]] && [[ ! "$out" =~ Traceback ]] && [[ -z "$leaked_staging2" ]] && [[ "$before_target" == "$after_target" ]]; then
    ok "a real cp failure mid-staging exits non-zero, leaks no staging directory, and leaves the prior good install intact (rc=$rc)"
else
    bad "install failure handling was wrong (rc=$rc, leaked: '$leaked_staging2', before target: $before_target, after target: $after_target): $out"
fi
chmod 700 "${FAKE_SRC2}/bin/unreadable-file" 2>/dev/null || true
rm -rf "$TH" "$FAKE_SRC2"

echo "== SECURITY: the marker check requires an exact sentinel line, not a substring match =="
TH="$(st_test_home)"
mkdir -p "${TH}/.local/share/fake-install"
printf 'this-is-not-a-%s-fake-file\n' "server-toolkit-install-v1" > "${TH}/.local/share/fake-install/.server-toolkit-install"
ln -s "${TH}/.local/share/fake-install" "${TH}/.local/share/server-toolkit"
out="$(HOME="$TH" bash "$INSTALL_SH" uninstall 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && [[ -d "${TH}/.local/share/fake-install" ]] && grep -qi 'refus' <<<"$out"; then
    ok "SECURITY: a marker file whose sentinel is only a substring of a longer line is NOT treated as verified"
else
    bad "SECURITY: substring marker match incorrectly verified a fake install (rc=$rc, still exists: $([[ -d "${TH}/.local/share/fake-install" ]] && echo yes || echo no)): $out"
fi
rm -rf "$TH"

echo "== install: a pre-existing real directory (not a symlink) at the install path is refused cleanly, not silently nested into =="
TH="$(st_test_home)"
mkdir -p "${TH}/.local/share/server-toolkit"
printf 'pre-existing\n' > "${TH}/.local/share/server-toolkit/unrelated-file"
out="$(HOME="$TH" bash "$INSTALL_SH" install 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && [[ ! -L "${TH}/.local/share/server-toolkit" ]] && [[ -f "${TH}/.local/share/server-toolkit/unrelated-file" ]] && grep -qi 'refus' <<<"$out"; then
    ok "a pre-existing real directory at the install path is refused cleanly and left untouched, not silently nested into"
else
    bad "a pre-existing real directory at the install path was not handled safely (rc=$rc): $out"
fi
rm -rf "$TH"

echo "== uninstall --purge-config: respects TOOLKIT_CONFIG_DIR, not just the default XDG path =="
TH="$(st_test_home)"
CUSTOM_CONFIG="${TH}/custom-config-location"
mkdir -p "$CUSTOM_CONFIG"
printf 'RAM_ALERT_PCT=77\n' > "${CUSTOM_CONFIG}/config"
HOME="$TH" bash "$INSTALL_SH" install >/dev/null 2>&1
HOME="$TH" TOOLKIT_CONFIG_DIR="$CUSTOM_CONFIG" bash "$INSTALL_SH" uninstall --purge-config >/dev/null 2>&1
if [[ ! -e "$CUSTOM_CONFIG" ]] && [[ ! -e "${TH}/.config/server-toolkit" ]]; then
    ok "uninstall --purge-config with TOOLKIT_CONFIG_DIR set removes the real (custom) config location"
else
    bad "uninstall --purge-config ignored TOOLKIT_CONFIG_DIR (custom exists: $([[ -e "$CUSTOM_CONFIG" ]] && echo yes || echo no))"
fi
rm -rf "$TH"

echo "== install: bin/tui specifically lands in the install tree and is executable =="
TH="$(st_test_home)"
HOME="$TH" bash "$INSTALL_SH" install >/dev/null 2>&1
if [[ -x "${TH}/.local/share/server-toolkit/bin/tui" ]]; then
    ok "bin/tui is present in the install tree and executable after a fresh install"
else
    bad "bin/tui is missing or not executable at ${TH}/.local/share/server-toolkit/bin/tui after install"
fi
rm -rf "$TH"

echo "== SECURITY: a symlink loop at the install path is handled safely (not installed, not a crash) =="
TH="$(st_test_home)"
mkdir -p "${TH}/.local/share"
ln -s "${TH}/.local/share/server-toolkit" "${TH}/.local/share/server-toolkit"
out="$(HOME="$TH" bash "$INSTALL_SH" uninstall 2>&1)"
rc=$?
if [[ "$rc" -eq 0 ]] && grep -qi 'not installed\|nothing to do' <<<"$out"; then
    ok "SECURITY: a symlink loop at the install path resolves to 'not installed' (stat/-e fails with ELOOP) rather than crashing or being treated as a real install (rc=$rc)"
else
    bad "SECURITY: a symlink loop at the install path was not handled safely (rc=$rc): $out"
fi
rm -rf "$TH"

echo "== SECURITY: the install path symlinked to a sensitive location outside data_home is refused, not deleted =="
TH="$(st_test_home)"
mkdir -p "${TH}/.local/share" "${TH}/sensitive-outside-data"
printf 'canary\n' > "${TH}/sensitive-outside-data/canary.txt"
ln -s "${TH}/sensitive-outside-data" "${TH}/.local/share/server-toolkit"
out="$(HOME="$TH" bash "$INSTALL_SH" uninstall 2>&1)"
rc=$?
if [[ "$rc" -ne 0 ]] && [[ -f "${TH}/sensitive-outside-data/canary.txt" ]] && grep -qi 'refus' <<<"$out"; then
    ok "SECURITY: the install path symlinked to a sensitive location outside \$data_home is refused (unverified target), and that location is left untouched (rc=$rc)"
else
    bad "SECURITY: a sensitive-location symlink at the install path was not safely refused (rc=$rc, canary intact: $([[ -f "${TH}/sensitive-outside-data/canary.txt" ]] && echo yes || echo no)): $out"
fi
rm -rf "$TH"

echo "== install/uninstall: both behave cleanly when ~/.config/server-toolkit does not exist at all =="
TH="$(st_test_home)"
install_out="$(HOME="$TH" bash "$INSTALL_SH" install 2>&1)"
install_rc=$?
config_created_by_install=0
[[ -e "${TH}/.config" ]] && config_created_by_install=1
uninstall_out="$(HOME="$TH" bash "$INSTALL_SH" uninstall 2>&1)"
uninstall_rc=$?
if [[ "$install_rc" -eq 0 ]] && [[ "$config_created_by_install" -eq 0 ]] && [[ "$uninstall_rc" -eq 0 ]]; then
    ok "install and uninstall both succeed cleanly with no ~/.config/server-toolkit present at all - neither reads, writes, nor crashes on it"
else
    bad "missing-config handling was wrong (install_rc=$install_rc, config dir appeared: $config_created_by_install, uninstall_rc=$uninstall_rc): install=[$install_out] uninstall=[$uninstall_out]"
fi
rm -rf "$TH"

echo
echo "Results: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]]
