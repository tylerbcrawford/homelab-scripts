#!/bin/bash
# Git Repository Weekly Status Report
# Purpose: Quick overview of all your git repos
# Usage: ./git-status-report.sh [--markdown]

# Customize this array with paths to your git repositories
REPOS=(
  "/path/to/repo1"
  "/path/to/repo2"
  "/path/to/repo3"
  # Add more repositories as needed
)

MARKDOWN=false
if [ "$1" == "--markdown" ]; then
  MARKDOWN=true
fi

if $MARKDOWN; then
  echo "# Git Repository Status Report"
  echo ""
  echo "**Generated:** $(date '+%Y-%m-%d %H:%M')"
  echo ""
  echo "| Repository | Branch | Last Commit | Status |"
  echo "|------------|--------|-------------|--------|"
fi

for repo in "${REPOS[@]}"; do
  name=$(basename "$repo")

  if [ -d "$repo/.git" ]; then
    cd "$repo"
    branch=$(git branch --show-current 2>/dev/null || echo "detached")
    last_commit=$(git log -1 --format='%ar' 2>/dev/null || echo "unknown")
    commit_msg=$(git log -1 --format='%s' 2>/dev/null | head -c 40)
    status_count=$(git status --porcelain 2>/dev/null | wc -l)
    ahead_behind=$(git rev-list --left-right --count HEAD...@{upstream} 2>/dev/null || echo "0	0")
    ahead=$(echo "$ahead_behind" | cut -f1)
    behind=$(echo "$ahead_behind" | cut -f2)

    if [ "$status_count" -gt 0 ]; then
      status="$status_count changes"
    elif [ "$ahead" -gt 0 ]; then
      status="$ahead unpushed"
    elif [ "$behind" -gt 0 ]; then
      status="$behind behind"
    else
      status="Clean"
    fi

    if $MARKDOWN; then
      echo "| $name | $branch | $last_commit | $status |"
    else
      printf "%-25s %-12s %-15s %s\n" "$name" "$branch" "$last_commit" "$status"
    fi
  else
    if $MARKDOWN; then
      echo "| $name | - | - | Not a repo |"
    else
      printf "%-25s %-12s %-15s %s\n" "$name" "-" "-" "Not a repo"
    fi
  fi
done

if ! $MARKDOWN; then
  echo ""
  echo "Run with --markdown for formatted output"
fi
