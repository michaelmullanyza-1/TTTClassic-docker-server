# TTT Classic Docker Server

A Docker Compose setup for a [TTT Classic](https://store.steampowered.com/app/4570530/TTT_Classic/)
dedicated server — the GoldSrc demake of *Trouble in Terrorist Town* — that checks
Steam for updates **every time the container starts or restarts**. No SSH, no cron,
no scheduler.

Restart the container from Portainer (or `docker restart`) and it will:

1. Check Steam for a new dedicated-server build (AppID `4753110`).
2. Update a **separate staging directory**, then snapshot a successful download
   into a release folder, leaving the installed copy untouched while it works.
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
  releases/                           versioned runtime snapshots
  staging/                            the only directory SteamCMD writes to
  persistent/                         bans + logs (survive update AND rollback)
  steam-home/                         SteamCMD state
```

- SteamCMD owns a single **stable `staging/` directory** that never runs the game.
  Releases are **snapshots** taken from it, so a failed or partial download never
  damages a working install.
- Partial downloads **resume** in `staging/` on the next start. SteamCMD escalates
  through three attempts — incremental, then `validate`, then discarding `staging/`
  for a clean reinstall — bounded by `UPDATE_TIMEOUT_SECONDS`. A clean reinstall
  is a recovery attempt, not a guarantee; network, Steam, or disk failures can
  still prevent it from completing.
- Each attempt must exit successfully, capture a fresh AppID-specific success
  message, and leave a complete installation with manifest `StateFlags == 4`.
  An old complete manifest alone cannot turn a failed check into "already current."
- After a successful check, if the build and runtime image match the active
  release and no forced update was requested, snapshotting is skipped.
- A new build is **preflighted on loopback in LAN mode** and must answer three
  consecutive A2S queries before it is allowed to serve players.
- If public startup fails, the previous release is **restored automatically** and
  the bad build is remembered so restarts do not keep re-activating it.
- Old releases are pruned; `current`, `previous` and any pending download are kept.
- Release replacement and cleanup refuse unrecognized directories, files, and
  symlinks. Only directories marked `.managed-release` may be deleted, and neither
  `current` nor `previous` may be removed. New snapshots are marked before copying
  so an interrupted copy can be safely retried. Keep unrelated data out of `staging/`;
  the final retry can discard that directory.

> **Why staging exists.** During the update from build `25453291` to `25722887`,
> updating copies of a running release failed with SteamCMD `state is 0x6`.
> Adding `validate` did not resolve that incident; a clean installation with
> refreshed app metadata succeeded. These observations did **not** establish
> that Steam binds installations to exact paths or that copied installs can never
> update. Stable staging separates Steam-managed content from runtime changes
> and keeps failed downloads away from working releases. The updater requests
> fresh app metadata with `+app_info_update 1`. `StateFlags == 4` describes the
> local installation, not proof that this attempt successfully contacted Steam.

Because the check happens during startup, players cannot connect until it
finishes. The container shows *starting* during this time.

### Regression checks

Run the dependency-free Bash checks in an isolated container using the same
SteamCMD image as the server. They substitute SteamCMD responses and do not
download game files, publish ports, or mount production data:

```bash
docker run --rm --network none --user 1000:1000 \
  --tmpfs /srv:exec,uid=1000,gid=1000,mode=0700 \
  --tmpfs /scripts:exec,uid=1000,gid=1000,mode=0700 \
  -e TTT_TEST_CONTAINER=1 -v "$PWD:/repo:ro" \
  --entrypoint /bin/bash \
  gameservermanagers/steamcmd@sha256:223bf8691bd2662bfa05ed5e3112651fc0f86491ca4590afc0e362983a3e1e6d \
  /repo/tests/update-release.sh
```

Coverage includes failed checks with stale complete manifests, unsuccessful
validation, missing or mismatched success messages, retry recovery, managed
target protection, interrupted snapshots, and boot's no-change/fallback cleanup.

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
> removes it before rewriting. Without that, the server crash-loops on the second
> start — a bug that is invisible on a first-boot-only test. SteamCMD never sees
> this file, because it only ever writes to `staging/`, which does not run the game.

## Security

- Runs as `PUID:PGID` (default `1000:1000`), never as root.
- `cap_drop: ALL` and `no-new-privileges`.
- Container logs are rotated (3 × 10 MB).
- No credentials in the image or the repository. `.env` and `config/rcon.cfg`
  are git-ignored.

## Requirements

- Docker with Compose v2
- ~3.5 GB free disk (SteamCMD's `staging/` copy is ~1 GB, plus the active release
  and a rollback release at ~1 GB each)
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
