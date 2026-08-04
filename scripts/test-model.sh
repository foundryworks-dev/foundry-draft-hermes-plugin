#!/usr/bin/env bash
# Model-detection tests for the Hermes MCP server (#569).
#
# The failure this guards is a silent one, and on a mixed machine it is worse
# than silent. The resolver was a verbatim copy of the Claude Code
# implementation: it located a transcript via CLAUDE_CODE_SESSION_ID and read
# `message.model` from it. On a clean Hermes host neither exists, so it
# returned "" and the header was omitted — indistinguishable from working,
# because omitting is also correct when the model is genuinely unknown.
#
# On a host that ALSO runs Claude Code, the same code finds a real Claude
# transcript and resolves a Claude model for a Hermes agent. That is
# mis-attribution rather than under-reporting, and it is the same defect that
# attributed 646M Claude tokens to a Codex story in #515.
#
# These call the real resolver in mcp/draft-mcp.js against fixture HERMES_HOMEs
# rather than reimplementing the parse.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

# resolve_with <dir-name> <config.yaml contents> — echoes the resolved model.
# CLAUDE_CODE_SESSION_ID is deliberately exported: the resolver must not care,
# and leaving it set is what proves the Claude path is gone rather than merely
# unreached on the test machine.
resolve_with() {
  local home="$WORK/$1"; shift
  mkdir -p "$home"
  printf '%s\n' "$1" > "$home/config.yaml"
  CLAUDE_CODE_SESSION_ID="pretend-claude-session" \
  HERMES_HOME="$home" \
    node -e '
      const m = require(process.argv[1] + "/mcp/draft-mcp.js");
      process.stdout.write(m.readModelFromHermesConfig() || "");
    ' "$REPO"
}

# 1. The real shape, copied from a live ~/.hermes/config.yaml.
got="$(resolve_with h1 'model:
  api_key: ollama
  base_url: http://127.0.0.1:11434/v1
  default: qwen3-coder:480b-cloud
  provider: ollama-launch
providers:
  ollama-launch:
    api: http://127.0.0.1:11434/v1')"
[ "$got" = "qwen3-coder:480b-cloud" ] \
  && ok "model.default resolves from a real-shaped config" \
  || bad "model.default resolves (got '$got')"

# 2. A `default:` under a LATER top-level key must not be picked up. This is
#    what the block tracking is for — Hermes configs carry several sections
#    with their own defaults.
got="$(resolve_with h2 'model:
  provider: ollama-launch
agents:
  default: not-a-model')"
[ -z "$got" ] \
  && ok "a default: outside the model block is ignored" \
  || bad "a default: outside the model block is ignored (got '$got')"

# 3. Quotes and trailing comments are stripped.
got="$(resolve_with h3 'model:
  default: "gpt-4o"   # inline comment')"
[ "$got" = "gpt-4o" ] \
  && ok "quotes and trailing comments are stripped" \
  || bad "quotes and comments (got '$got')"

# 4. No model block at all resolves to nothing, so the header is omitted.
#    Omitting is the designed behaviour when the model is unknown — a guessed
#    model produces a confident wrong cost.
got="$(resolve_with h4 'providers:
  ollama-launch:
    api: http://127.0.0.1:11434/v1')"
[ -z "$got" ] \
  && ok "a config with no model block resolves to nothing" \
  || bad "no model block (got '$got')"

# 5. No config at all — not a Hermes host — is silent, not an error.
H="$WORK/h5"; mkdir -p "$H"
got="$(CLAUDE_CODE_SESSION_ID=x HERMES_HOME="$H" node -e '
  const m = require(process.argv[1] + "/mcp/draft-mcp.js");
  process.stdout.write(m.readModelFromHermesConfig() || "");
' "$REPO")"
[ -z "$got" ] && ok "a missing config.yaml is silent" || bad "missing config (got '$got')"

# 6. THE regression. With CLAUDE_CODE_SESSION_ID set and a Claude transcript
#    on disk, the resolver must still return the Hermes model — never a Claude
#    one. Copying the Claude implementation is what shipped this bug twice, so
#    this asserts the Claude path is gone rather than dormant.
FAKE_CLAUDE="$WORK/claude/projects/-fake"
mkdir -p "$FAKE_CLAUDE"
printf '%s\n' '{"message":{"model":"claude-opus-4-8"}}' > "$FAKE_CLAUDE/session.jsonl"
got="$(HOME="$WORK" resolve_with h6 'model:
  default: qwen3-coder:480b-cloud')"
[ "$got" = "qwen3-coder:480b-cloud" ] \
  && ok "a Claude transcript on the same machine does not leak in" \
  || bad "Claude transcript must not leak in (got '$got')"

# 7. Requiring the module must not start the server — otherwise this file
#    would hang rather than fail.
timeout 10 node -e '
  const m = require(process.argv[1] + "/mcp/draft-mcp.js");
  if (typeof m.modelHeaders !== "function") process.exit(3);
' "$REPO" && ok "require() exports the resolver without starting the server" \
  || bad "require() must not start the server"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
