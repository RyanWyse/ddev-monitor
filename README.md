# ddev-monitor

Keeps a Mac with lots of DDEV projects responsive: idle projects get paused automatically, and a paused project starts itself again the moment you open its URL.

Two launchd agents:

| Agent | What it does |
|---|---|
| `com.ddev.monitor` → `ddev-monitor.sh` (every 5 min) | Pauses (`docker stop`, containers kept) projects idle longer than `IDLE_MINUTES`; pauses the least-recently-used project when Docker VM memory passes `MEM_THRESHOLD_PCT`; optionally `ddev delete -Oy`s projects that have been off for `DELETE_OFF_DAYS` (code and `.ddev/` untouched, one per run); restarts `ddev-router` if host `:443` wedges while `:80` still works. |
| `com.ddev.autostart` → `ddev-autostart.py` (port 31999) | Backend for a lowest-priority Traefik catch-all route. Hitting `https://<paused-project>.ddev.site` serves a "starting…" page with live `ddev start` output and reloads into the app when it's up (~1–2 min). |

### What counts as "active"

A project is active if any of these happened since its last check:

1. a `docker exec` into it (`ddev exec`, `artisan`, `composer`, tests…)
2. a write to the web container's nginx `access.log` (browser traffic)
3. a file edit in the project root (ignores `vendor`, `node_modules`, `.git`, `storage`, build output)
4. its web container is above `CPU_ACTIVE_PCT` CPU (long, quiet test runs)
5. a Claude Code session transcript for that folder is being written (`~/.claude/projects/…`)

## Requirements

macOS, DDEV (Docker Desktop or OrbStack), `jq`, `python3`, `curl`. Your projects must use the default `*.ddev.site` domain for autostart.

## Install

```bash
git clone https://github.com/RyanWyse/ddev-monitor.git
cd ddev-monitor
./install.sh
```

The installer copies the scripts to `~/.ddev/monitor/`, writes `monitor.conf` once (never overwrites yours), renders the plists into `~/Library/LaunchAgents/` and loads them, and drops the catch-all route into `~/.ddev/traefik/custom-global-config/`. Re-run it after a `git pull` to update.

Try it out safely first: set `DRY_RUN=1` in `~/.ddev/monitor/monitor.conf`, then watch `~/.ddev/monitor/logs/monitor.log` for a day.

## Configure

`~/.ddev/monitor/monitor.conf` is read on every run, so no reload is needed:

| Setting | Default | |
|---|---|---|
| `IDLE_MINUTES` | 60 | idle time before a project is paused |
| `STOP_IDLE` | 1 | 0 = only log idle projects |
| `MEM_THRESHOLD_PCT` | 80 | shed LRU projects above this Docker memory % |
| `CPU_ACTIVE_PCT` | 15 | web CPU at or above this counts as active |
| `DELETE_OFF_DAYS` | 7 | delete projects off this long; **0 disables** |
| `PROTECTED_PROJECTS` | "" | never paused, shed or deleted |
| `NEVER_DELETE` | "" | can be paused, never deleted (e.g. your main checkout) |
| `HEAL_ROUTER` | 1 | auto-restart a wedged `ddev-router` :443 |
| `NOTIFY` | 1 | macOS notification on pause/delete |
| `DRY_RUN` | 0 | log only |

> **Heads-up on `DELETE_OFF_DAYS`:** a deleted project loses its database volume. If you keep local data you care about, add the project to `NEVER_DELETE` or set this to `0`.

## Day to day

- A pause doesn't lose anything: `ddev start <project>`, any `ddev` command, or opening its URL brings it back.
- Logs: `~/.ddev/monitor/logs/monitor.log` and `autostart.log`.
- Run a pass by hand: `bash ~/.ddev/monitor/ddev-monitor.sh`.
- Avoid `ddev poweroff`; stop or restart just the one project you need to.

## Uninstall

```bash
./uninstall.sh            # keeps ~/.ddev/monitor (config/logs)
./uninstall.sh --purge    # removes it too
```

## How the pause/resume routing works

DDEV only removes a project's Traefik route on a full `ddev stop`, so a paused project would 502. On pause, the monitor backs up `<project>_merged.yaml` from the router to `~/.ddev/monitor/state/routes/` and removes it, so the domain falls through to the catch-all. On resume, the autostart daemon restores that same file: Traefik hot-reloads it without a router restart.
