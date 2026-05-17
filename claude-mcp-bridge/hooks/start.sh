#!/usr/bin/env bash
# SessionStart hook: attach to (or start) the mcp-companion mcp-bridge process
# via sharedserver. The bridge is registered under name "mcp-bridge" by default;
# multiple Claude Code sessions and other clients (nvim, OpenCode) that use the
# same name share one process.

set -u

ss_bin="${CLAUDE_PLUGIN_ROOT}/bin/sharedserver"

# --- Resolve mcp-bridge command -------------------------------------------------
# Priority: env override → `mcp-bridge` on PATH → `uv run -m mcp_bridge` from the
# checkout if present. If none work, log and bail.
resolve_bridge_command() {
  if [[ -n "${CLAUDE_MCP_BRIDGE_COMMAND:-}" ]]; then
    bridge_cmd=("${CLAUDE_MCP_BRIDGE_COMMAND}")
    if [[ -n "${CLAUDE_MCP_BRIDGE_ARGS:-}" ]]; then
      # Split on whitespace; users wanting embedded spaces should set bridge_cmd directly.
      read -r -a extra <<<"${CLAUDE_MCP_BRIDGE_ARGS}"
      bridge_cmd+=("${extra[@]}")
    fi
    return 0
  fi

  if command -v mcp-bridge >/dev/null 2>&1; then
    bridge_cmd=("mcp-bridge")
    return 0
  fi

  local checkout="${CLAUDE_MCP_BRIDGE_CHECKOUT:-$HOME/Development/neovim-plugins/mcp-companion/bridge}"
  if [[ -d "$checkout" ]] && command -v uv >/dev/null 2>&1; then
    bridge_cmd=(uv run --project "$checkout" python -m mcp_bridge)
    return 0
  fi

  return 1
}

bridge_cmd=()
if ! resolve_bridge_command; then
  echo "claude-mcp-bridge: cannot find mcp-bridge." >&2
  echo "  Set CLAUDE_MCP_BRIDGE_COMMAND, install with 'uv tool install mcp-bridge'," >&2
  echo "  or check out https://github.com/georgeharker/mcp-companion.nvim." >&2
  exit 0
fi

# --- Resolve config path --------------------------------------------------------
config="${CLAUDE_MCP_BRIDGE_CONFIG:-}"
if [[ -z "$config" ]]; then
  for candidate in \
    "$HOME/.cache/secrets/$USER.mcpservers.json" \
    "$HOME/.config/mcp-bridge/servers.json" \
    "$HOME/.config/mcp/servers.json"; do
    if [[ -f "$candidate" ]]; then
      config="$candidate"
      break
    fi
  done
fi
if [[ -z "$config" || ! -f "$config" ]]; then
  echo "claude-mcp-bridge: no mcp-servers config found." >&2
  echo "  Set CLAUDE_MCP_BRIDGE_CONFIG or create ~/.config/mcp-bridge/servers.json." >&2
  exit 0
fi

# --- Other knobs ---------------------------------------------------------------
port="${CLAUDE_MCP_BRIDGE_PORT:-9741}"
grace="${CLAUDE_MCP_BRIDGE_GRACE:-30m}"
name="${CLAUDE_MCP_BRIDGE_NAME:-mcp-bridge}"
log_file="${CLAUDE_MCP_BRIDGE_LOG:-}"

# --- Resolve client PID --------------------------------------------------------
# $PPID is the wrapper shell that claude execs to run this hook — ephemeral, so
# sharedserver's dead-client poller would reap our registration ~5s after the
# hook returns. Walk the parent chain to find the actual claude process.
find_claude_pid() {
  local pid=$PPID
  local comm
  while [[ "$pid" -gt 1 ]]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$comm" ]] && break
    # `comm` is the full executable path on macOS, basename elsewhere.
    if [[ "${comm##*/}" == "claude" ]]; then
      echo "$pid"
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$pid" ]] && break
  done
  return 1
}

if client_pid=$(find_claude_pid); then
  :
else
  echo "claude-mcp-bridge: no 'claude' process in parent chain; falling back to PPID=$PPID" >&2
  client_pid="$PPID"
fi

# --- Build and run sharedserver use --------------------------------------------
ss_args=(use "$name" --pid "$client_pid" --metadata "claude-$client_pid" --grace-period "$grace")
[[ -n "$log_file" ]] && ss_args+=(--log-file "$log_file")
ss_args+=(-- "${bridge_cmd[@]}" --config "$config" --port "$port")

if ! out="$("$ss_bin" "${ss_args[@]}" 2>&1)"; then
  echo "claude-mcp-bridge: sharedserver use failed (exit $?):" >&2
  [[ -n "$out" ]] && echo "$out" | sed 's/^/  /' >&2
elif [[ -n "$out" ]]; then
  echo "$out" | sed 's/^/  /' >&2
fi

exit 0
