# Palworld dedicated server

Runs on Proxmox VM 200 (Ubuntu 24.04, 12GB RAM, 6 vCPU, disk on the 1TB SATA
SSD). Exposed via playit.gg so no router ports are forwarded.

Palworld's own documentation warns that low-performance storage can corrupt save
data, which is why this lives on the SSD and not the 2TB HDD.

## Running it

```bash
op inject -i .env.tpl -o .env   # generates the gitignored .env
docker compose up -d
docker compose logs -f palworld
```

The first boot downloads the server via SteamCMD and takes several minutes.
`UPDATE_ON_BOOT` must stay `true` or the server is never installed.

## Connecting

- From the LAN: `<VM_IP>:8211`
- From anywhere: the address shown on the playit.gg tunnel

The playit tunnel must be **UDP**. A TCP tunnel looks perfectly healthy in the
dashboard while nobody is able to join. Set its local address to `127.0.0.1`
port `8211`, which works because the agent runs with host networking.

## Migrating a local co-op save

Save data lives at
`%LOCALAPPDATA%\Pal\Saved\SaveGames\<SteamID64>\<WorldGUID>\` on Windows and
belongs in `palworld/Pal/Saved/SaveGames/0/<WorldGUID>/` on the server.

1. Stop the server with `docker compose down` so the world is flushed to disk.
2. Copy `Level.sav`, `LevelMeta.sav`, and the whole `Players/` directory.
3. **Do not copy `WorldOption.sav`**, and delete it if the server generated one.
   While that file exists it overrides `PalWorldSettings.ini` entirely, which
   means every environment variable set in `compose.yaml` is silently ignored.
   This is the most common cause of "my server settings do nothing".
4. Skip `LocalData.sav` and the game's own `backup/` directory.
5. `chown -R 1000:1000 palworld/` to match `PUID`/`PGID`.
6. Remap the host player GUID (see below).

### The host GUID remap

In co-op and single player the host's character is stored under the fixed
placeholder GUID `00000000000000000000000000000001`. A dedicated server derives
real GUIDs from the Steam account ID, so without a remap the host logs in as a
fresh level 1 character while the real save sits unused on disk.

Other players who joined the co-op world already have server-format GUIDs
(8 hex characters of Steam account ID followed by zeros) and carry over
untouched.

Use the Physgun browser converter, which computes the new ID from a SteamID64
directly and also rewrites pal ownership and guild records. Converters that only
rewrite the character entry are why migrated pals end up standing around
unresponsive at base.

The scripted alternative is `xNul/palworld-host-save-fix`. Verify its argument
order against the current README first, because reversing the old and new GUIDs
silently produces a broken character.

After migrating, check Dimensional Pal Storage specifically. `GlobalPalStorage.sav`
sits at the account level rather than in the world folder and is easy to miss.

## Operational notes

- Nightly restart at 05:00 works around Palworld's server memory leak. It
  depends on `REST_API_ENABLED: true`; without that the cron job is never
  registered and the setting fails silently.
- Backups run at 03:00 with 14-day retention.
- `AUTO_PAUSE_ENABLED` idles the process while the server is empty. Worth
  turning on once things are stable, given the 32GB host budget.
