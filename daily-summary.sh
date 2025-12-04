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

# Emoji pairs representing past → future / young → old
# Format: "yesterday_emoji|today_emoji"
EMOJI_PAIRS=(
  "👶|👴"    # baby → old man
  "👶|👵"    # baby → old woman
  "🌱|🌳"    # seedling → tree
  "🐾|🦁"    # paw print → lion (cub to king)
  "🥚|🐔"    # egg → chicken
  "🐛|🦋"    # caterpillar → butterfly
  "🐣|🐓"    # hatching chick → rooster
  "🌸|🍎"    # blossom → apple
  "🍇|🍷"    # grapes → wine
  "🥛|🧀"    # milk → cheese
  "🌑|🌕"    # new moon → full moon
  "🌽|🍿"    # corn → popcorn
  "⏳|⌛"    # hourglass flowing → done
  "🪨|💎"    # rock → diamond
  "🪺|🦅"    # nest with eggs → eagle
  "🌧️|🌈"    # rain → rainbow
  "🫘|☕"    # coffee beans → coffee
  "🧱|🏰"    # brick → castle
  "🪵|🪑"    # log → chair
  "🐴|🦄"    # horse → unicorn (magical evolution)
  "📒|📚"    # notebook → books
  "🦎|🐉"    # lizard → dragon
  "🐺|🐕"    # wolf → dog (domestication)
  "🌾|🍞"    # wheat → bread
  "🫛|🥗"    # pea pod → salad
  "🪹|🐦"    # empty nest → bird
  "🧬|🧠"    # dna → brain (evolution)
  "🔩|🤖"    # screw → robot
  "🎒|🎓"    # backpack → graduation cap
)

# Randomly select an emoji pair
RANDOM_INDEX=$((RANDOM % ${#EMOJI_PAIRS[@]}))
SELECTED_PAIR="${EMOJI_PAIRS[$RANDOM_INDEX]}"
YESTERDAY_EMOJI="${SELECTED_PAIR%%|*}"
TODAY_EMOJI="${SELECTED_PAIR##*|}"

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
    
    output+="• 📅 $title"$'\n'
  done <<< "$raw_meetings"
  
  echo "$output"
}

echo ""

# =====================
# YESTERDAY SECTION
# =====================

if [ -z "$1" ]; then
  echo "$YESTERDAY_EMOJI Yesterday:"
else
  echo "$YESTERDAY_EMOJI $DISPLAY_DATE:"
fi
echo ""

# GitHub repo for PR information (change this to your repo)
GITHUB_REPO="sesolabor/seso-app"

# Get PRs created on the target date
CREATED_PRS=$(gh pr list --repo "$GITHUB_REPO" --author "@me" --state all --limit 50 --json number,title,state,url,createdAt,mergedAt | jq -r --arg date "$TARGET_DATE" --arg next "$NEXT_DATE" '
  .[] | select(.createdAt >= ($date + "T00:00:00Z") and .createdAt < ($next + "T00:00:00Z"))
  | "\(.number)|\(.title)|\(.state)|\(.url)"
')

# Get PRs merged on the target date (but created earlier)
MERGED_PRS=$(gh pr list --repo "$GITHUB_REPO" --author "@me" --state merged --limit 50 --json number,title,state,url,createdAt,mergedAt | jq -r --arg date "$TARGET_DATE" --arg next "$NEXT_DATE" '
  .[] | select(.mergedAt != null and .mergedAt >= ($date + "T00:00:00Z") and .mergedAt < ($next + "T00:00:00Z") and .createdAt < ($date + "T00:00:00Z"))
  | "\(.number)|\(.title)|\(.state)|\(.url)"
')

# Check if current branch was created before today (for "Worked on" in yesterday)
SESO_APP_DIR="$HOME/projects/seso-app"
BRANCH_CREATED_BEFORE_TODAY=false
BRANCH_HAS_OPEN_PR=false
CURRENT_BRANCH=""
FEATURE_NAME=""

if [ -d "$SESO_APP_DIR/.git" ]; then
  CURRENT_BRANCH=$(git -C "$SESO_APP_DIR" branch --show-current)
  
  if [ "$CURRENT_BRANCH" != "master" ] && [ "$CURRENT_BRANCH" != "main" ] && [ -n "$CURRENT_BRANCH" ]; then
    # Check if this branch already has an open PR (to avoid repetition)
    PR_STATE=$(gh pr view "$CURRENT_BRANCH" --repo "$GITHUB_REPO" --json state --jq '.state' 2>/dev/null)
    if [ "$PR_STATE" = "OPEN" ]; then
      BRANCH_HAS_OPEN_PR=true
    fi
    
    # Get the date of the first commit on this branch (branch creation)
    BRANCH_FIRST_COMMIT_DATE=$(git -C "$SESO_APP_DIR" log origin/master.."$CURRENT_BRANCH" --reverse --format="%cs" 2>/dev/null | head -1)
    
    if [ -n "$BRANCH_FIRST_COMMIT_DATE" ] && [ "$BRANCH_FIRST_COMMIT_DATE" \< "$TODAY" ]; then
      BRANCH_CREATED_BEFORE_TODAY=true
    fi
    
    # Extract feature name from branch - humanize it
    FEATURE_NAME=$(echo "$CURRENT_BRANCH" | \
      sed 's|feature/||g' | \
      sed 's|fix/||g' | \
      sed 's|SESO-[0-9]*[-_]*||g' | \
      sed 's/[-_]/ /g' | \
      awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')
  fi
fi

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
    echo "• $status $title ($url)"
  done <<< "$CREATED_PRS"
fi

if [ -n "$MERGED_PRS" ]; then
  while IFS='|' read -r number title state url; do
    echo "• ✅ $title ($url)"
  done <<< "$MERGED_PRS"
fi

# Show "Worked on" if branch was created before today (skip if PR already open - it'll appear in "Other PRs")
if [ "$BRANCH_CREATED_BEFORE_TODAY" = true ] && [ "$BRANCH_HAS_OPEN_PR" = false ] && [ -n "$FEATURE_NAME" ] && [ "$FEATURE_NAME" != " " ]; then
  echo "• 🔧 Worked on $FEATURE_NAME"
fi

# Yesterday's meetings
if command -v gcalcli &> /dev/null; then
  YESTERDAY_MEETINGS=$(get_meetings "$TARGET_DATE" "$NEXT_DATE" "true" "false")
  if [ -n "$YESTERDAY_MEETINGS" ]; then
    echo "$YESTERDAY_MEETINGS"
  fi
fi

SHOWED_WORKED_ON=$( [ "$BRANCH_CREATED_BEFORE_TODAY" = true ] && [ "$BRANCH_HAS_OPEN_PR" = false ] && [ -n "$FEATURE_NAME" ] && [ "$FEATURE_NAME" != " " ] && echo true || echo false )
if [ -z "$CREATED_PRS" ] && [ -z "$MERGED_PRS" ] && [ -z "$YESTERDAY_MEETINGS" ] && [ "$SHOWED_WORKED_ON" = false ]; then
  echo "_No activity_"
fi

# =====================
# TODAY SECTION
# =====================

echo ""
if [ -z "$1" ]; then
  echo "$TODAY_EMOJI Today:"
else
  echo "$TODAY_EMOJI Today ($TODAY_DISPLAY):"
fi
echo ""

# Current work in progress (skip if PR already open - it'll appear in "Other PRs")
if [ "$BRANCH_HAS_OPEN_PR" = false ] && [ -n "$FEATURE_NAME" ] && [ "$FEATURE_NAME" != " " ]; then
  if [ "$BRANCH_CREATED_BEFORE_TODAY" = true ]; then
    echo "• 🔧 Keep working on $FEATURE_NAME"
  else
    echo "• 🔧 Working on $FEATURE_NAME"
  fi
fi

# Today's meetings
if command -v gcalcli &> /dev/null; then
  TODAY_MEETINGS=$(get_meetings "$TODAY" "$TOMORROW" "true" "true")
  if [ -n "$TODAY_MEETINGS" ]; then
    echo "$TODAY_MEETINGS"
  fi
fi

# =====================
# OTHER OPEN PRs SECTION
# =====================

# Get all open PRs not created yesterday
OTHER_OPEN_PRS=$(gh pr list --repo "$GITHUB_REPO" --author "@me" --state open --limit 50 --json number,title,state,url,createdAt | jq -r --arg date "$TARGET_DATE" --arg next "$NEXT_DATE" '
  .[] | select(.createdAt < ($date + "T00:00:00Z") or .createdAt >= ($next + "T00:00:00Z"))
  | "\(.number)|\(.title)|\(.url)"
')

if [ -n "$OTHER_OPEN_PRS" ]; then
  echo ""
  echo "🔄 Other PRs in progress:"
  echo ""
  while IFS='|' read -r number title url; do
    echo "• 🟡 $title ($url)"
  done <<< "$OTHER_OPEN_PRS"
fi

echo ""
