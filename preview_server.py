#!/usr/bin/env python3
import http.server
import socketserver
import os
import json
import gzip
import io
import subprocess
import threading
import urllib.parse
import email.parser
import email.policy
from datetime import datetime

PORT = 9090
TUNNEL_FILE = "/tmp/tunnel_url.txt"
DOWNLOADS_DIR = os.path.expanduser("~/Downloads")
PULSE_RUNTIME_PATH = "/tmp/pulse-runtime"
FFMPEG_BIN = "ffmpeg"


def read_tunnel_url():
    try:
        if os.path.exists(TUNNEL_FILE):
            with open(TUNNEL_FILE, "r") as f:
                return f.read().strip()
    except Exception:
        pass
    return ""


def list_files():
    try:
        os.makedirs(DOWNLOADS_DIR, exist_ok=True)
        entries = []
        for name in sorted(os.listdir(DOWNLOADS_DIR)):
            path = os.path.join(DOWNLOADS_DIR, name)
            if os.path.isfile(path):
                size = os.path.getsize(path)
                entries.append({"name": name, "size": size})
        return entries
    except Exception:
        return []


def parse_multipart(headers, body_bytes):
    """Parse multipart/form-data without the deprecated cgi module."""
    content_type = headers.get("Content-Type", "")
    # Build a minimal RFC822 message to reuse email parser
    raw = f"Content-Type: {content_type}\r\n\r\n".encode() + body_bytes
    msg = email.parser.BytesParser(policy=email.policy.compat32).parsebytes(raw)
    parts = {}
    if msg.is_multipart():
        for part in msg.get_payload():
            disp = part.get("Content-Disposition", "")
            params = {}
            for item in disp.split(";"):
                item = item.strip()
                if "=" in item:
                    k, v = item.split("=", 1)
                    params[k.strip()] = v.strip().strip('"')
            name = params.get("name")
            if name:
                parts[name] = {
                    "filename": params.get("filename"),
                    "data": part.get_payload(decode=True),
                }
    return parts


class PreviewHandler(http.server.BaseHTTPRequestHandler):

    # ── CORS & common headers ────────────────────────────────────────────────
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")

    # ── GET dispatcher ───────────────────────────────────────────────────────
    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path

        if path == "/status":
            self._status()
        elif path == "/audio":
            self._audio_stream()
        elif path == "/files":
            self._files_list()
        elif path.startswith("/files/"):
            name = urllib.parse.unquote(path[len("/files/"):])
            self._file_download(name)
        elif path in ("/", ""):
            self._main_page()
        else:
            self._not_found()

    # ── POST dispatcher ──────────────────────────────────────────────────────
    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/upload":
            self._file_upload()
        else:
            self._not_found()

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    # ── /status JSON ─────────────────────────────────────────────────────────
    def _status(self):
        tunnel_url = read_tunnel_url()
        files = list_files()
        payload = json.dumps({
            "tunnel_url": tunnel_url,
            "timestamp": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
            "alive": bool(tunnel_url),
            "files": files,
        }).encode("utf-8")
        self._send_json(payload)

    # ── /audio — live MP3 stream from PulseAudio virtual sink ────────────────
    def _audio_stream(self):
        env = os.environ.copy()
        env["PULSE_RUNTIME_PATH"] = PULSE_RUNTIME_PATH
        env["PULSE_SERVER"] = f"unix:{PULSE_RUNTIME_PATH}/native"

        cmd = [
            FFMPEG_BIN,
            "-f", "pulse",
            "-i", "virtual_speaker.monitor",
            "-acodec", "libmp3lame",
            "-ab", "96k",
            "-ar", "44100",
            "-ac", "2",
            "-f", "mp3",
            "-",
        ]
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                env=env,
            )
        except Exception as e:
            self.send_error(500, f"Audio stream failed: {e}")
            return

        self.send_response(200)
        self.send_header("Content-Type", "audio/mpeg")
        self.send_header("Cache-Control", "no-cache, no-store")
        self.send_header("Connection", "close")
        self._cors()
        self.end_headers()

        try:
            while True:
                chunk = proc.stdout.read(4096)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
        except Exception:
            pass
        finally:
            proc.kill()

    # ── /files — JSON list of files in ~/Downloads ────────────────────────────
    def _files_list(self):
        payload = json.dumps(list_files()).encode("utf-8")
        self._send_json(payload)

    # ── /files/<name> — download a file ──────────────────────────────────────
    def _file_download(self, name):
        name = os.path.basename(name)
        filepath = os.path.join(DOWNLOADS_DIR, name)
        if not os.path.isfile(filepath):
            self.send_error(404, "File not found")
            return
        size = os.path.getsize(filepath)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", f'attachment; filename="{name}"')
        self.send_header("Content-Length", str(size))
        self._cors()
        self.end_headers()
        with open(filepath, "rb") as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                self.wfile.write(chunk)

    # ── POST /upload — save uploaded file to ~/Downloads ─────────────────────
    def _file_upload(self):
        os.makedirs(DOWNLOADS_DIR, exist_ok=True)
        ctype = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in ctype:
            self.send_error(400, "Expected multipart/form-data")
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            parts = parse_multipart(self.headers, body)
            filepart = parts.get("file")
            if not filepart or not filepart.get("filename"):
                self.send_error(400, "No file provided")
                return
            safe_name = os.path.basename(filepart["filename"])
            dest = os.path.join(DOWNLOADS_DIR, safe_name)
            with open(dest, "wb") as f:
                f.write(filepart["data"])
            payload = json.dumps({"ok": True, "name": safe_name}).encode()
            self._send_json(payload)
        except Exception as e:
            self.send_error(500, str(e))

    # ── / — main HTML page ────────────────────────────────────────────────────
    def _main_page(self):
        tunnel_url = read_tunnel_url()
        initial_novnc = ""
        if tunnel_url:
            initial_novnc = (
                f"{tunnel_url}?quality=6&compression=0&shared=true"
                "&autoconnect=true&reconnect=true&reconnect_delay=300"
                "&resize=scale&show_dot=true&view_clip=true"
            )

        html = self._build_html(tunnel_url, initial_novnc)
        html_bytes = html.encode("utf-8")

        buf = io.BytesIO()
        with gzip.GzipFile(fileobj=buf, mode="wb") as gz:
            gz.write(html_bytes)
        compressed = buf.getvalue()

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(compressed)))
        self._cors()
        self.end_headers()
        self.wfile.write(compressed)

    # ── Helpers ───────────────────────────────────────────────────────────────
    def _send_json(self, payload: bytes):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-cache, no-store, must-revalidate")
        self.send_header("Content-Length", str(len(payload)))
        self._cors()
        self.end_headers()
        self.wfile.write(payload)

    def _not_found(self):
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, format, *args):
        pass  # Suppress access logs

    # ── HTML ──────────────────────────────────────────────────────────────────
    def _build_html(self, tunnel_url, initial_novnc):
        files_json = json.dumps(list_files())
        return f"""<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>Chromium Desktop</title>
<style>
*{{margin:0;padding:0;box-sizing:border-box}}
body{{background:#000;font-family:system-ui,-apple-system,sans-serif;overflow:hidden}}
#wrap{{width:100vw;height:100vh;display:flex;flex-direction:column;position:fixed;top:0;left:0}}
#novnc{{flex:1;border:none;width:100%;background:#000}}

/* ── Footer bar ── */
#footer{{
  background:#0a0a0a;color:#666;padding:0 10px;
  font-size:11px;border-top:1px solid #1e1e1e;
  display:flex;align-items:center;gap:8px;
  height:30px;overflow:hidden;white-space:nowrap;flex-shrink:0
}}
#tunnel-info{{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis}}
#tunnel-link{{color:#4a9eff;text-decoration:none;font-weight:bold}}
#tunnel-link:hover{{text-decoration:underline}}
.dot{{font-size:9px;margin-right:3px}}
.dot-green{{color:#22c55e}}.dot-yellow{{color:#f59e0b}}
#ts{{flex-shrink:0;color:#444}}

/* ── Panel buttons ── */
.btn{{
  background:#141414;color:#888;border:1px solid #2a2a2a;
  border-radius:3px;padding:2px 7px;font-size:11px;cursor:pointer;
  flex-shrink:0;white-space:nowrap;transition:background .15s,color .15s
}}
.btn:hover{{background:#222;color:#ddd}}
.btn.active{{background:#1a3055;color:#4a9eff;border-color:#4a9eff}}

/* ── Slide-up panels ── */
.panel{{
  position:fixed;bottom:30px;right:0;
  background:#0f0f0f;border:1px solid #2a2a2a;border-radius:6px 6px 0 0;
  width:320px;max-height:55vh;display:none;flex-direction:column;
  overflow:hidden;box-shadow:0 -4px 24px rgba(0,0,0,.8);z-index:100
}}
.panel.open{{display:flex}}
.panel-head{{
  background:#161616;color:#bbb;font-size:12px;font-weight:600;
  padding:7px 12px;border-bottom:1px solid #2a2a2a;flex-shrink:0;
  display:flex;justify-content:space-between;align-items:center
}}
.panel-body{{flex:1;overflow-y:auto;padding:10px}}

/* ── File manager ── */
.file-row{{
  display:flex;align-items:center;justify-content:space-between;
  padding:5px 0;border-bottom:1px solid #1a1a1a;font-size:12px;color:#bbb
}}
.file-row:last-child{{border-bottom:none}}
.file-name{{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
.dl-btn{{
  background:#1a3055;color:#4a9eff;border:none;border-radius:3px;
  padding:2px 8px;font-size:11px;cursor:pointer;flex-shrink:0;margin-left:8px;
  transition:background .15s
}}
.dl-btn:hover{{background:#244070}}
.empty{{color:#444;font-size:12px;text-align:center;padding:20px 0}}

/* ── Upload zone ── */
#drop-zone{{
  border:2px dashed #2a2a2a;border-radius:5px;text-align:center;
  padding:14px;color:#444;font-size:12px;cursor:pointer;margin-bottom:8px;
  transition:border-color .2s,color .2s
}}
#drop-zone.drag-over{{border-color:#4a9eff;color:#4a9eff}}
#file-input{{display:none}}
#upload-status{{font-size:11px;color:#4a9eff;min-height:16px;margin-top:4px}}

/* ── Audio panel ── */
#audio-row{{display:flex;align-items:center;gap:10px;padding:6px 0}}
#audio-el{{width:100%;height:32px;filter:invert(1) hue-rotate(180deg)}}
#audio-status{{font-size:11px;color:#555}}

/* ── Spinner / waiting screen ── */
#waiting{{
  position:fixed;top:0;left:0;width:100vw;height:calc(100vh - 30px);
  background:#000;color:#666;display:flex;flex-direction:column;
  justify-content:center;align-items:center;gap:14px;z-index:50
}}
.spinner{{
  border:2px solid #1a1a1a;border-top:2px solid #4a9eff;
  border-radius:50%;width:28px;height:28px;
  animation:spin .8s linear infinite
}}
@keyframes spin{{0%{{transform:rotate(0deg)}}100%{{transform:rotate(360deg)}}}}
h1{{font-size:16px;color:#888}}p{{font-size:12px}}
</style>
</head>
<body>

<div id="wrap">
  <iframe id="novnc" src="{initial_novnc}" allow="clipboard-read; clipboard-write"></iframe>
  <div id="footer">
    <div id="tunnel-info">
      <span class="dot" id="dot">&#9679;</span>
      <span id="tunnel-text">{tunnel_url or 'Connecting...'}</span>
    </div>
    <span id="ts">{datetime.now().strftime('%H:%M:%S')}</span>
    <button class="btn" id="btn-audio" onclick="togglePanel('audio')">&#9654; Audio</button>
    <button class="btn" id="btn-files" onclick="togglePanel('files')">&#128193; Files</button>
    <button class="btn" onclick="copyClipboardTip()" title="Clipboard sync info">&#128203; Clipboard</button>
  </div>
</div>

<!-- Audio panel -->
<div class="panel" id="panel-audio">
  <div class="panel-head">
    Desktop Audio
    <button class="btn" style="padding:1px 6px" onclick="togglePanel('audio')">&#x2715;</button>
  </div>
  <div class="panel-body">
    <div id="audio-row">
      <audio id="audio-el" controls></audio>
    </div>
    <div id="audio-status">Click play to start streaming desktop audio.</div>
  </div>
</div>

<!-- Files panel -->
<div class="panel" id="panel-files">
  <div class="panel-head">
    File Transfer (~/Downloads)
    <button class="btn" style="padding:1px 6px" onclick="togglePanel('files')">&#x2715;</button>
  </div>
  <div class="panel-body">
    <div id="drop-zone" onclick="document.getElementById('file-input').click()"
         ondragover="event.preventDefault();this.classList.add('drag-over')"
         ondragleave="this.classList.remove('drag-over')"
         ondrop="handleDrop(event)">
      Click or drop file here to upload to desktop
    </div>
    <input type="file" id="file-input" multiple onchange="uploadFiles(this.files)">
    <div id="upload-status"></div>
    <div id="file-list"></div>
  </div>
</div>

<div id="waiting" style="display:{{'none' if tunnel_url else 'flex'}}">
  <div class="spinner"></div>
  <h1>Starting Desktop...</h1>
  <p id="wait-msg">Waiting for tunnel&hellip;</p>
</div>

<script>
let currentUrl = {json.dumps(tunnel_url)};
const iframe   = document.getElementById('novnc');
const dot      = document.getElementById('dot');
const txtEl    = document.getElementById('tunnel-text');
const tsEl     = document.getElementById('ts');
const waiting  = document.getElementById('waiting');
const waitMsg  = document.getElementById('wait-msg');
const audioEl  = document.getElementById('audio-el');
const audioSt  = document.getElementById('audio-status');

// ── noVNC URL builder ────────────────────────────────────────────────────
function buildNoVncUrl(base) {{
  return base + '?quality=6&compression=0&shared=true&autoconnect=true&reconnect=true&reconnect_delay=100&resize=scale&show_dot=true&view_clip=true';
}}

// ── Panel toggle ─────────────────────────────────────────────────────────
function togglePanel(id) {{
  const panel = document.getElementById('panel-' + id);
  const btn   = document.getElementById('btn-' + id);
  const isOpen = panel.classList.contains('open');

  document.querySelectorAll('.panel').forEach(p => p.classList.remove('open'));
  document.querySelectorAll('.btn').forEach(b => b.classList.remove('active'));

  if (!isOpen) {{
    panel.classList.add('open');
    if (btn) btn.classList.add('active');
    if (id === 'files') refreshFileList();
    if (id === 'audio') startAudio();
  }} else {{
    if (id === 'audio') stopAudio();
  }}
}}

// ── Clipboard tip ────────────────────────────────────────────────────────
function copyClipboardTip() {{
  alert('Clipboard sync is built into the noVNC toolbar.\\n\\nIn the remote desktop view, hover the left edge to reveal the noVNC toolbar, then click the clipboard icon to sync text between your browser and the remote desktop.');
}}

// ── Audio streaming ──────────────────────────────────────────────────────
function startAudio() {{
  audioEl.src = '/audio?t=' + Date.now();
  audioEl.load();
  audioSt.textContent = 'Streaming desktop audio via PulseAudio...';
  audioEl.onplay  = () => audioSt.textContent = 'Playing desktop audio.';
  audioEl.onerror = () => audioSt.textContent = 'Audio unavailable — PulseAudio may still be starting.';
}}
function stopAudio() {{
  audioEl.pause();
  audioEl.src = '';
  audioSt.textContent = 'Click play to start streaming desktop audio.';
}}

// ── File upload ──────────────────────────────────────────────────────────
function handleDrop(e) {{
  e.preventDefault();
  document.getElementById('drop-zone').classList.remove('drag-over');
  uploadFiles(e.dataTransfer.files);
}}

async function uploadFiles(files) {{
  if (!files.length) return;
  const status = document.getElementById('upload-status');
  for (const file of files) {{
    status.textContent = `Uploading ${{file.name}}...`;
    const fd = new FormData();
    fd.append('file', file);
    try {{
      const res = await fetch('/upload', {{ method: 'POST', body: fd }});
      if (res.ok) {{
        status.textContent = `\u2713 ${{file.name}} uploaded to ~/Downloads`;
        refreshFileList();
      }} else {{
        status.textContent = `\u2717 Upload failed for ${{file.name}}`;
      }}
    }} catch (e) {{
      status.textContent = `\u2717 Upload error: ${{e}}`;
    }}
  }}
}}

// ── File list ────────────────────────────────────────────────────────────
function humanSize(bytes) {{
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1048576) return (bytes/1024).toFixed(1) + ' KB';
  return (bytes/1048576).toFixed(1) + ' MB';
}}

async function refreshFileList() {{
  const list = document.getElementById('file-list');
  try {{
    const res   = await fetch('/files', {{ cache: 'no-store' }});
    const files = await res.json();
    if (!files.length) {{
      list.innerHTML = '<div class="empty">No files in ~/Downloads yet.</div>';
      return;
    }}
    list.innerHTML = files.map(f =>
      `<div class="file-row">
        <span class="file-name" title="${{f.name}}">${{f.name}}</span>
        <span style="color:#444;font-size:11px;flex-shrink:0">${{humanSize(f.size)}}</span>
        <button class="dl-btn" onclick="downloadFile('${{encodeURIComponent(f.name)}}')">&#11015;</button>
       </div>`
    ).join('');
  }} catch(e) {{
    list.innerHTML = '<div class="empty">Could not load file list.</div>';
  }}
}}

function downloadFile(encodedName) {{
  const a = document.createElement('a');
  a.href = '/files/' + encodedName;
  a.download = decodeURIComponent(encodedName);
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
}}

// ── Status poller (every 2s for snappier updates) ────────────────────────
let pollActive = true;
async function poll() {{
  if (!pollActive) return;
  try {{
    const res  = await fetch('/status', {{ cache: 'no-store' }});
    const data = await res.json();

    tsEl.textContent = data.timestamp.slice(11);

    if (data.alive) {{
      dot.className = 'dot dot-green';
      txtEl.textContent = data.tunnel_url;

      if (data.tunnel_url !== currentUrl) {{
        currentUrl = data.tunnel_url;
        iframe.src = buildNoVncUrl(currentUrl);
        waiting.style.display = 'none';
      }} else if (currentUrl && waiting.style.display !== 'none') {{
        waiting.style.display = 'none';
      }}
    }} else {{
      dot.className = 'dot dot-yellow';
      txtEl.textContent = 'Tunnel reconnecting\u2026';
      waitMsg.textContent = 'Tunnel reconnecting\u2026';
      if (!currentUrl) waiting.style.display = 'flex';
      currentUrl = '';
    }}
  }} catch(e) {{
    dot.className = 'dot dot-yellow';
    txtEl.textContent = 'Preview server unreachable';
  }}
}}

setInterval(poll, 2000);
poll();
</script>
</body>
</html>"""


# ── Threaded server so audio stream doesn't block other requests ──────────────
class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 64


try:
    with ThreadedTCPServer(("", PORT), PreviewHandler) as httpd:
        print(f"Preview server running on port {PORT}", flush=True)
        httpd.serve_forever()
except Exception as e:
    print(f"Preview server error: {e}", flush=True)
