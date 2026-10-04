#!/bin/bash
set -Eeuo pipefail
if [[ "${1:-}" != --probe && ! -f /tmp/game-serving ]]; then
    echo "Server is updating or starting."
    exit 1
fi
reply="$(mktemp)"
trap 'rm -f "$reply"' EXIT
exec 3<>"/dev/udp/127.0.0.1/${SERVER_PORT:-27015}"
request() { printf '\xff\xff\xff\xffTSource Engine Query\x00'; }
receive() { timeout 3 dd bs=4096 count=1 status=none <&3 >"$reply"; }
request >&3
receive
kind="$(od -An -N5 -tx1 "$reply" | tr -d ' \n')"
if [[ "$kind" == ffffffff41 ]]; then
    { request; tail -c 4 "$reply"; } >&3
    receive
    kind="$(od -An -N5 -tx1 "$reply" | tr -d ' \n')"
fi
[[ "$kind" == ffffffff49 || "$kind" == ffffffff6d ]] ||
    { echo "No valid A2S_INFO game-server response" >&2; exit 1; }
