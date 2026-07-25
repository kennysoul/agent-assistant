# Agent Assistant — Cloud Clipboard with OCR

Simple HTTP clipboard + OCR tool. Drop a file or paste text into a webpage, server saves it and shows history. Image OCR via RapidOCR, text preview with full-text expansion.

## Quick start

```bash
# venv with OCR deps
uv venv /tmp/clipboardenv
source /tmp/clipboardenv/bin/activate
uv pip install rapidocr_onnxruntime Pillow

# run
cd ~/codes/agent-assistant
python server.py          # listens on :9191
```

Open `http://localhost:9191/`.

## Endpoints

| Path | Purpose |
|---|---|
| `GET /` | HTML UI |
| `GET /list` | JSON list of files in `/tmp/clipboard/` |
| `POST /up` | multipart upload (`f=@file`) or `text=...` |
| `GET /ocr?path=…` | OCR on a PNG/JPG (returns JSON text) |
| `GET /preview?path=…` | first 200 chars of a text file |
| `GET /tmp/clipboard/<file>` | serve any saved file |
| `DELETE /del?path=…` | delete a file (path must live in `/tmp/clipboard/`) |

## Features

- Cmd+V / drag-drop into the drop zone
- Image preview + click-to-zoom
- One-click OCR on any image (RapidOCR / ONNX runtime)
- Text preview — first 200 chars, click to expand
- Auto-loads server-side file list on every reload (no localStorage dep)
- Hard no-cache headers (`no-store, no-cache, must-revalidate`)

## Versioning

`VERSION` constant at the top of `server.py`. Bump on every code change; rendered in the page footer.

## Layout

- `server.py` — single-file Python HTTP server + HTML/CSS/JS (no framework)
- `/tmp/clipboard/` — file storage
- `/tmp/clipboardenv/` — Python venv

## Requirements

- Python 3.11+
- `rapidocr_onnxruntime`, `Pillow`
- CPU is fine (no GPU/OpenCL needed)