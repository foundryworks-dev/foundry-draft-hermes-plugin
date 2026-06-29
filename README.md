# Draft — Hermes integration

Connects a [Hermes](https://github.com/NousResearch/hermes-agent)
session to a [Foundry/Draft](https://draft.foundryworks.dev) workspace
so an agent can see the work queue and pick up tickets.

It's the Hermes counterpart to the
[Claude Code plugin](https://github.com/foundryworks-dev/foundry-draft-cc-plugin)
and the
[Codex plugin](https://github.com/foundryworks-dev/foundry-draft-codex-plugin) —
same capabilities, expressed in Hermes' idioms.

## How this maps onto Hermes

Hermes is the easiest of the three hosts to target: it natively has
**both** an MCP client and an [agentskills.io](https://agentskills.io)
skills system, so the two reusable assets — the `draft-mcp.js` stdio
MCP server and the skill files — drop in almost unchanged. There's no
host program to wrap; you register the server and install the skills.

| Piece | Claude Code | Hermes |
| --- | --- | --- |
| API access | MCP server (bundled) | **same MCP server** — `mcp/draft-mcp.js`, registered in `~/.hermes/config.yaml` |
| Commands | `/draft:*` skills | `agentskills.io` skills in `~/.hermes/skills/` → `/draft-queue`, `/draft-work`, `/draft-watch`, `/draft-refresh` |
| Unattended polling | `/draft:watch` sleep loop | **native `hermes cron`** scheduling `/draft-work` (the `draft-watch` skill documents this) |
| "Draft is connected" notice | `SessionStart` hook | no equivalent — mention the commands in a Hermes context file if you want it |

The MCP server is the same one the Claude Code and Codex plugins ship
— MCP is a standard protocol, so it's portable. (For now it's vendored
into each repo; it may be extracted to a shared package later.)

### Tool names

Hermes namespaces a registered MCP server's tools as
`mcp_<server>_<tool>`. This server registers as `draft`, so its tools
are `mcp_draft_queue`, `mcp_draft_context`, `mcp_draft_claim_story`,
`mcp_draft_transition_story`, and so on — note the single underscores
(Claude Code uses `mcp__draft__*`). The bundled skills already
reference the `mcp_draft_*` names.

> **Token-tracking note.** The MCP server's `claim_story` and
> `transition_story` tools auto-PATCH a story's `agent_tokens_used`
> field on the finish transition by reading the agent session's
> transcript. Today that reader only knows the Claude Code transcript
> path (`~/.claude/projects/…`), so in a Hermes session the
> bookkeeping gracefully short-circuits and leaves the field null —
> it under-reports, never mis-reports. Teaching it to read Hermes'
> own usage totals is tracked as a follow-up. Until then, Hermes users
> can still PATCH `agent_tokens_used` themselves via `update_story` if
> they have a count to record.

## Install

```bash
git clone https://github.com/foundryworks-dev/foundry-draft-hermes-plugin
cd foundry-draft-hermes-plugin
./scripts/install.sh
```

`install.sh` copies the skills into `~/.hermes/skills/` and adds an
`mcp_servers.draft` block to `~/.hermes/config.yaml`. It's idempotent —
re-run it to refresh the skills after a `git pull`.

YAML has no repeated-key merge the way TOML tables do, so the config
step is conservative: it appends a fresh `mcp_servers:` block only when
your config has none, and otherwise prints the exact `draft:` entry for
you to paste under your existing `mcp_servers:` (rather than risk
corrupting a multi-server config). An existing `draft:` server is left
untouched.

**Requirement:** the MCP server is a Node script — Node 18+ must be on
`PATH` (it uses the built-in `fetch`). No npm dependencies, no build
step.

### Manual install

If you'd rather wire it up yourself:

1. Copy the three `skills/draft-*` directories into `~/.hermes/skills/`.
2. Merge the `mcp_servers.draft` entry from
   [`config.yaml.example`](config.yaml.example) into
   `~/.hermes/config.yaml`, using the absolute path to your clone's
   `mcp/draft-mcp.js`.

## Configure

| Variable        | Required | Default                          | Purpose                                    |
| --------------- | -------- | -------------------------------- | ------------------------------------------ |
| `DRAFT_API_KEY` | yes      | —                                | Your workspace agent API key (`fdrk_…`).   |
| `DRAFT_API_URL` | no       | `https://draft.foundryworks.dev` | Override for a self-hosted Draft instance. |

Get an API key from your Draft workspace under **Settings → Agents**.

### The key must live in the config's `env:` block

This trips people up coming from Claude Code or Codex, where exporting
`DRAFT_API_KEY` (or prefixing the launch, `DRAFT_API_KEY=… claude`) is
enough — those hosts hand the MCP subprocess your shell environment.
**Hermes does not.** For a stdio MCP server it forwards only a safe
baseline (`PATH`, `HOME`, `USER`, `LANG`, `LC_ALL`, `TERM`, `SHELL`,
`TMPDIR`, `XDG_*`) plus the server entry's own `env:` map, and it does
**not** interpolate `${VAR}` inside that map. So an exported
`DRAFT_API_KEY` never reaches the Draft server — the key has to be the
literal value in `env:`:

```yaml
mcp_servers:
  draft:
    command: "node"
    args: ["/abs/path/to/mcp/draft-mcp.js"]
    env:
      DRAFT_API_KEY: "fdrk_…"            # required — literal value
      # DRAFT_API_URL: "https://…"       # only for self-hosted Draft
```

`scripts/install.sh` writes this for you: it reads `DRAFT_API_KEY` (and
`DRAFT_API_URL`, if set) from your shell **at install time** and bakes
the value into the `env:` block. If the key isn't exported when you run
it, the installer leaves a `fdrk_REPLACE_WITH_YOUR_KEY` placeholder for
you to fill in. Because the key now lives in `~/.hermes/config.yaml`,
**keep that file out of version control.**

This applies everywhere the server runs — interactive sessions and
unattended `hermes cron` jobs alike.

## Use

After install + restart, in a Hermes session:

- **`/draft-queue`** — show the stories waiting in your agent queue
  (read-only).
- **`/draft-work`** — work the queue: claim the top story, implement
  it, and finish it. Name a story number to pick up a specific story
  instead of the top of the queue.
- **`/draft-watch`** — the unattended variant. On Hermes the
  recommended path is to schedule `/draft-work` with the native cron
  scheduler:

  ```bash
  hermes cron create "every 5m" "Drain the Foundry/Draft agent queue." --skill draft-work
  ```

  Each scheduled run is a fresh session that re-fetches the workflow
  context and re-reads the queue. The skill also describes an
  in-session poll-loop fallback. Manage the job with `hermes cron
  list` / `pause` / `resume` / `remove`.
- **`/draft-refresh`** — re-fetch Draft's authoritative operating
  instructions (the workspace context) from the API and adopt them as
  canonical for the rest of the session (read-only). Handy for a
  long-running session when the workflow rules may have changed
  server-side.

## MCP tools

The `draft` MCP server exposes (Hermes name in parentheses):

| Tool                | What it does                                                   |
| ------------------- | ------------------------------------------------------------- |
| `whoami`            | The authenticated agent's identity.                           |
| `context`           | Draft's authoritative how-to-operate instructions.            |
| `queue`             | The agent work queue across all reachable projects.           |
| `get_story`         | One story by project id + number.                             |
| `list_comments`     | A story's comment thread.                                     |
| `story_activity`    | A story's activity timeline.                                  |
| `claim_story`       | Claim ownership (resolves your own user id).                  |
| `transition_story`  | Move a story through its state machine (start/finish/block/…).|
| `comment`           | Post a comment on a story.                                    |
| `add_link`          | Attach a PR/commit URL to a story.                            |
| `create_story`      | File a new story (lands in the backlog for triage).          |
| `update_story`      | Patch arbitrary story fields (points, labels, …).            |

Invoke them as `mcp_draft_<tool>` (e.g. `mcp_draft_queue`).

## Layout

```
mcp/draft-mcp.js               zero-dependency MCP server wrapping the Draft API
skills/draft-queue/SKILL.md    /draft-queue   — read-only queue view
skills/draft-work/SKILL.md     /draft-work    — drain the queue once
skills/draft-watch/SKILL.md    /draft-watch   — drain + poll (prefers `hermes cron`)
skills/draft-refresh/SKILL.md  /draft-refresh — re-pull the workflow context
scripts/install.sh             copies skills + wires up config.yaml
config.yaml.example            the mcp_servers.draft entry to merge by hand
```

## License

MIT — see [LICENSE](LICENSE).
