#!/bin/bash
# Install (or update) ddev-monitor + ddev-autostart as launchd agents.
# Re-running is safe: scripts are replaced, an existing monitor.conf is kept.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
MON_DIR="$HOME/.ddev/monitor"
AGENTS="$HOME/Library/LaunchAgents"
TRAEFIK_DIR="$HOME/.ddev/traefik/custom-global-config"

[ "$(uname)" = "Darwin" ] || { echo "macOS only (uses launchd)."; exit 1; }
for bin in ddev docker jq python3 curl; do
    command -v "$bin" >/dev/null || { echo "missing dependency: $bin"; exit 1; }
done
PYTHON="$(command -v python3)"

mkdir -p "$MON_DIR/logs" "$MON_DIR/state" "$AGENTS" "$TRAEFIK_DIR"
install -m 755 "$REPO/ddev-monitor.sh" "$REPO/ddev-autostart.py" "$MON_DIR/"
install -m 644 "$REPO/autostart-catchall.yaml" "$MON_DIR/"
install -m 644 "$REPO/autostart-catchall.yaml" "$TRAEFIK_DIR/"
if [ ! -f "$MON_DIR/monitor.conf" ]; then
    install -m 644 "$REPO/monitor.conf.example" "$MON_DIR/monitor.conf"
    echo "wrote $MON_DIR/monitor.conf (edit to taste)"
else
    echo "kept existing $MON_DIR/monitor.conf"
fi

for name in com.ddev.monitor com.ddev.autostart; do
    sed -e "s|__HOME__|$HOME|g" -e "s|__PYTHON__|$PYTHON|g" \
        "$REPO/launchd/$name.plist" > "$AGENTS/$name.plist"
    launchctl bootout "gui/$(id -u)/$name" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$AGENTS/$name.plist"
    echo "loaded $name"
done

# Push the catch-all into a running router now; ddev copies it on every
# router (re)creation from here on.
if docker ps -q --filter name=ddev-router --filter status=running | grep -q .; then
    docker cp "$MON_DIR/autostart-catchall.yaml" \
        ddev-router:/mnt/ddev-global-cache/traefik/config/autostart-catchall.yaml \
        && echo "pushed catch-all into ddev-router"
fi

echo
echo "Done. Logs: $MON_DIR/logs/  Config: $MON_DIR/monitor.conf"
echo "Tip: set DRY_RUN=1 in monitor.conf for a first day to see what it would pause."
