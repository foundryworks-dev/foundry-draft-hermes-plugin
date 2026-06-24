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
for skill in draft-queue draft-work draft-watch; do
  cp -R "$REPO_DIR/skills/$skill" "$SKILLS_DIR/"
done
echo "  ✓ copied skills → $SKILLS_DIR"
echo "    (/draft-queue, /draft-work, /draft-watch)"

# --- 2. MCP server in config.yaml -----------------------------------
mkdir -p "$HERMES_HOME"
touch "$CONFIG"

# The draft entry, indented two spaces as a child of `mcp_servers:`.
# We rely on ambient env for the credentials so the key never lands on
# disk; uncomment the `env:` map if your Hermes gateway daemon (used by
# `hermes cron`) can't see DRAFT_API_KEY from its environment.
#
# Emitted via a literal heredoc (not `read`, which would strip the
# leading indentation off the first line and break the YAML nesting).
print_draft_entry() {
  cat <<EOF
  draft:
    command: "node"
    args: ["$MCP_PATH"]
    # env:
    #   DRAFT_API_KEY: "fdrk_..."
    #   DRAFT_API_URL: "https://draft.foundryworks.dev"
EOF
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

cat <<'EOF'

Done. Next steps:
  • Export your workspace agent key in your shell profile:
      export DRAFT_API_KEY=fdrk_...
  • (Self-hosted Draft only) also export:
      export DRAFT_API_URL=https://your-draft-host
  • Restart Hermes, then try:  /draft-queue

For unattended watching, schedule the work loop with Hermes cron:
      hermes cron create "every 5m" "Drain the Foundry/Draft agent queue." --skill draft-work
  (see the draft-watch skill / README for the env caveat under the gateway daemon).
EOF
