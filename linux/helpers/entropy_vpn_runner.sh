#!/bin/sh
# EntropyVPN privileged runner.
#
# Spawned via pkexec (or directly when the app is already root) to start the
# selected core (xray / sing-box) with CAP_NET_ADMIN so it can create the TUN
# interface and modify the route table.
#
# The unprivileged Flutter app launches this script and controls its lifetime
# via stdin: writing the line "stop" or closing stdin triggers a clean
# shutdown. The script also installs signal handlers so SIGTERM/SIGINT work
# when sent by a process that has permission (root or same UID).
#
# Usage: entropy_vpn_runner.sh <core_binary> <config_path>

set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <core_binary> <config_path>" >&2
  exit 64
fi

core_binary="$1"
config_path="$2"

if [ ! -x "$core_binary" ]; then
  echo "core binary not executable: $core_binary" >&2
  exit 65
fi

if [ ! -r "$config_path" ]; then
  echo "config not readable: $config_path" >&2
  exit 66
fi

echo "entropy_vpn_runner: starting $core_binary (config $config_path)"

"$core_binary" run -c "$config_path" &
core_pid=$!

shutdown_core() {
  if kill -0 "$core_pid" 2>/dev/null; then
    echo "entropy_vpn_runner: sending SIGTERM to core pid $core_pid"
    kill -TERM "$core_pid" 2>/dev/null || true
    i=0
    while [ "$i" -lt 5 ]; do
      if ! kill -0 "$core_pid" 2>/dev/null; then break; fi
      sleep 1
      i=$((i + 1))
    done
    if kill -0 "$core_pid" 2>/dev/null; then
      echo "entropy_vpn_runner: core did not exit after 5s, sending SIGKILL"
      kill -KILL "$core_pid" 2>/dev/null || true
    fi
  fi
  wait "$core_pid" 2>/dev/null || true
}

trap 'shutdown_core; exit 0' TERM INT HUP

# Drive shutdown from stdin: the unprivileged parent writes "stop\n" or
# simply closes stdin (which happens when the parent process exits).
while IFS= read -r line; do
  case "$line" in
    stop)
      shutdown_core
      exit 0
      ;;
  esac
done

# EOF on stdin -> parent went away. Tear the core down too.
shutdown_core
exit 0
