"""Spin's search and SoundCloud helper, beside yubal on the home server.

GET  /search?q=...&source=youtube|soundcloud  ytmusicapi / SoundCloud search, results carry a link to add
POST /soundcloud {"url": ...}                 queue a SoundCloud track or playlist for scdl
GET  /soundcloud                              the queue, in yubal's job shape so the app shows both alike

Files land in the Jellyfin Music folder as <Artist>/<Album>/; a single track becomes its own album.
No login: bound to 127.0.0.1 and reached over the tailnet only, like yubal.
"""
import itertools, json, os, queue, re, shutil, subprocess, sys, tempfile, threading, time, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

MUSIC = os.environ.get("SPIN_MUSIC", "/mnt/secondary/anime-server/data/media/music")
SCDL = os.path.join(os.path.dirname(sys.executable), "scdl")
PORT = int(os.environ.get("SPIN_SOURCES_PORT", "8011"))

def safe(name):
    """A folder name from a tag: no slashes, no leading dots, not empty."""
    name = re.sub(r'[/\\\x00-\x1f]', "-", (name or "").strip()).lstrip(".").strip()
    return name[:120] or "Unknown"

def is_soundcloud(url):
    try:
        u = urlparse(url.strip())
    except ValueError:
        return False
    host = (u.hostname or "").lower()
    return u.scheme == "https" and (host == "soundcloud.com" or host.endswith(".soundcloud.com"))

# --- search -----------------------------------------------------------------

_yt = None
def youtube(q):
    global _yt
    from ytmusicapi import YTMusic
    _yt = _yt or YTMusic()
    out = []
    for r in _yt.search(q, filter="songs", limit=12)[:12]:
        if not r.get("videoId"):
            continue
        out.append({"kind": "song", "title": r["title"], "artist": ", ".join(a["name"] for a in r.get("artists") or []),
                    "detail": (r.get("album") or {}).get("name") or "", "duration": r.get("duration") or "",
                    "thumbnail": (r.get("thumbnails") or [{}])[-1].get("url"), "url": f"https://music.youtube.com/watch?v={r['videoId']}"})
    for r in _yt.search(q, filter="albums", limit=6)[:6]:
        if not r.get("playlistId"):
            continue
        out.append({"kind": "album", "title": r["title"], "artist": ", ".join(a["name"] for a in r.get("artists") or []),
                    "detail": " · ".join(x for x in (r.get("type"), r.get("year")) if x), "duration": "",
                    "thumbnail": (r.get("thumbnails") or [{}])[-1].get("url"), "url": f"https://music.youtube.com/playlist?list={r['playlistId']}"})
    return out

_sc = None
def soundcloud(q):
    global _sc
    from soundcloud import SoundCloud
    _sc = _sc or SoundCloud()
    out = []
    for t in itertools.islice(_sc.search_tracks(q), 12):
        secs = round((t.full_duration or 0) / 1000)
        out.append({"kind": "track", "title": t.title, "artist": t.user.username, "detail": t.genre or "",
                    "duration": f"{secs // 60}:{secs % 60:02d}", "thumbnail": t.artwork_url or t.user.avatar_url, "url": t.permalink_url})
    for p in itertools.islice(_sc.search_playlists(q), 5):
        out.append({"kind": "playlist", "title": p.title, "artist": p.user.username, "detail": f"{p.track_count} tracks",
                    "duration": "", "thumbnail": p.artwork_url or p.user.avatar_url, "url": p.permalink_url})
    return out

# --- SoundCloud downloads ----------------------------------------------------

jobs = {}           # id -> job dict (yubal's shape)
work = queue.Queue()
lock = threading.Lock()

def tag_and_file(folder, album_hint=None):
    """Give every m4a/mp3/opus in folder an album (playlist name, else its own title) and move it to <Artist>/<Album>/."""
    import mutagen
    placed = []
    for root, _, files in os.walk(folder):
        for f in sorted(files):
            path = os.path.join(root, f)
            audio = mutagen.File(path, easy=True)
            if audio is None:
                continue
            title = (audio.get("title") or [os.path.splitext(f)[0]])[0]
            artist = (audio.get("artist") or ["Unknown"])[0]
            album = album_hint or (audio.get("album") or [title])[0]
            album_artist = artist if not album_hint else (audio.get("albumartist") or [artist])[0]
            audio["album"] = album
            audio["albumartist"] = album_artist
            audio.save()
            dest_dir = os.path.join(MUSIC, safe(album_artist), safe(album))
            os.makedirs(dest_dir, exist_ok=True)
            dest = os.path.join(dest_dir, safe(re.sub(r"^\[\d+\]\s*", "", f)))
            shutil.move(path, dest)
            placed.append(dest)
    return placed

def worker():
    while True:
        job = work.get()
        job.update(status="downloading", progress=10.0, started_at=time.time())
        tmp = tempfile.mkdtemp(prefix="spin-scdl-")
        try:
            # A list, never a shell: the URL was checked to be https://*soundcloud.com.
            run = subprocess.run([SCDL, "-l", job["url"], "--path", tmp, "--no-original", "--hide-progress", "-c",
                                  "--playlist-name-format", "{playlist[tracknumber]:02d} - {title}"],
                                 capture_output=True, text=True, timeout=1800)
            subdirs = [d for d in os.listdir(tmp) if os.path.isdir(os.path.join(tmp, d))]
            job.update(status="importing", progress=90.0)
            # scdl makes one subfolder for a playlist, named after it; that name becomes the album.
            placed = tag_and_file(tmp, album_hint=subdirs[0] if len(subdirs) == 1 else None)
            if not placed:
                raise RuntimeError((run.stderr or run.stdout or "scdl saved nothing").strip().splitlines()[-1][:200])
            first = placed[0]
            job["content_info"] = job.get("content_info") or {}
            job["content_info"].update(track_count=len(placed))
            job.update(status="completed", progress=100.0, completed_at=time.time())
            print(f"[spin-sources] {job['url']} -> {len(placed)} file(s), first {first}", flush=True)
        except Exception as e:
            job.update(status="failed", error=str(e)[:300], completed_at=time.time())
            print(f"[spin-sources] {job['url']} failed: {e}", flush=True)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

def queue_soundcloud(url):
    job = {"id": uuid.uuid4().hex[:12], "url": url.strip(), "status": "pending", "progress": 0.0,
           "content_info": None, "created_at": time.time()}
    try:  # title and art up front, so the queue reads well while scdl runs
        from soundcloud import SoundCloud
        global _sc
        _sc = _sc or SoundCloud()
        item = _sc.resolve(job["url"])
        job["content_info"] = {"title": item.title, "artist": item.user.username,
                               "thumbnail_url": getattr(item, "artwork_url", None) or item.user.avatar_url}
    except Exception:
        pass
    with lock:
        jobs[job["id"]] = job
        for old in sorted(jobs.values(), key=lambda j: j["created_at"])[:-30]:  # keep the last 30
            if old["status"] in ("completed", "failed"):
                jobs.pop(old["id"], None)
    work.put(job)
    return job

# --- HTTP --------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _path(self):
        u = urlparse(self.path)
        p = u.path[len("/sources"):] if u.path.startswith("/sources") else u.path  # mounted under /sources or at /
        return p.rstrip("/") or "/", parse_qs(u.query)

    def do_GET(self):
        path, qs = self._path()
        if path == "/search":
            q = (qs.get("q") or [""])[0].strip()
            source = (qs.get("source") or ["youtube"])[0]
            if not q:
                return self._send(400, {"detail": "Type something to search for."})
            try:
                return self._send(200, {"results": soundcloud(q) if source == "soundcloud" else youtube(q)})
            except Exception as e:
                return self._send(502, {"detail": f"Search failed: {e}"[:300]})
        if path == "/soundcloud":
            with lock:
                return self._send(200, {"jobs": sorted(jobs.values(), key=lambda j: j["created_at"])})
        if path == "/health":
            return self._send(200, {"ok": True})
        self._send(404, {"detail": "Not found"})

    def do_POST(self):
        path, _ = self._path()
        if path != "/soundcloud":
            return self._send(404, {"detail": "Not found"})
        try:
            length = min(int(self.headers.get("Content-Length") or 0), 10_000)
            url = json.loads(self.rfile.read(length) or b"{}").get("url", "")
        except (ValueError, AttributeError):
            return self._send(400, {"detail": "Send JSON like {\"url\": \"https://soundcloud.com/...\"}."})
        if not isinstance(url, str) or not is_soundcloud(url):
            return self._send(422, {"detail": "That is not a SoundCloud link."})
        self._send(201, {"id": queue_soundcloud(url)["id"]})

    def log_message(self, *args):
        pass

def selftest():
    assert safe("AC/DC") == "AC-DC" and safe("..hidden") == "hidden" and safe("") == "Unknown"
    assert is_soundcloud("https://soundcloud.com/a/b") and is_soundcloud("https://on.soundcloud.com/x")
    assert not is_soundcloud("http://soundcloud.com/a") and not is_soundcloud("https://evilsoundcloud.com/a")
    assert not is_soundcloud("--exec=rm") and not is_soundcloud("https://soundcloud.com.evil.net/a")
    print("selftest ok")

if __name__ == "__main__":
    if sys.argv[1:] == ["selftest"]:
        selftest()
        sys.exit()
    threading.Thread(target=worker, daemon=True).start()
    print(f"[spin-sources] on 127.0.0.1:{PORT}, music in {MUSIC}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
