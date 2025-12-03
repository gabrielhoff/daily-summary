# Daily Summary

A CLI tool that generates a Slack-ready daily work summary including:

- **Yesterday**: PRs created/merged + meetings attended
- **Today**: Current work in progress + upcoming meetings

## Features

- 🔗 PR links formatted for Slack (clickable titles)
- 📅 Google Calendar integration via `gcalcli`
- 🤖 AI-powered meeting title summarization (via Claude API)
- 🔧 Auto-detects current git branch as "work in progress"
- 🚫 Filters out noise (stand-ups, OOO, focus time, on-call)

## Prerequisites

1. **GitHub CLI** (`gh`) - for PR information

   ```bash
   brew install gh
   gh auth login
   ```

2. **gcalcli** - for Google Calendar integration

   ```bash
   pip3 install gcalcli
   ```

   Then authenticate: `gcalcli list` (opens browser for OAuth)

3. **Anthropic API Key** (optional, for AI meeting summaries)
   ```bash
   export ANTHROPIC_API_KEY="your-key-here"
   ```

## Installation

```bash
# Clone the repo
git clone https://github.com/gabrielhoff/daily-summary.git

# Make executable
chmod +x daily-summary/daily-summary.sh

# Copy to your scripts folder
mkdir -p ~/scripts
cp daily-summary/daily-summary.sh ~/scripts/

# Add alias to ~/.zshrc or ~/.bashrc
echo 'alias daily-summary="~/scripts/daily-summary.sh"' >> ~/.zshrc
source ~/.zshrc
```

## Usage

```bash
# Run from your project directory (for "working on" detection)
cd ~/projects/your-repo
daily-summary

# Or for a specific date
daily-summary 2025-12-01
```

## Configuration

Edit the script to customize:

```bash
# Patterns to exclude from calendar (case-insensitive)
EXCLUDE_PATTERNS="ask before booking|out of office|ooo|focus time|lunch|blocked|do not book|busy|on call -|stand up|standup|stand-up"
```

## License

MIT
