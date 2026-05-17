#!/usr/bin/env bash
# SessionEnd hook: detach from the shared mcp-bridge process. Best-effort —
# if it fails or doesn't run (hard crash), sharedserver's dead-client poller
# reaps the refcount within ~5s.

set -u

ss_bin="${CLAUDE_PLUGIN_ROOT}/bin/sharedserver"
name="${CLAUDE_MCP_BRIDGE_NAME:-mcp-bridge}"

# Mirror start.sh: $PPID is the ephemeral hook-wrapper shell, so walk parents
# to find the claude PID we originally registered.
find_claude_pid() {
  local pid=$PPID
  local comm
  while [[ "$pid" -gt 1 ]]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$comm" ]] && break
    if [[ "${comm##*/}" == "claude" ]]; then
      echo "$pid"
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -z "$pid" ]] && break
  done
  return 1
}

client_pid=$(find_claude_pid) || client_pid="$PPID"

"$ss_bin" unuse "$name" --pid "$client_pid" >/dev/null 2>&1 || true

exit 0
