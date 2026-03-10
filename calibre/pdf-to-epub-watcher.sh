#!/bin/bash
# pdf-to-epub-watcher.sh — inotifywait-based auto-converter for quarantined PDFs
#
# Watches pdf-quarantine/ for new PDFs, converts them to EPUB using the 3-stage
# fallback strategy, and routes results:
#   Success -> EPUB to incoming/ + source PDF to done/
#   Failure -> source PDF to failed/
#
# Designed to run as a systemd service (pdf-epub-converter.service).
# Follows the pattern of calibre-autoadd-watcher.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/pdf-convert-lib.sh"

QUARANTINE_DIR="${QUARANTINE_DIR:-/path/to/pdf-quarantine}"
CONVERTING_DIR="$QUARANTINE_DIR/converting"
DONE_DIR="$QUARANTINE_DIR/done"
FAILED_DIR="$QUARANTINE_DIR/failed"
INCOMING_DIR="${INCOMING_DIR:-/path/to/ebook/incoming}"
NOTIFICATION_DIR="${NOTIFICATION_DIR:-/path/to/notifications}"
LOCKFILE="/tmp/pdf-epub-converter.lock"
PROCESSED_FILE="${PROCESSED_FILE:-$HOME/.pdf-converter-processed}"
SETTLE_DELAY=5  # seconds to wait for file writes to complete

# Ensure directories exist
mkdir -p "$CONVERTING_DIR" "$DONE_DIR" "$FAILED_DIR" "$INCOMING_DIR" "$NOTIFICATION_DIR"
touch "$PROCESSED_FILE"

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $1"
}

write_notification() {
    local status="$1" title="$2" filename="$3"
    shift 3
    # Remaining args are key=value pairs for extra fields
    local json
    json=$(cat <<ENDJSON
{
    "timestamp": "$(date -Iseconds)",
    "status": "$status",
    "title": "$title",
    "filename": "$filename"
ENDJSON
)
    # Append extra fields
    while [[ $# -gt 0 ]]; do
        local key="${1%%=*}"
        local val="${1#*=}"
        json="$json,
    \"$key\": \"$val\""
        shift
    done
    json="$json
}"

    local notification_file="$NOTIFICATION_DIR/$(date +%s)-$(head -c 8 /dev/urandom | xxd -p).json"
    echo "$json" > "$notification_file"
    log_message "Wrote notification: $notification_file ($status)"
}

process_pdf() {
    local pdf="$1"
    local filename
    filename="$(basename "$pdf")"
    local base="${filename%.pdf}"

    # Skip non-PDF or already processed
    if [[ ! "$filename" =~ \.pdf$ ]]; then
        return 0
    fi

    # Atomic check-and-append with flock
    (
        flock 200

        if grep -Fxq "$pdf" "$PROCESSED_FILE"; then
            return 0
        fi

        log_message "Processing: $filename"

        # Move to converting/ to prevent re-trigger
        local converting_pdf="$CONVERTING_DIR/$filename"
        if ! mv "$pdf" "$converting_pdf" 2>/dev/null; then
            log_message "ERROR: Could not move $filename to converting/"
            return 1
        fi

        # Write "converting" notification
        write_notification "converting" "$base" "$filename"

        local epub="$CONVERTING_DIR/$base.epub"
        local start_time
        start_time=$(date +%s)

        if convert_single_pdf "$converting_pdf" "$epub"; then
            local end_time duration epub_size
            end_time=$(date +%s)
            duration=$(( end_time - start_time ))
            epub_size="$(du -h "$epub" | cut -f1)"

            # Move EPUB to incoming
            mv "$epub" "$INCOMING_DIR/"
            log_message "SUCCESS: $base.epub -> incoming/ (${CONVERT_METHOD}, ${epub_size}, ${duration}s)"

            # Move source PDF to done/
            mv "$converting_pdf" "$DONE_DIR/"

            # Write success notification
            write_notification "converted" "$base" "$filename" \
                "method=$CONVERT_METHOD" \
                "size=$epub_size" \
                "duration=${duration}s"
        else
            local end_time duration
            end_time=$(date +%s)
            duration=$(( end_time - start_time ))

            # Move source PDF to failed/
            mv "$converting_pdf" "$FAILED_DIR/"
            log_message "FAILED: $base after ${duration}s — moved to failed/"

            # Write failure notification
            write_notification "failed" "$base" "$filename" \
                "duration=${duration}s"
        fi

        # Mark as processed
        echo "$pdf" >> "$PROCESSED_FILE"

    ) 200>"$LOCKFILE"
}

# Scan for any unprocessed PDFs already in the directory
scan_existing() {
    log_message "Scanning for existing unprocessed PDFs..."
    for pdf in "$QUARANTINE_DIR"/*.pdf; do
        [[ -f "$pdf" ]] && process_pdf "$pdf"
    done
    log_message "Scan complete"
}

# Clean up done/ files older than 30 days
cleanup_done() {
    local count
    count=$(find "$DONE_DIR" -name '*.pdf' -mtime +30 -print -delete 2>/dev/null | wc -l)
    if [[ "$count" -gt 0 ]]; then
        log_message "Cleaned up $count PDF(s) from done/ (>30 days old)"
    fi
}

log_message "=== PDF-to-EPUB Auto-Converter starting ==="
log_message "Watching: $QUARANTINE_DIR"
log_message "EPUB output: $INCOMING_DIR"
log_message "Hang detection: ${DETECT_TIMEOUT}s | Conversion: ${CONVERT_TIMEOUT}s"

# Process any existing files on startup
scan_existing

# Background periodic sweep (safety net) + cleanup
sweep_loop() {
    while true; do
        sleep 600  # 10 minutes
        log_message "Periodic sweep starting..."
        scan_existing
        cleanup_done
        log_message "Periodic sweep complete"
    done
}

sweep_loop &
SWEEP_PID=$!
trap "kill $SWEEP_PID 2>/dev/null" EXIT

# Watch for new PDFs via inotifywait
log_message "Starting inotifywait monitor (sweep every 10 min, PID $SWEEP_PID)..."
inotifywait -m -e close_write,moved_to --format '%w%f' "$QUARANTINE_DIR" 2>/dev/null | while read -r FILE; do
    # Only process .pdf files
    if [[ "$FILE" =~ \.pdf$ ]]; then
        # Settle delay — let large file writes complete
        sleep "$SETTLE_DELAY"
        process_pdf "$FILE"
    fi
done
