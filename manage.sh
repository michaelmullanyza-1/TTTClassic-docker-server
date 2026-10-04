#!/bin/bash
# Optional helper. Restarting the container in Portainer does the same thing.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
cd "$ROOT"
[[ "$EUID" == 0 ]] || { echo "Run with sudo: sudo $0 ${*:-status}" >&2; exit 1; }

# Pick up SERVER_PATH / PUID / PGID from .env
if [[ -f "$ROOT/.env" ]]; then
    set -a; . "$ROOT/.env"; set +a
fi
: "${SERVER_PATH:?SERVER_PATH must be set in .env}"
PROJECT="${COMPOSE_PROJECT_NAME:-ttt-classic}"
compose=(docker compose --project-directory "$ROOT" -p "$PROJECT" -f "$ROOT/docker-compose.yml")

restart() {
    "${compose[@]}" stop server
    case "$1" in
        validate|force|rollback)
            install -m 640 -o "${PUID:-1000}" -g "${PGID:-1000}" /dev/null \
                "$SERVER_PATH/data/.$1-next-start"
            ;;
    esac
    "${compose[@]}" up -d --no-deps server
}

case "${1:-status}" in
    update)
        [[ "$#" -le 2 && "${2:---force}" == --force ]] ||
            { echo "Usage: $0 update [--force]" >&2; exit 1; }
        if [[ "${2:-}" == --force ]]; then restart force; else restart normal; fi
        ;;
    restart)  restart normal ;;
    validate) restart validate ;;
    rollback)
        [[ -L "$SERVER_PATH/data/previous" ]] ||
            { echo "No previous healthy release exists" >&2; exit 1; }
        restart rollback
        ;;
    stop) "${compose[@]}" stop server ;;
    status)
        "${compose[@]}" ps -a
        for label in current previous; do
            if [[ -L "$SERVER_PATH/data/$label" ]]; then
                echo "$label: $(readlink "$SERVER_PATH/data/$label") / build $(<"$SERVER_PATH/data/$label/.build")"
            fi
        done
        ;;
    logs) "${compose[@]}" logs --tail 100 server ;;
    *)
        echo "Usage: sudo $0 {update [--force]|validate|rollback|restart|stop|status|logs}" >&2
        exit 1
        ;;
esac
