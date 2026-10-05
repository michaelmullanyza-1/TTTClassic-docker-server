#!/bin/bash
# Keep Steam-managed staging separate from runtime-modified release snapshots.
set -Eeuo pipefail
umask 0027
source "$(dirname -- "${BASH_SOURCE[0]}")/release-helpers.sh"
: "${APPID:?APPID is required}"
: "${GAME_DIR:?GAME_DIR is required}"
: "${RELEASE_ID:?RELEASE_ID must be supplied by the startup manager}"
[[ "$RELEASE_ID" =~ ^r[0-9]+$ ]] || { echo "Invalid release ID" >&2; exit 1; }

STAGING=/srv/staging
# Distinct exit code: Steam matches the running release, so nothing was staged.
NO_CHANGE=10

mkdir -p /srv/releases "$HOME"
exec 9>/srv/.download.lock
flock -n 9 || { echo "Another download is already running" >&2; exit 1; }

target="/srv/releases/$RELEASE_ID"
check_release_target "$RELEASE_ID"

if command -v steamcmd >/dev/null; then
    steam=(steamcmd)
elif [[ -x /home/steam/steamcmd/steamcmd.sh ]]; then
    steam=(/home/steam/steamcmd/steamcmd.sh)
else
    echo "SteamCMD executable not found in this image" >&2; exit 1
fi

manifest="$STAGING/steamapps/appmanifest_$APPID.acf"
read_field() {
    awk -v key="\"$1\"" '$1==key {gsub(/"/,"",$2); print $2; exit}' "$manifest" 2>/dev/null
}
# StateFlags 4 is the only value meaning "fully installed, nothing outstanding".
# 6 (4|2) means Steam still wants an update and the tree cannot be trusted.
staging_complete() {
    [[ -s "$manifest" && -x "$STAGING/hlds_linux" ]] || return 1
    [[ -d "$STAGING/$GAME_DIR" && -d "$STAGING/valve" ]] || return 1
    [[ "$(read_field StateFlags)" == 4 ]] || return 1
    [[ "$(read_field buildid)" =~ ^[0-9]+$ ]] || return 1
}
# Request refreshed app metadata before attempting the update.
run_steamcmd() {
    local result
    local args=(+force_install_dir "$STAGING" +login anonymous
                +app_info_update 1 +app_update "$APPID")
    [[ -n "$1" ]] && args+=("$1")
    args+=(+quit)
    if "${steam[@]}" "${args[@]}" 2>&1 | tee /srv/.steam-update.log; then
        :
    else
        result=$?
        echo "SteamCMD or update log capture failed (exit $result)." >&2
        return "$result"
    fi
    if ! grep -Fq \
        -e "Success! App '$APPID' fully installed." \
        -e "Success! App '$APPID' already up to date." /srv/.steam-update.log; then
        echo "SteamCMD did not confirm success for AppID $APPID on this attempt." >&2
        return 1
    fi
    staging_complete ||
        { echo "SteamCMD reported success but the installation is incomplete." >&2; return 1; }
}

mkdir -p "$STAGING"
success=0
for attempt in 1 2 3; do
    validation=""
    case "$attempt" in
        1)
            if [[ "${VALIDATE:-0}" == 1 ]]; then
                echo "SteamCMD attempt 1 of 3 (validate, requested)."
                validation=validate
            else
                echo "SteamCMD attempt 1 of 3 (incremental)."
            fi
            ;;
        2)
            echo "SteamCMD attempt 2 of 3 (validate)." >&2
            validation=validate
            ;;
        3)
            # Rebuild staging as a last resort; network or disk failures can persist.
            echo "SteamCMD attempt 3 of 3 (discarding staging for a clean install)." >&2
            rm -rf -- "$STAGING"
            mkdir -p "$STAGING"
            ;;
    esac
    if run_steamcmd "$validation"; then success=1; break; fi
    echo "SteamCMD attempt $attempt failed; no release will be promoted from it." >&2
    [[ "$attempt" -lt 3 ]] && sleep 15
done
[[ "$success" == 1 ]] ||
    { echo "Download failed; the next container start will retry." >&2; exit 1; }

build="$(read_field buildid)"

if [[ -n "${ACTIVE_BUILD:-}" && "$build" == "$ACTIVE_BUILD" && "${FORCE:-0}" != 1 ]]; then
    echo "Steam build $build matches the running release; nothing to stage."
    exit "$NO_CHANGE"
fi

echo "Snapshotting build $build into $RELEASE_ID."
remove_release "$RELEASE_ID"
mkdir "$target"
# Mark ownership before copying so an interrupted snapshot can be retried safely.
touch "$target/.managed-release"
cp -a --reflink=auto "$STAGING/." "$target/"
# SteamCMD scratch space is worthless in a release and can be large.
rm -rf -- "$target/steamapps/downloading" "$target/steamapps/temp"
rm -f -- "$target/.ready" "$target/.image" "$target/.build" "$target/.healthy"

[[ -x "$target/hlds_linux" && -d "$target/$GAME_DIR" && -d "$target/valve" ]] ||
    { echo "Snapshot of $RELEASE_ID is incomplete" >&2; remove_release "$RELEASE_ID"; exit 1; }
printf '%s\n' "$build" > "$target/.build"

client="$(find "$HOME" -path '*/linux32/steamclient.so' -type f -print -quit)"
if [[ -n "$client" ]]; then
    mkdir -p "$HOME/.steam/sdk32"
    ln -sfn "$client" "$HOME/.steam/sdk32/steamclient.so"
else
    echo "32-bit Steam client library is missing after SteamCMD installation" >&2; exit 1
fi
touch "$target/.ready"
echo "Staged build $build in $RELEASE_ID; the running server was not changed."
