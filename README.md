# Draft — Hermes integration

Connects a [Hermes](https://github.com/NousResearch/hermes-agent)
session to a [Foundry/Draft](https://app.foundryworks.dev) workspace
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
| Commands | `/foundry:*` skills | `agentskills.io` skills in `~/.hermes/skills/` → `/foundry-queue`, `/foundry-work`, `/foundry-watch`, `/foundry-refresh` |
| Unattended polling | `/foundry:watch` sleep loop | **native `hermes cron`** scheduling `/foundry-work` (the `foundry-watch` skill documents this) |
| "Draft is connected" notice | `SessionStart` hook | no equivalent — mention the commands in a Hermes context file if you want it |

The MCP server is the same one the Claude Code and Codex plugins ship
— MCP is a standard protocol, so it's portable. (For now it's vendored
into each repo; it may be extracted to a shared package later.)

### Tool names

Hermes namespaces a registered MCP server's tools as
`mcp_<server>_<tool>`, and that prefix comes from the config key rather
than from anything the server returns. Both installers register the
same script under two keys, so both namespaces resolve:

| Namespace | Status |
| --------- | ------ |
| `mcp_foundry_*` | the name to use going forward; what the bundled skills call |
| `mcp_draft_*`   | still works; retired only once usage telemetry says nobody calls it (#458) |

So the tools are `mcp_foundry_queue`, `mcp_foundry_context`,
`mcp_foundry_claim_story`, and so on — note the single underscores
(Claude Code uses `mcp__foundry__*`).

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
export FOUNDRY_API_KEY=fdrk_...
curl -fsSL https://dl.foundryworks.dev/install-hermes.sh | sh
```

That downloads a versioned, SHA-256-verified release from
`dl.foundryworks.dev`, installs it under
`~/.foundry/hermes-draft-plugin/<version>` behind a stable `current`
symlink, copies the skills into `~/.hermes/skills/`, and adds
`mcp_servers.foundry` and `mcp_servers.draft` blocks to
`~/.hermes/config.yaml`. Re-run to upgrade; `--uninstall` removes it:

```bash
curl -fsSL https://dl.foundryworks.dev/install-hermes.sh | sh -s -- --uninstall
```

Pin a version with `FOUNDRY_HERMES_VERSION=v0.1.0`. Export the key
*before* running it — see [The key must live in the config's `env:` block](#the-key-must-live-in-the-configs-env-block)
for why hermes needs it at install time rather than at runtime.

### Installing from a clone

`scripts/install.sh` still works and does the same wiring against your
working copy, which is what you want when developing the plugin:

```bash
git clone https://github.com/foundryworks-dev/foundry-draft-hermes-plugin
cd foundry-draft-hermes-plugin
./scripts/install.sh
```

The difference is what `mcp_servers.*.args` points at: a clone path,
which the remote installer can't update for you (it won't rewrite YAML
it can't safely parse). If you switch from a clone to the remote
installer, it tells you the path to change — a one-time edit, after
which the `current` symlink absorbs every later upgrade.

YAML has no repeated-key merge the way TOML tables do, so the config
step is conservative: it appends a fresh `mcp_servers:` block only when
your config has none, and otherwise prints the exact entries for you to
paste under your existing `mcp_servers:` (rather than risk corrupting a
multi-server config). An existing `foundry:` or `draft:` server is left
untouched.

**Requirement:** the MCP server is a Node script — Node 18+ must be on
`PATH` (it uses the built-in `fetch`). No npm dependencies, no build
step.

### Upgrading from the `draft-` skills

The skills were `/draft-queue`, `/draft-work`, `/draft-watch`,
`/draft-refresh` and `/draft-agents`. They are now `/foundry-*`.

Re-running either installer copies the new skills in. Because installing only
ever copies and never deletes, your existing `~/.hermes/skills/draft-*`
directories stay put and keep working — they call `mcp_draft_*`, which
still resolves. They will not receive further updates, so once you are on
the `foundry-` skills you can remove them:

```bash
rm -rf ~/.hermes/skills/draft-{queue,work,watch,refresh,agents}
```

If you scheduled the old name with `hermes cron`, update the job:
`--skill draft-work` becomes `--skill foundry-work`. A cron job pointing
at a skill you have deleted will fail silently otherwise, which is worth
checking before you clean up.

### Manual install

If you'd rather wire it up yourself:

1. Copy the five `skills/foundry-*` directories into `~/.hermes/skills/`.
2. Merge the `mcp_servers.foundry` and `mcp_servers.draft` entries from
   [`config.yaml.example`](config.yaml.example) into
   `~/.hermes/config.yaml`, using the absolute path to your clone's
   `mcp/draft-mcp.js`.

## Configure

| Variable        | Required | Default                          | Purpose                                    |
| --------------- | -------- | -------------------------------- | ------------------------------------------ |
| `FOUNDRY_API_KEY` | yes      | —                                | Your workspace agent API key (`fdrk_…`).   |
| `FOUNDRY_API_URL` | no       | `https://app.foundryworks.dev` | Override for a self-hosted Draft instance. |

**The `DRAFT_API_KEY` / `DRAFT_API_URL` names are still accepted** and are
not going away. `FOUNDRY_*` wins when both are set; otherwise `DRAFT_*` is
used and the plugin prints a one-line notice on stderr. Existing setups need
no change (#456).

Get an API key from your Draft workspace under **Settings → Agents**.

### Tool names: `foundry` and `draft`

The plugin registers the MCP server under **two keys**, so both tool
namespaces resolve to the same handler:

| Namespace | Status |
| --------- | ------ |
| `mcp__foundry__*` | the name to use going forward |
| `mcp__draft__*`   | still works; retired only once usage telemetry says nobody calls it (#458) |

The prefix comes from the **client-side config key**, not from anything the
server returns — `tools/list` hands back bare tool names like `queue`. So
aliasing a namespace means mounting the same script twice. The cost is that
every tool appears twice in a session's tool list; that is inherent to MCP
namespacing, not something the server can dedupe (#457).

Each registration passes its own `--server-key=` so the process knows which
namespace it is serving — without it the two are indistinguishable, since
`tools/list` returns bare names either way.

### What gets reported about legacy names (#458)

`draft.` / `DRAFT_*` / `draft:` are supported indefinitely, so retiring any of
them has to be a decision backed by evidence rather than a guess. To make that
possible, requests carry an `X-Foundry-Legacy` header naming the legacy names
**this process is running on** — the `DRAFT_*` variables that supplied its
config, and `prefix=draft` when invoked under the legacy namespace. The server
logs those against your agent identity.

It is names only: no credential, no arguments, no story content, and nothing
at all is sent by a session already on `FOUNDRY_*` and `mcp_foundry_*`.

### The key must live in the config's `env:` block

This trips people up coming from Claude Code or Codex, where exporting
`FOUNDRY_API_KEY` (or prefixing the launch, `FOUNDRY_API_KEY=… claude`) is
enough — those hosts hand the MCP subprocess your shell environment.
**Hermes does not.** For a stdio MCP server it forwards only a safe
baseline (`PATH`, `HOME`, `USER`, `LANG`, `LC_ALL`, `TERM`, `SHELL`,
`TMPDIR`, `XDG_*`) plus the server entry's own `env:` map, and it does
**not** interpolate `${VAR}` inside that map. So an exported
`FOUNDRY_API_KEY` never reaches the Draft server — the key has to be the
literal value in `env:`:

```yaml
mcp_servers:
  foundry:
    command: "node"
    args: ["/abs/path/to/mcp/draft-mcp.js", "--server-key=foundry"]
    env:
      FOUNDRY_API_KEY: "fdrk_…"            # required — literal value
      # FOUNDRY_API_URL: "https://…"       # only for self-hosted Draft
```

The legacy `draft:` entry takes the same shape with
`--server-key=draft`; `install.sh` writes both.

`scripts/install.sh` writes this for you: it reads `FOUNDRY_API_KEY` (and
`FOUNDRY_API_URL`, if set) from your shell **at install time** and bakes
the value into the `env:` block. If the key isn't exported when you run
it, the installer leaves a `fdrk_REPLACE_WITH_YOUR_KEY` placeholder for
you to fill in. Because the key now lives in `~/.hermes/config.yaml`,
**keep that file out of version control.**

This applies everywhere the server runs — interactive sessions and
unattended `hermes cron` jobs alike.

**`--uninstall` does not take the key back out**, and that is deliberate
rather than an oversight (#533). Removing an entry means editing YAML,
and editing YAML safely means parsing it — a wrong guess corrupts a
config that may hold other people's MCP servers. So uninstall removes
the skills, the broker client and the install tree, then tells you
exactly which two entries to delete. The same rule governs install: it
appends an `mcp_servers:` block only when the file has none, and
otherwise prints the entries for you to paste.

The practical consequence, worth stating plainly because it is the
security-relevant half: **after `--uninstall`, your API key is still in
`~/.hermes/config.yaml`.** Delete the `foundry:` and `draft:` entries by
hand, and rotate the key if it should no longer work.

## Use

After install + restart, in a Hermes session:

- **`/foundry-queue`** — show the stories waiting in your agent queue
  (read-only).
- **`/foundry-work`** — work the queue: claim the top story, implement
  it, and finish it. Name a story number to pick up a specific story
  instead of the top of the queue.
- **`/foundry-watch`** — the unattended variant. On Hermes the
  recommended path is to schedule `/foundry-work` with the native cron
  scheduler:

  ```bash
  hermes cron create "every 5m" "Drain the Foundry/Draft agent queue." --skill foundry-work
  ```

  Each scheduled run is a fresh session that re-fetches the workflow
  context and re-reads the queue. The skill also describes an
  in-session poll-loop fallback. Manage the job with `hermes cron
  list` / `pause` / `resume` / `remove`.
- **`/foundry-refresh`** — re-fetch Draft's authoritative operating
  instructions (the workspace context) from the API and adopt them as
  canonical for the rest of the session (read-only). Handy for a
  long-running session when the workflow rules may have changed
  server-side.
- **`/foundry-agents`** — pick an agent key from the **Foundry Agent
  Registry** instead of exporting one by hand. When the local `foundry
  daemon` is running and `FOUNDRY_API_KEY` is unset, this lists the keys
  in a table — a Cross-Project column (workspace-level agents) and a
  Project column (project-scoped agents), plus availability — you
  choose one, and the plugin claims it for the session via the daemon.
  If `FOUNDRY_API_KEY` is already set, the registry flow is skipped
  entirely. `install.sh` places the broker client at
  `~/.hermes/scripts/foundry-registry.js`. (Hermes has no session-end
  hook, so release the key with the broker's `release` when done — the
  daemon/server idle auto-release is the backstop.)

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
| `library_write`     | Create or update a Library wiki page by (project, slug).        |

### Craft apps (EP-19)

When a project has a craft app enabled (Figcraft first), the `context`
tool's project section carries a **Craft apps** block, and these five
tools drive it through Draft's gateway. They are app-agnostic, so the next
ArtCraft app needs no plugin release.

| Tool          | What it does                                                                  |
| ------------- | ----------------------------------------------------------------------------- |
| `craft_tools` | The app's tools and argument schemas, after Foundry's policy.                 |
| `craft_open`  | Open a session on a story: a new document, or an existing one by id.         |
| `craft_call`  | Run one app tool. The app's result comes back unchanged, images as images.    |
| `craft_save`  | Save the document as a new version on the story, with an optional label.     |
| `craft_close` | End the session (does not save).                                              |

Agents never see a runner address or secret: every call goes to Draft,
which checks the command policy, forwards it, and records it.
`scripts/test-craft-tools.js` runs these tools against a stub API.

Invoke them as `mcp_foundry_<tool>` (e.g. `mcp_foundry_queue`). The legacy `mcp_draft_<tool>` names still resolve.

## Layout

```
mcp/draft-mcp.js               zero-dependency MCP server wrapping the Draft API
skills/foundry-queue/SKILL.md    /foundry-queue   — read-only queue view
skills/foundry-work/SKILL.md     /foundry-work    — drain the queue once
skills/foundry-watch/SKILL.md    /foundry-watch   — drain + poll (prefers `hermes cron`)
skills/foundry-refresh/SKILL.md  /foundry-refresh — re-pull the workflow context
skills/foundry-agents/SKILL.md   /foundry-agents  — pick + claim a key from the registry
scripts/foundry-registry.js    Agent Key Registry broker client (talks to the local daemon)
scripts/install.sh             copies skills + broker client + wires up config.yaml
config.yaml.example            the mcp_servers entries to merge by hand
```

## License

MIT — see [LICENSE](LICENSE).
