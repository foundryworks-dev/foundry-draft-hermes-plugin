---
name: foundry-refresh
description: Re-fetch Foundry/Draft's authoritative operating instructions (the workspace context) from the API and adopt them as canonical for the rest of the session, without restarting.
version: 0.1.0
metadata:
  hermes:
    tags: [foundry, draft, project-management, tickets]
    category: agent-workflow
---

# Refresh the Draft workflow context

Force a fresh pull of Draft's authoritative operating instructions from
the API. The instructions live server-side and **can change**, so this
is how you re-ground a session on the latest rules without restarting
it. Read-only: it claims, starts, and modifies nothing.

The `foundry` MCP server (registered in `~/.hermes/config.yaml`) exposes
its tools under the `mcp_foundry_*` prefix — Hermes namespaces a
registered server's tools as `mcp_<server>_<tool>`.

## Steps

1. Call `mcp_foundry_context`. It reads `FOUNDRY_API_KEY` / `FOUNDRY_API_URL`
   from the environment; if the call reports the key is unset, tell the
   user to export it and stop. The tool re-fetches the board model, the
   story state machine, the claim/start/comment/transition/finish
   mechanics, the @-mention format, the hand-off protocol, and any
   workspace- or project-specific notes straight from the API.
2. Adopt the freshly returned text as canonical, replacing any earlier
   understanding from this session — including anything cached from a
   previous `/foundry-work`, `/foundry-watch`, or `/foundry-refresh` run. If
   the new context conflicts with what you were doing, the new context
   wins.
3. Briefly tell the user what (if anything) changed since the context
   was last loaded — e.g. new workspace instructions, a changed
   transition rule, an updated role description — or confirm it's
   unchanged.

## Notes

- This does **not** start or continue working the queue. To do that,
  run `/foundry-work` (which loads the context itself before working).
- The `mcp_foundry_context` response is always canonical: if anything in
  this plugin's skill files conflicts with it, the API wins.
