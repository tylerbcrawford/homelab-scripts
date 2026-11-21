#!/usr/bin/env bash
set -euo pipefail

# Obsidian Sync health check + self-healing + quiet alerting (v4, 2026-07-29).
#
# v4 adds the per-file upload-wedge audit (obsidian-sync-audit.mjs): on
# 2026-07-29 specific files silently stopped syncing while every state flag —
# and syncStatus itself — stayed green ("Fully synced"). The audit reconciles
# the vault filesystem against the sync plugin's server-side mirror, so a
# partial wedge is caught per file. Heal escalation for wedges: strike 1
# triggers an in-app rescan (scanFiles + requestSync — what a restart would do,
# without the restart); strike 2 falls through to the normal restart path.
#
# Alerting policy: Discord hears about failures to SELF-HEAL, not failures.
#   - Transient crashes (systemd Restart= heals them in ~15 s) and probe blips
#     produce zero Discord traffic — journal lines only.
#   - An alert fires only when sync has been continuously unhealthy for
#     ALERT_AFTER_SECONDS despite healing restarts; one re-alert every
#     REALERT_SECONDS while the episode persists.
#   - A recovery notice is sent ONLY if the episode was alerted.
#   - Tripwire: >= TRIPWIRE_CRASHES crashes of obsidian.service within 24 h
#     posts one (daily-capped) heads-up, so silent healing can't mask decay.
#   - All posts go through obsidian-sync-notify.sh (delivery-confirmed).
#
# Self-healing (2-strike restart, DevTools bind retry, keyring handling,
# 120 s post-start probe grace) is unchanged from the 2026-07-13 version,
# with one addition: once an episode is running, healing restarts are spaced
# HEAL_BACKOFF_SECONDS apart instead of every 2 strikes, so a long outage
# (e.g. Obsidian cloud down) doesn't churn restarts every 4 minutes.

service_name="obsidian.service"
keyring_service="gnome-keyring-daemon.service"
vault_path="/home/tyler/obsidian-vault"
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
state_dir="$runtime_dir/obsidian-health"          # per-boot: strike counter
persist_dir="$HOME/.local/state/obsidian-health"  # survives reboots: episode state
fail_file="$state_dir/fail-count"
episode_file="$persist_dir/episode-start"
alerted_file="$persist_dir/alerted-at"
heal_count_file="$persist_dir/heal-attempts"
last_heal_file="$persist_dir/last-heal-restart"
tripwire_file="$persist_dir/crash-tripwire-at"
notify_bin="/home/tyler/.local/bin/obsidian-sync-notify.sh"
cli_sock="$runtime_dir/.obsidian-cli.sock"
max_failures="${MAX_FAILURES:-2}"
alert_after_seconds="${ALERT_AFTER_SECONDS:-600}"
realert_seconds="${REALERT_SECONDS:-21600}"
heal_backoff_seconds="${HEAL_BACKOFF_SECONDS:-900}"
tripwire_crashes="${TRIPWIRE_CRASHES:-3}"
tripwire_cap_seconds=86400
require_keyring=0
minimum_keyring_nofile=4096
keyring_fd_headroom=128
# Sync readiness probe (added 2026-07-13 after the oomd-kill zombie-sync incident:
# process/socket liveness stayed green for ~8h while sync was disconnected).
sync_probe="/home/tyler/.local/bin/obsidian-sync-probe.mjs"
sync_grace_seconds="${SYNC_GRACE_SECONDS:-120}"
# Per-file upload-wedge audit (added 2026-07-29 after files silently stopped
# uploading while the probe's state flags stayed green / "Fully synced").
sync_audit="/home/tyler/.local/bin/obsidian-sync-audit.mjs"
audit_grace_seconds="${AUDIT_GRACE_SECONDS:-300}"

mkdir -p "$state_dir" "$persist_dir"

log() {
  logger -t obsidian-healthcheck "$1"
  echo "$1"
}

notify_post() {
  # A Discord hiccup must never make the healthcheck itself look broken;
  # the notifier already logs loudly (user.err) when it gives up.
  "$notify_bin" "$@" || true
}

fmt_duration() {
  local s="$1"
  if (( s >= 3600 )); then
    printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 ))
  elif (( s >= 60 )); then
    printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
  else
    printf '%ds' "$s"
  fi
}

set_failures() {
  printf '%s\n' "$1" >"$fail_file"
}

get_failures() {
  if [[ -f "$fail_file" ]]; then
    cat "$fail_file"
  else
    echo 0
  fi
}

have_service() {
  systemctl --user is-active --quiet "$service_name"
}

have_keyring_service() {
  systemctl --user is-active --quiet "$keyring_service"
}

find_obsidian_pid() {
  pgrep -u "$(id -u)" -f "/obsidian .*${vault_path}" | head -n1 || true
}

have_cli_socket() {
  [[ -S "$cli_sock" ]]
}

have_cli_socket_connection() {
  python3 - "$cli_sock" <<'PY' >/dev/null 2>&1
import socket
import sys

sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(2)
sock.connect(sys.argv[1])
sock.close()
PY
}

node_bin() {
  # systemd/timer context has no nvm in PATH; resolve the newest nvm node.
  local n
  n=$(ls -1d /home/tyler/.nvm/versions/node/*/bin/node 2>/dev/null | sort -V | tail -n1)
  if [[ -n "$n" && -x "$n" ]]; then
    echo "$n"
    return 0
  fi
  command -v node
}

service_age_seconds() {
  local ts start_epoch
  ts=$(systemctl --user show "$service_name" -p ActiveEnterTimestamp --value)
  if [[ -z "$ts" ]]; then
    echo 999999
    return
  fi
  if ! start_epoch=$(date -d "$ts" +%s 2>/dev/null); then
    echo 999999
    return
  fi
  echo $(( $(date +%s) - start_epoch ))
}

sync_unready_reason() {
  # Prints a reason and returns 1 when Obsidian Sync is not connected/ready.
  # Returns 0 (healthy) during the post-start grace window, and when the probe
  # tooling itself is missing — a broken monitor must not restart-loop a
  # healthy service.
  local nb out reason
  if (( $(service_age_seconds) < sync_grace_seconds )); then
    return 0
  fi
  if [[ ! -f "$sync_probe" ]]; then
    log "WARNING: sync probe missing at $sync_probe; skipping sync readiness check."
    return 0
  fi
  if ! nb=$(node_bin); then
    log "WARNING: no node binary found for sync probe; skipping sync readiness check."
    return 0
  fi
  if out=$("$nb" "$sync_probe" 2>/dev/null); then
    return 0
  fi
  reason=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason","unknown"))' 2>/dev/null || echo "probe gave no verdict")
  echo "sync unhealthy: $reason"
  return 1
}

sync_upload_wedge_reason() {
  # Per-file divergence audit (2026-07-29): the readiness probe validates the
  # sync plugin's state flags, but a partial wedge keeps every flag green while
  # individual files silently stop syncing. The audit reconciles the vault
  # filesystem against sync's own server-side mirror. Same monitor-must-not-
  # harm philosophy as the probe: tooling problems skip, never strike.
  local nb out rc reason
  if (( $(service_age_seconds) < sync_grace_seconds )); then
    return 0
  fi
  if [[ ! -f "$sync_audit" ]]; then
    log "WARNING: sync audit missing at $sync_audit; skipping upload-wedge check."
    return 0
  fi
  if ! nb=$(node_bin); then
    log "WARNING: no node binary found for sync audit; skipping upload-wedge check."
    return 0
  fi
  rc=0
  out=$(AUDIT_GRACE_SECONDS="$audit_grace_seconds" timeout 60 "$nb" "$sync_audit" 2>/dev/null) || rc=$?
  if (( rc == 0 )); then
    return 0
  fi
  if (( rc != 1 )); then
    # Exit 2 / timeout / crash: a tooling problem, not a sync verdict. The
    # readiness probe already guards CDP reachability, so don't strike on this.
    log "WARNING: sync audit tooling error (exit ${rc}); skipping upload-wedge check."
    return 0
  fi
  reason=$(printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason","unknown"))' 2>/dev/null || echo "audit gave no verdict")
  echo "sync upload wedge: $reason"
  return 1
}

get_main_pid() {
  local service="$1"
  systemctl --user show "$service" -p MainPID --value
}

get_fd_count() {
  local pid="$1"
  [[ -d "/proc/$pid/fd" ]] || return 1
  find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 | wc -l
}

get_nofile_soft_limit() {
  local pid="$1"
  awk '/Max open files/ { print $4; exit }' "/proc/$pid/limits"
}

keyring_health_reason() {
  local pid fd_count nofile_limit

  if ! have_keyring_service; then
    echo "keyring service inactive"
    return 1
  fi

  pid="$(get_main_pid "$keyring_service")"
  if [[ -z "$pid" || "$pid" == "0" || ! -d "/proc/$pid" ]]; then
    echo "keyring process missing"
    return 1
  fi

  fd_count="$(get_fd_count "$pid" || true)"
  nofile_limit="$(get_nofile_soft_limit "$pid" || true)"
  if [[ -z "$fd_count" || -z "$nofile_limit" ]]; then
    echo "keyring limits unreadable"
    return 1
  fi

  if (( nofile_limit < minimum_keyring_nofile )); then
    echo "keyring NOFILE too low (${fd_count}/${nofile_limit})"
    return 1
  fi

  if (( fd_count + keyring_fd_headroom >= nofile_limit )); then
    echo "keyring fd pressure (${fd_count}/${nofile_limit})"
    return 1
  fi

  return 0
}

wait_for_cli_socket() {
  local tries=0
  while (( tries < 10 )); do
    if have_cli_socket && have_cli_socket_connection; then
      return 0
    fi
    sleep 2
    tries=$((tries + 1))
  done
  return 1
}

wait_for_keyring() {
  local tries=0
  while (( tries < 10 )); do
    if keyring_health_reason >/dev/null; then
      return 0
    fi
    sleep 1
    tries=$((tries + 1))
  done
  return 1
}

wait_for_devtools() {
  local tries=0
  while (( tries < 10 )); do
    if ss -tln 2>/dev/null | grep -qE '127\.0\.0\.1:9222\s'; then
      return 0
    fi
    sleep 3
    tries=$((tries + 1))
  done
  return 1
}

restart_stack() {
  local reason="$1" heals
  if (( require_keyring )) || [[ "$reason" == keyring* ]]; then
    log "Restarting keyring and ${service_name} (heal attempt) after repeated health check failures (${reason})."
    systemctl --user reset-failed "$keyring_service" || true
    systemctl --user restart "$keyring_service"
    wait_for_keyring || true
  else
    log "Restarting ${service_name} (heal attempt) after repeated health check failures (${reason})."
  fi
  heals=$(cat "$heal_count_file" 2>/dev/null || echo 0)
  printf '%s\n' "$(( heals + 1 ))" >"$heal_count_file"
  date +%s >"$last_heal_file"
  systemctl --user reset-failed "$service_name" || true
  systemctl --user restart "$service_name"
  # Electron's :9222 bind is racy across restarts (~50% observed 2026-07-13);
  # without it the sync readiness probe is blind, so retry until it binds.
  local bind_tries=0
  while ! wait_for_devtools && (( bind_tries < 2 )); do
    bind_tries=$((bind_tries + 1))
    log "DevTools port not bound after restart; restarting ${service_name} again (attempt ${bind_tries}/2)."
    systemctl --user restart "$service_name"
  done
  if ! ss -tln 2>/dev/null | grep -qE '127\.0\.0\.1:9222\s'; then
    log "WARNING: DevTools port still not listening after ${bind_tries} extra restart(s); sync probe will re-strike."
  fi
  wait_for_cli_socket || true
  set_failures 0
}

check_crash_tripwire() {
  # Self-healing hides individual crashes by design; this keeps an abnormal
  # crash RATE visible. Deliberate stops/restarts (status=15/TERM) don't count.
  local now="$1" crashes last_trip
  crashes=$(journalctl --user -u "$service_name" --since "24 hours ago" --no-pager 2>/dev/null \
    | grep 'Main process exited' | grep -vc 'status=15/TERM' || true)
  if (( crashes >= tripwire_crashes )); then
    last_trip=$(cat "$tripwire_file" 2>/dev/null || echo 0)
    if (( now - last_trip >= tripwire_cap_seconds )); then
      printf '%s\n' "$now" >"$tripwire_file"
      log "Crash tripwire: ${crashes} crashes in 24 h; posting daily-capped heads-up."
      notify_post info "Obsidian Sync crashing often" "Crashed ${crashes} times in the last 24 hours. Self-healing absorbed each one and sync is healthy right now, but the crash rate is abnormal. Worth a look when convenient. (Max one of these per day.)"
    fi
  fi
}

handle_healthy() {
  local now="$1" started duration heals
  if [[ -f "$episode_file" ]]; then
    started=$(cat "$episode_file")
    duration=$(( now - started ))
    heals=$(cat "$heal_count_file" 2>/dev/null || echo 0)
    if [[ -f "$alerted_file" ]]; then
      log "Recovered after alerted episode ($(fmt_duration "$duration"), ${heals} heal restart(s)); sending recovery notice."
      notify_post resolve "Obsidian Sync recovered" "${heals} auto-restart(s) during the episode."
    else
      log "Self-healed quietly: episode lasted $(fmt_duration "$duration"), ${heals} heal restart(s) — below alert threshold, no Discord alert."
    fi
    rm -f "$episode_file" "$alerted_file" "$heal_count_file" "$last_heal_file"
  fi
  set_failures 0
  check_crash_tripwire "$now"
}

handle_unhealthy() {
  local now="$1" reason="$2" failures="$3"
  local started episode_age alerted_at last_heal heals

  if [[ -f "$episode_file" ]]; then
    started=$(cat "$episode_file")
  else
    started="$now"
    printf '%s\n' "$now" >"$episode_file"
  fi
  episode_age=$(( now - started ))

  failures=$(( failures + 1 ))
  set_failures "$failures"
  log "Obsidian health check failed (${reason}), strike ${failures}/${max_failures}, episode age $(fmt_duration "$episode_age")."

  # Upload-wedge gentle heal: before restart escalation, ask the running app to
  # rescan (the same "Detecting changes" pass a restart triggers, without the
  # restart). Verified 2026-07-29 to clear a real watcher-miss wedge in ~25 s.
  # If it works, the next tick closes the episode quietly; if not, strike 2
  # falls through to the normal restart path below.
  if [[ "$reason" == "sync upload wedge"* ]] && (( failures < max_failures )); then
    local nudge_nb
    if nudge_nb=$(node_bin); then
      log "Upload wedge: requesting in-app rescan (gentle heal before restart escalation)."
      AUDIT_GRACE_SECONDS="$audit_grace_seconds" timeout 120 "$nudge_nb" "$sync_audit" --rescan >/dev/null 2>&1 || true
    fi
  fi

  if (( failures >= max_failures )); then
    last_heal=$(cat "$last_heal_file" 2>/dev/null || echo 0)
    if (( now - last_heal >= heal_backoff_seconds )); then
      restart_stack "$reason"
    else
      log "Heal backoff active: last restart $(fmt_duration $(( now - last_heal ))) ago, next allowed in $(fmt_duration $(( heal_backoff_seconds - (now - last_heal) )))."
    fi
  fi

  heals=$(cat "$heal_count_file" 2>/dev/null || echo 0)
  alerted_at=$(cat "$alerted_file" 2>/dev/null || echo "")
  if [[ -z "$alerted_at" ]]; then
    if (( episode_age >= alert_after_seconds )); then
      printf '%s\n' "$now" >"$alerted_file"
      log "Episode exceeded alert threshold; posting Discord alert."
      notify_post alert "Obsidian Sync is down" "Down for $(fmt_duration "$episode_age") (latest reason: ${reason}). Auto-healing tried ${heals} restart(s) and keeps retrying every $(fmt_duration "$heal_backoff_seconds"). One re-alert in $(( realert_seconds / 3600 )) h if still down." "Nothing to do unless this persists; manual restart: ssh media \"systemctl --user reset-failed obsidian.service && systemctl --user restart obsidian.service\""
    fi
  elif (( now - alerted_at >= realert_seconds )); then
    printf '%s\n' "$now" >"$alerted_file"
    notify_post alert "Obsidian Sync is still down" "Still down after $(fmt_duration "$episode_age") (latest reason: ${reason}; ${heals} restart attempts so far)." "Needs manual attention, or it is an Obsidian cloud outage that has to blow over"
  fi
}

main() {
  local pid failures reason sync_reason wedge_reason now
  now=$(date +%s)
  failures="$(get_failures)"
  reason=""

  if (( require_keyring )); then
    reason="$(keyring_health_reason || true)"
  fi

  if [[ -n "$reason" ]]; then
    :
  elif ! have_service; then
    reason="service inactive"
  else
    pid="$(find_obsidian_pid)"
    if [[ -z "$pid" ]]; then
      reason="vault process missing"
    elif ! have_cli_socket; then
      reason="cli socket missing"
    elif ! have_cli_socket_connection; then
      reason="cli socket unresponsive"
    elif ! sync_reason="$(sync_unready_reason)"; then
      reason="$sync_reason"
    elif ! wedge_reason="$(sync_upload_wedge_reason)"; then
      reason="$wedge_reason"
    fi
  fi

  if [[ -z "$reason" ]]; then
    # During the post-start probe grace window the sync verdict is UNKNOWN, not
    # healthy. If an episode is open, closing it here would reset the episode
    # clock on every healing restart and a persistent outage could never reach
    # the alert threshold — so defer judgment until the probe really ran.
    if [[ -f "$episode_file" ]] && (( $(service_age_seconds) < sync_grace_seconds )); then
      log "Liveness OK but probe still in post-start grace; keeping episode open, verdict deferred."
      exit 0
    fi
    handle_healthy "$now"
    exit 0
  fi

  handle_unhealthy "$now" "$reason" "$failures"
}

# A clean exit proves the healthcheck works again; close any "monitoring is blind"
# alert (cheap file test first, so the normal run never spawns the notifier).
meta_ok() {
  local rc=$?
  if (( rc == 0 )) && [[ -f "$HOME/.local/state/obsidian-health/healthcheck-broken-alerted-at" ]]; then
    "$notify_bin" healthcheck-ok >/dev/null 2>&1 \
      || logger -t obsidian-notify "healthcheck-ok resolve failed; will retry next run" || true
  fi
  return 0
}
trap meta_ok EXIT

main "$@"
