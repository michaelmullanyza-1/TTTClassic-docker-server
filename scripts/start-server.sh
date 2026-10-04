#!/bin/bash
set -Eeuo pipefail
umask 0027
: "${GAME_DIR:?GAME_DIR is required}"
: "${CLIENT_APPID:?CLIENT_APPID is required}"

if [[ -n "${GAME_RELEASE:-}" ]]; then
    [[ "$GAME_RELEASE" =~ ^r[0-9]+$ ]] || { echo "Invalid release ID" >&2; exit 1; }
    release="/srv/releases/$GAME_RELEASE"
else
    [[ -L /srv/current ]] || { echo "No installed release; run sudo ./manage.sh update" >&2; exit 1; }
    release="$(readlink -f /srv/current)"
fi
[[ "$release" == /srv/releases/r* && -f "$release/.ready" ]] ||
    { echo "Release is not ready: $release" >&2; exit 1; }
[[ -s /config/server.cfg ]] || { echo "/config/server.cfg is missing" >&2; exit 1; }

cd "$release"
cp /config/server.cfg "$GAME_DIR/server.cfg"
[[ -f /config/rcon.cfg ]] && cp /config/rcon.cfg "$GAME_DIR/rcon.cfg"
[[ -d /config/overrides ]] && cp -r /config/overrides/. ./

# TTT Classic ships no steam.inf in the mod folder, and the official hosting
# guide is explicit: steam_appid.txt next to the mod dir must contain the
# CLIENT app id (4570530) and be read-only, or clients cannot find/connect.
# NOTE: this file is left read-only (0444) for the engine, so it must be
# removed before rewriting - a plain '>' redirect onto a 0444 file fails with
# "Permission denied" on every boot after the first.
rm -f steam_appid.txt
printf '%s' "$CLIENT_APPID" > steam_appid.txt
chmod 0444 steam_appid.txt
export SteamAppId="$CLIENT_APPID"
export SteamGameId="$CLIENT_APPID"

state=/srv/persistent
extra=()
if [[ "${GAME_PREFLIGHT:-0}" == 1 ]]; then
    state="/srv/probes/$(basename "$release")"
    printf '\nsv_lan 1\n' >> "$GAME_DIR/server.cfg"
    extra=(+sv_lan 1)
fi
mkdir -p "$state/logs"
for file in banned.cfg listip.cfg; do
    touch "$state/$file"
    ln -sfn "$state/$file" "$GAME_DIR/$file"
done
if [[ -d "$GAME_DIR/logs" && ! -L "$GAME_DIR/logs" ]]; then
    mv "$GAME_DIR/logs" "$GAME_DIR/logs.packaged.$(date +%s)"
fi
ln -sfn "$state/logs" "$GAME_DIR/logs"

export LD_LIBRARY_PATH="$release:$HOME/.steam/sdk32:${LD_LIBRARY_PATH:-}"
echo "Starting TTT Classic build $(<.build): map=${START_MAP:-ttt_pinned}, port=${SERVER_PORT:-27015}, voice=${VOICE_PORT:-27030}, players=${MAX_PLAYERS:-24}"
# Run the engine directly: Docker, not the legacy hlds_run loop, owns restarts.
exec ./hlds_linux -console -game "$GAME_DIR" -pingboost 1 \
    -ip "${SERVER_IP:-0.0.0.0}" -port "${SERVER_PORT:-27015}" \
    +map "${START_MAP:-ttt_pinned}" +maxplayers "${MAX_PLAYERS:-24}" \
    +ttt_steam_voice_port "${VOICE_PORT:-27030}" "${extra[@]}"
