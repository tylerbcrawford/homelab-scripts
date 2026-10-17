#!/bin/bash
# pdf-convert-lib.sh — Shared 4-stage PDF-to-EPUB conversion function
#
# Source this file to use convert_single_pdf() in other scripts.
# Requires: pdftotext (poppler-utils), docker (calibre container running)
#
# The 4-stage fallback handles pdftohtml hangs (common with Internet Archive scans):
#   Stage 1: Direct PDF->EPUB via Calibre (short timeout to detect pdftohtml hang)
#   Stage 2: pdftotext on host -> text -> EPUB with heuristics (longer timeout)
#   Stage 3: Same without heuristics (fastest)
#   Stage 4: Heuristics with splitting disabled (--flow-size 0) — last resort for
#            scanned text with no usable split points (Calibre SplitError)

DETECT_TIMEOUT="${DETECT_TIMEOUT:-30}"     # Short timeout to detect pdftohtml hangs
CONVERT_TIMEOUT="${CONVERT_TIMEOUT:-300}"  # Longer timeout for actual conversion work
CALIBRE_CONTAINER="${CALIBRE_CONTAINER:-calibre}"  # Docker container name for Calibre

# Convert a single PDF to EPUB using the 4-stage fallback strategy.
#
# Arguments:
#   $1 — input PDF path (absolute)
#   $2 — output EPUB path (absolute)
#
# Returns:
#   0 on success, 1 on failure
#
# Sets global variable:
#   CONVERT_METHOD — "direct" / "fallback" / "fallback-no-heuristics" / "fallback-nosplit"
convert_single_pdf() {
    local pdf="$1"
    local epub="$2"
    CONVERT_METHOD=""

    if [[ -z "$pdf" || -z "$epub" ]]; then
        echo "  ERROR: convert_single_pdf requires input PDF and output EPUB paths"
        return 1
    fi

    if [[ ! -f "$pdf" ]]; then
        echo "  ERROR: Input PDF not found: $pdf"
        return 1
    fi

    local base
    base="$(basename "$pdf" .pdf)"

    # Stage 1: Direct PDF -> EPUB via Calibre (short timeout to detect pdftohtml hang)
    echo "  Stage 1: Direct conversion (${DETECT_TIMEOUT}s timeout)..."
    if docker exec "$CALIBRE_CONTAINER" timeout "$DETECT_TIMEOUT" ebook-convert "$pdf" "$epub" \
        --enable-heuristics 2>&1 | tail -3; then
        if [[ -f "$epub" ]]; then
            CONVERT_METHOD="direct"
            echo "  OK (direct): $(du -h "$epub" | cut -f1)"
            return 0
        fi
    fi

    echo "  Stage 1 failed — killing hung pdftohtml, falling back to pdftotext..."
    docker exec "$CALIBRE_CONTAINER" pkill -f pdftohtml 2>/dev/null || true
    sleep 1

    # Stage 2: pdftotext on host -> text -> EPUB via Calibre with heuristics
    local txt="${epub%.epub}.txt"
    if pdftotext "$pdf" "$txt" 2>&1; then
        echo "  Stage 2: Text->EPUB with heuristics (${CONVERT_TIMEOUT}s timeout)..."
        if docker exec "$CALIBRE_CONTAINER" timeout "$CONVERT_TIMEOUT" ebook-convert "$txt" "$epub" \
            --enable-heuristics 2>&1 | tail -3; then
            if [[ -f "$epub" ]]; then
                CONVERT_METHOD="fallback"
                echo "  OK (fallback): $(du -h "$epub" | cut -f1)"
                rm -f "$txt"
                return 0
            fi
        fi

        # Stage 3: Same without heuristics (faster for large text files)
        echo "  Stage 3: Text->EPUB without heuristics (${CONVERT_TIMEOUT}s timeout)..."
        if docker exec "$CALIBRE_CONTAINER" timeout "$CONVERT_TIMEOUT" ebook-convert "$txt" "$epub" \
            2>&1 | tail -3; then
            if [[ -f "$epub" ]]; then
                CONVERT_METHOD="fallback-no-heuristics"
                echo "  OK (fallback, no heuristics): $(du -h "$epub" | cut -f1)"
                rm -f "$txt"
                return 0
            fi
        fi

        # Stage 4: Splitting disabled. Scanned-book text with few block breaks makes
        # Calibre abort with "SplitError: Could not find reasonable point at which
        # to split" at the default ~260 KB flow size; one large flow is fine on
        # e-readers and keeps a good text layer from being reported as a failure.
        echo "  Stage 4: Text->EPUB with splitting disabled (${CONVERT_TIMEOUT}s timeout)..."
        if docker exec "$CALIBRE_CONTAINER" timeout "$CONVERT_TIMEOUT" ebook-convert "$txt" "$epub" \
            --enable-heuristics --flow-size 0 2>&1 | tail -3; then
            if [[ -f "$epub" ]]; then
                CONVERT_METHOD="fallback-nosplit"
                echo "  OK (fallback, no split): $(du -h "$epub" | cut -f1)"
                rm -f "$txt"
                return 0
            fi
        fi

        rm -f "$txt"
    else
        echo "  pdftotext failed on: $pdf"
    fi

    echo "  FAILED: All 4 stages exhausted for $base"
    return 1
}
