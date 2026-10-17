#!/bin/bash
# ddev-monitor: stop idle ddev projects and shed the least-recently-used
# project under Docker memory pressure. Run periodically via launchd.
#
# Activity signals per running project (last_active = max of all):
#   1. docker exec events (ddev exec / artisan / pest / composer, etc.)
#   2. nginx access.log mtime inside the web container (browser traffic)
#   3. recent file modifications in the project approot (editing code)
#   4. web-container CPU above CPU_ACTIVE_PCT counts as "active right now"
#   5. a Claude Code session transcript writing under this approot (live agent)

set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

MON_DIR="$HOME/.ddev/monitor"
STATE_DIR="$MON_DIR/state"
ROUTES_DIR="$STATE_DIR/routes"
ROUTER_CONF_DIR="/mnt/ddev-global-cache/traefik/config"
LOG_FILE="$MON_DIR/logs/monitor.log"
CONF="$MON_DIR/monitor.conf"

IDLE_MINUTES=60
STOP_IDLE=1
DELETE_OFF_DAYS=7
NEVER_DELETE=""
MEM_THRESHOLD_PCT=80
CPU_ACTIVE_PCT=15
PROTECTED_PROJECTS=""
DRY_RUN=0
NOTIFY=1
[ -f "$CONF" ] && . "$CONF"

mkdir -p "$STATE_DIR" "$MON_DIR/logs"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
}

# Rotate log at ~1MB
if [ -f "$LOG_FILE" ] && [ "$(stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)" -gt 1048576 ]; then
    mv "$LOG_FILE" "$LOG_FILE.1"
fi

# ---------------------------------------------------------------------------
# Watchdog: never let a run wedge.
#
# 2026-08-06: the `docker info` probe below hung for 2 days 14 hours across the
# Docker Desktop -> OrbStack migration. launchd's StartInterval will not spawn a
# second instance while the first is alive, so the monitor silently stopped
# pausing anything and every project stayed up. Two guards: reap a stale
# predecessor, then arm a self-kill so no run can outlive MAX_RUNTIME_SECS.
# ---------------------------------------------------------------------------
MAX_RUNTIME_SECS=${MAX_RUNTIME_SECS:-120}
LOCK_FILE="$STATE_DIR/.monitor.pid"

if [ -f "$LOCK_FILE" ]; then
    prev=$(cat "$LOCK_FILE" 2>/dev/null)
    if [ -n "$prev" ] && [ "$prev" != "$$" ] && kill -0 "$prev" 2>/dev/null; then
        log "reaping wedged predecessor (pid $prev)"
        pkill -9 -P "$prev" 2>/dev/null
        kill -9 "$prev" 2>/dev/null
    fi
fi
echo $$ > "$LOCK_FILE"

( sleep "$MAX_RUNTIME_SECS"
  kill -0 $$ 2>/dev/null || exit 0
  echo "$(date '+%Y-%m-%d %H:%M:%S') WATCHDOG: run exceeded ${MAX_RUNTIME_SECS}s, killing pid $$" >> "$LOG_FILE"
  # Kill the wedged docker child too, but never kill this watchdog before it
  # has finished the sweep. /bin/bash here is 3.2, which has no $BASHPID, so
  # derive this subshell's pid from a throwaway child's $PPID.
  selfpid=$(sh -c 'echo $PPID')
  for victim in $(pgrep -P $$ 2>/dev/null); do
      [ "$victim" = "$selfpid" ] && continue
      kill -9 "$victim" 2>/dev/null
  done
  kill -9 $$ 2>/dev/null
  exit 0 ) &
WATCHDOG_PID=$!
disown "$WATCHDOG_PID" 2>/dev/null   # keep the exit-trap kill out of stderr
trap 'kill "$WATCHDOG_PID" 2>/dev/null; rm -f "$LOCK_FILE"' EXIT

if ! docker info >/dev/null 2>&1; then
    log "docker not available, skipping run"
    exit 0
fi

NOW=$(date +%s)
LAST_RUN_FILE="$STATE_DIR/.last_run"
if [ -f "$LAST_RUN_FILE" ]; then
    LAST_RUN=$(cat "$LAST_RUN_FILE")
else
    LAST_RUN=$((NOW - 600))
fi
echo "$NOW" > "$LAST_RUN_FILE"

notify() {
    [ "$NOTIFY" = "1" ] || return 0
    osascript -e "display notification \"$1\" with title \"DDEV Monitor\"" >/dev/null 2>&1
}

is_protected() {
    local p
    for p in $PROTECTED_PROJECTS; do
        [ "$p" = "$1" ] && return 0
    done
    return 1
}

stop_project() {
    local project="$1" reason="$2"
    if [ "$DRY_RUN" = "1" ]; then
        log "DRY_RUN: would stop $project ($reason)"
        return 0
    fi
    # "Pause" = docker stop on the project's containers without removing them
    # (ddev shows this as "paused"; `ddev pause` itself was removed from ddev,
    # and `ddev stop` removes the containers). Frees the same memory, resumes
    # slightly faster via `ddev start`.
    log "pausing $project ($reason)"
    local ids
    ids=$(docker ps -q --filter "label=com.ddev.site-name=$project")
    if [ -z "$ids" ] || ! echo "$ids" | xargs docker stop >/dev/null 2>>"$LOG_FILE"; then
        log "ERROR: pausing $project failed"
        return 0
    fi
    # Back up the project's Traefik route, then drop it so the autostart
    # catch-all matches the domain (ddev only removes it on full `ddev stop`;
    # leaving it routes to the dead container and 502s). The autostart daemon
    # restores this exact file on resume — a Traefik file-provider hot-reload
    # that does NOT restart the router, so Docker Desktop never re-publishes
    # :80/:443 and the port-forward never gets wedged. Only remove the live
    # route once a non-empty backup exists.
    mkdir -p "$ROUTES_DIR"
    if docker exec ddev-router cat "$ROUTER_CONF_DIR/${project}_merged.yaml" \
         > "$ROUTES_DIR/${project}_merged.yaml" 2>/dev/null \
       && [ -s "$ROUTES_DIR/${project}_merged.yaml" ]; then
        docker exec ddev-router rm -f "$ROUTER_CONF_DIR/${project}_merged.yaml" 2>>"$LOG_FILE"
    else
        rm -f "$ROUTES_DIR/${project}_merged.yaml"
        log "warn: no route backup for $project; leaving route in place (domain 502s until resumed via ddev start)"
    fi
    notify "Paused $project ($reason)"
}

# ---------------------------------------------------------------------------
# Heal a wedged host-side :443 port-forward into ddev-router.
#
# Docker Desktop intermittently half-opens the published :443 forward: the
# TCP connect succeeds but the TLS handshake is reset before traefik sees any
# bytes, so every *.ddev.site HTTPS URL dies (curl exit 35 / code 000) even
# though the router, its routes, certs and all web containers are healthy and
# port 80 still works. It's a Docker Desktop forwarding bug, not ddev or the
# sites. Restarting the container that publishes :443 rebuilds the forward.
#
# Signature we require before restarting (kept tight to avoid needless
# restarts): host :443 fails for a known-running project AND host :80 for the
# same project works. A cooldown prevents restart loops.
# ---------------------------------------------------------------------------
heal_router_forward() {
    local probe="$1"
    docker ps --filter 'name=ddev-router' --filter 'status=running' -q | grep -q . || return 0

    # Any HTTP status (even 5xx) over :443 means the forward is fine.
    curl -sk -m 5 -o /dev/null "https://${probe}.ddev.site/" 2>/dev/null && return 0

    # :443 failed — only act if :80 still works, confirming it's the per-port
    # forward wedging rather than a full router/stack outage.
    if ! curl -s -m 5 -o /dev/null "http://${probe}.ddev.site/" 2>/dev/null; then
        log "router probe: :80 and :443 both fail for $probe — leaving router alone"
        return 0
    fi

    local ts_file="$STATE_DIR/.router_heal_ts" last=0
    [ -f "$ts_file" ] && last=$(cat "$ts_file")
    if [ $((NOW - last)) -lt 600 ]; then
        log "router :443 wedged but healed <10m ago — not restarting again yet"
        return 0
    fi

    log "router :443 forward wedged (host :80 ok, :443 reset) — restarting ddev-router"
    echo "$NOW" > "$ts_file"
    if docker restart ddev-router >/dev/null 2>>"$LOG_FILE"; then
        sleep 5
        if curl -sk -m 8 -o /dev/null "https://${probe}.ddev.site/" 2>/dev/null; then
            log "router restart restored :443"
            notify "Restored HTTPS — ddev-router :443 forward was wedged"
        else
            log "router restarted but :443 still failing — likely needs Docker Desktop restart"
            notify "HTTPS still down after router restart; check Docker Desktop"
        fi
    else
        log "ERROR: ddev-router restart failed"
    fi
}

# ---------------------------------------------------------------------------
# Keep the autostart catch-all traefik config in place.
#
# Primary mechanism: ~/.ddev/traefik/custom-global-config/ is the ddev-native
# persistent location — ddev copies files there into the router volume on every
# router (re)creation and never deletes them, so the catch-all survives Docker
# restarts, `ddev poweroff`, and router recreation on its own. (The old
# ~/.ddev/traefik/config/ path was a STAGING dir ddev wipes — do not use it.)
#
# Safety net: if the router is momentarily missing the catch-all (dropped
# without a recreation, or before the next ddev start re-copies it), push it in
# now so paused-project domains never 404.
# ---------------------------------------------------------------------------
CATCHALL_MASTER="$MON_DIR/autostart-catchall.yaml"
CATCHALL_PERSIST="$HOME/.ddev/traefik/custom-global-config/autostart-catchall.yaml"
if [ -f "$CATCHALL_MASTER" ]; then
    if ! cmp -s "$CATCHALL_MASTER" "$CATCHALL_PERSIST" 2>/dev/null; then
        mkdir -p "$(dirname "$CATCHALL_PERSIST")"
        cp "$CATCHALL_MASTER" "$CATCHALL_PERSIST" && log "synced catch-all to custom-global-config"
    fi
    if ! docker exec ddev-router test -f /mnt/ddev-global-cache/traefik/config/autostart-catchall.yaml 2>/dev/null; then
        if docker cp "$CATCHALL_MASTER" ddev-router:/mnt/ddev-global-cache/traefik/config/autostart-catchall.yaml 2>/dev/null; then
            log "pushed catch-all config into ddev-router"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Gather running projects
# ---------------------------------------------------------------------------
PROJECTS_JSON=$(ddev list -j 2>/dev/null)
RUNNING=$(echo "$PROJECTS_JSON" | jq -r '.raw[] | select(.status=="running") | .name')

# ---------------------------------------------------------------------------
# Delete projects that have stayed off (stopped/paused) for DELETE_OFF_DAYS.
#
# `ddev delete -Oy` removes containers, volumes, and the registration but
# leaves code and .ddev config untouched — `ddev start` (+ pull-staging-db)
# recreates it. First observation of an off project seeds
# $STATE_DIR/<name>.off_since; seeing it running again clears it. At most ONE
# delete per run: a delete takes tens of seconds (the watchdog allows 120s),
# and the 2026-08-11 bulk delete of 62 projects crashed the OrbStack docker
# daemon — the 5-minute cadence drains any backlog at ~12/hour anyway.
# DELETE_OFF_DAYS=0 disables the sweep.
# ---------------------------------------------------------------------------
if [ "${DELETE_OFF_DAYS:-0}" -gt 0 ]; then
    OFF=$(echo "$PROJECTS_JSON" | jq -r '.raw[] | select(.status=="stopped" or .status=="paused") | .name')
    deleted_this_run=0
    for project in $OFF; do
        is_protected "$project" && continue
        skip_delete=0
        for p in $NEVER_DELETE; do
            [ "$p" = "$project" ] && skip_delete=1
        done
        [ "$skip_delete" = "1" ] && continue
        off_file="$STATE_DIR/$project.off_since"
        if [ ! -f "$off_file" ]; then
            echo "$NOW" > "$off_file"
            continue
        fi
        off_days=$(( (NOW - $(cat "$off_file")) / 86400 ))
        [ "$off_days" -ge "$DELETE_OFF_DAYS" ] || continue
        if [ "$DRY_RUN" = "1" ]; then
            log "DRY_RUN: would delete $project (off ${off_days}d)"
        elif [ "$deleted_this_run" = "0" ]; then
            log "deleting $project (off ${off_days}d)"
            if ddev delete -Oy "$project" >/dev/null 2>>"$LOG_FILE"; then
                rm -f "$off_file" "$STATE_DIR/$project.last_active" \
                      "$ROUTES_DIR/${project}_merged.yaml"
                notify "Deleted $project (off ${off_days}d) — code kept; ddev start recreates it"
                deleted_this_run=1
            else
                log "ERROR: delete of $project failed"
            fi
        fi
    done
    # Clear off_since for projects now running or no longer registered
    for f in "$STATE_DIR"/*.off_since; do
        [ -e "$f" ] || continue
        name=$(basename "$f" .off_since)
        if echo "$RUNNING" | grep -qx "$name"; then
            rm -f "$f"
        elif ! echo "$PROJECTS_JSON" | jq -r '.raw[].name' | grep -qx "$name"; then
            rm -f "$f"
        fi
    done
fi

[ -z "$RUNNING" ] && { log "no running projects"; exit 0; }

# Restore host HTTPS if Docker Desktop has wedged the :443 forward.
# HEAL_ROUTER=0 disables it.
if [ "${HEAL_ROUTER:-1}" = "1" ]; then
    heal_router_forward "$(echo "$RUNNING" | head -1)"
fi

# ---------------------------------------------------------------------------
# Signal 1: docker exec events since last run (ignore healthchecks and our
# own access.log probes).
#
# 2026-08-06 (OrbStack): the daemon's replayable event history is a 256-entry
# ring buffer — roughly 90 seconds with a dozen projects healthchecking — so
# `docker events --since "$LAST_RUN"` silently lost most of its 5-minute window
# and real exec activity stopped registering. Stream events to a file
# continuously instead and read the window from there; the live query is kept
# only as a first-run fallback while the tailer has no history yet.
#
# The tailer must outlive this run, which needs AbandonProcessGroup=true in
# com.ddev.monitor.plist (launchd otherwise reaps a job's leftover children).
# ---------------------------------------------------------------------------
EVENTS_LOG="$STATE_DIR/events.log"
TAILER_PID_FILE="$STATE_DIR/.events_tailer.pid"

ensure_events_tailer() {
    local pid=""
    [ -f "$TAILER_PID_FILE" ] && pid=$(cat "$TAILER_PID_FILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        return 0
    fi
    nohup docker events --filter type=container --filter event=exec_create \
        --format '{{.Time}}|{{index .Actor.Attributes "com.ddev.site-name"}}|{{.Action}}' \
        >> "$EVENTS_LOG" 2>/dev/null &
    pid=$!
    echo "$pid" > "$TAILER_PID_FILE"
    log "started docker events tailer (pid $pid)"
}
ensure_events_tailer

# Trim in place with `cat >` rather than mv — the tailer holds an append fd, and
# replacing the inode would leave it writing to an orphaned file.
if [ "$(stat -f %z "$EVENTS_LOG" 2>/dev/null || echo 0)" -gt 2097152 ]; then
    tail -n 2000 "$EVENTS_LOG" > "$EVENTS_LOG.tmp" \
        && cat "$EVENTS_LOG.tmp" > "$EVENTS_LOG"
    rm -f "$EVENTS_LOG.tmp"
fi

filter_exec_events() {
    grep -v 'healthcheck' | grep -v '/var/log/nginx/access.log' \
        | cut -d'|' -f2 | grep -v '^$'
}

EXEC_ACTIVE=$( { awk -F'|' -v since="$LAST_RUN" '$1+0 >= since' "$EVENTS_LOG" 2>/dev/null
                 docker events --since "$LAST_RUN" --until "$NOW" \
                    --filter type=container --filter event=exec_create \
                    --format '{{.Time}}|{{index .Actor.Attributes "com.ddev.site-name"}}|{{.Action}}' 2>/dev/null
               } | filter_exec_events | sort -u)

# One docker stats snapshot reused for CPU checks and memory math
STATS=$(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}|{{.CPUPerc}}' 2>/dev/null)

web_cpu() {
    echo "$STATS" | awk -F'|' -v c="ddev-$1-web" '$1==c {gsub(/%/,"",$3); print int($3)}'
}

# ---------------------------------------------------------------------------
# Update last-active state per running project
# ---------------------------------------------------------------------------
for project in $RUNNING; do
    state_file="$STATE_DIR/$project.last_active"
    if [ -f "$state_file" ]; then
        last_active=$(cat "$state_file")
    else
        last_active=$NOW   # first observation: grace period starts now
    fi

    # Signal 1: exec activity in this window
    if echo "$EXEC_ACTIVE" | grep -qx "$project"; then
        last_active=$NOW
    fi

    # Signal 2: nginx access.log mtime (browser/HTTP traffic; healthchecks
    # don't write to it). This probe itself creates an exec event, which is
    # filtered above by the access.log pattern.
    nginx_mtime=$(docker exec "ddev-$project-web" stat -c %Y /var/log/nginx/access.log 2>/dev/null)
    if [ -n "$nginx_mtime" ] && [ "$nginx_mtime" -gt "$last_active" ]; then
        last_active=$nginx_mtime
    fi

    # Signal 3: file edits in the approot since last_active (prunes heavy
    # and machine-written dirs; .claude holds nested worktrees of *other*
    # projects, so it must not count for the parent)
    approot=$(echo "$PROJECTS_JSON" | jq -r --arg n "$project" '.raw[] | select(.name==$n) | .approot')
    ref="$STATE_DIR/.findref"
    if [ -d "$approot" ]; then
        touch -t "$(date -r "$last_active" +%Y%m%d%H%M.%S)" "$ref"
        edited=$(find "$approot" \
            \( -name node_modules -o -name vendor -o -name .git -o -name .claude \
               -o -name .ddev -o -name storage -o -path '*/public/build' \
               -o -path '*/public/hot' \) -prune \
            -o -type f -newer "$ref" -print -quit 2>/dev/null)
        [ -n "$edited" ] && last_active=$NOW
    fi

    # Signal 5: a live Claude Code session working in this approot. Transcripts
    # live in ~/.claude/projects/<approot with / and . replaced by ->. An agent
    # can go well over an hour between docker execs while reading, thinking, or
    # waiting on the user, and touch no project file — signals 1-4 all read that
    # as idle and pause the project out from under the session, so its next
    # `ddev exec` fails. Transcript writes are the reliable liveness signal.
    if [ -n "$approot" ] && [ "$approot" != "null" ]; then
        sess_dir="$HOME/.claude/projects/$(echo "$approot" | sed 's|[/.]|-|g')"
        if [ -d "$sess_dir" ]; then
            touch -t "$(date -r "$last_active" +%Y%m%d%H%M.%S)" "$ref"
            [ -n "$(find "$sess_dir" -type f -newer "$ref" -print -quit 2>/dev/null)" ] \
                && last_active=$NOW
        fi
    fi

    # Signal 4: busy web container counts as active (long silent test runs)
    cpu=$(web_cpu "$project")
    if [ -n "$cpu" ] && [ "$cpu" -ge "$CPU_ACTIVE_PCT" ]; then
        last_active=$NOW
    fi

    echo "$last_active" > "$state_file"
done

# ---------------------------------------------------------------------------
# Stop idle projects
# ---------------------------------------------------------------------------
IDLE_SECS=$((IDLE_MINUTES * 60))
for project in $RUNNING; do
    is_protected "$project" && continue
    last_active=$(cat "$STATE_DIR/$project.last_active")
    idle_for=$((NOW - last_active))
    if [ "$idle_for" -gt "$IDLE_SECS" ]; then
        if [ "$STOP_IDLE" = "1" ]; then
            stop_project "$project" "idle $((idle_for / 60))m"
        else
            log "idle: $project ($((idle_for / 60))m) — STOP_IDLE=0, not stopping"
        fi
    fi
done

# ---------------------------------------------------------------------------
# Memory pressure: stop LRU projects until under threshold
# ---------------------------------------------------------------------------
mem_pct() {
    local total used
    total=$(docker info --format '{{.MemTotal}}' 2>/dev/null)
    [ -z "$total" ] || [ "$total" = "0" ] && { echo 0; return; }
    used=$(docker stats --no-stream --format '{{.MemUsage}}' 2>/dev/null | awk '
        { u=$1
          if (u ~ /GiB/) { gsub(/GiB/,"",u); b+=u*1073741824 }
          else if (u ~ /MiB/) { gsub(/MiB/,"",u); b+=u*1048576 }
          else if (u ~ /KiB/) { gsub(/KiB/,"",u); b+=u*1024 }
          else { gsub(/B/,"",u); b+=u } }
        END { printf "%.0f", b }')
    echo $((used * 100 / total))
}

pct=$(mem_pct)
log "run complete: running=[$(echo $RUNNING | tr '\n' ' ')] mem=${pct}%"

attempts=0
while [ "$pct" -ge "$MEM_THRESHOLD_PCT" ] && [ "$attempts" -lt 5 ]; do
    still_running=$(ddev list -j 2>/dev/null | jq -r '.raw[] | select(.status=="running") | .name')
    lru="" lru_ts=""
    for project in $still_running; do
        is_protected "$project" && continue
        cpu=$(web_cpu "$project")
        [ -n "$cpu" ] && [ "$cpu" -ge "$CPU_ACTIVE_PCT" ] && continue
        ts=$(cat "$STATE_DIR/$project.last_active" 2>/dev/null || echo "$NOW")
        if [ -z "$lru_ts" ] || [ "$ts" -lt "$lru_ts" ]; then
            lru="$project"; lru_ts="$ts"
        fi
    done
    [ -z "$lru" ] && { log "memory at ${pct}% but no stoppable project"; break; }
    stop_project "$lru" "memory pressure ${pct}%"
    [ "$DRY_RUN" = "1" ] && break
    sleep 5
    pct=$(mem_pct)
    attempts=$((attempts + 1))
done

# Clean up state files for projects that no longer exist
ALL_NAMES=$(echo "$PROJECTS_JSON" | jq -r '.raw[].name')
for f in "$STATE_DIR"/*.last_active; do
    [ -e "$f" ] || continue
    name=$(basename "$f" .last_active)
    echo "$ALL_NAMES" | grep -qx "$name" || rm -f "$f"
done

exit 0
