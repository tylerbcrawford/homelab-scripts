# b2-mint-host-keys

One-shot Backblaze B2 setup for a fleet host's restic backup (vps #38).

    b2-mint-host-keys 800803 800804

Asks for the B2 **master** keyID and applicationKey at hidden prompts and keeps them in memory only. Per host it:

- creates bucket `<id>-restic` if it's missing: private, no SSE (restic encrypts), no Object Lock (prune deletes), hidden versions deleted after 30 days
- creates a key limited to that bucket (`listBuckets readBuckets listFiles readFiles writeFiles deleteFiles`), unless `~/.config/b2/<id>.env` already holds a working key
- writes `B2_ACCOUNT_ID` / `B2_ACCOUNT_KEY` to `~/.config/b2/<id>.env` (0600, old file → `.bak`)
- prints only `<id> bucket created|exists, new key <http code>`

The master key is never stored. Secrets go through `urllib`, so they never appear in `ps`. Install: `ln -sf <repo>/utils/b2-mint-host-keys/b2-mint-host-keys ~/.local/bin/`.
