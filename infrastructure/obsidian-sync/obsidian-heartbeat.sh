#!/bin/bash
# 800801: stamp a heartbeat note that Obsidian Sync carries to every device.
# obsidian-fleet-ensure.sh (800802) compares each device's copy against this
# one to measure sync lag. Git-ignored, so it never creates commits.
set -euo pipefail
f="$HOME/obsidian-vault/06_Metadata/sync-heartbeat.md"
printf -- '---\nheartbeat: %s\n---\nWritten every 15 min on 800801 to measure Obsidian Sync lag across the fleet. Do not edit.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$f.tmp"
mv "$f.tmp" "$f"
