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
  echo "    before using /foundry-work or /foundry-queue."
else
  major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
  if [ "$major" -lt 18 ]; then
    echo "  ! Node $(node -v) is too old — the MCP server needs Node 18+."
  fi
fi

# --- 1. skills ------------------------------------------------------
mkdir -p "$SKILLS_DIR"
for skill in foundry-queue foundry-work foundry-watch foundry-refresh foundry-agents; do
  cp -R "$REPO_DIR/skills/$skill" "$SKILLS_DIR/"
done
echo "  ✓ copied skills → $SKILLS_DIR"
echo "    (/foundry-queue, /foundry-work, /foundry-watch, /foundry-refresh, /foundry-agents)"

# --- 1b. registry broker client -------------------------------------
# The foundry-agents skill shells out to this to talk to the local Foundry
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
# $1 = the YAML key, which is what determines the tool namespace the
# client exposes (mcp__foundry__queue vs mcp__draft__queue). That prefix
# comes from the config key, not from anything the MCP server returns —
# tools/list hands back bare names — so aliasing it means mounting the
# same script twice (#457). `foundry` is the name to use going forward;
# `draft` stays until the telemetry gate (#458) says nobody calls it.
# The key is also passed to the process as --server-key, because that gate
# needs to know which namespace a call came through and the two entries
# are otherwise identical from inside the script (#458).
print_entry() {
  cat <<EOF
  $1:
    command: "node"
    args: ["$MCP_PATH", "--server-key=$1"]
    env:
      FOUNDRY_API_KEY: "$KEY"
EOF
  if [ -n "$URL" ]; then
    echo "      FOUNDRY_API_URL: \"$URL\""
  fi
}

# Only emit the entries that aren't already there, so re-running is safe
# and an operator who has hand-tuned one of them keeps it. Tracked as two
# flags rather than a space-separated string — an unquoted "$MISSING" only
# splits into words under bash, and this file gets sourced/read by enough
# shells that relying on that is a trap.
need_foundry=1
need_draft=1
if grep -qE "^[[:space:]]+foundry:[[:space:]]*$" "$CONFIG"; then
  echo "  • a 'foundry:' MCP server is already in $CONFIG — left untouched"
  need_foundry=0
fi
if grep -qE "^[[:space:]]+draft:[[:space:]]*$" "$CONFIG"; then
  echo "  • a 'draft:' MCP server is already in $CONFIG — left untouched"
  need_draft=0
fi

# An entry that's already there is left untouched (above) — but "untouched"
# is only the right outcome if it points at *this* install. Someone who first
# installed from a git clone has a config whose args path is their clone; a
# later tarball install leaves that entry alone and they keep running the old
# code, having just been told the install succeeded. That silent no-op is the
# thing this installer family exists to remove, so say it out loud.
#
# Warn, never edit: the same reason uninstall won't strip entries. We can't
# rewrite YAML we can't parse.
warn_if_stale_path() {
  [ -f "$CONFIG" ] || return 0
  grep -q "$MCP_PATH" "$CONFIG" && return 0
  grep -q 'draft-mcp' "$CONFIG" || return 0
  local old
  old="$(grep 'draft-mcp' "$CONFIG" | head -n1 | sed -E 's|.*"([^"]*draft-mcp[^"]*)".*|\1|')"
  echo
  echo "  ! an existing entry does not point at this install."
  [ -n "$old" ] && echo "    it currently runs: $old"
  echo "    to use the version just installed, edit $CONFIG"
  echo "    and set the args path to:"
  echo "        $MCP_PATH"
  echo "    (a stable symlink, so future upgrades will not need this again)"
  return 0
}

print_missing() {
  [ "$need_foundry" -eq 1 ] && print_entry foundry
  [ "$need_draft" -eq 1 ] && print_entry draft
  return 0
}
report_added() {
  [ "$need_foundry" -eq 1 ] && echo "  ✓ added mcp_servers.foundry → $CONFIG"
  [ "$need_draft" -eq 1 ] && echo "  ✓ added mcp_servers.draft → $CONFIG"
  return 0
}

# Checked whenever *any* entry already existed, not only when both did — a
# single stale entry runs the same old code as two.
if [ "$need_foundry" -eq 0 ] || [ "$need_draft" -eq 0 ]; then
  warn_if_stale_path
fi

if [ "$need_foundry" -eq 0 ] && [ "$need_draft" -eq 0 ]; then
  :
elif grep -qE '^mcp_servers:[[:space:]]*$' "$CONFIG"; then
  echo "  • $CONFIG already has an 'mcp_servers:' block."
  echo "    Add the missing server(s) by pasting this under it:"
  echo
  print_missing
  echo
else
  {
    echo ""
    echo "mcp_servers:"
    print_missing
  } >> "$CONFIG"
  report_added
fi

if [ "$KEY_IS_PLACEHOLDER" -eq 1 ]; then
  cat <<EOF

  ! FOUNDRY_API_KEY was not set in your shell, so the config now has a
    placeholder. Edit $CONFIG and replace
    fdrk_REPLACE_WITH_YOUR_KEY under mcp_servers.foundry.env with your
    real key. (Re-running this script with FOUNDRY_API_KEY exported will
    NOT overwrite an existing draft entry — edit the file directly.)
EOF
else
  echo
  echo "  ✓ wrote your workspace API key into the MCP server env block(s)"
fi

cat <<EOF

Note: Hermes only forwards a safe baseline of env vars to stdio MCP
servers, so the key must live in the config's env: block (above) — an
exported FOUNDRY_API_KEY in your shell is NOT enough on its own. Keep
$CONFIG out of version control since it now holds the key.

Restart Hermes, then try:  /foundry-queue

For unattended watching, schedule the work loop with Hermes cron:
      hermes cron create "every 5m" "Drain the Foundry/Draft agent queue." --skill foundry-work
EOF
