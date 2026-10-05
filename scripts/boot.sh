#!/bin/bash
# Release-managed startup for a GoldSrc dedicated server.
# App, game directory and ports are parameterised via environment variables.
set -Eeuo pipefail
umask 0027
source "$(dirname -- "${BASH_SOURCE[0]}")/release-helpers.sh"
cd /srv
: "${APPID:?APPID is required}"
: "${GAME_DIR:?GAME_DIR is required}"
: "${UPDATE_TIMEOUT_SECONDS:=900}"
[[ "$UPDATE_TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] ||
    { echo "UPDATE_TIMEOUT_SECONDS must be a positive integer" >&2; exit 1; }
rm -f /tmp/game-serving
mkdir -p releases persistent probes "$HOME"

child=""
stop_child() {
    if [[ -n "$child" ]]; then
        if kill -0 "$child" 2>/dev/null; then
            kill -TERM "$child"
            for ((n=0; n<20; n++)); do
                kill -0 "$child" 2>/dev/null || break
                sleep 1
            done
            if kill -0 "$child" 2>/dev/null; then
                echo "Child did not stop gracefully; terminating it." >&2
                kill -KILL "$child"
            fi
        fi
        if wait "$child"; then :; else echo "Stopped child (exit $?)."; fi
        child=""
    fi
}
shutdown() { trap - INT TERM; rm -f /tmp/game-serving; stop_child; exit 0; }
trap shutdown INT TERM
trap 'rc=$?; trap - EXIT; rm -f /tmp/game-serving; stop_child; exit "$rc"' EXIT

exec 8>/srv/.lifecycle.lock
flock -n 8 || { echo "Another server is already using this installation" >&2; exit 1; }

get_release() {
    local value
    value="$(readlink "/srv/$1")"
    [[ "$value" =~ ^releases/r[0-9]+$ && -f "/srv/$value/.ready" ]] ||
        { echo "Invalid $1 release: $value" >&2; return 1; }
    printf '%s\n' "${value#releases/}"
}
set_release() { ln -sfn "releases/$1" "/srv/$2.next"; mv -Tf "/srv/$2.next" "/srv/$2"; }
probe_child() {
    local good=0
    for ((n=0; n<60; n++)); do
        kill -0 "$child" 2>/dev/null || return 1
        if /bin/bash /scripts/healthcheck.sh --probe >/dev/null 2>&1; then
            good=$((good+1)); [[ "$good" -ge 3 ]] && return 0
        else
            good=0
        fi
        sleep 2
    done
    echo "Game did not become responsive within the startup window." >&2
    return 1
}
start_game() {
    GAME_RELEASE="$1" GAME_PREFLIGHT="${2:-0}" SERVER_IP="${3:-0.0.0.0}" \
        /bin/bash /scripts/start-server.sh &
    child=$!
}
prune() {
    local path name
    for path in /srv/releases/r*; do
        [[ -d "$path" && ! -L "$path" && -f "$path/.managed-release" ]] || continue
        name="${path##*/}"
        [[ "$name" == "$active" || "$name" == "$previous" || "$name" == "$pending" ]] && continue
        remove_release "$name"
    done
}

active="" previous="" pending="" candidate="" force=0 validate=0 manual_rollback=0
[[ -L current  ]] && active="$(get_release current)"
[[ -L previous ]] && previous="$(get_release previous)"
if [[ -f pending ]]; then
    pending="$(<pending)"
    [[ "$pending" =~ ^r[0-9]+$ ]] || { echo "Invalid pending release" >&2; exit 1; }
    if [[ "$pending" == "$active" || "$pending" == "$previous" ]]; then rm pending; pending=""; fi
fi
if [[ -f .rollback-next-start ]]; then
    [[ -n "$previous" ]] || { echo "Rollback requested but no previous release exists" >&2; exit 1; }
    manual_rollback=1; candidate="$previous"; rm .rollback-next-start
    echo "Manual rollback requested; skipping Steam update on this start."
else
    [[ -f .force-next-start    ]] && { force=1; rm .force-next-start; }
    [[ -f .validate-next-start ]] && { validate=1; force=1; rm .validate-next-start; }
fi

if [[ "$manual_rollback" == 0 && ( "${UPDATE_ON_START:-1}" == 1 || -z "$active" ) ]]; then
    if [[ -z "$pending" ]]; then
        pending="r$(date -u +%Y%m%d%H%M%S%N)"
        printf '%s\n' "$pending" > pending
    fi
    prune
    # Tell the updater which build is already running so it can skip snapshotting
    # a release we would only discard. Left empty when the runtime image changed
    # or an update was forced, because then a fresh release is wanted regardless.
    active_build=""
    if [[ -n "$active" && "$force" == 0 &&
          "${RUNTIME_IMAGE:?RUNTIME_IMAGE is required}" == "$(<"releases/$active/.image")" ]]; then
        active_build="$(<"releases/$active/.build")"
    fi
    echo "Checking Steam for dedicated-server AppID $APPID updates on container start."
    RELEASE_ID="$pending" VALIDATE="$validate" FORCE="$force" ACTIVE_BUILD="$active_build" \
        timeout --signal=TERM --kill-after=10 "$UPDATE_TIMEOUT_SECONDS" \
        /bin/bash /scripts/update-release.sh &
    child=$!
    if wait "$child"; then result=0; else result=$?; fi
    child=""
    if [[ "$result" == 0 ]]; then
        printf '%s\n' "$RUNTIME_IMAGE" > "releases/$pending/.image"
        build="$(<"releases/$pending/.build")"
        if [[ -f rejected-build && "$(<rejected-build)" == "$build|$RUNTIME_IMAGE" && "$force" == 0 ]]; then
            echo "Build $build previously failed startup; keeping the known-good release." >&2
            remove_release "$pending"; rm -f pending; pending=""
        else
            candidate="$pending"
        fi
    elif [[ "$result" == 10 ]]; then
        echo "Already current at build $active_build."
        remove_release "$pending"; rm -f pending; pending=""
    else
        echo "WARNING: Steam update failed or timed out (exit $result); starting the installed release. Staged download is retained." >&2
    fi
elif [[ "$manual_rollback" == 0 ]]; then
    echo "Automatic updates explicitly disabled by UPDATE_ON_START."
fi

if [[ -n "$candidate" && "$manual_rollback" == 0 ]]; then
    echo "Preflight build $(<"releases/$candidate/.build") on loopback only."
    start_game "$candidate" 1 127.0.0.1
    if probe_child; then
        stop_child; rm -rf -- "probes/$candidate"
    else
        echo "Candidate failed preflight; the installed release is unchanged." >&2
        stop_child
        printf '%s|%s\n' "$(<"releases/$candidate/.build")" "$RUNTIME_IMAGE" > rejected-build
        candidate=""
    fi
fi

old="$active"; old_previous="$previous"
if [[ -n "$candidate" ]]; then
    [[ -n "$old" ]] && { set_release "$old" previous; previous="$old"; }
    set_release "$candidate" current
    active="$candidate"
fi
[[ -n "$active" ]] || { echo "No usable release is installed; inspect the update failure above." >&2; exit 1; }

echo "Launching public server from $active."
start_game "$active"
if ! probe_child; then
    stop_child
    fallback="$previous"
    if [[ -z "$fallback" || "$fallback" == "$active" ]]; then
        echo "Server startup failed and no alternate release is available." >&2; exit 1
    fi
    echo "WARNING: Public startup failed; rolling back to $fallback." >&2
    printf '%s|%s\n' "$(<"releases/$active/.build")" "$RUNTIME_IMAGE" > rejected-build
    set_release "$fallback" current; active="$fallback"
    if [[ -n "$candidate" && -n "$old_previous" ]]; then
        set_release "$old_previous" previous; previous="$old_previous"
    fi
    start_game "$active"
    probe_child || { echo "Rollback also failed; server is not healthy." >&2; exit 1; }
fi
touch "releases/$active/.healthy" /tmp/game-serving
[[ "$pending" == "$active" ]] && { rm pending; pending=""; }
prune
echo "READY: build $(<"releases/$active/.build"), port ${SERVER_PORT:-27015}, voice ${VOICE_PORT:-27030}. Restart this container to check for updates again."
if wait "$child"; then result=0; else result=$?; fi
child=""
echo "Game process exited with status $result."
exit "$result"
