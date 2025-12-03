#!/bin/bash

# Daily Summary Script
# Generates a Slack-ready summary of your PRs, meetings, and current work
# 
# Usage:
#   daily-summary.sh              # Yesterday's summary + today's agenda
#   daily-summary.sh 2025-12-01   # Specific date
#
# Prerequisites:
#   - gh (GitHub CLI) - brew install gh
#   - gcalcli - pip3 install gcalcli
#   - ANTHROPIC_API_KEY env var (optional, for AI meeting summaries)

# Claude API key for meeting summaries (set via environment variable)
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"

# Patterns to exclude from calendar (case-insensitive)
EXCLUDE_PATTERNS="ask before booking|out of office|ooo|focus time|lunch|blocked|do not book|busy|on call -|stand up|standup|stand-up"

# Default to yesterday if no date provided
if [ -z "$1" ]; then
  if [[ "$OSTYPE" == "darwin"* ]]; then
    TARGET_DATE=$(date -v-1d +%Y-%m-%d)
  else
    TARGET_DATE=$(date -d "yesterday" +%Y-%m-%d)
  fi
else
  TARGET_DATE="$1"
fi

# Format date for display
if [[ "$OSTYPE" == "darwin"* ]]; then
  DISPLAY_DATE=$(date -j -f "%Y-%m-%d" "$TARGET_DATE" "+%A, %B %d, %Y")
  NEXT_DATE=$(date -j -f "%Y-%m-%d" -v+1d "$TARGET_DATE" "+%Y-%m-%d")
  TODAY=$(date +%Y-%m-%d)
  TODAY_DISPLAY=$(date "+%A, %B %d, %Y")
  TOMORROW=$(date -v+1d +%Y-%m-%d)
else
  DISPLAY_DATE=$(date -d "$TARGET_DATE" "+%A, %B %d, %Y")
  NEXT_DATE=$(date -d "$TARGET_DATE + 1 day" "+%Y-%m-%d")
  TODAY=$(date +%Y-%m-%d)
  TODAY_DISPLAY=$(date "+%A, %B %d, %Y")
  TOMORROW=$(date -d "tomorrow" +%Y-%m-%d)
fi

# Function to summarize a meeting title using Claude
summarize_meeting_title() {
  local title="$1"
  
  # Skip if title is short enough already
  if [ ${#title} -lt 30 ]; then
    echo "$title"
    return
  fi
  
  # Escape quotes for JSON
  local escaped_title=$(echo "$title" | sed 's/"/\\"/g')
  
  # Call Claude API
  local response=$(curl -s https://api.anthropic.com/v1/messages \
    -H "Content-Type: application/json" \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    -d "{
      \"model\": \"claude-3-haiku-20240307\",
      \"max_tokens\": 50,
      \"messages\": [{
        \"role\": \"user\",
        \"content\": \"Shorten this meeting title to 5-8 words max. Keep it professional and clear. Just output the shortened title, nothing else. Meeting: ${escaped_title}\"
      }]
    }" 2>/dev/null)
  
  # Extract the text from response
  local summary=$(echo "$response" | jq -r '.content[0].text // empty' 2>/dev/null)
  
  if [ -n "$summary" ] && [ "$summary" != "null" ]; then
    echo "$summary"
  else
    echo "$title"
  fi
}

# Function to get and format meetings for a date range
get_meetings() {
  local start_date="$1"
  local end_date="$2"
  local use_ai="${3:-true}"
  local hide_started="${4:-true}"
  
  # Build gcalcli command
  local gcal_cmd="gcalcli agenda $start_date $end_date"
  if [ "$hide_started" = "true" ]; then
    gcal_cmd="$gcal_cmd --nostarted"
  fi
  
  # Get meetings and strip ALL ANSI color codes
  local raw_meetings=$(eval "$gcal_cmd" 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -v "^$" | grep -v "^[[:space:]]*$")
  
  if [ -z "$raw_meetings" ]; then
    return
  fi
  
  local output=""
  
  # Process each line
  while IFS= read -r line; do
    # Skip date headers
    if echo "$line" | grep -qE "^[A-Z][a-z]{2} [A-Z][a-z]{2} [0-9]{1,2}[[:space:]]*$"; then
      continue
    fi
    
    # Extract time (HH:MM format)
    local time=$(echo "$line" | grep -oE '[0-9]{1,2}:[0-9]{2}' | head -1)
    
    # Skip all-day events (no time)
    if [ -z "$time" ]; then
      continue
    fi
    
    # Extract title - everything after the time
    local title=$(echo "$line" | sed -E 's/.*[0-9]{1,2}:[0-9]{2}[[:space:]]*//')
    
    # Skip if no title
    if [ -z "$title" ]; then
      continue
    fi
    
    # Skip excluded patterns
    if echo "$title" | grep -iqE "$EXCLUDE_PATTERNS"; then
      continue
    fi
    
    # Get summarized title using AI
    if [ "$use_ai" = "true" ]; then
      title=$(summarize_meeting_title "$title")
    fi
    
    output+="• $title"$'\n'
  done <<< "$raw_meetings"
  
  echo "$output"
}

echo ""

# =====================
# YESTERDAY SECTION
# =====================

if [ -z "$1" ]; then
  echo "*Yesterday:*"
else
  echo "*$DISPLAY_DATE:*"
fi
echo ""

# Get PRs created on the target date
CREATED_PRS=$(gh pr list --author "@me" --state all --limit 50 --json number,title,state,url,createdAt,mergedAt | jq -r --arg date "$TARGET_DATE" --arg next "$NEXT_DATE" '
  .[] | select(.createdAt >= ($date + "T00:00:00Z") and .createdAt < ($next + "T00:00:00Z"))
  | "\(.number)|\(.title)|\(.state)|\(.url)"
')

# Get PRs merged on the target date (but created earlier)
MERGED_PRS=$(gh pr list --author "@me" --state merged --limit 50 --json number,title,state,url,createdAt,mergedAt | jq -r --arg date "$TARGET_DATE" --arg next "$NEXT_DATE" '
  .[] | select(.mergedAt != null and .mergedAt >= ($date + "T00:00:00Z") and .mergedAt < ($next + "T00:00:00Z") and .createdAt < ($date + "T00:00:00Z"))
  | "\(.number)|\(.title)|\(.state)|\(.url)"
')

# Output PRs
if [ -n "$CREATED_PRS" ]; then
  while IFS='|' read -r number title state url; do
    if [ "$state" = "MERGED" ]; then
      status="✅"
    elif [ "$state" = "OPEN" ]; then
      status="🟡"
    else
      status="🔴"
    fi
    echo "• $status <$url|$title>"
  done <<< "$CREATED_PRS"
fi

if [ -n "$MERGED_PRS" ]; then
  while IFS='|' read -r number title state url; do
    echo "• ✅ <$url|$title>"
  done <<< "$MERGED_PRS"
fi

# Yesterday's meetings
if command -v gcalcli &> /dev/null; then
  YESTERDAY_MEETINGS=$(get_meetings "$TARGET_DATE" "$NEXT_DATE" "true" "false")
  if [ -n "$YESTERDAY_MEETINGS" ]; then
    echo "$YESTERDAY_MEETINGS"
  fi
fi

if [ -z "$CREATED_PRS" ] && [ -z "$MERGED_PRS" ] && [ -z "$YESTERDAY_MEETINGS" ]; then
  echo "_No activity_"
fi

# =====================
# TODAY SECTION
# =====================

echo ""
if [ -z "$1" ]; then
  echo "*Today:*"
else
  echo "*Today ($TODAY_DISPLAY):*"
fi
echo ""

# Current work in progress
if git rev-parse --is-inside-work-tree &>/dev/null; then
  CURRENT_BRANCH=$(git branch --show-current)
  
  if [ "$CURRENT_BRANCH" != "master" ] && [ "$CURRENT_BRANCH" != "main" ]; then
    # Extract feature name from branch - humanize it
    FEATURE_NAME=$(echo "$CURRENT_BRANCH" | \
      sed 's|feature/||g' | \
      sed 's|fix/||g' | \
      sed 's|SESO-[0-9]*[-_]*||g' | \
      sed 's/[-_]/ /g' | \
      awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
    
    if [ -n "$FEATURE_NAME" ] && [ "$FEATURE_NAME" != " " ]; then
      echo "• 🔧 Working on $FEATURE_NAME"
    fi
  fi
fi

# Today's meetings
if command -v gcalcli &> /dev/null; then
  TODAY_MEETINGS=$(get_meetings "$TODAY" "$TOMORROW" "true" "true")
  if [ -n "$TODAY_MEETINGS" ]; then
    echo "$TODAY_MEETINGS"
  fi
fi

echo ""
