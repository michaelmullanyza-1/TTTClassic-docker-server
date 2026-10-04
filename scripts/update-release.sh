#!/bin/bash
set -Eeuo pipefail
umask 0027
: "${APPID:?APPID is required}"
: "${GAME_DIR:?GAME_DIR is required}"
: "${RELEASE_ID:?RELEASE_ID must be supplied by the startup manager}"
[[ "$RELEASE_ID" =~ ^r[0-9]+$ ]] || { echo "Invalid release ID" >&2; exit 1; }
mkdir -p /srv/releases "$HOME"
exec 9>/srv/.download.lock
flock -n 9 || { echo "Another download is already running" >&2; exit 1; }
target="/srv/releases/$RELEASE_ID"
for link in current previous; do
    if [[ -L "/srv/$link" && "$(readlink -f "/srv/$link")" == "$target" ]]; then
        echo "Refusing to update the $link release in place" >&2; exit 1
    fi
done
if [[ -e "$target" ]]; then
    [[ -d "$target" && ! -L "$target" && -f "$target/.managed-release" ]] ||
        { echo "Cannot resume an unrecognized release" >&2; exit 1; }
    echo "Resuming staged download $RELEASE_ID."
else
    mkdir "$target"; touch "$target/.managed-release"
fi

if [[ ( ! -f "$target/.seeded" || -f "$target/.copying" ) && -L /srv/current ]]; then
    active="$(readlink -f /srv/current)"
    [[ "$active" == /srv/releases/r* && -f "$active/.managed-release" ]] ||
        { echo "Invalid active release" >&2; exit 1; }
    touch "$target/.copying"
    cp -a --reflink=auto "$active/." "$target/"
    rm "$target/.copying"
fi
touch "$target/.seeded"
rm -f "$target/.ready" "$target/.image" "$target/.build" "$target/.healthy"
# Do not let SteamCMD follow runtime links into the persistent state.
rm -f "$target/$GAME_DIR/banned.cfg" "$target/$GAME_DIR/listip.cfg"
[[ -L "$target/$GAME_DIR/logs" ]] && rm "$target/$GAME_DIR/logs"
# steam_appid.txt is written 0444 by start-server.sh; make it writable so
# SteamCMD/rsync can replace it without a permission error.
[[ -e "$target/steam_appid.txt" ]] && chmod u+w "$target/steam_appid.txt"

args=(+force_install_dir "$target" +login anonymous +app_update "$APPID")
[[ "${VALIDATE:-0}" == 1 ]] && args+=(validate)
args+=(+quit)
if command -v steamcmd >/dev/null; then
    steam=(steamcmd)
elif [[ -x /home/steam/steamcmd/steamcmd.sh ]]; then
    steam=(/home/steam/steamcmd/steamcmd.sh)
else
    echo "SteamCMD executable not found in this image" >&2; exit 1
fi
success=0
for attempt in 1 2 3; do
    echo "SteamCMD attempt $attempt of 3."
    if "${steam[@]}" "${args[@]}" 2>&1 | tee "$target/.steam-update.log"; then
        if grep -Eq "Success! App '$APPID' (fully installed|already up to date)" "$target/.steam-update.log"; then
            success=1; break
        fi
        echo "SteamCMD returned without confirming success." >&2
    else
        echo "SteamCMD attempt $attempt failed; downloaded data is retained." >&2
    fi
    [[ "$attempt" -lt 3 ]] && sleep 15
done
[[ "$success" == 1 ]] || { echo "Download failed; the next container start will resume it." >&2; exit 1; }

manifest="$target/steamapps/appmanifest_$APPID.acf"
[[ -s "$manifest" && -x "$target/hlds_linux" ]] ||
    { echo "Download did not produce a complete server" >&2; exit 1; }
[[ -d "$target/$GAME_DIR" && -d "$target/valve" ]] ||
    { echo "Download is missing $GAME_DIR/ or valve/" >&2; exit 1; }
flags="$(awk '$1=="\"StateFlags\"" {gsub(/"/,"",$2); print $2}' "$manifest")"
build="$(awk '$1=="\"buildid\"" {gsub(/"/,"",$2); print $2}' "$manifest")"
[[ "$flags" == 4 && "$build" =~ ^[0-9]+$ ]] ||
    { echo "Steam reports an incomplete installation (state $flags, build $build)" >&2; exit 1; }
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
