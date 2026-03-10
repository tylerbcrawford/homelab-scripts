#!/bin/bash
# Calibre Auto-Add Watcher for Readarr
# This script watches for new ebooks and copies them to Calibre's auto-add folder

WATCH_DIR="${WATCH_DIR:-/path/to/ebook/downloads}"
AUTOADD_DIR="${AUTOADD_DIR:-/path/to/calibre/autoadd}"
LOG_FILE="${LOG_DIR:-$HOME/.local/share/calibre/logs}/calibre-autoadd.log"
PROCESSED_FILE="${PROCESSED_FILE:-$HOME/.calibre-autoadd-processed}"

# Ensure auto-add directory exists
mkdir -p "$AUTOADD_DIR"

# Create processed file list if it doesn't exist
touch "$PROCESSED_FILE"

log_message() {
    echo "$(date): $1" | tee -a "$LOG_FILE"
}

process_ebook() {
    local file="$1"
    local filename=$(basename "$file")

    # Check if it's an ebook file
    if [[ ! "$file" =~ \.(epub|mobi|azw3|pdf|cbz|cbr)$ ]]; then
        return 0
    fi

    # Atomic check-and-append with flock to prevent races between
    # the inotify handler and the background sweep loop
    (
        flock 200

        if grep -Fxq "$file" "$PROCESSED_FILE"; then
            return 0
        fi

        log_message "New ebook detected: $file"

        if cp "$file" "$AUTOADD_DIR/"; then
            log_message "Successfully copied $filename to auto-add folder"
            echo "$file" >> "$PROCESSED_FILE"
        else
            log_message "ERROR: Failed to copy $filename"
        fi
    ) 200>"${PROCESSED_FILE}.lock"
}

# Process any existing files that haven't been processed yet
scan_existing_files() {
    log_message "Scanning for existing unprocessed ebooks..."
    while IFS= read -r -d '' file; do
        process_ebook "$file"
    done < <(find "$WATCH_DIR" -type f \( -name "*.epub" -o -name "*.mobi" -o -name "*.azw3" -o -name "*.pdf" -o -name "*.cbz" -o -name "*.cbr" \) -print0)
    log_message "Finished scanning existing files"
}

log_message "Starting Calibre auto-add watcher"
log_message "Watching: $WATCH_DIR"
log_message "Auto-add: $AUTOADD_DIR"

# First, process any existing files
scan_existing_files

# Background sweep - catches anything inotifywait missed (race condition safety net)
sweep_loop() {
    while true; do
        sleep 300
        log_message "Periodic sweep starting..."
        scan_existing_files
        log_message "Periodic sweep complete"
    done
}

sweep_loop &
SWEEP_PID=$!
trap "kill $SWEEP_PID 2>/dev/null" EXIT

# Now start watching for new files
log_message "Setting up file system watches (sweep every 5 min, PID $SWEEP_PID)..."

# Use inotifywait in monitor mode (doesn't exit after each event)
inotifywait -m -r -e close_write,moved_to --format '%w%f' "$WATCH_DIR" 2>/dev/null | while read FILE; do
    process_ebook "$FILE"
done
