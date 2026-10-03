#!/usr/bin/env bash
# Agent Assistant Installer
# Usage: curl -sSL https://raw.githubusercontent.com/kennysoul/agent-assistant/main/install.sh | bash

set -euo pipefail

# Check for dry-run mode
DRY_RUN=false
for arg in "$@"; do
    if [[ "$arg" == "--dry-run" ]]; then
        DRY_RUN=true
        shift
    fi
done

# ── Configuration ─────────────────────────────────────────────────────────────
INSTALL_DIR="$HOME/opt/agent-assistant"
PYTHON_RELEASE="20261001"
PYTHON_VERSION="3.14.8"
REPO_URL="https://github.com/kennysoul/agent-assistant"
DEFAULT_PORT=9191

# ── Utility Functions ─────────────────────────────────────────────────────────
log() { echo "[$(date +%H:%M:%S)] $*"; }
err() { echo "ERROR: $*" >&2; exit 1; }

# Dry-run wrapper for commands
run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "[DRY-RUN] Would execute: $*"
        return 0
    else
        "$@"
    fi
}

# ── Platform Detection ────────────────────────────────────────────────────────
detect_platform() {
    PLATFORM=$(uname -s | tr '[:upper:]' '[:lower:]')
    ARCH=$(uname -m)
    
    case "$PLATFORM-$ARCH" in
        darwin-arm64) PY_PLATFORM="aarch64-apple-darwin" ;;
        darwin-x86_64) PY_PLATFORM="x86_64-apple-darwin" ;;
        linux-x86_64) PY_PLATFORM="x86_64-unknown-linux-gnu" ;;
        linux-aarch64) PY_PLATFORM="aarch64-unknown-linux-gnu" ;;
        *) err "Unsupported platform: $PLATFORM-$ARCH" ;;
    esac
    
    # Construct URL with proper encoding for the plus sign
    PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PYTHON_RELEASE}/cpython-${PYTHON_VERSION}%2B${PYTHON_RELEASE}-${PY_PLATFORM}-install_only.tar.gz"
    
    log "Detected: $PLATFORM/$ARCH → $PY_PLATFORM"
}

# ── Installation Functions ────────────────────────────────────────────────────
download_python() {
    log "Downloading Python (${PYTHON_VERSION})..."
    mkdir -p "$INSTALL_DIR/python"
    curl -sSL "$PYTHON_URL" | tar xz -C "$INSTALL_DIR/python/" --strip-components=1
    log "Python installed to $INSTALL_DIR/python/"
}

create_venv() {
    log "Creating virtual environment..."
    run "$INSTALL_DIR/python/bin/python" -m venv "$INSTALL_DIR/venv"
    run "$INSTALL_DIR/venv/bin/pip" install --upgrade pip
}

install_deps() {
    log "Installing dependencies..."
    run "$INSTALL_DIR/venv/bin/pip" install rapidocr_onnxruntime Pillow
}

clone_app() {
    log "Cloning application..."
    mkdir -p "$INSTALL_DIR/app"
    run curl -sSL "$REPO_URL/raw/main/server.py" -o "$INSTALL_DIR/app/server.py"
    run curl -sSL "$REPO_URL/raw/main/index.html" -o "$INSTALL_DIR/app/index.html"
}

# ── Autostart Functions ───────────────────────────────────────────────────────
configure_autostart() {
    local enable=${1:-true}
    [[ "$enable" != "true" ]] && return
    
    case "$PLATFORM" in
        darwin)
            configure_launchd
            ;;
        linux)
            configure_systemd
            ;;
    esac
}

configure_launchd() {
    local plist="$HOME/Library/LaunchAgents/com.agent.assistant.plist"
    mkdir -p "$(dirname "$plist")"
    
    cat > "$plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.agent.assistant</string>
    <key>ProgramArguments</key>
    <array>
        <string>$INSTALL_DIR/venv/bin/python</string>
        <string>$INSTALL_DIR/app/server.py</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>WorkingDirectory</key>
    <string>$INSTALL_DIR/app</string>
</dict>
</plist>
EOF
    
    run launchctl unload "$plist" 2>/dev/null || true
    run launchctl load "$plist"
    log "Configured launchd autostart"
}

configure_systemd() {
    local unit_dir="$HOME/.config/systemd/user"
    local unit_file="$unit_dir/agent-assistant.service"
    mkdir -p "$unit_dir"
    
    cat > "$unit_file" << EOF
[Unit]
Description=Agent Assistant — Cloud Clipboard + OCR
After=network.target

[Service]
Type=simple
WorkingDirectory=$INSTALL_DIR/app
ExecStart=$INSTALL_DIR/venv/bin/python server.py
Restart=on-failure
RestartSec=5
Environment=OMP_NUM_THREADS=4

[Install]
WantedBy=default.target
EOF
    
    run systemctl --user daemon-reload
    run systemctl --user enable --now agent-assistant.service
    log "Configured systemd autostart"
}

# ── Alias Functions ───────────────────────────────────────────────────────────
setup_alias() {
    local shell_config=""
    case "${SHELL##*/}" in
        bash) shell_config="$HOME/.bashrc" ;;
        zsh) shell_config="$HOME/.zshrc" ;;
        *) log "Unsupported shell for alias setup: $SHELL" ; return ;;
    esac
    
    local alias_line="alias agent-assistant='$INSTALL_DIR/venv/bin/python $INSTALL_DIR/app/server.py'"
    
    if ! grep -qF "$alias_line" "$shell_config" 2>/dev/null; then
        echo "" >> "$shell_config"
        echo "# Agent Assistant CLI" >> "$shell_config"
        echo "$alias_line" >> "$shell_config"
        log "Added alias to $shell_config"
        log "Run 'source $shell_config' or restart your terminal to use 'agent-assistant' command"
    else
        log "Alias already exists in $shell_config"
    fi
}

# ── Menu Functions ────────────────────────────────────────────────────────────
show_menu() {
    echo ""
    echo "📋 Agent Assistant already installed"
    echo "   Location:     $INSTALL_DIR"
    echo "   Python:       $PYTHON_VERSION"
    echo "   Autostart:    $(check_autostart)"
    echo ""
    echo "What would you like to do?"
    echo "  1. Update (pull latest code + upgrade packages)"
    echo "  2. Toggle autostart"
    echo "  3. Upgrade Python"
    echo "  4. Uninstall completely"
    echo "  5. Exit"
    echo ""
    
    read -rp "Choose an option [1-5]: " choice
    case "$choice" in
        1) update_app ;;
        2) toggle_autostart ;;
        3) upgrade_python ;;
        4) uninstall ;;
        5) exit 0 ;;
        *) echo "Invalid option"; show_menu ;;
    esac
}

check_autostart() {
    case "$PLATFORM" in
        darwin)
            if launchctl list | grep -q "com.agent.assistant"; then
                echo "enabled"
            else
                echo "disabled"
            fi
            ;;
        linux)
            if systemctl --user is-enabled agent-assistant.service &>/dev/null; then
                echo "enabled"
            else
                echo "disabled"
            fi
            ;;
        *)
            echo "unknown"
            ;;
    esac
}

update_app() {
    log "Updating application..."
    # For now, we'll just reinstall since we don't have git repo locally
    run clone_app
    run "$INSTALL_DIR/venv/bin/pip" install --upgrade rapidocr_onnxruntime Pillow
    run restart_service
    log "Update complete!"
}

toggle_autostart() {
    local current=$(check_autostart)
    if [[ "$current" == "enabled" ]]; then
        run disable_autostart
        log "Autostart disabled"
    else
        run enable_autostart
        log "Autostart enabled"
    fi
}

enable_autostart() {
    configure_autostart true
}

disable_autostart() {
    case "$PLATFORM" in
        darwin)
            local plist="$HOME/Library/LaunchAgents/com.agent.assistant.plist"
            run launchctl unload "$plist" 2>/dev/null || true
            rm -f "$plist"
            ;;
        linux)
    run systemctl --user stop agent-assistant.service 2>/dev/null || true
    run systemctl --user disable agent-assistant.service 2>/dev/null || true
            rm -f "$HOME/.config/systemd/user/agent-assistant.service"
            run systemctl --user daemon-reload
            ;;
    esac
}

restart_service() {
    case "$PLATFORM" in
        darwin)
    run launchctl stop com.agent.assistant 2>/dev/null || true
    run launchctl start com.agent.assistant 2>/dev/null || true
            ;;
        linux)
            run systemctl --user restart agent-assistant.service 2>/dev/null || true
            ;;
    esac
}

upgrade_python() {
    local backup_dir="$INSTALL_DIR/python_backup_$(date +%s)"
    log "Backing up current Python to $backup_dir..."
    run cp -r "$INSTALL_DIR/python" "$backup_dir"
    
    log "Upgrading Python..."
    rm -rf "$INSTALL_DIR/python"
    
    if run download_python && run create_venv && run install_deps; then
        run rm -rf "$backup_dir"
        log "Python upgrade successful!"
        run restart_service
    else
        log "Python upgrade failed, restoring backup..."
    run rm -rf "$INSTALL_DIR/python"
        run mv "$backup_dir" "$INSTALL_DIR/python"
        err "Python upgrade failed, restored to previous version"
    fi
}

uninstall() {
    read -rp "Are you sure you want to uninstall? This will remove all data. [y/N]: " confirm
    [[ "${confirm,,}" != "y" ]] && return
    
    log "Uninstalling..."
    disable_autostart
    run rm -rf "$INSTALL_DIR"
    run rm -rf /tmp/clipboard
    
    # Remove alias from shell configs
    for config in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [[ -f "$config" ]]; then
            sed -i.bak '/# Agent Assistant CLI/,+2d' "$config"
        fi
    done
    
    log "Uninstallation complete!"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    detect_platform
    
    # Check if already installed
    if [[ -d "$INSTALL_DIR/python/bin/python" ]]; then
        show_menu
        exit 0
    fi
    
    # Fresh installation
    echo "📋 Agent Assistant Installer"
    echo "────────────────────────────────"
    echo "Platform:   $PLATFORM/$ARCH"
    echo "Python:     $PYTHON_VERSION (standalone)"
    echo ""
    
    read -rp "Enable autostart? [Y/n]: " enable_autostart
    enable_autostart=${enable_autostart:-Y}
    # Convert to lowercase manually for compatibility
    enable_autostart_lower=$(echo "$enable_autostart" | tr '[:upper:]' '[:lower:]')
    [[ "$enable_autostart_lower" =~ ^(y|yes)$ ]] && enable_autostart=true || enable_autostart=false
    
    # Execute installation steps
    download_python
    create_venv
    install_deps
    clone_app
    configure_autostart "$enable_autostart"
    setup_alias
    
    echo ""
    echo "✅ Installation complete!"
    echo ""
    echo "  → http://localhost:$DEFAULT_PORT"
    echo "  → Run 'source ~/.bashrc' or '~/.zshrc' to use 'agent-assistant' command"
    echo "  → For advanced management, re-run this installer"
}

# Run main if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi