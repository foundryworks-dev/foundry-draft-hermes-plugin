---
name: foundry-queue
description: Show the Foundry/Draft agent queue — a read-only snapshot of the stories waiting to be worked, without claiming or modifying anything.
version: 0.1.0
metadata:
  hermes:
    tags: [foundry, draft, project-management, tickets]
    category: agent-workflow
---

# Show the Draft queue

Read-only. Does not claim, start, or modify any story.

The `foundry` MCP server (registered in `~/.hermes/config.yaml`) exposes
its tools under the `mcp_foundry_*` prefix — Hermes namespaces a
registered server's tools as `mcp_<server>_<tool>`.

## Steps

1. Call `mcp_foundry_queue`. It reads `FOUNDRY_API_KEY` / `FOUNDRY_API_URL`
   from the environment. If the key is unset, resolve it from the
   registry:
   `node "${HERMES_HOME:-$HOME/.hermes}/scripts/foundry-registry.js" resolve`
   prints `FOUNDRY_API_KEY<TAB>FOUNDRY_API_URL` (env if set, else a lease
   claimed via `/foundry-agents`) — use it over REST. If that exits
   non-zero, tell the user to run `/foundry-agents` or export
   `FOUNDRY_API_KEY`, and stop.
2. Summarize the stories that still need work (i.e. not yet finished
   or accepted): story number, type, state, points, and title — in the
   queue's priority order.
3. Stop there. To actually pick something up, the user runs
   `/foundry-work`.
