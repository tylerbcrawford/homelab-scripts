#!/usr/bin/env bash
# start-media-server.sh — Tiered Docker service startup
#
# Starts services in 5 waves to prevent CPU spike on boot.
# Designed to be called by systemd (e.g., docker-compose-app.service).
#
# Wave 1: Infrastructure        — wait 20s
# Wave 2: Dashboard + Downloads  — poll download clients healthy
# Wave 3: Media Managers         — wait 30s
# Wave 4: Media Server + Heavy   — poll media server healthy
# Wave 5: Notifications          — done
#
# Customize the service arrays below for your stack.

set -euo pipefail

COMPOSE_DIR="${COMPOSE_DIR:-/path/to/docker-compose-directory}"
LOG_DIR="${LOG_DIR:-${COMPOSE_DIR}/logs}"
LOG_FILE="${LOG_DIR}/startup-$(date +%Y%m%d-%H%M%S).log"
POLL_INTERVAL=5
POLL_TIMEOUT=180  # 3 minutes max per health poll

mkdir -p "$LOG_DIR"

# --- Logging -----------------------------------------------------------------

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" | tee -a "$LOG_FILE"
}

# --- Wave helpers -------------------------------------------------------------

start_wave() {
    local wave_name="$1"
    shift
    local services=("$@")

    log ""
    log "-- Wave: ${wave_name} (${#services[@]} services) ------"
    cd "$COMPOSE_DIR"
    docker compose up -d "${services[@]}" 2>&1 | tee -a "$LOG_FILE"
    log "  Started ${#services[@]} services"
}

wait_seconds() {
    local seconds="$1"
    log "  Waiting ${seconds}s for services to initialize..."
    sleep "$seconds"
}

# Poll a single container until healthy or timeout
wait_healthy() {
    local container="$1"
    local timeout="${2:-$POLL_TIMEOUT}"
    local elapsed=0
    local status="unknown"

    while [ "$elapsed" -lt "$timeout" ]; do
        status=$(docker inspect --format='{{.State.Health.Status}}' "$container" 2>/dev/null || echo "not_found")

        case "$status" in
            healthy)
                log "  + $container healthy (${elapsed}s)"
                return 0
                ;;
            unhealthy)
                log "  ! $container unhealthy after ${elapsed}s -- continuing"
                return 1
                ;;
        esac

        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done

    log "  ! $container timed out after ${timeout}s (last: ${status})"
    return 1
}

# Poll multiple containers — log warnings but don't abort
wait_all_healthy() {
    local timeout="$1"
    shift
    local containers=("$@")
    local failed=0

    log "  Polling ${#containers[@]} services for healthy status..."
    for container in "${containers[@]}"; do
        wait_healthy "$container" "$timeout" || ((failed++))
    done

    if [ "$failed" -eq 0 ]; then
        log "  All polled services healthy"
    else
        log "  ${failed}/${#containers[@]} services not healthy -- continuing anyway"
    fi
}

# --- Main ---------------------------------------------------------------------

main() {
    log "================================================================"
    log "  Docker Tiered Startup"
    log "  Host: $(hostname) | Cores: $(nproc) | Load: $(uptime | awk -F'load average:' '{print $2}')"
    log "================================================================"

    # Pre-flight checks
    if ! docker info &>/dev/null; then
        log "ERROR: Docker daemon not running"
        exit 1
    fi

    if [ ! -f "${COMPOSE_DIR}/docker-compose.yml" ]; then
        log "ERROR: ${COMPOSE_DIR}/docker-compose.yml not found"
        exit 1
    fi

    local start_time=$SECONDS

    # -- Stop any auto-restarted containers ------------------------------------
    # Docker's on-failure restart policy triggers on shutdown exit codes
    # (SIGKILL = exit 137), so some containers may already be running.
    # Stop them all first to ensure clean tiered startup.
    log "Stopping any auto-restarted containers..."
    cd "$COMPOSE_DIR"
    docker compose stop 2>&1 | tee -a "$LOG_FILE"
    log "  Clean slate ready"

    # -- Wave 1: Infrastructure ------------------------------------------------
    # Customize these service arrays for your stack
    # Light services with no dependencies. Gets auth proxy + databases ready.
    start_wave "1 -- Infrastructure" \
        oauth2-proxy \
        mongo \
        redis \
        portainer \
        landing-page \
        watchtower

    wait_seconds 20

    # -- Wave 2: Dashboard + Download Infrastructure + Light Services -----------
    # Customize these service arrays for your stack
    # Dashboard + download clients + monitoring + utilities.
    start_wave "2 -- Dashboard + Downloads" \
        homarr \
        prowlarr \
        nzbget \
        qbittorrent \
        glances \
        tautulli \
        filebrowser \
        wetty \
        metube \
        unpackerr

    # Wait for download infra — media managers in Wave 3 depend on these
    wait_all_healthy 180 \
        prowlarr \
        nzbget \
        qbittorrent

    # -- Wave 3: Media Managers ------------------------------------------------
    # Customize these service arrays for your stack
    # Sonarr/Radarr/Readarr/Lidarr + Calibre stack.
    start_wave "3 -- Media Managers" \
        sonarr \
        radarr \
        readarr \
        lidarr \
        bazarr \
        calibre \
        calibre-web \
        audiobookshelf

    wait_seconds 30

    # -- Wave 4: Media Server + Heavy Processing -------------------------------
    # Customize these service arrays for your stack
    # Plex (heaviest), Tdarr (transcoding), etc.
    start_wave "4 -- Media Server + Heavy" \
        plex \
        tdarr

    # Wait for plex + readarr — notification services depend on these
    wait_all_healthy 180 \
        plex \
        readarr

    # -- Wave 5: Notifications -------------------------------------------------
    # Customize these service arrays for your stack
    # Last wave — these monitor the arr stack and plex.
    start_wave "5 -- Notifications" \
        notifiarr

    # -- Summary ---------------------------------------------------------------
    local elapsed=$((SECONDS - start_time))
    local final_load
    final_load=$(uptime | awk -F'load average:' '{print $2}')

    log ""
    log "================================================================"
    log "  Startup complete in ${elapsed}s"
    log "  Final load:${final_load}"
    log "================================================================"

    # Health summary
    log ""
    log "Service status:"
    cd "$COMPOSE_DIR"
    docker compose ps --format "table {{.Name}}\t{{.Status}}" 2>&1 | tee -a "$LOG_FILE"
}

main "$@"
