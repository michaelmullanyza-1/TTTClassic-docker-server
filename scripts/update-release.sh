#!/bin/bash
# Fetch the dedicated server from Steam and stage it as an immutable release.
#
# SteamCMD can only apply an update to an installation it created at that exact
# path: its recorded state (library registration plus the app manifest) is tied
# to the install directory. Copying an existing install to a fresh directory and
# running app_update against the copy makes Steam try to reconfigure an install
# it does not recognise, which fails instantly with
#   Error! App '<id>' state is 0x6 after update job
# before a single byte is downloaded. That failure is invisible while the server
# is already on the newest build, because Steam short-circuits on "already up to
# date" and never attempts the update path.
#
# So SteamCMD owns one stable directory ($STAGING) that never runs the game, and
# releases are snapshots taken from it. Staging stays a pristine Steam install,
# which keeps incremental updates working.
set -Eeuo pipefail
umask 0027
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
for link in current previous; do
    if [[ -L "/srv/$link" && "$(readlink -f "/srv/$link")" == "$target" ]]; then
        echo "Refusing to update the $link release in place" >&2; exit 1
    fi
done

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
# app_info_update forces a fresh appinfo fetch. Without it SteamCMD can answer
# from a stale cache and report "already up to date" for a superseded build.
run_steamcmd() {
    local args=(+force_install_dir "$STAGING" +login anonymous
                +app_info_update 1 +app_update "$APPID")
    [[ -n "$1" ]] && args+=("$1")
    args+=(+quit)
    "${steam[@]}" "${args[@]}" 2>&1 | tee /srv/.steam-update.log || true
}

mkdir -p "$STAGING"
success=0
for attempt in 1 2 3; do
    case "$attempt" in
        1)
            if [[ "${VALIDATE:-0}" == 1 ]]; then
                echo "SteamCMD attempt 1 of 3 (validate, requested)."
                run_steamcmd validate
            else
                echo "SteamCMD attempt 1 of 3 (incremental)."
                run_steamcmd ""
            fi
            ;;
        2)
            echo "SteamCMD attempt 2 of 3 (validate)." >&2
            run_steamcmd validate
            ;;
        3)
            # Last resort, and the one case that is always able to succeed:
            # discard staging so Steam performs a first-time install.
            echo "SteamCMD attempt 3 of 3 (discarding staging for a clean install)." >&2
            rm -rf -- "$STAGING"
            mkdir -p "$STAGING"
            run_steamcmd ""
            ;;
    esac
    if staging_complete; then success=1; break; fi
    echo "SteamCMD attempt $attempt did not produce a complete installation" \
         "(state $(read_field StateFlags), build $(read_field buildid))." >&2
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
rm -rf -- "$target"
mkdir "$target"
cp -a --reflink=auto "$STAGING/." "$target/"
# SteamCMD scratch space is worthless in a release and can be large.
rm -rf -- "$target/steamapps/downloading" "$target/steamapps/temp"
rm -f -- "$target/.ready" "$target/.image" "$target/.build" "$target/.healthy"
touch "$target/.managed-release"

[[ -x "$target/hlds_linux" && -d "$target/$GAME_DIR" && -d "$target/valve" ]] ||
    { echo "Snapshot of $RELEASE_ID is incomplete" >&2; rm -rf -- "$target"; exit 1; }
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
