---
name: draft-work
description: Work the Foundry/Draft agent queue — fetch the workflow context, claim the top story, implement it, and finish it. Invoke when the user wants to start working Draft tickets.
version: 0.1.0
metadata:
  hermes:
    tags: [foundry, draft, project-management, tickets]
    category: agent-workflow
---

# Work the Draft queue

Run the Foundry/Draft agent loop for this session, using the `draft`
MCP tools. The `draft` MCP server (registered in
`~/.hermes/config.yaml`) exposes its tools under the `mcp_draft_*`
prefix — Hermes namespaces a registered server's tools as
`mcp_<server>_<tool>` (e.g. `mcp_draft_queue`, `mcp_draft_context`).

## Configuration

The MCP server reads its config from the environment:

- `FOUNDRY_API_KEY` — the workspace agent API key. If it's not set in the
  environment, resolve it from the registry:
  `node "${HERMES_HOME:-$HOME/.hermes}/scripts/foundry-registry.js" resolve`
  prints `FOUNDRY_API_KEY<TAB>FOUNDRY_API_URL` (env if set, else a lease
  claimed via `/draft-agents`) — use it over REST. If that exits
  non-zero, tell the user to run `/draft-agents` or export
  `FOUNDRY_API_KEY`, and stop.
- `FOUNDRY_API_URL` (optional) — defaults to
  `https://draft.foundryworks.dev`.

## 1. Load the workflow instructions — first, every time

Call `mcp_draft_context`. It returns Draft's own authoritative
instructions for operating within a workspace: the board model, the
story state machine, claim/start/comment/transition/finish mechanics,
and any workspace- or project-specific notes. **Those instructions
are the source of truth** — follow them. They can change server-side,
so fetch them fresh each run rather than relying on memory.

## 2. Work the queue

Call `mcp_draft_queue` and take the highest-priority item (the
context explains the ordering). Then drive it to completion with the
matching tools, exactly as the context instructions describe:

- `mcp_draft_claim_story` — claim ownership (resolves your own user
  id for you).
- `mcp_draft_transition_story` with `action: "start"`.
- `mcp_draft_comment` — post a short plan comment.
- Do the implementation. Run the project's tests / build.
- `mcp_draft_add_link` — attach the PR or commit URL if the project
  has a connected repo.
- `mcp_draft_transition_story` with `action: "finish"`.

`mcp_draft_get_story`, `mcp_draft_list_comments`, and
`mcp_draft_story_activity` are there for reading detail along the
way — e.g. check for reviewer replies before you finish.

If the user named a specific story number when invoking this skill,
pick that up instead of the top of the queue.

## 3. Repeat or stop

When `mcp_draft_queue` shows no available work, say so and stop.
Otherwise continue to the next item — but check in with the user
rather than looping indefinitely if a story turns out far larger than
expected or needs a decision you can't make. To poll and wait for new
work instead of stopping, use `/draft-watch`.

## Guardrails

- The `mcp_draft_context` response is canonical. If anything in this
  file conflicts with it, the API wins.
- Never transition a story to `accepted` — that's the human reviewer's
  call. `finish` is the right terminal state for agent work.
- If you genuinely can't proceed (a question only a human can
  answer), follow the context instructions for *blocking* the story
  (`transition_story` with `action: "block"`, plus a comment
  explaining what you need) rather than abandoning it.
- The MCP tools are the intended interface. If they're somehow
  unavailable in the session, the same operations are plain REST
  calls against `FOUNDRY_API_URL` with an
  `Authorization: Bearer $FOUNDRY_API_KEY` header — but prefer the tools.
