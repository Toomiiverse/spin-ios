"""Spin's search and SoundCloud helper, beside yubal on the home server.

GET  /search?q=...&source=youtube|soundcloud  ytmusicapi / SoundCloud search, results carry a link to add
POST /soundcloud {"url": ...}                 queue a SoundCloud track or playlist for scdl
GET  /soundcloud                              the queue, in yubal's job shape so the app shows both alike
DELETE /soundcloud                            clear finished downloads from the queue

Library changes, for a signed-in Jellyfin admin (the app's own Jellyfin token in the Authorization header):
POST   /library/refresh                        rescan the Music library now (new downloads show in seconds)
PATCH  /library/items/<id>  {"title","artist","album"}  rewrite the file's tags
PUT    /library/items/<id>/art  <jpeg or png bytes>       embed cover art (and cover.jpg when the song is alone)
DELETE /library/items/<id>                     delete the file, and its folder once no songs are left

Files land in the Jellyfin Music folder as <Artist>/<Album>/; a single track becomes its own album.
No login: bound to 127.0.0.1 and reached over the tailnet only, like yubal.
"""
import itertools, json, os, queue, re, shutil, subprocess, sys, tempfile, threading, time, uuid
import urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

MUSIC = os.environ.get("SPIN_MUSIC", "/mnt/secondary/anime-server/data/media/music")
SCDL = os.path.join(os.path.dirname(sys.executable), "scdl")
PORT = int(os.environ.get("SPIN_SOURCES_PORT", "8011"))
JELLYFIN = os.environ.get("SPIN_JELLYFIN", "http://127.0.0.1:8096")
JELLYFIN_MUSIC = "/data/media/music"  # the same folder as Jellyfin's container sees it
AUDIO = (".m4a", ".mp3", ".flac", ".opus", ".ogg", ".aac", ".wav", ".mp4")

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

class Duplicate(Exception):
    pass

def queue_soundcloud(url, force=False):
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
    info = job["content_info"]
    if not force and info and not urlparse(job["url"]).path.count("/sets/"):
        # A single lands in <Artist>/<Title>/ (tag_and_file); anything already there is this song.
        folder = os.path.join(MUSIC, safe(info["artist"]), safe(info["title"]))
        if os.path.isdir(folder) and any(f.lower().endswith(AUDIO) for f in os.listdir(folder)):
            raise Duplicate(f"Already in your library: {info['title']}")
    with lock:
        jobs[job["id"]] = job
        for old in sorted(jobs.values(), key=lambda j: j["created_at"])[:-30]:  # keep the last 30
            if old["status"] in ("completed", "failed"):
                jobs.pop(old["id"], None)
    work.put(job)
    return job

# --- library changes -----------------------------------------------------------

class Refused(Exception):
    def __init__(self, code, detail):
        super().__init__(detail)
        self.code, self.detail = code, detail

def jellyfin(method, path, auth, body=None):
    request = urllib.request.Request(JELLYFIN + path, data=body, method=method, headers={"Authorization": auth})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            data = response.read()
            return json.loads(data) if data else None
    except urllib.error.HTTPError as e:
        raise Refused(403 if e.code in (401, 403) else 502, "Jellyfin refused that; sign in again on the phone." if e.code in (401, 403) else f"Jellyfin answered {e.code}.")
    except OSError:
        raise Refused(502, "Jellyfin is not answering.")

def admin(auth):
    """The caller's Jellyfin user, which must be an administrator: changing files is theirs alone."""
    if not auth or "Token=" not in auth:
        raise Refused(401, "Sign in on the phone first.")
    me = jellyfin("GET", "/Users/Me", auth)
    if not (me.get("Policy") or {}).get("IsAdministrator"):
        raise Refused(403, "Only a Jellyfin administrator can change the library.")
    return me

def music_library(auth, user_id):
    views = jellyfin("GET", f"/UserViews?userId={user_id}", auth)["Items"]
    return next((v["Id"] for v in views if v.get("CollectionType") == "music"), None)

def refresh(auth, user_id):
    library = music_library(auth, user_id)
    if library:
        jellyfin("POST", f"/Items/{library}/Refresh?metadataRefreshMode=Default&imageRefreshMode=Default", auth)

def song_file(auth, user_id, item_id):
    """The song's file on this machine, refusing anything outside the music folder."""
    if not re.fullmatch(r"[0-9a-f]{32}", item_id or ""):
        raise Refused(400, "That is not a song id.")
    item = jellyfin("GET", f"/Items/{item_id}?userId={user_id}", auth)
    path = item.get("Path") or ""
    if item.get("Type") != "Audio" or not path.startswith(JELLYFIN_MUSIC + "/"):
        raise Refused(400, "That is not a song in the Music library.")
    local = os.path.realpath(os.path.join(MUSIC, path[len(JELLYFIN_MUSIC) + 1:]))
    if not local.startswith(os.path.realpath(MUSIC) + os.sep) or not os.path.isfile(local):
        raise Refused(404, "The song's file is gone; pull down to refresh the list.")
    return local

def alone(path):
    folder = os.path.dirname(path)
    return [f for f in os.listdir(folder) if f.lower().endswith(AUDIO)] == [os.path.basename(path)]

def edit_tags(path, fields):
    import mutagen
    audio = mutagen.File(path, easy=True)
    if audio is None:
        raise Refused(415, "Spin can't edit this kind of file.")
    for key in ("title", "artist", "album"):
        value = (fields.get(key) or "").strip()
        if value:
            audio[key] = value[:300]
    if (fields.get("artist") or "").strip() and alone(path):
        audio["albumartist"] = fields["artist"].strip()[:300]  # an album of one follows its song's artist
    audio.save()

def image_kind(data):
    if data[:3] == b"\xff\xd8\xff":
        return "jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "png"
    raise Refused(415, "Send a JPEG or PNG picture.")

def set_art(path, data):
    import mutagen
    kind = image_kind(data)
    ext = os.path.splitext(path)[1].lower()
    if ext in (".m4a", ".mp4", ".aac"):
        from mutagen.mp4 import MP4, MP4Cover
        audio = MP4(path)
        audio["covr"] = [MP4Cover(data, imageformat=MP4Cover.FORMAT_JPEG if kind == "jpeg" else MP4Cover.FORMAT_PNG)]
        audio.save()
    elif ext == ".mp3":
        from mutagen.id3 import APIC, ID3, ID3NoHeaderError
        try:
            tags = ID3(path)
        except ID3NoHeaderError:
            tags = ID3()
        tags.delall("APIC")
        tags.add(APIC(encoding=3, mime=f"image/{kind}", type=3, desc="Cover", data=data))
        tags.save(path)
    elif ext == ".flac":
        from mutagen.flac import FLAC, Picture
        audio = FLAC(path)
        picture = Picture()
        picture.type, picture.mime, picture.data = 3, f"image/{kind}", data
        audio.clear_pictures()
        audio.add_picture(picture)
        audio.save()
    elif not alone(path):
        raise Refused(415, "This file can't hold a picture, and its folder has other songs.")
    if alone(path):  # the album's own picture too, which Jellyfin prefers to embedded art
        folder = os.path.dirname(path)
        for old in ("cover.jpg", "cover.png", "folder.jpg", "folder.png"):
            if os.path.exists(os.path.join(folder, old)):
                os.remove(os.path.join(folder, old))
        with open(os.path.join(folder, "cover.jpg" if kind == "jpeg" else "cover.png"), "wb") as f:
            f.write(data)

def delete_song(path):
    folder = os.path.dirname(path)
    stem = os.path.splitext(os.path.basename(path))[0]
    os.remove(path)
    for f in os.listdir(folder):  # its lyrics and the like
        if os.path.splitext(f)[0] == stem:
            os.remove(os.path.join(folder, f))
    music = os.path.realpath(MUSIC)
    if not any(f.lower().endswith(AUDIO) for f in os.listdir(folder)):
        for f in os.listdir(folder):
            if f.lower().endswith((".jpg", ".jpeg", ".png", ".lrc", ".txt", ".nfo", ".m3u")):
                os.remove(os.path.join(folder, f))
        for d in (folder, os.path.dirname(folder)):  # the album, then the artist, once empty
            if os.path.realpath(d) != music and os.path.realpath(d).startswith(music + os.sep):
                try:
                    os.rmdir(d)
                except OSError:
                    break

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

    def _body(self, limit):
        length = int(self.headers.get("Content-Length") or 0)
        if length > limit:
            raise Refused(413, "That is too big.")
        return self.rfile.read(length)

    def _library(self, method):
        """Library routes: check the caller, change the file, rescan so the phone sees it in seconds."""
        path, _ = self._path()
        m = re.fullmatch(r"/library/items/([^/]+)(/art)?", path)
        try:
            if method == "POST" and path == "/library/refresh":
                auth = self.headers.get("Authorization", "")
                refresh(auth, admin(auth)["Id"])
                return self._send(200, {"ok": True})
            if not m or (method, bool(m.group(2))) not in (("PATCH", False), ("DELETE", False), ("PUT", True)):
                return self._send(404, {"detail": "Not found"})
            auth = self.headers.get("Authorization", "")
            user = admin(auth)["Id"]
            file = song_file(auth, user, m.group(1))
            if method == "PATCH":
                fields = json.loads(self._body(10_000) or b"{}")
                if not isinstance(fields, dict):
                    raise Refused(400, "Send JSON like {\"title\": \"...\"}.")
                edit_tags(file, fields)
                jellyfin("POST", f"/Items/{m.group(1)}/Refresh?metadataRefreshMode=FullRefresh&imageRefreshMode=Default&replaceAllMetadata=true", auth)
            elif method == "PUT":
                set_art(file, self._body(15_000_000))
                jellyfin("POST", f"/Items/{m.group(1)}/Refresh?metadataRefreshMode=FullRefresh&imageRefreshMode=FullRefresh&replaceAllImages=true", auth)
            else:
                delete_song(file)
            refresh(auth, user)
            print(f"[spin-sources] {method} {path} -> {file}", flush=True)
            self._send(200, {"ok": True})
        except Refused as e:
            self._send(e.code, {"detail": e.detail})
        except (ValueError, OSError) as e:
            self._send(500, {"detail": f"Could not change the file: {e}"[:300]})

    def do_PATCH(self):
        self._library("PATCH")

    def do_PUT(self):
        self._library("PUT")

    def do_DELETE(self):
        path, _ = self._path()
        if path == "/soundcloud":
            with lock:
                for job in [j for j in jobs.values() if j["status"] in ("completed", "failed")]:
                    jobs.pop(job["id"], None)
            return self._send(200, {"ok": True})
        self._library("DELETE")

    def do_POST(self):
        path, _ = self._path()
        if path.startswith("/library/"):
            return self._library("POST")
        if path != "/soundcloud":
            return self._send(404, {"detail": "Not found"})
        try:
            body = json.loads(self._body(10_000) or b"{}")
            url, force = body.get("url", ""), bool(body.get("force"))
        except (ValueError, AttributeError, Refused):
            return self._send(400, {"detail": "Send JSON like {\"url\": \"https://soundcloud.com/...\"}."})
        if not isinstance(url, str) or not is_soundcloud(url):
            return self._send(422, {"detail": "That is not a SoundCloud link."})
        try:
            self._send(201, {"id": queue_soundcloud(url, force)["id"]})
        except Duplicate as e:
            self._send(409, {"detail": str(e), "duplicate": True})

    def log_message(self, *args):
        pass

def selftest():
    assert safe("AC/DC") == "AC-DC" and safe("..hidden") == "hidden" and safe("") == "Unknown"
    assert is_soundcloud("https://soundcloud.com/a/b") and is_soundcloud("https://on.soundcloud.com/x")
    assert not is_soundcloud("http://soundcloud.com/a") and not is_soundcloud("https://evilsoundcloud.com/a")
    assert not is_soundcloud("--exec=rm") and not is_soundcloud("https://soundcloud.com.evil.net/a")
    assert image_kind(b"\xff\xd8\xff\xe0rest") == "jpeg" and image_kind(b"\x89PNG\r\n\x1a\nrest") == "png"
    try:
        image_kind(b"GIF89a")
        raise AssertionError("a GIF must be refused")
    except Refused as e:
        assert e.code == 415
    # Delete leaves the music folder itself and other albums alone, and clears an emptied album and artist.
    global MUSIC
    saved, MUSIC = MUSIC, tempfile.mkdtemp()
    try:
        album = os.path.join(MUSIC, "Artist", "Album")
        other = os.path.join(MUSIC, "Artist", "Other")
        os.makedirs(album); os.makedirs(other)
        for f in ("a.m4a", "a.lrc", "b.m4a", "cover.jpg"):
            open(os.path.join(album, f), "w").close()
        open(os.path.join(other, "c.m4a"), "w").close()
        delete_song(os.path.join(album, "a.m4a"))
        assert sorted(os.listdir(album)) == ["b.m4a", "cover.jpg"], "the song and its lyrics go, the rest stays"
        assert alone(os.path.join(other, "c.m4a"))
        delete_song(os.path.join(album, "b.m4a"))
        assert not os.path.exists(album) and os.path.isdir(other), "an emptied album folder goes, its sibling stays"
        delete_song(os.path.join(other, "c.m4a"))
        assert os.listdir(MUSIC) == [], "an emptied artist folder goes too"
        assert os.path.isdir(MUSIC), "the music folder itself never goes"
    finally:
        shutil.rmtree(MUSIC, ignore_errors=True)
        MUSIC = saved
    print("selftest ok")

if __name__ == "__main__":
    if sys.argv[1:] == ["selftest"]:
        selftest()
        sys.exit()
    threading.Thread(target=worker, daemon=True).start()
    print(f"[spin-sources] on 127.0.0.1:{PORT}, music in {MUSIC}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
