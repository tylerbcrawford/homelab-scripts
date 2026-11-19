# set-secret

Paste an API key/token into its home without it touching the screen, shell
history, `ps`, or an LLM. One script; one registry per host
(`registry-<hostname -s>.conf`, names/paths/commands only — never values).

    set-secret              # numbered pick list
    set-secret <name>       # direct
    set-secret --list       # names + targets
    ssh -t media ~/.local/bin/set-secret <name>   # remote host, prompt stays in your terminal

Hidden `read -s` → optional verify (HTTP code only) → `.bak` copy → atomic
write, chmod 600 → optional restart. Install: `ln -sf <repo>/utils/set-secret/set-secret ~/.local/bin/`.

Restart column is blank for media-server keys: the compose service that
consumes each key varies — run `docker compose up -d <service>` afterwards.
