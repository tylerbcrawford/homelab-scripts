# Homelab Scripts

These are the scripts that actually run my [homelab](https://github.com/tylerbcrawford/infrastructure-showcase) on cron and systemd. The audiobookshelf author matcher was born out of frustration with 200+ authors showing blank photos in the UI — it tries 6 different sources before giving up. The PDF converter exists because Readarr occasionally grabs PDF-only books that Calibre can't auto-import without conversion.

They're not pretty, but they work. Each one solves a specific annoyance I ran into while managing a 49-service media server.

## Table of Contents

- [Quick Start](#quick-start)
- [Scripts](#scripts)
  - [Audiobookshelf](#audiobookshelf)
  - [Calibre](#calibre)
  - [Infrastructure](#infrastructure)
  - [Utils](#utils)
- [Configuration](#configuration)
- [License](#license)

## Quick Start

```bash
# Clone the repo
git clone https://github.com/tylerbcrawford/homelab-scripts.git
cd homelab-scripts

# Copy and edit the environment config
cp .env.example .env
# Edit .env with your paths, tokens, and URLs

# Make scripts executable
chmod +x audiobookshelf/*.sh calibre/*.sh infrastructure/*.sh utils/*.sh

# Source your config and run a script
source .env
./audiobookshelf/audiobookshelf-author-match.sh --dry-run
```

## Scripts

### Audiobookshelf

#### `audiobookshelf-author-match.sh`

Automatically enriches author metadata (photos and biographies) in Audiobookshelf using a 6-source fallback chain:

1. **Audnexus** (via ABS built-in match API)
2. **Open Library** (photo + bio)
3. **Wikipedia** (photo + bio)
4. **Goodreads** (photo only, scrapes author pages)
5. **Penguin Random House** (bio only, extracts JSON-LD structured data)
6. **Google Books** (bio only, last resort -- uses book descriptions mentioning the author)

Also includes a **duplicate author detector** that normalizes Unicode names (strips diacritics) to find and merge duplicates.

**Prerequisites:** `curl`, `jq`, `iconv`

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `ABS_URL` | `http://localhost:13378` | Audiobookshelf URL |
| `ABS_API_TOKEN` | *(required)* | API token (Settings > Users > your user) |
| `RATE_LIMIT_SECONDS` | `2` | Delay between API calls |
| `LOG_DIR` | `/var/log` | Directory for log file |
| `TOKEN_FILE` | `./audiobookshelf/.abs-token` | Alternative to env var for token |

**Usage:**

```bash
# Dry run -- see what would be matched
./audiobookshelf/audiobookshelf-author-match.sh --dry-run

# Match all authors missing metadata
./audiobookshelf/audiobookshelf-author-match.sh

# Re-match all authors (even those with existing data)
./audiobookshelf/audiobookshelf-author-match.sh --force-all

# Detect duplicate authors (dry run)
./audiobookshelf/audiobookshelf-author-match.sh --dedup

# Merge duplicate authors
./audiobookshelf/audiobookshelf-author-match.sh --dedup --confirm
```

**Cron setup:**

```bash
# Run weekly on Sunday at 3am
0 3 * * 0 source /path/to/.env && /path/to/audiobookshelf/audiobookshelf-author-match.sh >> /var/log/audiobookshelf-author-match.log 2>&1
```

---

### Calibre

#### `calibre-autoadd-watcher.sh`

Watches a directory for new ebook files and automatically copies them to Calibre's auto-add folder for import. Uses `inotifywait` for real-time detection with a background sweep every 5 minutes as a safety net. Race conditions between the two are prevented with `flock`.

**Prerequisites:** `inotifywait` (`sudo apt install inotify-tools`)

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `WATCH_DIR` | `/path/to/ebook/downloads` | Directory to watch for new ebooks |
| `AUTOADD_DIR` | `/path/to/calibre/autoadd` | Calibre's auto-add directory |
| `LOG_DIR` | `$HOME/.local/share/calibre/logs` | Log directory |
| `PROCESSED_FILE` | `$HOME/.calibre-autoadd-processed` | Tracks processed files |

**Supported formats:** `.epub`, `.mobi`, `.azw3`, `.pdf`, `.cbz`, `.cbr`

**Usage:**

```bash
# Run directly
./calibre/calibre-autoadd-watcher.sh

# Or as a systemd service (recommended)
# See systemd example below
```

#### `pdf-to-epub-watcher.sh`

Watches a quarantine directory for PDF files and converts them to EPUB using a 3-stage fallback strategy (defined in `pdf-convert-lib.sh`):

1. **Direct**: PDF to EPUB via Calibre's `ebook-convert` (30s timeout to detect pdftohtml hangs)
2. **Fallback**: Extract text with `pdftotext`, then convert text to EPUB with heuristics
3. **Last resort**: Text to EPUB without heuristics (fastest)

Converted EPUBs are routed to an incoming directory; failed PDFs are moved to a `failed/` subdirectory. Includes automatic cleanup of processed PDFs older than 30 days.

**Prerequisites:** `inotifywait`, `pdftotext` (`sudo apt install poppler-utils`), Docker with a running Calibre container

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `QUARANTINE_DIR` | `/path/to/pdf-quarantine` | Directory to watch for PDFs |
| `INCOMING_DIR` | `/path/to/ebook/incoming` | Where converted EPUBs go |
| `NOTIFICATION_DIR` | `/path/to/notifications` | JSON notification output |
| `CALIBRE_CONTAINER` | `calibre` | Docker container name for Calibre |
| `DETECT_TIMEOUT` | `30` | Seconds before declaring pdftohtml hung |
| `CONVERT_TIMEOUT` | `300` | Max seconds for conversion stages 2-3 |
| `PROCESSED_FILE` | `$HOME/.pdf-converter-processed` | Tracks processed files |

#### `pdf-convert-lib.sh`

Shared library providing the `convert_single_pdf()` function used by `pdf-to-epub-watcher.sh`. Source this file to use the 3-stage conversion in your own scripts.

---

### Infrastructure

#### `start-media-server.sh`

Tiered Docker Compose startup script that brings up services in 5 waves to prevent CPU spikes on boot. Each wave waits for critical services to become healthy before starting the next.

The wave architecture:
1. **Infrastructure** -- auth proxies, databases, container management
2. **Dashboard + Downloads** -- dashboards, download clients, monitoring
3. **Media Managers** -- Sonarr, Radarr, Readarr, Calibre, etc.
4. **Media Server + Heavy** -- Plex, transcoding services
5. **Notifications** -- services that monitor the arr stack

**Prerequisites:** Docker, Docker Compose

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `COMPOSE_DIR` | `/path/to/docker-compose-directory` | Directory containing `docker-compose.yml` |
| `LOG_DIR` | `${COMPOSE_DIR}/logs` | Startup log directory |

**Usage:**

```bash
# Edit the service arrays in the script to match your stack, then:
./infrastructure/start-media-server.sh

# Or via systemd
# [Unit]
# Description=Docker Compose Tiered Startup
# After=docker.service
# Requires=docker.service
#
# [Service]
# Type=oneshot
# RemainAfterExit=yes
# ExecStart=/path/to/infrastructure/start-media-server.sh
# Environment=COMPOSE_DIR=/path/to/your/docker-compose-directory
#
# [Install]
# WantedBy=multi-user.target
```

#### `tautulli-newsletter-discord.py`

Forwards Tautulli newsletter notifications to a Discord channel via webhook. Rewrites internal Docker IPs to your public domain so newsletter links work outside your network.

**Prerequisites:** Python 3, `requests` (`pip install requests`)

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `DISCORD_WEBHOOK` | *(required)* | Discord webhook URL |
| `INTERNAL_URL` | `http://localhost:8181` | Tautulli internal URL |
| `PUBLIC_URL` | `https://stats.yourdomain.com` | Tautulli public URL |

**Tautulli setup:**
1. Go to Settings > Notification Agents > Add Script
2. Set the script path to `tautulli-newsletter-discord.py`
3. Under Triggers, enable "Newsletter"
4. Set the environment variables in the script arguments or via `.env`

---

### Utils

#### `git-status-report.sh`

Generates a quick status report for all your git repositories -- shows branch, last commit time, dirty/clean status, and ahead/behind counts.

**Usage:**

```bash
# Edit the REPOS array in the script with your repo paths, then:
./utils/git-status-report.sh

# Markdown table output (great for pasting into notes)
./utils/git-status-report.sh --markdown
```

---

## Configuration

All scripts support configuration via environment variables. The recommended approach:

1. Copy `.env.example` to `.env`
2. Edit `.env` with your paths, tokens, and URLs
3. Source it before running: `source .env`

For systemd services, set variables in the `[Service]` section:

```ini
[Service]
Environment=WATCH_DIR=/path/to/ebooks
Environment=AUTOADD_DIR=/path/to/calibre/autoadd
ExecStart=/path/to/calibre/calibre-autoadd-watcher.sh
```

## License

[MIT](LICENSE)
