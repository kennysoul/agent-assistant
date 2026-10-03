#!/usr/bin/env bash
# Agent Assistant Installer
# Recommended (keeps stdin as your terminal; no local .sh file):
#   bash <(curl -sSL https://raw.githubusercontent.com/kennysoul/agent-assistant/main/install.sh)
# Avoid: curl ... | bash  (stdin is the script stream, interactive prompts break)

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

# Interactive prompts must use the real terminal when the script is piped
# (curl ... | bash), because stdin is the script stream, not the keyboard.
read_input() {
    local prompt=$1
    local __var=$2
    local reply=""
    if [[ -t 0 ]]; then
        read -rp "$prompt" reply
    elif [[ -r /dev/tty ]]; then
        read -rp "$prompt" reply </dev/tty
    else
        err "No interactive terminal available for prompts. Run: bash install.sh"
    fi
    printf -v "$__var" '%s' "$reply"
}

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
# Prefer systemd --user; fall back to system service when root or no user bus.
systemd_scope() {
    if [[ "$(id -u)" -eq 0 ]]; then
        echo "system"
        return
    fi
    if [[ -n "${XDG_RUNTIME_DIR:-}" ]] && systemctl --user show-environment &>/dev/null; then
        echo "user"
        return
    fi
    echo "system"
}

systemd_ctl() {
    if [[ "$(systemd_scope)" == "system" ]]; then
        if [[ "$(id -u)" -eq 0 ]]; then
            systemctl "$@"
        else
            sudo systemctl "$@"
        fi
    else
        systemctl --user "$@"
    fi
}

write_systemd_unit() {
    local unit_file="$1"
    local wanted_by="$2"
    local user_lines=""
    # System units installed by a non-root user should run as that user.
    if [[ "$(systemd_scope)" == "system" ]] && [[ "$(id -u)" -ne 0 ]]; then
        user_lines="User=$(id -un)
Group=$(id -gn)"
    fi

    local content
    content=$(cat << EOF
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
${user_lines}

[Install]
WantedBy=${wanted_by}
EOF
)

    if [[ "$(id -u)" -ne 0 ]] && [[ "$unit_file" == /etc/* ]]; then
        printf '%s\n' "$content" | sudo tee "$unit_file" >/dev/null
    else
        mkdir -p "$(dirname "$unit_file")"
        printf '%s\n' "$content" > "$unit_file"
    fi
}

configure_autostart() {
    local enable=${1:-true}
    local boot_without_login=${2:-}
    [[ "$enable" != "true" ]] && return
    
    case "$PLATFORM" in
        darwin)
            configure_launchd "$boot_without_login"
            ;;
        linux)
            configure_systemd
            ;;
    esac
}

# Ask when not pre-answered (menu enable path).
ask_launchd_boot_without_login() {
    local answer
    read_input "Start at boot without login (LaunchDaemon, needs sudo)? [y/N]: " answer
    answer=$(echo "${answer:-N}" | tr '[:upper:]' '[:lower:]')
    [[ "$answer" =~ ^(y|yes)$ ]] && echo "true" || echo "false"
}

write_launchd_plist() {
    local plist_path="$1"
    local as_daemon="$2"
    local user_keys=""

    if [[ "$as_daemon" == "true" ]] && [[ "$(id -u)" -ne 0 ]]; then
        user_keys="
    <key>UserName</key>
    <string>$(id -un)</string>
    <key>GroupName</key>
    <string>$(id -gn)</string>"
    fi

    local content
    content=$(cat << EOF
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
    <string>$INSTALL_DIR/app</string>${user_keys}
</dict>
</plist>
EOF
)

    if [[ "$as_daemon" == "true" ]]; then
        if [[ "$(id -u)" -eq 0 ]]; then
            printf '%s\n' "$content" > "$plist_path"
            chown root:wheel "$plist_path"
            chmod 644 "$plist_path"
        else
            printf '%s\n' "$content" | sudo tee "$plist_path" >/dev/null
            sudo chown root:wheel "$plist_path"
            sudo chmod 644 "$plist_path"
        fi
    else
        mkdir -p "$(dirname "$plist_path")"
        printf '%s\n' "$content" > "$plist_path"
        chmod 644 "$plist_path"
    fi
}

launchd_load_agent() {
    local plist="$1"
    if launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null; then
        return 0
    fi
    run launchctl unload "$plist" 2>/dev/null || true
    run launchctl load "$plist"
}

launchd_load_daemon() {
    local plist="$1"
    if [[ "$(id -u)" -eq 0 ]]; then
        if launchctl bootstrap system "$plist" 2>/dev/null; then
            return 0
        fi
        run launchctl unload "$plist" 2>/dev/null || true
        run launchctl load "$plist"
    else
        if sudo launchctl bootstrap system "$plist" 2>/dev/null; then
            return 0
        fi
        run sudo launchctl unload "$plist" 2>/dev/null || true
        run sudo launchctl load "$plist"
    fi
}

launchd_unload_agent() {
    local plist="$HOME/Library/LaunchAgents/com.agent.assistant.plist"
    [[ -f "$plist" ]] || return 0
    launchctl bootout "gui/$(id -u)/com.agent.assistant" 2>/dev/null || true
    launchctl unload "$plist" 2>/dev/null || true
    rm -f "$plist"
}

launchd_unload_daemon() {
    local plist="/Library/LaunchDaemons/com.agent.assistant.plist"
    [[ -f "$plist" ]] || return 0
    if [[ "$(id -u)" -eq 0 ]]; then
        launchctl bootout system/com.agent.assistant 2>/dev/null || true
        launchctl unload "$plist" 2>/dev/null || true
        rm -f "$plist"
    else
        sudo launchctl bootout system/com.agent.assistant 2>/dev/null || true
        sudo launchctl unload "$plist" 2>/dev/null || true
        sudo rm -f "$plist"
    fi
}

configure_launchd() {
    local boot_without_login=${1:-}
    if [[ -z "$boot_without_login" ]]; then
        boot_without_login="$(ask_launchd_boot_without_login)"
    fi

    # Only one domain at a time.
    launchd_unload_agent
    launchd_unload_daemon

    if [[ "$boot_without_login" == "true" ]]; then
        local plist="/Library/LaunchDaemons/com.agent.assistant.plist"
        write_launchd_plist "$plist" "true"
        launchd_load_daemon "$plist"
        log "Configured LaunchDaemon autostart (boot without login)"
    else
        local plist="$HOME/Library/LaunchAgents/com.agent.assistant.plist"
        write_launchd_plist "$plist" "false"
        launchd_load_agent "$plist"
        log "Configured LaunchAgent autostart (after user login)"
    fi
}

configure_systemd() {
    local scope
    scope="$(systemd_scope)"
    local unit_file wanted_by

    if [[ "$scope" == "system" ]]; then
        unit_file="/etc/systemd/system/agent-assistant.service"
        wanted_by="multi-user.target"
        log "No systemd user bus (or running as root) — using system service"
    else
        unit_file="$HOME/.config/systemd/user/agent-assistant.service"
        wanted_by="default.target"
    fi

    write_systemd_unit "$unit_file" "$wanted_by"
    run systemd_ctl daemon-reload
    run systemd_ctl enable --now agent-assistant.service
    log "Configured systemd autostart ($scope)"
}

# ── Alias / manager script ────────────────────────────────────────────────────
install_manager_script() {
    mkdir -p "$INSTALL_DIR"
    local src="${BASH_SOURCE[0]:-}"
    if [[ -n "$src" && -f "$src" && -r "$src" ]]; then
        cp "$src" "$INSTALL_DIR/install.sh"
    else
        run curl -sSL "$REPO_URL/raw/main/install.sh" -o "$INSTALL_DIR/install.sh"
    fi
    chmod +x "$INSTALL_DIR/install.sh"
    log "Installed manager script: $INSTALL_DIR/install.sh"
}

setup_alias() {
    local shell_config=""
    case "${SHELL##*/}" in
        bash) shell_config="$HOME/.bashrc" ;;
        zsh) shell_config="$HOME/.zshrc" ;;
        *) log "Unsupported shell for alias setup: $SHELL" ; return ;;
    esac

    install_manager_script

    local alias_line="alias agent-assistant='bash \"$INSTALL_DIR/install.sh\"'"

    if [[ -f "$shell_config" ]]; then
        # Replace any previous alias / marker block.
        sed -i.bak '/# Agent Assistant CLI/,+1d' "$shell_config" 2>/dev/null || true
        sed -i.bak '/alias agent-assistant=/d' "$shell_config" 2>/dev/null || true
    fi

    {
        echo ""
        echo "# Agent Assistant CLI"
        echo "$alias_line"
    } >> "$shell_config"

    log "Added alias to $shell_config (opens management menu)"
    log "Run 'source $shell_config' or restart your terminal to use 'agent-assistant'"
}

# ── Listen / allowlist config ─────────────────────────────────────────────────
# Default: bind 0.0.0.0; allow localhost + private LAN.
# 127.0.0.1 / ::1 can never be removed from the allowlist.
LISTEN_CONF="$INSTALL_DIR/listen.conf"
DEFAULT_BIND_HOSTS="0.0.0.0"
DEFAULT_ALLOW="127.0.0.1/32,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"

_valid_ip_or_cidr() {
    local value=$1
    if [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
        return 0
    fi
    if [[ "$value" =~ ^::1(/128)?$ ]]; then
        return 0
    fi
    return 1
}

normalize_bind_hosts() {
    local raw=${1:-$DEFAULT_BIND_HOSTS}
    local -a result=()
    local part host h

    if [[ -z "$raw" ]]; then
        echo "$DEFAULT_BIND_HOSTS"
        return
    fi

    local -a parts=()
    IFS=',' read -ra parts <<< "$raw"
    for part in "${parts[@]}"; do
        host=$(echo "$part" | tr -d '[:space:]')
        [[ -z "$host" ]] && continue
        if [[ "$host" != "0.0.0.0" && ! "$host" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            err "Invalid bind address: $host"
        fi
        local exists=false
        for h in "${result[@]+"${result[@]}"}"; do
            [[ "$h" == "$host" ]] && exists=true && break
        done
        [[ "$exists" == "true" ]] || result+=("$host")
    done

    if [[ ${#result[@]} -eq 0 ]]; then
        echo "$DEFAULT_BIND_HOSTS"
        return
    fi

    local has_all=false
    for h in "${result[@]}"; do
        [[ "$h" == "0.0.0.0" ]] && has_all=true && break
    done
    if [[ "$has_all" == "true" ]]; then
        echo "$DEFAULT_BIND_HOSTS"
        return
    fi

    local has_local=false
    for h in "${result[@]}"; do
        [[ "$h" == "127.0.0.1" ]] && has_local=true && break
    done
    [[ "$has_local" == "true" ]] || result=("127.0.0.1" "${result[@]}")

    local IFS=','
    echo "${result[*]}"
}

normalize_allow() {
    local raw=${1:-}
    local -a result=()
    local part item h

    # Start from defaults, then append extras.
    IFS=',' read -ra result <<< "$DEFAULT_ALLOW"

    if [[ -n "$raw" ]]; then
        local -a parts=()
        IFS=',' read -ra parts <<< "$raw"
        for part in "${parts[@]}"; do
            item=$(echo "$part" | tr -d '[:space:]')
            [[ -z "$item" ]] && continue
            if ! _valid_ip_or_cidr "$item"; then
                err "Invalid allow IP/CIDR: $item"
            fi
            local exists=false
            for h in "${result[@]+"${result[@]}"}"; do
                [[ "$h" == "$item" ]] && exists=true && break
            done
            [[ "$exists" == "true" ]] || result+=("$item")
        done
    fi

    # Force localhost entries first.
    local -a forced=("127.0.0.1/32" "::1/128")
    local -a final=()
    for item in "${forced[@]}" "${result[@]+"${result[@]}"}"; do
        local exists=false
        for h in "${final[@]+"${final[@]}"}"; do
            [[ "$h" == "$item" ]] && exists=true && break
        done
        [[ "$exists" == "true" ]] || final+=("$item")
    done

    local IFS=','
    echo "${final[*]}"
}

ask_listen_config() {
    local extra_allow bind_hosts
    echo "Default access: localhost + private LAN (10/8, 172.16/12, 192.168/16)" >&2
    echo "Default listen: all interfaces (0.0.0.0)" >&2
    read_input "Extra allowed IPs/CIDRs (optional, e.g. 203.0.113.10 or 192.168.111.0/24): " extra_allow
    read_input "Listen bind addresses [${DEFAULT_BIND_HOSTS}]: " bind_hosts
    bind_hosts=$(normalize_bind_hosts "${bind_hosts:-$DEFAULT_BIND_HOSTS}")
    local allow
    allow=$(normalize_allow "$extra_allow")
    printf '%s\n%s\n' "$bind_hosts" "$allow"
}

write_listen_conf() {
    local hosts=${1:-$DEFAULT_BIND_HOSTS}
    local allow=${2:-$DEFAULT_ALLOW}
    mkdir -p "$INSTALL_DIR"
    cat > "$LISTEN_CONF" << EOF
# Agent Assistant listen config
# hosts: bind addresses (0.0.0.0 = all interfaces)
# allow: client IP/CIDR allowlist (127.0.0.1 and ::1 are always forced by the server)
hosts=${hosts}
allow=${allow}
port=${DEFAULT_PORT}
EOF
    log "Wrote listen config: $LISTEN_CONF"
    log "  bind:  $hosts:$DEFAULT_PORT"
    log "  allow: $allow"
}

current_bind_hosts() {
    if [[ -f "$LISTEN_CONF" ]]; then
        local line
        line=$(grep -E '^[[:space:]]*hosts=' "$LISTEN_CONF" | tail -1 | cut -d= -f2- | tr -d '[:space:]')
        if [[ -n "$line" ]]; then
            normalize_bind_hosts "$line"
            return
        fi
    fi
    echo "$DEFAULT_BIND_HOSTS"
}

current_allow() {
    if [[ -f "$LISTEN_CONF" ]]; then
        local line
        line=$(grep -E '^[[:space:]]*allow=' "$LISTEN_CONF" | tail -1 | cut -d= -f2- | tr -d '[:space:]')
        if [[ -n "$line" ]]; then
            echo "$line"
            return
        fi
    fi
    echo "$DEFAULT_ALLOW"
}

configure_listen_addresses() {
    echo "Current bind:  $(current_bind_hosts):$DEFAULT_PORT"
    echo "Current allow: $(current_allow)"
    local hosts allow
    local cfg
    cfg="$(ask_listen_config)"
    hosts=$(printf '%s\n' "$cfg" | sed -n '1p')
    allow=$(printf '%s\n' "$cfg" | sed -n '2p')
    write_listen_conf "$hosts" "$allow"
    run restart_service
    log "Network access updated. Restarted service if running."
}

# ── Menu Functions ────────────────────────────────────────────────────────────
show_menu() {
    echo ""
    echo "📋 Agent Assistant already installed"
    echo "   Location:     $INSTALL_DIR"
    echo "   Python:       $PYTHON_VERSION"
    echo "   Autostart:    $(check_autostart)"
    echo "   Bind:         $(current_bind_hosts):$DEFAULT_PORT"
    echo "   Allow:        $(current_allow)"
    echo ""
    echo "What would you like to do?"
    echo "  1. Update (pull latest code + upgrade packages)"
    echo "  2. Toggle autostart"
    echo "  3. Configure network access"
    echo "  4. Upgrade Python"
    echo "  5. Run server in foreground"
    echo "  6. Repair shell alias (agent-assistant → this menu)"
    echo "  7. Uninstall completely"
    echo "  8. Exit"
    echo ""
    
    read_input "Choose an option [1-8]: " choice
    case "$choice" in
        1) update_app ;;
        2) toggle_autostart ;;
        3) configure_listen_addresses ;;
        4) upgrade_python ;;
        5) run_foreground ;;
        6) setup_alias ;;
        7) uninstall ;;
        8) exit 0 ;;
        *) echo "Invalid option"; show_menu ;;
    esac
}

run_foreground() {
    log "Starting server in foreground (Ctrl+C to stop)..."
    exec "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/app/server.py"
}

check_autostart() {
    case "$PLATFORM" in
        darwin)
            if launchctl print "system/com.agent.assistant" &>/dev/null \
                || [[ -f /Library/LaunchDaemons/com.agent.assistant.plist ]]; then
                echo "enabled (boot)"
            elif launchctl print "gui/$(id -u)/com.agent.assistant" &>/dev/null \
                || [[ -f "$HOME/Library/LaunchAgents/com.agent.assistant.plist" ]]; then
                echo "enabled (login)"
            else
                echo "disabled"
            fi
            ;;
        linux)
            if systemd_ctl is-enabled agent-assistant.service &>/dev/null; then
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
    install_manager_script
    run restart_service
    log "Update complete!"
}

toggle_autostart() {
    local current=$(check_autostart)
    if [[ "$current" != "disabled" ]]; then
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
            launchd_unload_agent
            launchd_unload_daemon
            ;;
        linux)
            # Clean both scopes in case a previous install left the other behind.
            systemctl --user stop agent-assistant.service 2>/dev/null || true
            systemctl --user disable agent-assistant.service 2>/dev/null || true
            rm -f "$HOME/.config/systemd/user/agent-assistant.service"
            systemctl --user daemon-reload 2>/dev/null || true

            if [[ "$(id -u)" -eq 0 ]]; then
                systemctl stop agent-assistant.service 2>/dev/null || true
                systemctl disable agent-assistant.service 2>/dev/null || true
                rm -f /etc/systemd/system/agent-assistant.service
                systemctl daemon-reload 2>/dev/null || true
            else
                sudo systemctl stop agent-assistant.service 2>/dev/null || true
                sudo systemctl disable agent-assistant.service 2>/dev/null || true
                sudo rm -f /etc/systemd/system/agent-assistant.service
                sudo systemctl daemon-reload 2>/dev/null || true
            fi
            ;;
    esac
}

restart_service() {
    case "$PLATFORM" in
        darwin)
            if [[ -f /Library/LaunchDaemons/com.agent.assistant.plist ]]; then
                if [[ "$(id -u)" -eq 0 ]]; then
                    run launchctl kickstart -k system/com.agent.assistant 2>/dev/null \
                        || { run launchctl stop com.agent.assistant 2>/dev/null || true
                             run launchctl start com.agent.assistant 2>/dev/null || true; }
                else
                    run sudo launchctl kickstart -k system/com.agent.assistant 2>/dev/null \
                        || { run sudo launchctl stop com.agent.assistant 2>/dev/null || true
                             run sudo launchctl start com.agent.assistant 2>/dev/null || true; }
                fi
            else
                run launchctl kickstart -k "gui/$(id -u)/com.agent.assistant" 2>/dev/null \
                    || { run launchctl stop com.agent.assistant 2>/dev/null || true
                         run launchctl start com.agent.assistant 2>/dev/null || true; }
            fi
            ;;
        linux)
            run systemd_ctl restart agent-assistant.service 2>/dev/null || true
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
    local confirm
    read_input "Are you sure you want to uninstall? This will remove all data. [y/N]: " confirm
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
    if [[ -x "$INSTALL_DIR/python/bin/python" ]]; then
        show_menu
        exit 0
    fi
    
    # Fresh installation
    echo "📋 Agent Assistant Installer"
    echo "────────────────────────────────"
    echo "Platform:   $PLATFORM/$ARCH"
    echo "Python:     $PYTHON_VERSION (standalone)"
    echo ""
    
    read_input "Enable autostart? [Y/n]: " enable_autostart
    enable_autostart=${enable_autostart:-Y}
    # Convert to lowercase manually for compatibility
    enable_autostart_lower=$(echo "$enable_autostart" | tr '[:upper:]' '[:lower:]')
    [[ "$enable_autostart_lower" =~ ^(y|yes)$ ]] && enable_autostart=true || enable_autostart=false

    local boot_without_login=""
    if [[ "$enable_autostart" == "true" && "$PLATFORM" == "darwin" ]]; then
        boot_without_login="$(ask_launchd_boot_without_login)"
    fi

    local listen_hosts listen_allow
    local listen_cfg
    listen_cfg="$(ask_listen_config)"
    listen_hosts=$(printf '%s\n' "$listen_cfg" | sed -n '1p')
    listen_allow=$(printf '%s\n' "$listen_cfg" | sed -n '2p')
    
    # Execute installation steps
    download_python
    create_venv
    install_deps
    clone_app
    write_listen_conf "$listen_hosts" "$listen_allow"
    configure_autostart "$enable_autostart" "$boot_without_login"
    setup_alias
    
    echo ""
    echo "✅ Installation complete!"
    echo ""
    echo "  → http://127.0.0.1:$DEFAULT_PORT"
    echo "  → LAN / private networks allowed by default"
    if [[ "$listen_hosts" == "0.0.0.0" ]]; then
        echo "  → Bound on all interfaces ($listen_hosts:$DEFAULT_PORT)"
    else
        local host
        IFS=',' read -ra _hosts <<< "$listen_hosts"
        for host in "${_hosts[@]}"; do
            echo "  → http://${host}:$DEFAULT_PORT"
        done
    fi
    echo "  → Run 'source ~/.zshrc' (or ~/.bashrc), then 'agent-assistant' for the management menu"
    echo "  → Or: bash \"$INSTALL_DIR/install.sh\""
}

# Run main if script is executed directly
main "$@"