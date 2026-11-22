# set-secret

Paste an API key/token into its home without it touching the screen, shell
history, `ps`, or an LLM. One script; one registry per host
(`registry-<hostname -s>.conf`, names/paths/commands only — never values).

    set-secret              # numbered pick list
    set-secret <name>       # direct
    set-secret <bundle>     # several related values in one run (client id + secret, key id + key)
    set-secret --list       # names + targets
    ssh -t media ~/.local/bin/set-secret <name>   # remote host, prompt stays in your terminal

Hidden `read -s` → optional verify (HTTP code only) → `.bak` copy → atomic
write, chmod 600 → optional restart. Install: `ln -sf <repo>/utils/set-secret/set-secret ~/.local/bin/`.

Restart column is blank for media-server keys: the compose service that
consumes each key varies — run `docker compose up -d <service>` afterwards.

**Bundles.** Credentials that come in pairs get one bundle row, so Tyler pastes
both in a single run: `name | bundle: member1 member2`. Members are prompted in
order and each is saved before the next, so a later member's verify can read the
earlier one from its file (put the id first, the secret last). Each distinct
restart command runs once, after the last member. Members stay settable alone.
Rule: **any new credential pair gets a bundle row**, and handoffs give the bundle
name, not the members.

**Web UI (`set-secret-web`).** Same registry, same write path, from any browser on
the tailnet: <http://100.94.198.72:3900> (800802), <http://100.83.95.43:3900> (800801);
the nav bar links the hosts. Pick a row, paste into the password field(s), Save.
Listens on the Tailscale IP only; every request is checked with `tailscale whois`
and only the tailnet owner's login gets in (override: `SET_SECRET_WEB_USERS`).
Values travel as a POST body, go to `set-secret --stdin` on stdin, and are never
logged or echoed. Failed provider check → form comes back with a "save anyway" box.
Install per host: `ln -sf <repo>/utils/set-secret/set-secret-web ~/.local/bin/` +
`ln -sf <repo>/utils/set-secret/set-secret-web.service ~/.config/systemd/user/` →
`systemctl --user daemon-reload && systemctl --user enable --now set-secret-web`.
Plain HTTP is fine here: WireGuard already encrypts tailnet traffic end-to-end.
**Adding a secret from the web UI.** `+ New secret` → name, file (must be under `~/`),
KEY (blank = whole file), optional second KEY (makes `<name>-<key>` members + a bundle
row). The row is appended to this host's registry and auto-committed + pushed. Restart
and verify commands are CLI-only on purpose: they run as shell, so the web form can't set
them. Edit the row by hand to add one.
