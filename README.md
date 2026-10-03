> **Migration note:** If you previously installed Agent Assistant by cloning this git repo and running `server.py` manually (flat `server.py` layout), **uninstall / stop that copy first, then reinstall with the one-line installer below**. Mixing old layouts with the new installer will not upgrade cleanly.

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
- **LAN-friendly defaults** — binds all interfaces, but only accepts localhost + private LAN clients unless you add more allow rules
- **No build step** — pure Python HTTP server + a single `index.html`

---

## Requirements

- **Linux** (x86_64 / aarch64) or **macOS** (Intel / Apple Silicon), or **Windows** via `install.ps1`
- The one-line installer downloads an embedded standalone Python (currently **3.14.x**) — system Python is not required for that path
- ~50 MB of disk for the OCR model (downloaded on first use by `rapidocr_onnxruntime`)
- 1 GB RAM is plenty
- CPU-only — no GPU / OpenCL / CUDA required

---

## Quick Installation (Recommended)

### Linux / macOS

One-liner (no local `.sh` file; stdin stays your terminal so prompts work):

```bash
bash <(curl -sSL https://raw.githubusercontent.com/kennysoul/agent-assistant/main/install.sh)
```

Do **not** use `curl ... | bash` for this installer — the pipe steals stdin, so the first prompt exits immediately.

### Windows (PowerShell)

```powershell
powershell -Command "iex (irm https://raw.githubusercontent.com/kennysoul/agent-assistant/main/install.ps1)"
```

### What the Unix installer does

Install root:

| Platform | Path | Notes |
|---|---|---|
| **macOS** | `~/opt/agent-assistant` | Per-user; no sudo required for the app files |
| **Linux** | `/opt/agent-assistant` | System-wide; writing needs root/sudo |

| Path | Purpose |
|---|---|
| `python/` | Embedded standalone Python |
| `venv/` | Virtualenv with `rapidocr_onnxruntime` + `Pillow` |
| `app/server.py`, `app/index.html` | Application files |
| `install.sh` | Management menu entrypoint (`agent-assistant`) |
| `listen.conf` | Bind addresses, client allowlist, port |

During a fresh install you will be asked:

1. **Enable autostart?**
2. **macOS only:** Start at boot without login? (`LaunchDaemon` + sudo) vs after user login (`LaunchAgent`)
3. **Extra allowed IPs/CIDRs** (optional) and **listen bind addresses** (default `0.0.0.0`)

It also installs a PATH command and a shell alias backup:

```bash
# Primary (works without sourcing rc files):
/usr/local/bin/agent-assistant → <install-root>/bin/agent-assistant

# Backup alias in ~/.zshrc or ~/.bashrc:
alias agent-assistant='bash "<install-root>/install.sh"'
```

Running `agent-assistant` opens the **management menu**.

After install, open `http://127.0.0.1:9191/`.

### Re-run installer / `agent-assistant` menu

If the install’s `python/bin/python` already exists, `agent-assistant` (or re-running `install.sh`) opens a menu:

1. Update (pull latest `server.py` / `index.html` + upgrade packages)
2. Toggle autostart
3. Configure network access (`listen.conf`)
4. Upgrade Python
5. Run server in foreground
6. Repair CLI command (`/usr/local/bin/agent-assistant`)
7. Uninstall completely
8. Exit

Dry-run (print planned actions only):

```bash
bash ./install.sh --dry-run
```

---

## Network defaults (important)

By default the server:

- **Binds** `0.0.0.0:9191` (all interfaces), so LAN devices can reach the port
- **Allows clients from**:
  - `127.0.0.1/32` and `::1/128` (**always forced**; cannot be disabled)
  - `10.0.0.0/8`
  - `172.16.0.0/12`
  - `192.168.0.0/16`
- **Rejects** other clients with HTTP `403` (for example a VPS public IP hitting the port from the internet)

So “listening on all interfaces” does **not** mean “open to the whole internet”.

Example `listen.conf` (under the install root):

```ini
# hosts: bind addresses (0.0.0.0 = all interfaces)
# allow: client IP/CIDR allowlist (127.0.0.1 and ::1 are always forced by the server)
hosts=0.0.0.0
allow=127.0.0.1/32,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
port=9191
```

To allow an extra public admin IP or a tighter LAN subnet, use the installer menu **Configure network access**, or edit `listen.conf` / set env vars, then restart the service.

Environment overrides (optional):

| Variable | Meaning |
|---|---|
| `AGENT_ASSISTANT_CONFIG` | Path to a config file (otherwise `../listen.conf` or `./listen.conf` next to `server.py`) |
| `AGENT_ASSISTANT_HOSTS` | Comma-separated bind addresses |
| `AGENT_ASSISTANT_ALLOW` | Comma-separated allow IPs/CIDRs |
| `AGENT_ASSISTANT_PORT` | Listen port |

---

## Autostart behavior

### Linux (`install.sh`)

- Prefers **systemd user** units (`~/.config/systemd/user/agent-assistant.service`) when a user bus is available
- If running as **root** or there is **no systemd user bus**, falls back to a **system** unit: `/etc/systemd/system/agent-assistant.service`

### macOS (`install.sh`)

- Default: **LaunchAgent** `~/Library/LaunchAgents/com.agent.assistant.plist` (starts after user login)
- Optional: **LaunchDaemon** `/Library/LaunchDaemons/com.agent.assistant.plist` (starts at boot without GUI login; needs sudo; runs as your user via `UserName` / `GroupName`)

### Windows (`install.ps1`)

- Scheduled Task based autostart (see `install.ps1`)

---

## Manual / development run

Useful for hacking on the repo without the installer:

```bash
git clone https://github.com/kennysoul/agent-assistant.git
cd agent-assistant

python3 -m venv .venv
source .venv/bin/activate
pip install rapidocr_onnxruntime Pillow

python server.py
```

Without `listen.conf`, the same network defaults apply: bind `0.0.0.0:9191`, allow localhost + private LAN.

First OCR use downloads ONNX models (~50 MB) under `~/.cache/rapidocr/`.

---

## Reverse proxy (HTTPS)

If you expose the service through Caddy / Nginx / Cloudflare Tunnel, proxy to loopback:

```caddy
clip.example.com {
    reverse_proxy 127.0.0.1:9191
}
```

Notes:

- The page sends `Cache-Control: no-store` so proxies should not cache the UI
- TLS termination makes `navigator.clipboard.writeText` happier in browsers
- The allowlist checks the **direct TCP peer**. If the proxy connects from localhost, peers appear as `127.0.0.1` (allowed). If something connects from a non-private address straight to port 9191, it is rejected unless you add that address/CIDR to `allow`

---

## Configuration in `server.py`

| Constant | Default | Purpose |
|---|---|---|
| `VERSION` | `'0.0.10'` | Shown in the page footer; bump when shipping UI/server changes |
| `SAVE_DIR` | `'/tmp/clipboard'` | Upload storage (not persistent across reboot unless you change it) |
| `MAX_PIXELS` | `1200` | OCR resize cap (longest side) |
| `TEXT_PREVIEW_CHARS` | `200` | Preview length for text snippets |
| `DEFAULT_PORT` | `9191` | Port when config/env does not override |
| `DEFAULT_BIND_HOSTS` | `['0.0.0.0']` | Bind when config/env does not override |
| `DEFAULT_ALLOW` | localhost + RFC1918 | Client allowlist when config/env does not override |

Prefer `listen.conf` / env for network settings so installer updates do not wipe your edits inside `server.py`.

---

## HTTP API

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/` | HTML UI |
| `GET` | `/list?ts=<ms>` | JSON list of files in `SAVE_DIR`, sorted by mtime desc |
| `POST` | `/up` | multipart upload: `f=<file>` for files, `text=<utf8>` for clipboard text |
| `GET` | `/ocr?path=<urlencoded>` | OCR an image, returns `{success, text}` |
| `GET` | `/preview?path=<urlencoded>` | First `TEXT_PREVIEW_CHARS` characters of a text file |
| `GET` | `/text?path=<urlencoded>` | Full text body |
| `GET` | `/tmp/clipboard/<filename>` | Serve any saved file (images, etc.) |
| `DELETE` | `/del?path=<urlencoded>` | Delete a single file (must live under `SAVE_DIR`) |
| `DELETE` | `/del-all` | Delete every file in `SAVE_DIR` |

All responses set:

```
Cache-Control: no-store, no-cache, must-revalidate, max-age=0
Pragma: no-cache
Expires: 0
```

Unauthorized clients (outside the allowlist) receive `403 Forbidden`.

---

## Project layout

```
agent-assistant/
├── server.py       # HTTP server + OCR + listen/allowlist logic
├── index.html      # UI
├── install.sh      # Linux/macOS installer + management menu
├── install.ps1     # Windows installer
├── agent-cli.py    # Optional helper CLI in the repo (not what install.sh aliases)
├── README.md
└── .gitignore
```

Installed layout (Unix installer):

```
# macOS: ~/opt/agent-assistant   |   Linux: /opt/agent-assistant
├── python/         # embedded Python
├── venv/           # dependencies
├── app/
│   ├── server.py
│   └── index.html
├── install.sh      # management entrypoint (`agent-assistant`)
└── listen.conf     # bind / allow / port
```

---

## Troubleshooting

- **Previously installed from git and things look wrong** — stop the old process, remove the old files/service, then use `install.sh` / `install.ps1` for a clean install (see the migration note at the top).
- **Can open on the machine but not from another LAN device** — confirm bind is `0.0.0.0`, the client is in a private range, and no host firewall is blocking `9191`.
- **VPS public access returns 403** — expected with default allowlist. Add your client IP/CIDR via **Configure network access** or `allow=` in `listen.conf`, then restart.
- **OCR is slow on first call** — model download + warm-up; later calls are much faster. Images larger than 1200 px are resized before OCR.
- **Copy button says "❌ 复制失败"** — `navigator.clipboard.writeText` needs a secure context (HTTPS or `localhost`). Fallback `execCommand('copy')` still works in many HTTP cases.
- **`/tmp/clipboard/` fills up** — files stay until deleted in the UI. Use a cron job if you need automatic expiry.
- **Port 9191 already in use** — find the process (`lsof -nP -iTCP:9191 -sTCP:LISTEN` / `ss -tlnp | grep 9191`), stop it, or change `port=` in `listen.conf`.
- **Linux autostart failed with D-Bus / user bus errors** — current installer falls back to a system unit when root or when no user bus is available; re-run the installer / toggle autostart after updating `install.sh`.
- **macOS needs service before GUI login (SSH-only box)** — choose LaunchDaemon (“boot without login”) during install or when enabling autostart.

---

## Versioning

`VERSION` in `server.py` is rendered in the page footer. Bump it when you ship changes users should notice. Convention: `0.0.N`.

---

## License

Use it however you like.
