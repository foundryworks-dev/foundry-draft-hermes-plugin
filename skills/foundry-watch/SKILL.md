---
name: foundry-watch
description: Work the Foundry/Draft agent queue and keep polling for new work when the queue empties. The "set it and forget it" variant of /foundry-work — for an unattended stretch, prefer scheduling it with `hermes cron`.
version: 0.1.0
metadata:
  hermes:
    tags: [foundry, draft, project-management, tickets, unattended]
    category: agent-workflow
---

# Watch the Draft queue

Same per-story flow as `/foundry-work`, but instead of stopping when the
queue is empty, keep checking until new work arrives or the user
interrupts. Use this when the operator wants the agent to run
unattended for a stretch — kick it off, walk away, come back to
delivered stories.

The `foundry` MCP server (registered in `~/.hermes/config.yaml`) exposes
its tools under the `mcp_foundry_*` prefix.

## Preferred on Hermes: schedule it with `hermes cron`

Hermes has a first-class cron scheduler, and it's a better fit for
unattended polling than an in-session sleep loop: each run is a fresh
agent session with an isolated context, and the gateway daemon keeps
firing it even after you close your terminal.

Register `/foundry-work` to run on an interval:

```bash
hermes cron create "every 5m" "Drain the Foundry/Draft agent queue." --skill foundry-work
```

(Or from inside a chat session: `/cron add "every 5m" "Drain the
Foundry/Draft agent queue." --skill foundry-work`.)

Notes:

- The gateway daemon executes scheduled jobs — install it once with
  `hermes gateway install` if you haven't.
- Each scheduled run is a **fresh session**, so it naturally re-fetches
  `mcp_foundry_context` and re-reads the queue every time — exactly what
  the poll loop below does by hand.
- `FOUNDRY_API_KEY` must be set in the server's `env:` block in
  `~/.hermes/config.yaml` (the installer does this) — Hermes doesn't
  forward your shell env to a stdio MCP server, so an exported key
  alone won't reach the Draft tools. This is the same requirement as
  interactive use; cron doesn't add anything special here.
- Manage the job with `hermes cron list` / `pause` / `resume` /
  `remove`.

## In-session fallback: poll, don't stop

If you'd rather watch within a single live session instead of using
cron, run the per-story flow and, when the queue empties, poll:

### 1. Load the workflow instructions — first, every time

Call `mcp_foundry_context` and follow it; it is the source of truth for
the state machine, claim mechanics, and hand-off protocol. Fetch fresh
each run rather than relying on memory.

### 2. Drain the queue

Call `mcp_foundry_queue` and work each available item to completion:

- `mcp_foundry_claim_story` — claim ownership.
- `mcp_foundry_transition_story` with `action: "start"`.
- `mcp_foundry_comment` — post a short plan comment.
- Do the implementation. Run the project's tests / build.
- `mcp_foundry_add_link` — attach the PR or commit URL if the project
  has a connected repo.
- `mcp_foundry_transition_story` with `action: "finish"`.

Repeat for each available item in priority order.

### 3. When the queue empties

1. Print one line: `Queue empty — watching for new work. Sleeping
   5 minutes before next check. Interrupt to stop.`
2. Wait roughly 5 minutes (a `sleep 300` is fine if your host allows
   shell access).
3. Call `mcp_foundry_queue` again.
   - If there are stories, drop back to step 2 and drain them.
   - If still empty, repeat the wait + re-check. There is no hardcoded
     stopping condition — the user ends the watch by interrupting.

5 minutes is the default poll interval. If the user passed a number
when invoking this skill, treat it as the interval in seconds (clamped
to [60, 3600]).

## Guardrails

- The `mcp_foundry_context` response is canonical. If anything in this
  file conflicts with it, the API wins.
- Never transition a story to `accepted` — that's the human reviewer's
  call. `finish` is the right terminal state for agent work.
- If a particular story turns out far larger than expected or needs a
  decision you can't make, follow the context instructions for
  *blocking* (`transition_story` with `action: "block"`, plus a
  comment). Don't silently skip it — block it so a human sees it.
- The MCP tools are the intended interface. The same operations are
  reachable as plain REST calls against `FOUNDRY_API_URL` with an
  `Authorization: Bearer $FOUNDRY_API_KEY` header, but prefer the tools.
