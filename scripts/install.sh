#!/usr/bin/env bash
# Install the Foundry/Draft Hermes integration:
#
#   1. copy the skills into ~/.hermes/skills/
#   2. register the draft MCP server in ~/.hermes/config.yaml
#
# Both steps are idempotent — re-running refreshes the skills and
# leaves an existing draft MCP server entry untouched.
#
# YAML has no repeated-key merge the way TOML tables do, so step 2 is
# deliberately conservative: it appends a fresh `mcp_servers:` block
# only when the file has none, and otherwise prints the exact block
# for you to paste under your existing `mcp_servers:` rather than
# risk corrupting a multi-server config.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
SKILLS_DIR="$HERMES_HOME/skills"
CONFIG="$HERMES_HOME/config.yaml"
MCP_PATH="$REPO_DIR/mcp/draft-mcp.js"

echo "Foundry/Draft Hermes integration — installing into $HERMES_HOME"

# --- Node check (the MCP server needs Node 18+ for global fetch) ----
if ! command -v node >/dev/null 2>&1; then
  echo "  ! Node is not on PATH. The MCP server needs Node 18+ — install it"
  echo "    before using /draft-work or /draft-queue."
else
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [ "$major" -lt 18 ]; then
    echo "  ! Node $(node -v) is too old — the MCP server needs Node 18+."
  fi
fi

# --- 1. skills ------------------------------------------------------
mkdir -p "$SKILLS_DIR"
for skill in draft-queue draft-work draft-watch draft-refresh draft-agents; do
  cp -R "$REPO_DIR/skills/$skill" "$SKILLS_DIR/"
done
echo "  ✓ copied skills → $SKILLS_DIR"
echo "    (/draft-queue, /draft-work, /draft-watch, /draft-refresh, /draft-agents)"

# --- 1b. registry broker client -------------------------------------
# The draft-agents skill shells out to this to talk to the local Foundry
# Agent Registry daemon (#194). Installed under $HERMES_HOME/scripts so
# the skill can find it regardless of where this repo lives.
mkdir -p "$HERMES_HOME/scripts"
cp "$REPO_DIR/scripts/foundry-registry.js" "$HERMES_HOME/scripts/"
echo "  ✓ copied registry broker client → $HERMES_HOME/scripts/foundry-registry.js"

# --- 2. MCP server in config.yaml -----------------------------------
mkdir -p "$HERMES_HOME"
touch "$CONFIG"

# Credentials. Unlike Claude Code / Codex, Hermes does NOT hand a stdio
# MCP subprocess your shell environment — it passes only a safe baseline
# (PATH, HOME, USER, LANG, LC_ALL, TERM, SHELL, TMPDIR, XDG_*) plus
# whatever is in the entry's `env:` map, and it does NOT interpolate
# ${VAR} inside that map. So `FOUNDRY_API_KEY=... hermes` never reaches the
# server: the key must be written literally into `env:` below. We read it
# from your shell at install time; if it isn't exported yet, we write a
# clear placeholder for you to fill in.
# Read either name from your shell; write the current one into the config.
# Configs already carrying DRAFT_* keep working — the server falls back to
# them (#456) — so an existing install needs no edit.
KEY="${FOUNDRY_API_KEY:-${DRAFT_API_KEY:-}}"
URL="${FOUNDRY_API_URL:-${DRAFT_API_URL:-}}"
KEY_IS_PLACEHOLDER=0
if [ -z "$KEY" ]; then
  KEY="fdrk_REPLACE_WITH_YOUR_KEY"
  KEY_IS_PLACEHOLDER=1
fi

# The draft entry, indented two spaces as a child of `mcp_servers:`.
# Emitted via a literal heredoc (not `read`, which would strip the
# leading indentation off the first line and break the YAML nesting).
# FOUNDRY_API_URL is only emitted when you've set a non-default host.
print_draft_entry() {
  cat <<EOF
  draft:
    command: "node"
    args: ["$MCP_PATH"]
    env:
      FOUNDRY_API_KEY: "$KEY"
EOF
  if [ -n "$URL" ]; then
    echo "      FOUNDRY_API_URL: \"$URL\""
  fi
}

if grep -qE '^[[:space:]]+draft:[[:space:]]*$' "$CONFIG"; then
  echo "  • a 'draft:' MCP server is already in $CONFIG — left untouched"
elif grep -qE '^mcp_servers:[[:space:]]*$' "$CONFIG"; then
  echo "  • $CONFIG already has an 'mcp_servers:' block."
  echo "    Add the draft server by pasting this under it:"
  echo
  print_draft_entry
  echo
else
  {
    echo ""
    echo "mcp_servers:"
    print_draft_entry
  } >> "$CONFIG"
  echo "  ✓ added mcp_servers.draft → $CONFIG"
fi

if [ "$KEY_IS_PLACEHOLDER" -eq 1 ]; then
  cat <<EOF

  ! FOUNDRY_API_KEY was not set in your shell, so the config now has a
    placeholder. Edit $CONFIG and replace
    fdrk_REPLACE_WITH_YOUR_KEY under mcp_servers.draft.env with your
    real key. (Re-running this script with FOUNDRY_API_KEY exported will
    NOT overwrite an existing draft entry — edit the file directly.)
EOF
else
  echo
  echo "  ✓ wrote your workspace API key into mcp_servers.draft.env"
fi

cat <<EOF

Note: Hermes only forwards a safe baseline of env vars to stdio MCP
servers, so the key must live in the config's env: block (above) — an
exported FOUNDRY_API_KEY in your shell is NOT enough on its own. Keep
$CONFIG out of version control since it now holds the key.

Restart Hermes, then try:  /draft-queue

For unattended watching, schedule the work loop with Hermes cron:
      hermes cron create "every 5m" "Drain the Foundry/Draft agent queue." --skill draft-work
EOF
