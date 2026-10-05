#!/bin/bash
set -Eeuo pipefail

[[ "${TTT_TEST_CONTAINER:-}" == 1 &&
   "$(stat -f -c %T /srv)" == tmpfs &&
   "$(stat -f -c %T /scripts)" == tmpfs ]] ||
    { echo "Run only in the isolated container documented in README.md." >&2; exit 2; }
[[ -z "$(find /srv /scripts -mindepth 1 -print -quit)" ]] ||
    { echo "Test mounts must be empty; refusing to remove existing data." >&2; exit 2; }

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
boot_pid=""
passed=0
stop_boot() {
    kill -TERM "$boot_pid"
    wait "$boot_pid"
    boot_pid=""
}
cleanup() {
    if [[ -n "$boot_pid" ]] && kill -0 "$boot_pid" 2>/dev/null; then stop_boot; fi
    rm -rf -- "$work"
}
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; [[ ! -f "$work/run.log" ]] || cat "$work/run.log" >&2; exit 1; }
pass() { passed=$((passed+1)); echo "PASS: $*"; }
export REAL_CP="$(command -v cp)" REAL_TEE="$(command -v tee)"
mkdir "$work/bin"
cp "$repo"/scripts/*.sh /scripts/
for file in /scripts/*.sh "$repo/tests/update-release.sh"; do bash -n "$file"; done

make_install() {
    local path="$1" build="$2" flags="${3:-4}"
    mkdir -p "$path/steamapps" "$path/ttt" "$path/valve"
    printf '#!/bin/bash\nexit 0\n' > "$path/hlds_linux"
    chmod +x "$path/hlds_linux"
    printf '"AppState"\n{\n"appid" "4753110"\n"StateFlags" "%s"\n"buildid" "%s"\n}\n' \
        "$flags" "$build" > "$path/steamapps/appmanifest_4753110.acf"
}
export -f make_install

cat > "$work/bin/steamcmd" <<'STUB'
#!/bin/bash
set -Eeuo pipefail
count=0
[[ ! -f /srv/mock-calls ]] || count="$(</srv/mock-calls)"
count=$((count+1))
printf '%s\n' "$count" > /srv/mock-calls
printf '%s\n' "$*" >> /srv/mock-args
case "$MOCK_CASE" in
    failure) echo "Login failed" >&2; exit 42 ;;
    false-success) echo "Success! App '4753110' already up to date."; exit 42 ;;
    no-confirmation) exit 0 ;;
    wrong-app) echo "Success! App '70' fully installed."; exit 0 ;;
    incomplete) make_install /srv/staging "$MOCK_BUILD" 6 ;;
    retry)
        if [[ "$count" == 1 ]]; then echo "Login failed" >&2; exit 42; fi
        make_install /srv/staging "$MOCK_BUILD"
        ;;
    clean)
        if [[ "$count" -lt 3 ]]; then echo "Install failed" >&2; exit 42; fi
        [[ ! -e /srv/staging/old-content ]] || exit 43
        make_install /srv/staging "$MOCK_BUILD"
        ;;
    success) make_install /srv/staging "$MOCK_BUILD" ;;
    *) echo "Unknown mock mode: $MOCK_CASE" >&2; exit 99 ;;
esac
echo "Success! App '4753110' fully installed."
STUB
cat > "$work/bin/tee" <<'STUB'
#!/bin/bash
set -Eeuo pipefail
"$REAL_TEE" "$@"
if [[ "${MOCK_TEE_FAILURE:-0}" == 1 ]]; then exit 73; fi
STUB
cat > "$work/bin/cp" <<'STUB'
#!/bin/bash
set -Eeuo pipefail
if [[ "${MOCK_COPY_FAILURE:-0}" == 1 && "$*" == *--reflink=auto* ]]; then
    target="${@: -1}"
    [[ -f "$target/.managed-release" ]] || exit 99
    touch "$target/partial-copy"
    exit 74
fi
exec "$REAL_CP" "$@"
STUB
cat > "$work/bin/sleep" <<'STUB'
#!/bin/bash
case "$1" in 15|2) exit 0 ;; esac
exec /bin/sleep "$@"
STUB
cat > /scripts/start-server.sh <<'STUB'
#!/bin/bash
trap 'exit 0' INT TERM
while :; do /bin/sleep 0.1; done
STUB
printf '#!/bin/bash\nexit 0\n' > /scripts/healthcheck.sh
chmod +x "$work/bin/"* /scripts/*.sh
export PATH="$work/bin:$PATH"

reset_case() {
    find /srv -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    rm -f /tmp/game-serving
    mkdir -p /srv/releases /srv/steam-home/client/linux32
    touch /srv/steam-home/client/linux32/steamclient.so
    make_install /srv/staging 100
    export HOME=/srv/steam-home APPID=4753110 GAME_DIR=ttt RELEASE_ID=r300
    export ACTIVE_BUILD=100 FORCE=0 VALIDATE=0 MOCK_CASE=success MOCK_BUILD=100
    export MOCK_TEE_FAILURE=0 MOCK_COPY_FAILURE=0
}
run_update() {
    local expected="$1" result
    if bash /scripts/update-release.sh > "$work/run.log" 2>&1; then
        result=0
    else
        result=$?
    fi
    [[ "$result" == "$expected" ]] || fail "Expected exit $expected, got $result"
}
assert_calls() {
    local count=0
    [[ ! -f /srv/mock-calls ]] || count="$(</srv/mock-calls)"
    [[ "$count" == "$1" ]] || fail "Expected $1 Steam calls, got $count"
}
assert_no_snapshot() {
    [[ ! -e /srv/releases/r300/.ready ]] || fail "Failure promoted a snapshot"
    ! grep -q 'nothing to stage' "$work/run.log" || fail "Failure reported no change"
}

for mode in failure false-success no-confirmation wrong-app incomplete; do
    reset_case
    export MOCK_CASE="$mode"
    printf "Success! App '4753110' already up to date.\n" > /srv/.steam-update.log
    run_update 1
    assert_calls 3
    assert_no_snapshot
    pass "$mode cannot succeed using a stale complete manifest or old log"
done

reset_case
export MOCK_TEE_FAILURE=1
run_update 1
assert_calls 3
assert_no_snapshot
pass "log capture failure is not ignored"

for operation in force validate; do
    reset_case
    export MOCK_CASE=failure FORCE=1
    [[ "$operation" != validate ]] || export VALIDATE=1
    run_update 1
    assert_calls 3
    assert_no_snapshot
    pass "failed $operation cannot snapshot the old complete installation"
done

reset_case
run_update 10
assert_calls 1
[[ ! -e /srv/releases/r300 ]] || fail "No-change update copied a release"
pass "successful unchanged build skips snapshotting"

reset_case
export FORCE=1 VALIDATE=1
run_update 0
assert_calls 1
[[ -f /srv/releases/r300/.ready ]] || fail "Forced validation did not stage a release"
grep -q '+app_update 4753110 validate' /srv/mock-args || fail "Validation was not requested"
pass "successful forced validation stages the same build"

for mode in retry clean; do
    reset_case
    export MOCK_CASE="$mode" MOCK_BUILD=200
    touch /srv/staging/old-content
    run_update 0
    if [[ "$mode" == retry ]]; then assert_calls 2; else assert_calls 3; fi
    [[ "$(< /srv/releases/r300/.build)" == 200 &&
       -f /srv/releases/r300/.managed-release &&
       -f /srv/releases/r300/.ready ]] || fail "Recovery did not stage a complete new release"
    pass "$mode recovery stages the new build"
done

for kind in directory file symlink dangling marker-symlink current previous parent-symlink; do
    reset_case
    case "$kind" in
        directory) mkdir /srv/releases/r300; touch /srv/releases/r300/keep ;;
        file) touch /srv/releases/r300 ;;
        symlink)
            mkdir /srv/foreign
            touch /srv/foreign/.managed-release /srv/foreign/keep
            ln -s /srv/foreign /srv/releases/r300
            ;;
        dangling) ln -s /srv/missing /srv/releases/r300 ;;
        marker-symlink)
            mkdir /srv/releases/r300
            touch /srv/foreign-marker /srv/releases/r300/keep
            ln -s /srv/foreign-marker /srv/releases/r300/.managed-release
            ;;
        current|previous)
            mkdir /srv/releases/r300
            touch /srv/releases/r300/.managed-release /srv/releases/r300/keep
            ln -s releases/r300 "/srv/$kind"
            ;;
        parent-symlink)
            mv /srv/releases /srv/foreign-releases
            ln -s /srv/foreign-releases /srv/releases
            mkdir /srv/releases/r300
            touch /srv/releases/r300/.managed-release /srv/releases/r300/keep
            ;;
    esac
    run_update 1
    assert_calls 0
    [[ -e /srv/releases/r300 || -L /srv/releases/r300 ]] || fail "Updater removed $kind target"
    source /scripts/release-helpers.sh
    if remove_release r300 >> "$work/run.log" 2>&1; then fail "Cleanup accepted $kind target"; fi
    [[ -e /srv/releases/r300 || -L /srv/releases/r300 ]] || fail "Cleanup removed $kind target"
    pass "$kind target is protected in update and cleanup"
done

reset_case
export FORCE=1 MOCK_COPY_FAILURE=1
run_update 74
[[ -f /srv/releases/r300/.managed-release &&
   -f /srv/releases/r300/partial-copy &&
   ! -e /srv/releases/r300/.ready ]] || fail "Interrupted copy lacks a safe retry marker"
export MOCK_COPY_FAILURE=0
run_update 0
[[ -f /srv/releases/r300/.ready &&
   ! -e /srv/releases/r300/partial-copy ]] || fail "Interrupted snapshot was not rebuilt"
pass "interrupted snapshot remains managed and can be retried"

start_boot() {
    export RUNTIME_IMAGE=test-image
    mkdir -p /srv/releases/r100
    touch /srv/releases/r100/.managed-release /srv/releases/r100/.ready
    printf '100\n' > /srv/releases/r100/.build
    printf '%s\n' "$RUNTIME_IMAGE" > /srv/releases/r100/.image
    ln -s releases/r100 /srv/current
    printf 'r300\n' > /srv/pending
    bash /scripts/boot.sh > "$work/run.log" 2>&1 &
    boot_pid=$!
    for ((i=0; i<100; i++)); do
        if grep -q 'READY: build 100' "$work/run.log"; then return 0; fi
        kill -0 "$boot_pid" 2>/dev/null || fail "Boot exited before READY"
        /bin/sleep 0.05
    done
    fail "Boot did not reach READY"
}

reset_case
mkdir /srv/releases/r300
touch /srv/releases/r300/.managed-release /srv/releases/r300/partial-copy
start_boot
[[ ! -e /srv/pending && ! -e /srv/releases/r300 ]] || fail "No-change cleanup left pending snapshot"
[[ "$(readlink /srv/current)" == releases/r100 ]] || fail "No-change cleanup changed current"
stop_boot
pass "boot no-change cleanup removes only the managed pending snapshot"

reset_case
export MOCK_CASE=failure
start_boot
assert_calls 3
grep -q 'WARNING: Steam update failed' "$work/run.log" || fail "Boot hid update failure"
! grep -q 'Already current' "$work/run.log" || fail "Boot reported failed check as current"
[[ "$(readlink /srv/current)" == releases/r100 && -f /srv/pending ]] ||
    fail "Failed update did not preserve installed release and retry state"
stop_boot
pass "boot falls back explicitly after failed checks"

reset_case
mkdir /srv/releases/r300
touch /srv/releases/r300/keep
start_boot
assert_calls 0
[[ -f /srv/releases/r300/keep && -f /srv/pending ]] || fail "Boot removed unrecognized pending data"
stop_boot
pass "boot leaves unrecognized pending data untouched and serves installed release"

echo "All $passed regression checks passed."
