# kasa-cycle

Runs on 800803 (`~/.local/bin/kasa-cycle`, needs `uv tool install python-kasa`). Power-cycles a Kasa plug as one detached job: off, sleep, on, with 5 retries of the on. It is detached because cycling the `.135` "Server" plug kills 800801, and with it any SSH session HA opened.

```text
kasa-cycle 192.168.4.135 20 --dry-run   # checks the plug answers, changes nothing
kasa-cycle 192.168.4.135 20             # real cycle; log ~/Library/Logs/kasa-cycle.log
```

From HA (mediaserver #24): a `shell_command` running `ssh mac ~/.local/bin/kasa-cycle 192.168.4.135 20`.
