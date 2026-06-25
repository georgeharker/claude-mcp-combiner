# claude-mcp-combiner

A focused [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) plugin that manages a single shared [`mcp-combiner`](https://github.com/georgeharker/mcp-companion.nvim) process across Claude Code sessions (and other clients) via the [`sharedserver`](https://github.com/georgeharker/sharedserver) CLI.

On `SessionStart` it runs `sharedserver use mcp-combiner --pid $PPID -- mcp-combiner --config … --port 9741`. On `SessionEnd` it runs `sharedserver unuse mcp-combiner --pid $PPID`. Multiple Claude Code sessions — or Neovim with `mcp-companion.nvim`, or any other client using the same name — share one combiner process. The combiner stays alive for the configured grace period after the last client exits, so a quick restart re-attaches instantly.

## Relationship to claude-sharedserver

This plugin is a **focused, zero-config alternative** to the more general [`claude-sharedserver`](https://github.com/georgeharker/claude-sharedserver) plugin:

| You want…                                              | Use                       |
|:-------------------------------------------------------|:--------------------------|
| Only mcp-combiner, no other shared services              | **`claude-mcp-combiner`** (this plugin) |
| Multiple shared services described in one config file  | `claude-sharedserver`     |

Both plugins call the same `sharedserver` CLI underneath, and `sharedserver` tracks clients by PID, so it's safe to enable both — they share the registration for `mcp-combiner` without double-incrementing the refcount. But you don't need to: pick the one that fits your needs.

## Requirements

- Claude Code with plugin support
- [`sharedserver`](https://crates.io/crates/sharedserver) reachable via `PATH`, `SHAREDSERVER_BIN`, or one of `~/.cargo/bin`, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`. Install with `cargo install sharedserver`.
- An `mcp-combiner` binary or checkout (see [Config](#configuration)).
- An `mcp-servers.json` config file describing the upstream MCP servers you want the combiner to proxy.

## Install

```sh
# From GitHub (recommended)
claude plugin marketplace add georgeharker/claude-mcp-combiner
claude plugin install claude-mcp-combiner

# …or from a local checkout
claude plugin marketplace add /path/to/claude-mcp-combiner
claude plugin install claude-mcp-combiner
```

**That's it — the MCP endpoint is registered automatically.** The plugin bundles a
[`.mcp.json`](./claude-mcp-combiner/.mcp.json) at its root, so installing it registers a `mcp-combiner`
HTTP server with Claude Code; no `claude mcp add` step is needed. Claude Code connects
the server on session start and reconnects after `/reload-plugins`.

> **Why the `${…}` URL.** The bundled `.mcp.json` registers the endpoint as
> `${MCP_COMPANION_COMBINER_URL:-http://127.0.0.1:9741/mcp}`. Claude Code expands env
> vars in the MCP config `url` at connect time, so one entry works two ways:
>
> - **Standalone Claude Code:** `MCP_COMPANION_COMBINER_URL` is unset, so the `:-`
>   default `http://127.0.0.1:9741/mcp` is used — a plain, tokenless connection.
> - **Launched from Neovim** (CodeCompanion + [`mcp-companion.nvim`](https://github.com/georgeharker/mcp-companion.nvim)):
>   the editor sets `MCP_COMPANION_COMBINER_URL=http://127.0.0.1:9741/mcp/<token>`
>   on the agent's launch, so Claude dials `/mcp/<token>`. The combiner then
>   correlates the session to **that editor** — enabling the `neovim_*` editor-
>   control tools to route back to it, plus per-chat server filtering.
>
> The bundled URL hardcodes port `9741`. If you set `CLAUDE_MCP_COMBINER_PORT` to run
> the combiner elsewhere, set `MCP_COMPANION_COMBINER_URL` to the matching full URL so the
> registration follows.

### Upgrading from `claude-mcp-bridge`

This plugin was previously named **`claude-mcp-bridge`**. If you installed the old one, remove it
before adding the renamed plugin — removing the marketplace also uninstalls its plugin. (Find the
old names with `claude plugin list` and `claude plugin marketplace list`.)

```sh
# Remove the old marketplace (this also uninstalls the old plugin)
claude plugin marketplace remove claude-mcp-bridge

# Add the renamed plugin (from GitHub)
claude plugin marketplace add georgeharker/claude-mcp-combiner
claude plugin install claude-mcp-combiner
```

You can also do this interactively with `/plugin` (Installed / Marketplaces tabs). The underlying
`mcp-combiner` package and `CLAUDE_MCP_COMBINER_*` env vars were renamed too — see the
[combiner migration notes](https://github.com/georgeharker/mcp-companion/tree/main/combiner#readme).

### Registering manually instead

If you'd rather own the registration yourself (e.g. a different scope, or you don't
want the bundled server), register the same endpoint by hand and skip the `.mcp.json`:

```sh
claude mcp add --transport http --scope user mcp-combiner \
  '${MCP_COMPANION_COMBINER_URL:-http://127.0.0.1:9741/mcp}'
```

Single-quote it so your shell stores the `${…}` literally for Claude to expand. (If
you previously registered the bare `http://127.0.0.1:9741/mcp` URL, re-run with
`--force`, or `claude mcp remove mcp-combiner` first, to pick up the `${…}` form.)

That's the two-layer setup: this plugin owns the lifecycle (start on SessionStart, stop
on SessionEnd with grace) **and** the connection (the bundled `.mcp.json`). The layers
are still independent — you can run the combiner yourself for testing, or pull the combiner
out and leave it running for other clients.

> **A note on timing.** Claude Code connects any registered `mcp-combiner` server at
> session start, while the `SessionStart` hook is what brings the combiner process up.
> This ordering is the same whether you use the bundled `.mcp.json` or register manually
> with `claude mcp add` — bundling doesn't introduce the race, it just automates the
> registration. In practice it rarely bites: the combiner survives the
> `CLAUDE_MCP_COMBINER_GRACE` window between sessions, so on almost every launch it's
> already alive and the connection succeeds immediately. Only on a true cold start can
> the connection beat the hook; if `mcp-combiner` shows as failed on that first launch,
> `/reload-plugins` (or `/mcp` → reconnect) re-dials once the combiner is up.

## Configuration

All knobs are env-var overrides; sensible defaults cover the common case.

| Env var                       | Default                                                                                | Description                                                                          |
|:------------------------------|:---------------------------------------------------------------------------------------|:-------------------------------------------------------------------------------------|
| `CLAUDE_MCP_COMBINER_CONFIG`    | first existing of `~/.cache/secrets/$USER.mcpservers.json`, `~/.config/mcp-combiner/servers.json`, `~/.config/mcp/servers.json` | Path to the mcp-servers JSON config.                                                  |
| `CLAUDE_MCP_COMBINER_PORT`      | `9741`                                                                                 | Port the combiner listens on. Matches the URL in `claude mcp add`.                     |
| `CLAUDE_MCP_COMBINER_GRACE`     | `30m`                                                                                  | Duration string (`30s`, `5m`, `1h`, `2h30m`). How long the combiner survives idle.     |
| `CLAUDE_MCP_COMBINER_NAME`      | `mcp-combiner`                                                                           | sharedserver name. Change only if you want a non-default combiner identity.            |
| `CLAUDE_MCP_COMBINER_LOG`       | _(unset)_                                                                              | Capture combiner stdout/stderr to this path (passed as `sharedserver --log-file`).     |
| `CLAUDE_MCP_COMBINER_COMMAND`   | resolved automatically (see below)                                                     | Override the combiner command entirely.                                                |
| `CLAUDE_MCP_COMBINER_ARGS`      | _(empty)_                                                                              | Extra space-split args appended to `CLAUDE_MCP_COMBINER_COMMAND`.                      |
| `CLAUDE_MCP_COMBINER_CHECKOUT`  | _(unset)_                                                                              | Optional combiner-source dir for the `uv run` fallback when `mcp-combiner` isn't on PATH. No default — prefer a real install (`uv tool install <…>/combiner`) or a shared venv on PATH. |

### Command resolution

`start.sh` walks this list to find the combiner command:

1. `CLAUDE_MCP_COMBINER_COMMAND` if set (plus optional `CLAUDE_MCP_COMBINER_ARGS`)
2. `mcp-combiner` on `PATH` (recommended: `uv tool install mcp-combiner` once and forget)
3. `uv run --project $CLAUDE_MCP_COMBINER_CHECKOUT python -m mcp_combiner` (works from a source checkout without needing a global install)

If none resolve, the hook logs a one-line note and exits cleanly — Claude Code starts normally without the combiner.

### Per-session env overrides

Because env vars are read at hook time, you can set them in your shell rc:

```sh
# ~/.zshrc
export CLAUDE_MCP_COMBINER_PORT=9742          # if 9741 is busy
export CLAUDE_MCP_COMBINER_GRACE=2h           # keep combiner warm longer
export CLAUDE_MCP_COMBINER_LOG="$HOME/Library/Logs/mcp-combiner.log"
```

## What it runs

```sh
sharedserver use mcp-combiner --pid <claude-session-pid> --grace-period 30m \
    [--log-file <log>] \
    -- <resolved-combiner-command> --config <config-path> --port 9741
```

And on `SessionEnd`:

```sh
sharedserver unuse mcp-combiner --pid <claude-session-pid>
```

`$PPID` of the hook process is the Claude Code session itself, so the refcount tracks Claude sessions rather than ephemeral hook invocations.

## Behavior

- Any failure (missing binary, bad config, `sharedserver use` non-zero exit) is logged to stderr and ignored. The hook never blocks a Claude session from starting.
- `sharedserver` polls every ~5s for dead clients, so even if `SessionEnd` doesn't fire (hard crash, `kill -9`) the refcount eventually self-corrects.
- Multiple Claude sessions, plus a running Neovim with `mcp-companion.nvim`, plus an OpenCode session via `opencode-sharedserver` — all sharing one combiner process. First in starts it; the rest attach; last one out triggers grace.

## Diagnostics

```sh
sharedserver list                       # is mcp-combiner running?
sharedserver info mcp-combiner --json     # PID, refcount, attached clients, grace state
curl http://127.0.0.1:9741/health       # combiner HTTP health
claude mcp list                         # is the MCP registration in place?
```

Combiner logs (if `CLAUDE_MCP_COMBINER_LOG` is set) capture stdout/stderr from the combiner process itself.

Hook stderr is captured by Claude Code's normal logging. Common issues:

- **Hook reports "cannot find mcp-combiner"**: install it (`uv tool install mcp-combiner`) or set `CLAUDE_MCP_COMBINER_COMMAND`.
- **`sharedserver use` fails immediately**: run the resolved command standalone (`mcp-combiner --config … --port …`) to see what the combiner is complaining about.
- **Stale lockfile after a crash**: `sharedserver admin doctor` validates/clears; `sharedserver admin kill mcp-combiner` is the nuclear option.

## License

MIT
