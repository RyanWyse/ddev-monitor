#!/bin/bash
# Unload the launchd agents and remove the Traefik catch-all.
# Leaves ~/.ddev/monitor (config, logs, state) unless --purge is passed.
set -uo pipefail

MON_DIR="$HOME/.ddev/monitor"
AGENTS="$HOME/Library/LaunchAgents"

for name in com.ddev.monitor com.ddev.autostart; do
    launchctl bootout "gui/$(id -u)/$name" 2>/dev/null && echo "unloaded $name"
    rm -f "$AGENTS/$name.plist"
done

# Stop the persistent `docker events` tailer the monitor leaves running.
pid_file="$MON_DIR/state/.events_tailer.pid"
[ -f "$pid_file" ] && kill "$(cat "$pid_file")" 2>/dev/null && echo "stopped events tailer"

rm -f "$HOME/.ddev/traefik/custom-global-config/autostart-catchall.yaml"
docker exec ddev-router rm -f /mnt/ddev-global-cache/traefik/config/autostart-catchall.yaml 2>/dev/null \
    && echo "removed catch-all from ddev-router"

if [ "${1:-}" = "--purge" ]; then
    rm -rf "$MON_DIR" && echo "removed $MON_DIR"
fi
echo "Paused projects stay paused; resume them with: ddev start <project>"
