# TTT Classic Docker Server

A Docker Compose setup for a [TTT Classic](https://store.steampowered.com/app/4570530/TTT_Classic/)
dedicated server — the GoldSrc demake of *Trouble in Terrorist Town* — that checks
Steam for updates **every time the container starts or restarts**. No SSH, no cron,
no scheduler.

Restart the container from Portainer (or `docker restart`) and it will:

1. Check Steam for a new dedicated-server build (AppID `4753110`).
2. Download any update into a **separate release folder**, leaving the installed
   copy untouched while it works.
3. Start the new build privately on loopback and wait for it to answer a real
   game query before it is allowed to serve players.
4. Promote it, keeping the previous release for rollback.

If Steam is slow, broken, or the new build fails to start, the server falls back
to the last release that actually worked and says so in the container log.

## You do not need to own Half-Life to run this

This trips people up, so it is worth being explicit:

| App | ID | Needs Half-Life? | Notes |
|---|---|---|---|
| TTT Classic (client) | `4570530` | **Yes** | Free, but `mustownapptopurchase: 70`. Windows-only. |
| TTT Classic **Dedicated Server** | `4753110` | **No** | Free, **anonymous**, native Linux. |

The dedicated server app is a hidden Steam *Tool* app that bundles its own `hlds`
binaries **plus `valve/` and `ttt/`**. You do not need app 90 (HLDS), you do not
need a Steam login, and you do not need a Half-Life licence on the server.

Your **players** still need to own Half-Life.

## Quick start

```bash
git clone https://github.com/michaelmullanyza-1/TTTClassic-docker-server.git
cd TTTClassic-docker-server
cp example.env .env          # set SERVER_PATH, PUID/PGID, SERVER_PORT, VOICE_PORT

# shellcheck disable=SC1091
set -a; . ./.env; set +a
mkdir -p "$SERVER_PATH"/{data,config}
cp config/server.example.cfg "$SERVER_PATH/config/server.cfg"
echo 'rcon_password "choose-something-long"' > "$SERVER_PATH/config/rcon.cfg"
chmod 640 "$SERVER_PATH/config/rcon.cfg"
sudo chown -R "${PUID:-1000}:${PGID:-1000}" "$SERVER_PATH"

docker compose up -d
docker compose logs -f
```

The first start downloads roughly **1 GB**, so it takes a while. Watch for
`READY: build <id>, port <port>, voice <port>` in the log.

In Portainer, deploy this repository as a stack and set the same variables in the
stack's environment section.

### Two ports, not one

TTT Classic uses a **second UDP port for Steam voice** (`ttt_steam_voice_port`,
default `27030`). It must be published by Docker *and* open in your firewall.
If you run more than one TTT server on a host, give each one a unique voice port.

## Configuration

| Path | Purpose |
|---|---|
| `$SERVER_PATH/config/server.cfg` | Your settings. Copied into the active release on every start. |
| `$SERVER_PATH/config/rcon.cfg` | RCON password. Git-ignored — create it yourself. |
| `$SERVER_PATH/config/overrides/` | Game-relative files copied in at launch. |

Overrides mirror the game directory, so to replace the map rotation:

```
$SERVER_PATH/config/overrides/ttt/mapcycle.txt
$SERVER_PATH/config/overrides/ttt/motd.txt
```

Prefer small overrides over copying whole upstream folders — anything you copy
stops receiving upstream updates.

Bans and logs live in `$SERVER_PATH/data/persistent` and survive both updates and
rollbacks.

The full cvar reference is in the developer's guide:
<https://steamcommunity.com/sharedfiles/filedetails/?id=3751635002>

## How updates work

```
data/
  current  -> releases/r<timestamp>   active release
  previous -> releases/r<timestamp>   rollback target
  releases/                           versioned installs
  persistent/                         bans + logs (survive update AND rollback)
  steam-home/                         SteamCMD state
```

- Downloads go into a **new release folder**, seeded from the active one, so a
  failed or partial download never damages a working install.
- Partial downloads **resume** on the next start. SteamCMD is retried 3 times and
  bounded by `UPDATE_TIMEOUT_SECONDS`.
- A new build is **preflighted on loopback in LAN mode** and must answer three
  consecutive A2S queries before it is allowed to serve players.
- If public startup fails, the previous release is **restored automatically** and
  the bad build is remembered so restarts do not keep re-activating it.
- Old releases are pruned; `current`, `previous` and any pending download are kept.

Because the check happens during startup, players cannot connect until it
finishes. The container shows *starting* during this time.

## Optional helper

Everything below is optional — restarting the container in Portainer does the same
thing.

```bash
sudo ./manage.sh status      # which release is live, and its build id
sudo ./manage.sh logs
sudo ./manage.sh update      # restart, checking for updates
sudo ./manage.sh update --force
sudo ./manage.sh validate    # ask SteamCMD to verify/repair files on next start
sudo ./manage.sh rollback    # switch to previous release, skip updating
sudo ./manage.sh restart
sudo ./manage.sh stop
```

## steam_appid.txt

The official hosting guide requires a read-only `steam_appid.txt` containing the
**client** AppID (`4570530`) next to the `ttt/` folder, or clients cannot find or
connect to the server. `start-server.sh` writes it on every launch, so you do not
have to.

> Implementation note: the file is left mode `0444`, which means a plain `>`
> redirect on the *next* boot fails with `Permission denied`. The script therefore
> removes it before rewriting, and `update-release.sh` makes it writable before
> SteamCMD runs. Without that, the server crash-loops on the second start —
> a bug that is invisible on a first-boot-only test.

## Security

- Runs as `PUID:PGID` (default `1000:1000`), never as root.
- `cap_drop: ALL` and `no-new-privileges`.
- Container logs are rotated (3 × 10 MB).
- No credentials in the image or the repository. `.env` and `config/rcon.cfg`
  are git-ignored.

## Requirements

- Docker with Compose v2
- ~2.5 GB free disk (the install is ~1 GB; a second release is staged during updates)
- Outbound access to the Steam CDN
- Inbound UDP+TCP on `SERVER_PORT`, inbound UDP on `VOICE_PORT`

## Credits

TTT Classic is by **Crazydog** — [Steam](https://store.steampowered.com/app/4570530/TTT_Classic/)
· [Discord](https://discord.gg/ZKWa88Zn9P)
· [hosting guide](https://steamcommunity.com/sharedfiles/filedetails/?id=3750150966)

This repository only packages the dedicated server; it does not redistribute any
game content.

The release machinery is parameterised (`APPID`, `CLIENT_APPID`, `GAME_DIR`,
`SERVER_PORT`, `VOICE_PORT`, `START_MAP`, `MAX_PLAYERS`), so it can be
adapted to other GoldSrc mods by changing `.env` alone.
