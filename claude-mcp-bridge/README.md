# claude-mcp-bridge

A focused [Claude Code](https://docs.claude.com/en/docs/claude-code/overview) plugin that manages a single shared [`mcp-bridge`](https://github.com/georgeharker/mcp-companion.nvim) process across Claude Code sessions (and other clients) via the [`sharedserver`](https://github.com/georgeharker/sharedserver) CLI.

On `SessionStart` it runs `sharedserver use mcp-bridge --pid $PPID -- mcp-bridge --config … --port 9741`. On `SessionEnd` it runs `sharedserver unuse mcp-bridge --pid $PPID`. Multiple Claude Code sessions — or Neovim with `mcp-companion.nvim`, or any other client using the same name — share one bridge process. The bridge stays alive for the configured grace period after the last client exits, so a quick restart re-attaches instantly.

## Relationship to claude-sharedserver

This plugin is a **focused, zero-config alternative** to the more general [`claude-sharedserver`](https://github.com/georgeharker/claude-sharedserver) plugin:

| You want…                                              | Use                       |
|:-------------------------------------------------------|:--------------------------|
| Only mcp-bridge, no other shared services              | **`claude-mcp-bridge`** (this plugin) |
| Multiple shared services described in one config file  | `claude-sharedserver`     |

Both plugins call the same `sharedserver` CLI underneath, and `sharedserver` tracks clients by PID, so it's safe to enable both — they share the registration for `mcp-bridge` without double-incrementing the refcount. But you don't need to: pick the one that fits your needs.

## Requirements

- Claude Code with plugin support
- [`sharedserver`](https://crates.io/crates/sharedserver) reachable via `PATH`, `SHAREDSERVER_BIN`, or one of `~/.cargo/bin`, `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`. Install with `cargo install sharedserver`.
- An `mcp-bridge` binary or checkout (see [Config](#configuration)).
- An `mcp-servers.json` config file describing the upstream MCP servers you want the bridge to proxy.

## Install

```sh
# Local marketplace install
claude plugin marketplace add /path/to/claude-mcp-bridge
claude plugin install claude-mcp-bridge
```

Then register the bridge endpoint with Claude Code so it can dial in:

```sh
claude mcp add --transport http --scope user mcp-companion http://127.0.0.1:9741/mcp
```

That's the two-layer setup: this plugin owns the lifecycle (start on SessionStart, stop on SessionEnd with grace), `claude mcp` owns the connection. They're independent — you can run the bridge yourself for testing and just use the `claude mcp` half, or you can pull `claude mcp` and leave the bridge running for other clients.

## Configuration

All knobs are env-var overrides; sensible defaults cover the common case.

| Env var                       | Default                                                                                | Description                                                                          |
|:------------------------------|:---------------------------------------------------------------------------------------|:-------------------------------------------------------------------------------------|
| `CLAUDE_MCP_BRIDGE_CONFIG`    | first existing of `~/.cache/secrets/$USER.mcpservers.json`, `~/.config/mcp-bridge/servers.json`, `~/.config/mcp/servers.json` | Path to the mcp-servers JSON config.                                                  |
| `CLAUDE_MCP_BRIDGE_PORT`      | `9741`                                                                                 | Port the bridge listens on. Matches the URL in `claude mcp add`.                     |
| `CLAUDE_MCP_BRIDGE_GRACE`     | `30m`                                                                                  | Duration string (`30s`, `5m`, `1h`, `2h30m`). How long the bridge survives idle.     |
| `CLAUDE_MCP_BRIDGE_NAME`      | `mcp-bridge`                                                                           | sharedserver name. Change only if you want a non-default bridge identity.            |
| `CLAUDE_MCP_BRIDGE_LOG`       | _(unset)_                                                                              | Capture bridge stdout/stderr to this path (passed as `sharedserver --log-file`).     |
| `CLAUDE_MCP_BRIDGE_COMMAND`   | resolved automatically (see below)                                                     | Override the bridge command entirely.                                                |
| `CLAUDE_MCP_BRIDGE_ARGS`      | _(empty)_                                                                              | Extra space-split args appended to `CLAUDE_MCP_BRIDGE_COMMAND`.                      |
| `CLAUDE_MCP_BRIDGE_CHECKOUT`  | `~/Development/neovim-plugins/mcp-companion/bridge`                                    | Where to find the bridge source if `mcp-bridge` isn't on PATH (`uv run` fallback).   |

### Command resolution

`start.sh` walks this list to find the bridge command:

1. `CLAUDE_MCP_BRIDGE_COMMAND` if set (plus optional `CLAUDE_MCP_BRIDGE_ARGS`)
2. `mcp-bridge` on `PATH` (recommended: `uv tool install mcp-bridge` once and forget)
3. `uv run --project $CLAUDE_MCP_BRIDGE_CHECKOUT python -m mcp_bridge` (works from a source checkout without needing a global install)

If none resolve, the hook logs a one-line note and exits cleanly — Claude Code starts normally without the bridge.

### Per-session env overrides

Because env vars are read at hook time, you can set them in your shell rc:

```sh
# ~/.zshrc
export CLAUDE_MCP_BRIDGE_PORT=9742          # if 9741 is busy
export CLAUDE_MCP_BRIDGE_GRACE=2h           # keep bridge warm longer
export CLAUDE_MCP_BRIDGE_LOG="$HOME/Library/Logs/mcp-bridge.log"
```

## What it runs

```sh
sharedserver use mcp-bridge --pid <claude-session-pid> --grace-period 30m \
    [--log-file <log>] \
    -- <resolved-bridge-command> --config <config-path> --port 9741
```

And on `SessionEnd`:

```sh
sharedserver unuse mcp-bridge --pid <claude-session-pid>
```

`$PPID` of the hook process is the Claude Code session itself, so the refcount tracks Claude sessions rather than ephemeral hook invocations.

## Behavior

- Any failure (missing binary, bad config, `sharedserver use` non-zero exit) is logged to stderr and ignored. The hook never blocks a Claude session from starting.
- `sharedserver` polls every ~5s for dead clients, so even if `SessionEnd` doesn't fire (hard crash, `kill -9`) the refcount eventually self-corrects.
- Multiple Claude sessions, plus a running Neovim with `mcp-companion.nvim`, plus an OpenCode session via `opencode-sharedserver` — all sharing one bridge process. First in starts it; the rest attach; last one out triggers grace.

## Diagnostics

```sh
sharedserver list                       # is mcp-bridge running?
sharedserver info mcp-bridge --json     # PID, refcount, attached clients, grace state
curl http://127.0.0.1:9741/health       # bridge HTTP health
claude mcp list                         # is the MCP registration in place?
```

Bridge logs (if `CLAUDE_MCP_BRIDGE_LOG` is set) capture stdout/stderr from the bridge process itself.

Hook stderr is captured by Claude Code's normal logging. Common issues:

- **Hook reports "cannot find mcp-bridge"**: install it (`uv tool install mcp-bridge`) or set `CLAUDE_MCP_BRIDGE_COMMAND`.
- **`sharedserver use` fails immediately**: run the resolved command standalone (`mcp-bridge --config … --port …`) to see what the bridge is complaining about.
- **Stale lockfile after a crash**: `sharedserver admin doctor` validates/clears; `sharedserver admin kill mcp-bridge` is the nuclear option.

## License

MIT
