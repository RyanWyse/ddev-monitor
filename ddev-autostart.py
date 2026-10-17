#!/usr/bin/env python3
"""ddev-autostart: catch-all backend for the ddev Traefik router.

When a *.ddev.site domain is hit whose project is stopped, the router's
lowest-priority catch-all route lands here. This server maps the hostname
to a ddev project, kicks off `ddev start` in the background (streaming its
output into a per-project buffer), and serves a "starting..." page that
shows the live ddev output and reloads once the real project's router
takes over.

Up-detection: the page polls /__ddev-autostart/status with redirect:"manual".
While this daemon answers, the response carries X-Ddev-Autostart and JSON.
Once the real project's router wins the route, the app answers instead —
typically a 302 (opaqueredirect) or a page without the header — and the
page reloads to the originally requested URL.
"""

import json
import re
import shutil
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

DDEV = shutil.which("ddev") or "/opt/homebrew/bin/ddev"
DOCKER = shutil.which("docker") or "/usr/local/bin/docker"
PORT = 31999
MON_DIR = Path.home() / ".ddev" / "monitor"
LOG_FILE = MON_DIR / "logs" / "autostart.log"
STATE_DIR = MON_DIR / "state"
ROUTES_DIR = STATE_DIR / "routes"
ROUTER = "ddev-router"
ROUTER_CONF_DIR = "/mnt/ddev-global-cache/traefik/config"
STATUS_PATH = "/__ddev-autostart/status"
MAX_LOG_LINES = 400
SUBPROC_ENV = {"PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
               "HOME": str(Path.home()), "TERM": "dumb"}

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]|\x1b\][^\x07]*\x07")

_lock = threading.Lock()
_projects_cache = {"ts": 0.0, "data": []}
_starting = {}  # project -> {"started_at": ts, "error": str|None, "log": [...], "done": bool}


def log(msg: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with LOG_FILE.open("a") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}\n")


def list_projects() -> list:
    with _lock:
        if time.time() - _projects_cache["ts"] < 20:
            return _projects_cache["data"]
    data = None
    try:
        out = subprocess.run(
            [DDEV, "list", "-j"], capture_output=True, text=True, timeout=30
        ).stdout
        parsed = json.loads(out).get("raw", [])
        if parsed:
            data = parsed
    except Exception as e:  # noqa: BLE001
        log(f"ddev list failed: {e}")
    with _lock:
        if data is not None:
            _projects_cache.update(ts=time.time(), data=data)
            return data
        # Transient `ddev list` timeout/empty (common right after a Docker
        # restart): keep serving the last known-good list instead of caching an
        # empty one, which would make resolve_project() 404 a real project.
        return _projects_cache["data"]


def resolve_project(host: str):
    host = host.split(":")[0].lower()
    for p in list_projects():
        name = p.get("name", "").lower()
        if not name:
            continue
        if host == f"{name}.ddev.site" or host.endswith(f".{name}.ddev.site"):
            return p
    return None


def append_log(entry: dict, raw: str) -> None:
    # ddev redraws spinner lines with \r; keep only the final rendering
    for part in raw.split("\r"):
        clean = ANSI_RE.sub("", part).rstrip()
        if not clean:
            continue
        with _lock:
            if entry["log"] and entry["log"][-1] == clean:
                continue
            entry["log"].append(clean)
            del entry["log"][:-MAX_LOG_LINES]


def _project_container_ids(project: str) -> list:
    r = subprocess.run(
        [DOCKER, "ps", "-aq", "--filter", f"label=com.ddev.site-name={project}"],
        capture_output=True, text=True, timeout=30,
    )
    return [c for c in r.stdout.split() if c]


def _web_health(project: str) -> str:
    r = subprocess.run(
        [DOCKER, "inspect", f"ddev-{project}-web", "--format",
         "{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}"],
        capture_output=True, text=True, timeout=30,
    )
    return r.stdout.strip() or "unknown"


# Vite prints "VITE v7.3.1  ready in 41422 ms" when its dev server is actually
# serving assets; the version and ms vary, so match only the stable tail.
VITE_READY_RE = re.compile(r"ready in \d+\s*ms")
VITE_LOG = "/var/log/vite-dev.log"
HOT_FILE = "/var/www/html/public/hot"


def _vite_state(project: str) -> str:
    """'ready' | 'absent' (no Vite / deps missing) | 'nofile' (no signal yet) |
    'booting'. Ready is signalled by EITHER public/hot existing (the canonical
    "dev server is serving" marker) OR the "ready in Nms" log line. Both are
    cleared right after docker start, so a hit reflects the current boot."""
    r = subprocess.run(
        [DOCKER, "exec", f"ddev-{project}-web", "sh", "-c",
         f"test -f {HOT_FILE} && echo __HOT__; "
         f"test -f {VITE_LOG} && cat {VITE_LOG} || echo __NOFILE__"],
        capture_output=True, text=True, timeout=15,
    )
    if r.returncode != 0:
        return "booting"  # transient exec failure; keep waiting
    out = r.stdout
    clean = ANSI_RE.sub("", out)
    if "__HOT__" in out or VITE_READY_RE.search(clean):
        return "ready"
    if "Vite not found" in clean:
        return "absent"
    if "__NOFILE__" in out:  # no hot file, no log yet
        return "nofile"
    return "booting"


def wait_for_vite(project: str, entry: dict, deadline: float) -> None:
    """Block until the Vite dev server reports ready, so the route is restored
    (and the page redirects) only once assets are actually served — not while
    Vite is still compiling, which lands the user on an error page. Proceeds
    without blocking if the project has no Vite daemon."""
    append_log(entry, "[autostart] waiting for Vite dev server to finish booting")
    nofile_since = None
    while time.time() < deadline:
        state = _vite_state(project)
        if state == "ready":
            append_log(entry, "[autostart] Vite ready — assets are being served")
            return
        if state == "absent":
            append_log(entry, "[autostart] no Vite dev server for this project; proceeding")
            return
        if state == "nofile":
            nofile_since = nofile_since or time.time()
            if time.time() - nofile_since > 45:
                append_log(entry, "[autostart] no Vite log after 45s; assuming no Vite, proceeding")
                return
        else:
            nofile_since = None
        time.sleep(2)
    append_log(entry, "[autostart] Vite not ready before deadline; proceeding anyway")


def resume_fast(project: str, entry: dict) -> bool:
    """Resume a paused project by starting its kept containers and restoring the
    saved Traefik route — WITHOUT `ddev start`, so the shared router is never
    restarted and Docker Desktop never re-publishes (and wedges) :80/:443.
    Returns False (caller falls back to `ddev start`) when the containers were
    fully removed or no route backup exists."""
    ids = _project_container_ids(project)
    route = ROUTES_DIR / f"{project}_merged.yaml"
    if not ids or not route.exists() or route.stat().st_size == 0:
        append_log(entry, "[autostart] no paused containers or usable saved route — full start needed")
        return False

    # A duplicate trigger can arrive in the brief window after a prior resume
    # restored the route but before Traefik propagated it. If the web container
    # is already running, DON'T docker-start or clear Vite's signals (clearing
    # public/hot on a serving project would break it, since Vite only writes it
    # on startup) — just re-assert the route and return.
    web_running = subprocess.run(
        [DOCKER, "inspect", f"ddev-{project}-web", "--format", "{{.State.Running}}"],
        capture_output=True, text=True, timeout=15,
    ).stdout.strip()
    if web_running == "true":
        append_log(entry, "[autostart] containers already running — re-asserting route only")
        subprocess.run(
            [DOCKER, "cp", str(route), f"{ROUTER}:{ROUTER_CONF_DIR}/{project}_merged.yaml"],
            capture_output=True, text=True, timeout=30,
        )
        return True

    append_log(entry, f"[autostart] resuming {project} without restarting the router")
    started = subprocess.run([DOCKER, "start", *ids],
                             capture_output=True, text=True, timeout=120)
    if started.returncode != 0:
        append_log(entry, f"[autostart] docker start failed: {started.stderr.strip()[:200]}")
        return False
    append_log(entry, f"[autostart] started {len(ids)} containers; waiting for web health")

    # Clear stale Vite readiness signals from the pre-pause session so
    # wait_for_vite only ever sees THIS boot's: (1) the "ready in Nms" log line,
    # and (2) public/hot, which laravel-vite-plugin (re)creates when the dev
    # server is actually serving. Both otherwise linger from before the pause
    # (vite-daemon.sh only clears them tens of seconds in, when it relaunches),
    # which would open the gate before assets are really being served.
    subprocess.run(
        [DOCKER, "exec", f"ddev-{project}-web", "sh", "-c",
         f": > {VITE_LOG} 2>/dev/null; rm -f {HOT_FILE} 2>/dev/null || true"],
        capture_output=True, text=True, timeout=15,
    )

    while time.time() - entry["started_at"] < 300:
        h = _web_health(project)
        if h == "healthy":
            break
        append_log(entry, f"[autostart] web: {h}")
        time.sleep(2)
    else:
        append_log(entry, "[autostart] web never became healthy — falling back to ddev start")
        return False

    # Hold the route until Vite is serving assets, so the page redirects to a
    # working app rather than a mid-compile error page.
    wait_for_vite(project, entry, entry["started_at"] + 600)

    # Restore the route (Traefik file-provider hot-reload; no router restart)
    cp = subprocess.run(
        [DOCKER, "cp", str(route), f"{ROUTER}:{ROUTER_CONF_DIR}/{project}_merged.yaml"],
        capture_output=True, text=True, timeout=30,
    )
    if cp.returncode != 0:
        append_log(entry, f"[autostart] route restore failed: {cp.stderr.strip()[:200]}")
        return False
    append_log(entry, "[autostart] route restored; router will pick it up momentarily")
    return True


def ddev_start(project: str, entry: dict) -> None:
    """Full `ddev start` fallback — restarts the router (accepts the port-forward
    churn). Streams ddev's output into the page. Used only when the fast path
    can't apply (containers removed, or no saved route)."""
    append_log(entry, f"[autostart] running full `ddev start {project}`")
    proc = subprocess.Popen(
        [DDEV, "start", project],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=SUBPROC_ENV,
    )
    for line in proc.stdout:
        append_log(entry, line)
        if time.time() - entry["started_at"] > 600:
            proc.kill()
            raise TimeoutError("ddev start exceeded 600s")
    rc = proc.wait(timeout=30)
    if rc != 0:
        raise RuntimeError(f"ddev start exited {rc}")


def run_start(project: str, entry: dict) -> None:
    log(f"resuming {project}")
    try:
        if not resume_fast(project, entry):
            ddev_start(project, entry)
        log(f"resumed {project}")
        append_log(entry, f"[autostart] {project} is up — waiting for router")
        with _lock:
            entry["done"] = True
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        (STATE_DIR / f"{project}.last_active").write_text(str(int(time.time())))
    except Exception as e:  # noqa: BLE001
        log(f"resume FAILED for {project}: {e}")
        with _lock:
            entry["error"] = str(e)


def trigger_start(project: str) -> dict:
    with _lock:
        entry = _starting.get(project)
        if entry:
            if entry.get("done"):
                # A previous resume finished. If we're being asked again, the
                # project was paused/killed since (the real app would answer
                # directly, bypassing this daemon), so start a fresh resume
                # instead of returning the stale "done" entry.
                entry = None
            elif entry.get("error") and time.time() - entry["started_at"] > 300:
                # Retry after 5 minutes if the last attempt failed
                entry = None
            else:
                return entry  # resume in progress — dedupe concurrent hits
        entry = {"started_at": time.time(), "error": None, "log": [], "done": False}
        _starting[project] = entry
    threading.Thread(target=run_start, args=(project, entry), daemon=True).start()
    return entry


PAGE = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>Starting {project}&hellip;</title>
<style>
  body {{ font-family: -apple-system, sans-serif; background: #1a1d23; color: #e6e9ef;
         display: flex; align-items: center; justify-content: center; min-height: 100vh; margin: 0; }}
  .card {{ text-align: center; max-width: 46rem; width: 100%; padding: 2rem 1rem; }}
  .spinner {{ width: 44px; height: 44px; border: 4px solid #333a45; border-top-color: #4c9aff;
              border-radius: 50%; animation: spin 0.9s linear infinite; margin: 0 auto 1.2rem; }}
  @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
  h1 {{ font-size: 1.3rem; font-weight: 600; }}
  code {{ color: #4c9aff; }}
  .sub {{ color: #8a93a3; font-size: 0.9rem; }}
  .err {{ color: #ff6b6b; white-space: pre-wrap; text-align: left; font-size: 0.8rem; }}
  #term {{ background: #0d0f13; border: 1px solid #333a45; border-radius: 8px;
           text-align: left; font: 0.72rem/1.45 ui-monospace, Menlo, monospace;
           color: #9aa7b8; padding: 0.8rem 1rem; margin-top: 1.2rem;
           height: 16rem; overflow-y: auto; white-space: pre-wrap; }}
  #term .new {{ color: #d7dee9; }}
</style>
</head>
<body>
<div class="card">
  <div class="spinner"></div>
  <h1 id="headline">Starting <code>{project}</code>&hellip;</h1>
  <p class="sub">This project was stopped; ddev is bringing it back up.
     The page reloads automatically when it&rsquo;s ready.</p>
  <p class="sub" id="elapsed"></p>
  {error_block}
  <div id="term">waiting for ddev output&hellip;</div>
</div>
<script>
console.log("[ddev-autostart] project '{project}' is stopped — `ddev start {project}` has been triggered");
const t0 = Date.now();
setInterval(() => {{
  document.getElementById("elapsed").textContent =
    "Elapsed: " + Math.round((Date.now() - t0) / 1000) + "s";
}}, 1000);

const term = document.getElementById("term");
let shown = 0;

function goLive() {{
  console.log("[ddev-autostart] project is up — reloading");
  document.getElementById("headline").innerHTML = "<code>{project}</code> is up — loading&hellip;";
  window.location.reload();
}}

async function poll() {{
  try {{
    // redirect:"manual": the real app often answers with a 302 (login/tenant
    // redirect). An opaqueredirect therefore means the site is up; only this
    // daemon's responses carry X-Ddev-Autostart.
    const r = await fetch("{status_path}", {{ cache: "no-store", redirect: "manual" }});
    if (r.type === "opaqueredirect" || !r.headers.get("X-Ddev-Autostart")) {{
      goLive();
      return;
    }}
    const s = await r.json();
    if (s.log.length > shown) {{
      term.querySelectorAll(".new").forEach(el => el.classList.remove("new"));
      if (shown === 0) term.textContent = "";
      for (const line of s.log.slice(shown)) {{
        console.log("[ddev start] " + line);
        const div = document.createElement("div");
        div.className = "new";
        div.textContent = line;
        term.appendChild(div);
      }}
      shown = s.log.length;
      term.scrollTop = term.scrollHeight;
    }}
    if (s.error) {{
      console.error("[ddev-autostart] start failed: " + s.error);
    }}
  }} catch (e) {{
    console.log("[ddev-autostart] poll error (router may be reloading): " + e);
  }}
  setTimeout(poll, 1200);
}}
setTimeout(poll, 1200);
</script>
</body>
</html>"""

NOT_FOUND = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Unknown ddev project</title></head>
<body style="font-family:-apple-system,sans-serif;padding:3rem;background:#1a1d23;color:#e6e9ef">
<h1>No ddev project matches <code style="color:#4c9aff">{host}</code></h1>
<p>Known projects: {projects}</p>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # silence default stderr logging
        pass

    def _send(self, status: int, body: str, ctype: str = "text/html; charset=utf-8") -> None:
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Ddev-Autostart", "1")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def _page(self, name: str, entry: dict) -> None:
        error_block = ""
        if entry.get("error"):
            error_block = (
                f'<p class="err">Last start attempt failed: {entry["error"]}\n'
                f"Will retry in a few minutes, or run `ddev start {name}` manually.</p>"
            )
        self._send(503, PAGE.format(project=name, error_block=error_block,
                                    status_path=STATUS_PATH))

    def do_GET(self):  # noqa: N802
        host = self.headers.get("Host", "")
        project = resolve_project(host)
        if project is None:
            projects = list_projects()
            if not projects:
                # No project data at all (ddev list unavailable/timing out) — do
                # NOT dead-end on a 404; the project probably exists. Serve a
                # generic waiting page that keeps polling until the list returns.
                self._send(503, PAGE.format(
                    project=host.split(":")[0], error_block="", status_path=STATUS_PATH))
                return
            names = ", ".join(sorted(p["name"] for p in projects))
            self._send(404, NOT_FOUND.format(host=host, projects=names))
            return

        name = project["name"]

        if self.path.split("?")[0] == STATUS_PATH:
            with _lock:
                entry = _starting.get(name) or {}
                body = json.dumps({
                    "project": name,
                    "phase": "error" if entry.get("error")
                             else "ready" if entry.get("done") else "starting",
                    "error": entry.get("error"),
                    "log": list(entry.get("log", [])),
                })
            self._send(200, body, ctype="application/json")
            return

        if project.get("status") == "running":
            # Router config may still be propagating; tell the page to keep polling
            with _lock:
                entry = _starting.get(name) or {"error": None}
            self._page(name, entry)
            return

        self._page(name, trigger_start(name))

    do_HEAD = do_GET
    do_POST = do_GET


if __name__ == "__main__":
    log(f"ddev-autostart listening on 127.0.0.1:{PORT}")
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
