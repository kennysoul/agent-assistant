# Agent Assistant — Cloud Clipboard with OCR

A simple self-hosted cloud clipboard that lets you paste text, screenshots, or files into a webpage. Saved items are listed on the page with quick access to copy the path, preview text, or OCR images via [RapidOCR](https://github.com/RapidAI/RapidOCR). Files are stored locally on the server (default: `/tmp/clipboard/`) — nothing leaves your machine.

---

## Features

- **Cmd+V / drag-drop** — paste text, screenshots, or files straight into the page
- **Image preview** — click thumbnail to zoom in
- **One-click OCR** — runs RapidOCR (CPU, ONNX runtime) on any image and shows the recognised text in a split-pane modal
- **Text preview** — clipboard-text entries show the first 200 characters, click to expand the full content in a modal
- **Copy path** — every item has a copy-to-clipboard button (uses `navigator.clipboard.writeText` with `execCommand` fallback for non-secure contexts)
- **One-click delete** — deletes the file from disk and the entry from the UI immediately
- **Clear directory** — modal confirmation, then `DELETE /del-all` wipes `/tmp/clipboard/`
- **Live refresh** — every page load fetches the server's truth (`cache:'no-store'` + `Cache-Control: no-store, no-cache, must-revalidate` + timestamp query string)
- **No build step** — pure Python HTTP server + a single `index.html`

---

## Requirements

- Linux (Debian / Ubuntu tested)
- Python 3.11 or newer
- ~50 MB of disk for the OCR model (downloaded on first run by `rapidocr_onnxruntime`)
- 1 GB RAM is plenty
- CPU-only — no GPU / OpenCL / CUDA required

---

## Deployment

### Option A — quick start (foreground)

```bash
# 1. Clone the repo
git clone https://github.com/kennysoul/agent-assistant.git
cd agent-assistant

# 2. Create a venv and install OCR deps
uv venv /tmp/clipboardenv
source /tmp/clipboardenv/bin/activate
uv pip install rapidocr_onnxruntime Pillow

# 3. Run
python server.py
```

Open `http://localhost:9191/`. First OCR request downloads the ONNX models (~50 MB) and caches them under `~/.cache/rapidocr/` — subsequent calls are fast (~1 s per image on CPU).

### Option B — systemd service (recommended for always-on)

```bash
# 1. Place the code somewhere stable
sudo mkdir -p /opt/agent-assistant
sudo cp server.py index.html /opt/agent-assistant/
sudo chown -R $USER:$USER /opt/agent-assistant

# 2. Create the venv
uv venv /opt/agent-assistant/venv
/opt/agent-assistant/venv/bin/pip install rapidocr_onnxruntime Pillow

# 3. Create the systemd unit
sudo tee /etc/systemd/system/agent-assistant.service > /dev/null <<'UNIT'
[Unit]
Description=Agent Assistant — Cloud Clipboard + OCR
After=network.target

[Service]
Type=simple
User=YOUR_USER
WorkingDirectory=/opt/agent-assistant
ExecStart=/opt/agent-assistant/venv/bin/python server.py
Restart=on-failure
RestartSec=5
Environment=OMP_NUM_THREADS=4

[Install]
WantedBy=multi-user.target
UNIT

# 4. Enable + start
sudo systemctl daemon-reload
sudo systemctl enable --now agent-assistant.service
sudo systemctl status agent-assistant.service
```

The server listens on `0.0.0.0:9191` by default. Open `http://<server-ip>:9191/`.

Logs: `journalctl -u agent-assistant.service -f`

### Option C — behind a reverse proxy (HTTPS)

If you expose port 9191 through Caddy / Nginx / Cloudflare Tunnel, just proxy the port. The page sends `Cache-Control: no-store` so the proxy won't cache it. If the proxy terminates TLS, the browser will allow `navigator.clipboard.writeText` — useful if you depend on the copy button.

Example Caddy snippet:

```caddy
clip.example.com {
    reverse_proxy 127.0.0.1:9191
}
```

---

## Configuration

The top of `server.py` has a few constants you may want to tweak:

| Constant | Default | Purpose |
|---|---|---|
| `VERSION` | `'0.0.9'` | Displayed in the page footer; bump on every code change |
| `SAVE_DIR` | `'/tmp/clipboard'` | Where uploaded files live. Change to e.g. `/var/lib/agent-assistant` for persistence across reboots |
| `MAX_PIXELS` | `1200` | Largest dimension the OCR engine sees — large images get resized down for speed |
| `TEXT_PREVIEW_CHARS` | `200` | First N characters shown for a text snippet |

The HTTP port is hardcoded at the bottom of `server.py` (`HTTPServer(('0.0.0.0', 9191), Handler)`). Change it if 9191 is taken.

---

## HTTP API

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/` | HTML UI |
| `GET` | `/list?ts=<ms>` | JSON list of files in `SAVE_DIR`, sorted by mtime desc |
| `POST` | `/up` | multipart upload: `f=<file>` for files, `text=<utf8>` for clipboard text |
| `GET` | `/ocr?path=<urlencoded>` | OCR an image, returns `{success, text}` |
| `GET` | `/preview?path=<urlencoded>` | First `TEXT_PREVIEW_CHARS` characters of a text file |
| `GET` | `/tmp/clipboard/<filename>` | Serve any saved file (images, etc.) |
| `DELETE` | `/del?path=<urlencoded>` | Delete a single file (must live under `SAVE_DIR`) |
| `DELETE` | `/del-all` | Delete every file in `SAVE_DIR` |

All responses set:
```
Cache-Control: no-store, no-cache, must-revalidate, max-age=0
Pragma: no-cache
Expires: 0
```

---

## Project layout

```
agent-assistant/
├── server.py          # Pure-Python HTTP handler (~10 KB)
├── index.html         # UI: HTML + CSS + JS (~20 KB)
├── README.md          # this file
└── .gitignore         # Python bytecode, backup files
```

No build pipeline, no `node_modules`, no framework.

---

## Troubleshooting

- **OCR is slow (~2 s)** — first call downloads the ONNX model; later calls hit the warm model cache. Bigger images are auto-resized to 1200 px before OCR. To go faster, install `libopenblas` or `intel-openmp` system packages for SIMD acceleration.
- **Copy button says "❌ 复制失败"** — `navigator.clipboard.writeText` requires a secure context (HTTPS or `localhost`). The fallback uses `document.execCommand('copy')` with a hidden textarea — works in most browsers even over plain HTTP.
- **`/tmp/clipboard/` fills up** — files are kept until you click the 🗑 button or use "清空目录" in the footer. Add a cron job to clean old files if you need automatic expiry.
- **Service won't start on port 9191** — another process is bound. `sudo ss -tlnp | grep 9191` and kill it, or change the port in `server.py`.

---

## Versioning

The `VERSION` constant at the top of `server.py` is rendered in the page footer. Bump it on every change so users can confirm they're on the latest copy. Convention used here: `0.0.N` increments per change.

---

## License

Use it however you like.