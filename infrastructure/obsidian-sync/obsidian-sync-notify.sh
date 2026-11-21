#!/bin/bash
# obsidian-sync-notify.sh — post Obsidian Sync health via boo-notify.
#   obsidian-sync-notify.sh alert|resolve|info <headline> [body] [next]
#   obsidian-sync-notify.sh healthcheck-broken     (OnFailure meta-alert, capped 6 h)
#   obsidian-sync-notify.sh healthcheck-ok         (resolve the meta-alert after a clean run)
#   obsidian-sync-notify.sh post <text>            (legacy; posts as info --status warn)
# Delivery, dedupe and branding are handled by boo-notify. The old webhook file
# (~/.config/obsidian-notify.env) is no longer read.
set -u
BOO=/home/tyler/.local/bin/boo-notify
persist_dir="$HOME/.local/state/obsidian-health"
meta_flag="$persist_dir/healthcheck-broken-alerted-at"
meta_cap_seconds=21600 # at most one healthcheck-broken alert per 6 h

kind=${1:-}
case "$kind" in
  alert|resolve|info)
    if [[ $# -lt 2 || -z "$2" ]]; then
      echo "usage: $0 alert|resolve|info headline [body] [next]" >&2
      exit 2
    fi
    headline=$2 body=${3:-} next=${4:-"Nothing to do — auto-healing keeps retrying"}
    case "$kind" in
      alert)   exec "$BOO" alert --key obsidian-sync --subsystem Health --headline "$headline" ${body:+--body "$body"} --next "$next" ;;
      resolve) exec "$BOO" resolve --key obsidian-sync --headline "$headline" ${body:+--body "$body"} ;;
      info)    exec "$BOO" info --subsystem Health --status warn --headline "$headline" ${body:+--body "$body"} ;;
    esac
    ;;
  post)
    if [[ $# -lt 2 || -z "$2" ]]; then
      echo "usage: $0 post <message>" >&2
      exit 2
    fi
    exec "$BOO" info --subsystem Health --status warn --headline "Obsidian Sync notice" --body "$2"
    ;;
  healthcheck-broken)
    mkdir -p "$persist_dir"
    now=$(date +%s)
    last=$(cat "$meta_flag" 2>/dev/null || echo 0)
    if (( now - last >= meta_cap_seconds )); then
      printf '%s\n' "$now" >"$meta_flag"
      "$BOO" alert --key obsidian-healthcheck --subsystem Health \
        --headline "Obsidian Sync monitoring is blind" \
        --body "The Obsidian Sync health check itself failed, so sync problems will not be reported until it is fixed." \
        --next 'ssh media "journalctl --user -u obsidian-healthcheck.service -n 30"'
    else
      logger -t obsidian-notify "healthcheck-broken alert suppressed (last one $(( (now - last) / 60 )) min ago, cap $(( meta_cap_seconds / 3600 )) h)."
    fi
    ;;
  healthcheck-ok)
    # A healthcheck run finished cleanly: close an open "monitoring is blind" alert.
    [[ -f "$meta_flag" ]] || exit 0
    "$BOO" resolve --key obsidian-healthcheck --headline "Obsidian Sync monitoring restored" \
      && rm -f "$meta_flag"
    ;;
  *)
    echo "usage: $0 {alert|resolve|info headline [body] [next]|healthcheck-broken|post <text>}" >&2
    exit 2
    ;;
esac
