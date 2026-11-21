# Obsidian Sync tooling

Source of truth for the fleet's Obsidian Sync helpers. Runbook and fleet map: vault `01_Projects/media-server/obsidian-sync/README.md`.

| File | Runs on | What |
|------|---------|------|
| `obsidian-healthcheck.sh`, `obsidian-sync-{audit,probe}.mjs`, `obsidian-sync-notify.sh`, `systemd/obsidian*.{service,timer}` | 800801 (`~/.local/bin`, user units) | Headless bridge client + 2-min health check / self-heal |
| `obsidian-heartbeat.sh` + `systemd/obsidian-heartbeat.*` | 800801 | Writes `06_Metadata/sync-heartbeat.md` every 15 min (git-ignored, Sync-only) |
| `obsidian-fleet-ensure.sh` + `systemd-800802/obsidian-fleet-ensure.*` | 800802 (runs from this checkout) | Every 30 min: start Obsidian on reachable Sync-only machines, alert (boo-notify, warn, 2 strikes) if a device's heartbeat lags >120 min. Offline machines are skipped. `DRY=1` to test |
| `mac-obsidian-login.plist` | 800803, 800804 → `~/Library/LaunchAgents/bid.800802.obsidian-login.plist` | `open -g -a Obsidian` at login |
| `dell-obsidian-autostart.desktop` | 800805 → `~/.config/autostart/obsidian.desktop` | GNOME autostart |

Deploy 800801 pieces: `./deploy.sh`. 800802 units: `cp systemd-800802/* ~/.config/systemd/user/ && systemctl --user daemon-reload`.
