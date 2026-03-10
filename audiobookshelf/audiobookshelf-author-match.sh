#!/bin/bash
# =============================================================================
# Audiobookshelf Author Metadata Matcher
# =============================================================================
# Automatically matches authors missing images or descriptions
# Uses the Audiobookshelf API with rate limiting to avoid 429 errors
#
# Usage: ./audiobookshelf-author-match.sh [--dry-run] [--force-all] [--dedup] [--confirm]
#   --dry-run     Show what would be matched without making changes
#   --force-all   Re-match all authors, even those with existing metadata
#   --dedup       Detect duplicate authors (dry-run by default)
#   --confirm     Execute dedup merges (requires --dedup)
#
# Fallback chain: Audnexus -> Open Library -> Wikipedia -> Goodreads -> PRH -> Google Books
#
# Requires: curl, jq, iconv
# API Token: Set ABS_API_TOKEN environment variable
# =============================================================================

set -euo pipefail

# Configuration
ABS_URL="${ABS_URL:-http://localhost:13378}"
ABS_API_TOKEN="${ABS_API_TOKEN:-}"
RATE_LIMIT_SECONDS="${RATE_LIMIT_SECONDS:-2}"  # Delay between API calls
LOG_FILE="${LOG_DIR:-/var/log}/audiobookshelf-author-match.log"
TOKEN_FILE="${TOKEN_FILE:-$(dirname "$0")/.abs-token}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse arguments
DRY_RUN=false
FORCE_ALL=false
DEDUP=false
CONFIRM=false
for arg in "$@"; do
    case $arg in
        --dry-run)
            DRY_RUN=true
            ;;
        --force-all)
            FORCE_ALL=true
            ;;
        --dedup)
            DEDUP=true
            ;;
        --confirm)
            CONFIRM=true
            ;;
    esac
done

# Logging function
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Check dependencies
check_dependencies() {
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v jq >/dev/null 2>&1 || missing+=("jq")
    command -v iconv >/dev/null 2>&1 || missing+=("iconv")

    if [ ${#missing[@]} -gt 0 ]; then
        log "ERROR" "Missing dependencies: ${missing[*]}"
        echo "Install with: sudo apt install ${missing[*]}"
        exit 1
    fi
}

# Load API token
load_token() {
    # Try environment variable first
    if [ -n "$ABS_API_TOKEN" ]; then
        return 0
    fi

    # Try token file
    if [ -f "$TOKEN_FILE" ]; then
        ABS_API_TOKEN=$(cat "$TOKEN_FILE")
        return 0
    fi

    echo -e "${RED}Error: ABS_API_TOKEN not set${NC}"
    echo ""
    echo "To set your API token, either:"
    echo "  1. export ABS_API_TOKEN='your-token-here'"
    echo "  2. echo 'your-token-here' > $TOKEN_FILE && chmod 600 $TOKEN_FILE"
    echo ""
    echo "To get your API token:"
    echo "  1. Log into Audiobookshelf as admin"
    echo "  2. Go to Settings -> Users"
    echo "  3. Click on your user"
    echo "  4. Copy the API Token"
    exit 1
}

# Validate API token by fetching libraries
validate_token() {
    local response
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $ABS_API_TOKEN" \
        "$ABS_URL/api/libraries")

    if [ "$response" != "200" ]; then
        log "ERROR" "API token validation failed (HTTP $response)"
        echo -e "${RED}Error: Invalid API token or Audiobookshelf not reachable${NC}"
        exit 1
    fi

    log "INFO" "API token validated successfully"
}

# Get all audiobook libraries (mediaType=book)
get_audiobook_libraries() {
    curl -s \
        -H "Authorization: Bearer $ABS_API_TOKEN" \
        "$ABS_URL/api/libraries" | jq -c '.libraries[] | select(.mediaType == "book") | {id, name}'
}

# Get authors for a library
get_library_authors() {
    local library_id=$1
    curl -s \
        -H "Authorization: Bearer $ABS_API_TOKEN" \
        "$ABS_URL/api/libraries/$library_id/authors" | jq -c '.authors[]'
}

# Match a single author
match_author() {
    local author_id=$1
    local author_name=$2

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Bearer $ABS_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"q\": \"$author_name\"}" \
        "$ABS_URL/api/authors/$author_id/match")

    local http_code
    http_code=$(echo "$response" | tail -n1)
    local body
    body=$(echo "$response" | sed '$d')

    if [ "$http_code" = "200" ]; then
        local updated
        updated=$(echo "$body" | jq -r '.updated')
        local has_image
        has_image=$(echo "$body" | jq -r '.author.imagePath // empty')
        local has_desc
        has_desc=$(echo "$body" | jq -r '.author.description // empty')

        if [ "$updated" = "true" ]; then
            echo -e "${GREEN}✓${NC} Matched: $author_name"
            log "SUCCESS" "Matched author: $author_name (ID: $author_id)"
            return 0
        elif [ -n "$has_image" ] || [ -n "$has_desc" ]; then
            echo -e "${YELLOW}○${NC} Already has data: $author_name"
            log "INFO" "Author already has data: $author_name"
            return 0
        else
            echo -e "${YELLOW}○${NC} No data found: $author_name"
            log "INFO" "No match data for: $author_name (ID: $author_id)"
            return 1
        fi
    elif [ "$http_code" = "429" ]; then
        echo -e "${RED}!${NC} Rate limited - waiting longer..."
        log "WARN" "Rate limited on: $author_name - increasing delay"
        sleep 10
        return 2
    else
        echo -e "${RED}✗${NC} Failed ($http_code): $author_name"
        log "ERROR" "Failed to match: $author_name (HTTP $http_code)"
        return 1
    fi
}

# Fallback: Open Library author search + photo/bio
# Returns 0 if anything updated, 1 otherwise
fallback_openlibrary() {
    local author_id=$1
    local author_name=$2
    local needs_image=$3
    local needs_desc=$4

    local encoded_name
    encoded_name=$(echo "$author_name" | sed 's/ /+/g')
    local search_result
    search_result=$(curl -s "https://openlibrary.org/search/authors.json?q=${encoded_name}&limit=1")

    local ol_key
    ol_key=$(echo "$search_result" | jq -r '.docs[0].key // empty')

    if [ -z "$ol_key" ]; then
        return 1
    fi

    local updated=false

    # Fetch photo if needed
    if [ "$needs_image" = "true" ]; then
        local photo_url="https://covers.openlibrary.org/a/olid/${ol_key}-L.jpg"

        # Open Library returns tiny 1x1 placeholders instead of 404s — download to check size first
        local tmp_photo="/tmp/abs_author_${author_id}.jpg"
        curl -s -o "$tmp_photo" "$photo_url"
        local file_size
        file_size=$(stat -c%s "$tmp_photo" 2>/dev/null || echo "0")
        rm -f "$tmp_photo"

        if [ "$file_size" -gt 1000 ]; then
            # ABS image API accepts {"url": "..."} and downloads server-side
            curl -s -X POST \
                -H "Authorization: Bearer $ABS_API_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"url\": \"$photo_url\"}" \
                "$ABS_URL/api/authors/$author_id/image" > /dev/null
            updated=true
            log "SUCCESS" "Open Library photo for: $author_name (OLID: $ol_key)"
        fi
    fi

    # Fetch bio if needed
    if [ "$needs_desc" = "true" ]; then
        local author_data
        author_data=$(curl -s "https://openlibrary.org/authors/${ol_key}.json")

        # Bio can be a string OR an object {type, value} — handle both
        local bio
        bio=$(echo "$author_data" | jq -r '
            if .bio | type == "object" then .bio.value
            elif .bio | type == "string" then .bio
            else empty end')

        if [ -n "$bio" ]; then
            local escaped_bio
            escaped_bio=$(echo "$bio" | jq -Rs '.')
            curl -s -X PATCH \
                -H "Authorization: Bearer $ABS_API_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"description\": $escaped_bio}" \
                "$ABS_URL/api/authors/$author_id" > /dev/null
            updated=true
            log "SUCCESS" "Open Library bio for: $author_name"
        fi
    fi

    $updated && return 0 || return 1
}

# Fallback: Wikipedia REST API for photo + bio
# Returns 0 if anything updated, 1 otherwise
fallback_wikipedia() {
    local author_id=$1
    local author_name=$2
    local needs_image=$3
    local needs_desc=$4

    local encoded_name
    encoded_name=$(echo "$author_name" | sed 's/ /_/g')
    local wiki_result
    wiki_result=$(curl -s "https://en.wikipedia.org/api/rest_v1/page/summary/${encoded_name}")

    local wiki_type
    wiki_type=$(echo "$wiki_result" | jq -r '.type // empty')

    if [ "$wiki_type" != "standard" ]; then
        return 1
    fi

    local updated=false

    # Fetch photo if needed — Wikipedia provides .originalimage.source
    if [ "$needs_image" = "true" ]; then
        local photo_url
        photo_url=$(echo "$wiki_result" | jq -r '.originalimage.source // empty')

        if [ -n "$photo_url" ]; then
            # ABS image API accepts {"url": "..."} and downloads server-side
            local escaped_url
            escaped_url=$(echo "$photo_url" | jq -Rs '.' | sed 's/^"//;s/"$//')
            curl -s -X POST \
                -H "Authorization: Bearer $ABS_API_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"url\": \"$escaped_url\"}" \
                "$ABS_URL/api/authors/$author_id/image" > /dev/null
            updated=true
            log "SUCCESS" "Wikipedia photo for: $author_name"
        fi
    fi

    # Fetch bio if needed
    if [ "$needs_desc" = "true" ]; then
        local extract
        extract=$(echo "$wiki_result" | jq -r '.extract // empty')

        if [ -n "$extract" ] && [ ${#extract} -gt 50 ]; then
            local escaped_extract
            escaped_extract=$(echo "$extract" | jq -Rs '.')
            curl -s -X PATCH \
                -H "Authorization: Bearer $ABS_API_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"description\": $escaped_extract}" \
                "$ABS_URL/api/authors/$author_id" > /dev/null
            updated=true
            log "SUCCESS" "Wikipedia bio for: $author_name"
        fi
    fi

    $updated && return 0 || return 1
}

# Fallback: Goodreads — photo only (bios require JS rendering)
# Scrapes author search results and author page for gr-assets photo URL
# Returns 0 if photo uploaded, 1 otherwise
fallback_goodreads() {
    local author_id=$1
    local author_name=$2
    local needs_image=$3
    local needs_desc=$4  # unused — Goodreads bios need JS

    if [ "$needs_image" != "true" ]; then
        return 1  # Goodreads is photo-only in this script
    fi

    local encoded_name
    encoded_name=$(echo "$author_name" | sed 's/ /+/g')

    # Step 1: Search Goodreads for author ID
    local search_html
    search_html=$(curl -sL "https://www.goodreads.com/search?q=${encoded_name}")
    local gr_author_id
    gr_author_id=$(echo "$search_html" | grep -oP 'author/show/\d+' | head -1 | grep -oP '\d+')

    if [ -z "$gr_author_id" ]; then
        return 1
    fi

    # Step 2: Fetch author page, extract photo URL
    local author_html
    author_html=$(curl -sL "https://www.goodreads.com/author/show/$gr_author_id")

    # Check for nophoto placeholder
    if echo "$author_html" | grep -q 'nophoto'; then
        return 1
    fi

    local photo_url
    photo_url=$(echo "$author_html" | grep -oP 'https://images\.gr-assets\.com/authors/[0-9]+p8/[0-9]+\.jpg' | head -1)

    if [ -z "$photo_url" ]; then
        return 1
    fi

    # Step 3: Upload to ABS via JSON URL (server-side download)
    curl -s -X POST \
        -H "Authorization: Bearer $ABS_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"url\": \"$photo_url\"}" \
        "$ABS_URL/api/authors/$author_id/image" > /dev/null

    log "SUCCESS" "Goodreads photo for: $author_name (GR ID: $gr_author_id)"
    return 0
}

# Fallback: Penguin Random House — bio only
# Scrapes PRH author page for JSON-LD structured data containing bio
# Returns 0 if bio updated, 1 otherwise
fallback_prh() {
    local author_id=$1
    local author_name=$2

    local encoded_name
    encoded_name=$(echo "$author_name" | sed 's/ /+/g')

    # Search PRH for author page
    local search_html
    search_html=$(curl -sL "https://www.penguinrandomhouse.com/search/site?q=${encoded_name}")
    local prh_path
    prh_path=$(echo "$search_html" | grep -oP 'authors/\d+/[^"]+' | head -1)

    if [ -z "$prh_path" ]; then
        return 1
    fi

    # Fetch author page, extract bio from JSON-LD
    local author_html
    author_html=$(curl -sL "https://www.penguinrandomhouse.com/$prh_path")
    local bio
    bio=$(echo "$author_html" | grep -oP '"description"\s*:\s*"[^"]+' | head -1 | sed 's/"description"\s*:\s*"//')

    if [ -z "$bio" ] || [ ${#bio} -lt 30 ]; then
        return 1
    fi

    # Decode HTML entities
    bio=$(echo "$bio" | sed 's/&nbsp;/ /g; s/&#160;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g')

    local escaped_bio
    escaped_bio=$(echo "$bio" | jq -Rs '.')
    curl -s -X PATCH \
        -H "Authorization: Bearer $ABS_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"description\": $escaped_bio}" \
        "$ABS_URL/api/authors/$author_id" > /dev/null

    log "SUCCESS" "PRH bio for: $author_name"
    return 0
}

# Fallback: Google Books — bio only (last resort)
# Searches for books by the author and uses the book description if it mentions the author
# Returns 0 if bio updated, 1 otherwise
fallback_google_books() {
    local author_id=$1
    local author_name=$2

    local encoded_name
    encoded_name=$(echo "$author_name" | sed 's/ /+/g')
    local gb_result
    gb_result=$(curl -s "https://www.googleapis.com/books/v1/volumes?q=inauthor:${encoded_name}&maxResults=1")

    local description
    description=$(echo "$gb_result" | jq -r '.items[0].volumeInfo.description // empty')

    if [ -z "$description" ]; then
        return 1
    fi

    # Only use if description mentions the author name (avoid unrelated book descriptions)
    # Check against first and last name parts for flexibility
    local last_name
    last_name=$(echo "$author_name" | awk '{print $NF}')
    if ! echo "$description" | grep -qi "$last_name"; then
        return 1
    fi

    local escaped_desc
    escaped_desc=$(echo "$description" | jq -Rs '.')
    curl -s -X PATCH \
        -H "Authorization: Bearer $ABS_API_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{\"description\": $escaped_desc}" \
        "$ABS_URL/api/authors/$author_id" > /dev/null

    log "SUCCESS" "Google Books bio for: $author_name"
    return 0
}

# Resolve duplicate authors (Unicode name variations)
# Dry-run by default — requires --confirm to execute
resolve_duplicates() {
    local do_confirm=$1

    log "INFO" "Starting duplicate author detection..."
    echo -e "${BLUE}Scanning for duplicate authors...${NC}"
    echo ""

    # Fetch all authors from all libraries
    local all_authors=""
    local seen_ids=""

    while IFS= read -r library; do
        [ -z "$library" ] && continue
        local lib_id
        lib_id=$(echo "$library" | jq -r '.id')

        while IFS= read -r author; do
            [ -z "$author" ] && continue
            local author_id
            author_id=$(echo "$author" | jq -r '.id')

            if [[ "$seen_ids" == *"$author_id"* ]]; then
                continue
            fi
            seen_ids="$seen_ids $author_id"

            if [ -n "$all_authors" ]; then
                all_authors="$all_authors"$'\n'"$author"
            else
                all_authors="$author"
            fi
        done < <(get_library_authors "$lib_id")
    done < <(get_audiobook_libraries)

    if [ -z "$all_authors" ]; then
        echo "No authors found."
        return 0
    fi

    # Build normalized name map: normalized_name -> list of "id|name|numBooks|hasImage|hasDesc"
    declare -A name_groups
    while IFS= read -r author; do
        [ -z "$author" ] && continue
        local author_id author_name num_books has_image has_desc
        author_id=$(echo "$author" | jq -r '.id')
        author_name=$(echo "$author" | jq -r '.name')
        num_books=$(echo "$author" | jq -r '.numBooks // 0')
        has_image=$(echo "$author" | jq -r 'if .imagePath and .imagePath != "" then "1" else "0" end')
        has_desc=$(echo "$author" | jq -r 'if .description and .description != "" then "1" else "0" end')

        # Normalize: strip diacritics, lowercase
        local normalized
        normalized=$(echo "$author_name" | iconv -f utf-8 -t ascii//TRANSLIT 2>/dev/null | tr '[:upper:]' '[:lower:]')

        local entry="${author_id}|${author_name}|${num_books}|${has_image}|${has_desc}"
        if [ -n "${name_groups[$normalized]:-}" ]; then
            name_groups[$normalized]="${name_groups[$normalized]}"$'\n'"$entry"
        else
            name_groups[$normalized]="$entry"
        fi
    done <<< "$all_authors"

    # Find groups with >1 author (duplicates)
    local dup_count=0
    local merge_count=0

    for normalized in "${!name_groups[@]}"; do
        local group="${name_groups[$normalized]}"
        local group_size
        group_size=$(echo "$group" | wc -l)

        if [ "$group_size" -le 1 ]; then
            continue
        fi

        dup_count=$((dup_count + 1))

        # Sort by: numBooks desc, hasImage desc, hasDesc desc, name length asc (prefer ASCII/shorter)
        local sorted
        sorted=$(echo "$group" | sort -t'|' -k3,3nr -k4,4nr -k5,5nr | head -1)

        local canonical_id canonical_name
        canonical_id=$(echo "$sorted" | cut -d'|' -f1)
        canonical_name=$(echo "$sorted" | cut -d'|' -f2)

        echo -e "${YELLOW}Duplicate group:${NC} $normalized"

        while IFS= read -r entry; do
            local eid ename enbooks eimage edesc
            eid=$(echo "$entry" | cut -d'|' -f1)
            ename=$(echo "$entry" | cut -d'|' -f2)
            enbooks=$(echo "$entry" | cut -d'|' -f3)
            eimage=$(echo "$entry" | cut -d'|' -f4)
            edesc=$(echo "$entry" | cut -d'|' -f5)

            local marker=""
            if [ "$eid" = "$canonical_id" ]; then
                marker=" ${GREEN}<- canonical${NC}"
            fi

            echo -e "  ${ename} (books: ${enbooks}, image: ${eimage}, bio: ${edesc})${marker}"
        done <<< "$group"

        # Process duplicates (non-canonical entries)
        while IFS= read -r entry; do
            local dup_id dup_name
            dup_id=$(echo "$entry" | cut -d'|' -f1)
            dup_name=$(echo "$entry" | cut -d'|' -f2)

            if [ "$dup_id" = "$canonical_id" ]; then
                continue
            fi

            if [ "$do_confirm" = "true" ]; then
                # Fetch books for this duplicate author
                local author_detail
                author_detail=$(curl -s \
                    -H "Authorization: Bearer $ABS_API_TOKEN" \
                    "$ABS_URL/api/authors/$dup_id?include=items")

                local book_ids
                book_ids=$(echo "$author_detail" | jq -r '.libraryItems[]?.id // empty')

                # Reassign each book to canonical author
                local books_moved=0
                while IFS= read -r book_id; do
                    [ -z "$book_id" ] && continue

                    # Get current book metadata to preserve other authors
                    local book_data
                    book_data=$(curl -s \
                        -H "Authorization: Bearer $ABS_API_TOKEN" \
                        "$ABS_URL/api/items/$book_id")

                    # Replace duplicate author with canonical in the authors array
                    local updated_authors
                    updated_authors=$(echo "$book_data" | jq -c --arg dup_name "$dup_name" --arg canon_name "$canonical_name" '
                        .media.metadata.authors | map(
                            if .name == $dup_name then .name = $canon_name
                            else . end
                        )')

                    curl -s -X PATCH \
                        -H "Authorization: Bearer $ABS_API_TOKEN" \
                        -H "Content-Type: application/json" \
                        -d "{\"metadata\": {\"authors\": $updated_authors}}" \
                        "$ABS_URL/api/items/$book_id/media" > /dev/null

                    books_moved=$((books_moved + 1))
                    sleep 1
                done <<< "$book_ids"

                # Delete the orphaned duplicate author
                curl -s -X DELETE \
                    -H "Authorization: Bearer $ABS_API_TOKEN" \
                    "$ABS_URL/api/authors/$dup_id" > /dev/null

                echo -e "  ${GREEN}Merged:${NC} ${dup_name} -> ${canonical_name} (${books_moved} books reassigned)"
                log "SUCCESS" "Merged: ${dup_name} -> ${canonical_name} (${books_moved} books reassigned)"
                merge_count=$((merge_count + 1))
                sleep "$RATE_LIMIT_SECONDS"
            else
                echo -e "  ${BLUE}Would merge:${NC} ${dup_name} -> ${canonical_name}"
            fi
        done <<< "$group"

        echo ""
    done

    if [ "$dup_count" -eq 0 ]; then
        echo -e "${GREEN}No duplicate authors found!${NC}"
        log "INFO" "No duplicate authors detected"
    else
        echo "=========================================="
        echo "Duplicate groups found: $dup_count"
        if [ "$do_confirm" = "true" ]; then
            echo -e "${GREEN}Authors merged:${NC} $merge_count"
        else
            echo -e "${YELLOW}Run with --dedup --confirm to execute merges${NC}"
        fi
        echo "=========================================="
        log "INFO" "Dedup complete: $dup_count groups, $merge_count merged"
    fi
}

# Main execution
main() {
    log "INFO" "=========================================="
    log "INFO" "Audiobookshelf Author Matcher Started"
    log "INFO" "=========================================="

    if $DRY_RUN; then
        echo -e "${YELLOW}DRY RUN MODE - No changes will be made${NC}"
        log "INFO" "Running in dry-run mode"
    fi

    if $FORCE_ALL; then
        echo -e "${YELLOW}FORCE ALL MODE - Re-matching all authors${NC}"
        log "INFO" "Force-all mode enabled"
    fi

    check_dependencies
    load_token
    validate_token

    # Handle --dedup mode (separate from metadata matching)
    if $DEDUP; then
        resolve_duplicates "$CONFIRM"
        exit 0
    fi

    echo ""
    echo -e "${BLUE}Fetching libraries from Audiobookshelf...${NC}"

    # Collect all authors from all audiobook libraries
    local all_authors=""
    local seen_ids=""

    while IFS= read -r library; do
        [ -z "$library" ] && continue
        local lib_id lib_name
        lib_id=$(echo "$library" | jq -r '.id')
        lib_name=$(echo "$library" | jq -r '.name')

        echo "  Library: $lib_name"
        log "INFO" "Scanning library: $lib_name (ID: $lib_id)"

        while IFS= read -r author; do
            [ -z "$author" ] && continue
            local author_id
            author_id=$(echo "$author" | jq -r '.id')

            # Skip if already seen (author in multiple libraries)
            if [[ "$seen_ids" == *"$author_id"* ]]; then
                continue
            fi
            seen_ids="$seen_ids $author_id"

            if [ -n "$all_authors" ]; then
                all_authors="$all_authors"$'\n'"$author"
            else
                all_authors="$author"
            fi
        done < <(get_library_authors "$lib_id")
    done < <(get_audiobook_libraries)

    echo ""

    local total_authors
    total_authors=$(echo "$all_authors" | grep -c '^' 2>/dev/null || echo "0")

    echo "Found $total_authors total unique authors"
    log "INFO" "Found $total_authors total unique authors"

    # Filter authors needing updates
    local needs_update=""
    if $FORCE_ALL; then
        needs_update="$all_authors"
    else
        # Filter to authors missing image OR description
        # Also detect "ghost images" — imagePath set but actual file missing (404)
        while IFS= read -r author; do
            [ -z "$author" ] && continue
            local has_image has_desc author_id_check
            has_image=$(echo "$author" | jq -r '.imagePath // empty')
            has_desc=$(echo "$author" | jq -r '.description // empty')

            # Verify image actually exists if imagePath is set
            if [ -n "$has_image" ]; then
                author_id_check=$(echo "$author" | jq -r '.id')
                local img_http_code
                img_http_code=$(curl -s -o /dev/null -w "%{http_code}" \
                    -H "Authorization: Bearer $ABS_API_TOKEN" \
                    "$ABS_URL/api/authors/$author_id_check/image")
                if [ "$img_http_code" != "200" ]; then
                    log "WARN" "Ghost image detected for $(echo "$author" | jq -r '.name') (HTTP $img_http_code)"
                    has_image=""  # Treat as missing
                fi
            fi

            if [ -z "$has_image" ] || [ -z "$has_desc" ]; then
                if [ -n "$needs_update" ]; then
                    needs_update="$needs_update"$'\n'"$author"
                else
                    needs_update="$author"
                fi
            fi
        done <<< "$all_authors"
    fi

    local count=0
    local matched=0
    local failed=0
    local matched_audnexus=0
    local matched_openlibrary=0
    local matched_wikipedia=0
    local matched_goodreads=0
    local matched_prh=0
    local matched_google_books=0

    # Count items needing update
    local needs_count
    if [ -z "$needs_update" ]; then
        needs_count=0
    else
        needs_count=$(echo "$needs_update" | grep -c '^' 2>/dev/null || echo "0")
    fi

    if [ "$needs_count" = "0" ]; then
        echo -e "${GREEN}All authors already have metadata!${NC}"
        log "INFO" "All authors already have metadata - nothing to do"
        exit 0
    fi

    echo "Authors needing metadata: $needs_count"
    echo ""
    log "INFO" "Authors needing metadata: $needs_count"

    # Process each author
    while IFS= read -r author; do
        [ -z "$author" ] && continue

        local author_id author_name has_image has_desc
        author_id=$(echo "$author" | jq -r '.id')
        author_name=$(echo "$author" | jq -r '.name')
        has_image=$(echo "$author" | jq -r '.imagePath // empty')
        has_desc=$(echo "$author" | jq -r '.description // empty')

        count=$((count + 1))

        echo -ne "[${count}/${needs_count}] "

        if $DRY_RUN; then
            local missing=""
            [ -z "$has_image" ] && missing+="image "
            [ -z "$has_desc" ] && missing+="bio "
            echo -e "${BLUE}Would match:${NC} $author_name (missing: ${missing:-none}) [Audnexus -> OL -> Wikipedia -> Goodreads -> PRH -> Google Books]"
            continue
        fi

        # Attempt to match via Audnexus first
        local match_rc=0
        match_author "$author_id" "$author_name" || match_rc=$?

        if [ "$match_rc" -eq 0 ]; then
            matched=$((matched + 1))
            matched_audnexus=$((matched_audnexus + 1))
        elif [ "$match_rc" -eq 2 ]; then
            # Rate limited — retry once after the extended sleep already done in match_author
            local retry_rc=0
            match_author "$author_id" "$author_name" || retry_rc=$?
            if [ "$retry_rc" -eq 0 ]; then
                matched=$((matched + 1))
                matched_audnexus=$((matched_audnexus + 1))
            fi
            # If retry also fails, fall through to fallbacks below
            [ "$retry_rc" -ne 0 ] && match_rc=1
        fi

        # Fallback chain — only if Audnexus didn't fully resolve
        if [ "$match_rc" -ne 0 ]; then
            # Re-fetch author to check what Audnexus may have partially filled
            local refreshed
            refreshed=$(curl -s \
                -H "Authorization: Bearer $ABS_API_TOKEN" \
                "$ABS_URL/api/authors/$author_id")
            local still_needs_image="false"
            local still_needs_desc="false"
            local refreshed_image refreshed_desc
            refreshed_image=$(echo "$refreshed" | jq -r '.imagePath // empty')
            refreshed_desc=$(echo "$refreshed" | jq -r '.description // empty')
            [ -z "$refreshed_image" ] && still_needs_image="true"
            [ -z "$refreshed_desc" ] && still_needs_desc="true"

            local any_fallback_success=false

            # Fallback 1: Open Library (photo + bio)
            if [ "$still_needs_image" = "true" ] || [ "$still_needs_desc" = "true" ]; then
                echo -ne "  ${BLUE}-> Open Library...${NC} "
                if fallback_openlibrary "$author_id" "$author_name" "$still_needs_image" "$still_needs_desc"; then
                    echo -e "${GREEN}found${NC}"
                    any_fallback_success=true
                    matched_openlibrary=$((matched_openlibrary + 1))
                    # Re-check what's still missing after OL
                    refreshed=$(curl -s \
                        -H "Authorization: Bearer $ABS_API_TOKEN" \
                        "$ABS_URL/api/authors/$author_id")
                    refreshed_image=$(echo "$refreshed" | jq -r '.imagePath // empty')
                    refreshed_desc=$(echo "$refreshed" | jq -r '.description // empty')
                    [ -n "$refreshed_image" ] && still_needs_image="false"
                    [ -n "$refreshed_desc" ] && still_needs_desc="false"
                else
                    echo -e "${YELLOW}no match${NC}"
                fi
                sleep 1
            fi

            # Fallback 2: Wikipedia (photo + bio)
            if [ "$still_needs_image" = "true" ] || [ "$still_needs_desc" = "true" ]; then
                echo -ne "  ${BLUE}-> Wikipedia...${NC} "
                if fallback_wikipedia "$author_id" "$author_name" "$still_needs_image" "$still_needs_desc"; then
                    echo -e "${GREEN}found${NC}"
                    any_fallback_success=true
                    matched_wikipedia=$((matched_wikipedia + 1))
                    # Re-check what's still missing after Wikipedia
                    refreshed=$(curl -s \
                        -H "Authorization: Bearer $ABS_API_TOKEN" \
                        "$ABS_URL/api/authors/$author_id")
                    refreshed_image=$(echo "$refreshed" | jq -r '.imagePath // empty')
                    refreshed_desc=$(echo "$refreshed" | jq -r '.description // empty')
                    [ -n "$refreshed_image" ] && still_needs_image="false"
                    [ -n "$refreshed_desc" ] && still_needs_desc="false"
                else
                    echo -e "${YELLOW}no match${NC}"
                fi
                sleep 1
            fi

            # Fallback 3: Goodreads (photo only)
            if [ "$still_needs_image" = "true" ]; then
                echo -ne "  ${BLUE}-> Goodreads...${NC} "
                if fallback_goodreads "$author_id" "$author_name" "$still_needs_image" "$still_needs_desc"; then
                    echo -e "${GREEN}found${NC}"
                    any_fallback_success=true
                    matched_goodreads=$((matched_goodreads + 1))
                else
                    echo -e "${YELLOW}no match${NC}"
                fi
                sleep 1
            fi

            # Fallback 4: Penguin Random House (bio only)
            if [ "$still_needs_desc" = "true" ]; then
                echo -ne "  ${BLUE}-> PRH...${NC} "
                if fallback_prh "$author_id" "$author_name"; then
                    echo -e "${GREEN}found${NC}"
                    any_fallback_success=true
                    matched_prh=$((matched_prh + 1))
                    # Re-check what's still missing after PRH
                    refreshed=$(curl -s \
                        -H "Authorization: Bearer $ABS_API_TOKEN" \
                        "$ABS_URL/api/authors/$author_id")
                    refreshed_desc=$(echo "$refreshed" | jq -r '.description // empty')
                    [ -n "$refreshed_desc" ] && still_needs_desc="false"
                else
                    echo -e "${YELLOW}no match${NC}"
                fi
                sleep 1
            fi

            # Fallback 5: Google Books (bio only — last resort)
            if [ "$still_needs_desc" = "true" ]; then
                echo -ne "  ${BLUE}-> Google Books...${NC} "
                if fallback_google_books "$author_id" "$author_name"; then
                    echo -e "${GREEN}found${NC}"
                    any_fallback_success=true
                    matched_google_books=$((matched_google_books + 1))
                else
                    echo -e "${YELLOW}no match${NC}"
                fi
                sleep 1
            fi

            if $any_fallback_success; then
                matched=$((matched + 1))
            else
                failed=$((failed + 1))
                log "WARN" "All sources exhausted for: $author_name"
            fi
        fi

        # Rate limiting between authors
        if [ $count -lt "$needs_count" ]; then
            sleep "$RATE_LIMIT_SECONDS"
        fi

    done <<< "$needs_update"

    echo ""
    echo "=========================================="
    echo "Processed: $count authors"
    echo -e "  ${GREEN}Audnexus:${NC}      $matched_audnexus"
    echo -e "  ${GREEN}Open Library:${NC}  $matched_openlibrary"
    echo -e "  ${GREEN}Wikipedia:${NC}     $matched_wikipedia"
    echo -e "  ${GREEN}Goodreads:${NC}     $matched_goodreads"
    echo -e "  ${GREEN}PRH:${NC}           $matched_prh"
    echo -e "  ${GREEN}Google Books:${NC}  $matched_google_books"
    echo -e "  ${RED}Still missing:${NC} $failed"
    echo "=========================================="

    log "INFO" "Completed: $count processed, $matched matched (audnexus=$matched_audnexus, openlibrary=$matched_openlibrary, wikipedia=$matched_wikipedia, goodreads=$matched_goodreads, prh=$matched_prh, google_books=$matched_google_books), $failed failed"
    log "INFO" "=========================================="
}

# Run
main "$@"
