#!/usr/bin/env python3
"""
Agent Assistant CLI Tool
Provides commands to manage the Agent Assistant service.
"""

import os
import sys
import subprocess
import platform
import shutil
from pathlib import Path

# Configuration
INSTALL_DIR = Path.home() / "opt" / "agent-assistant"
DEFAULT_PORT = 9191

def log(message):
    print(f"[{sys.argv[0]}] {message}")

def err(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)

def get_platform():
    return platform.system().lower()

def is_installed():
    return (INSTALL_DIR / "python" / "bin" / "python").exists() or \
           (INSTALL_DIR / "python" / "python.exe").exists()

def check_autostart():
    plat = get_platform()
    if plat == "darwin":
        try:
            result = subprocess.run(["launchctl", "list"], capture_output=True, text=True)
            return "com.agent.assistant" in result.stdout
        except:
            return False
    elif plat == "linux":
        try:
            result = subprocess.run(["systemctl", "--user", "is-enabled", "agent-assistant.service"], 
                                  capture_output=True, text=True)
            return "enabled" in result.stdout
        except:
            return False
    elif plat == "windows":
        try:
            result = subprocess.run(["schtasks", "/query", "/tn", "AgentAssistant"], 
                                  capture_output=True, text=True, stderr=subprocess.DEVNULL)
            return "AgentAssistant" in result.stdout
        except:
            return False
    return False

def start_service():
    plat = get_platform()
    try:
        if plat == "darwin":
            subprocess.run(["launchctl", "start", "com.agent.assistant"], check=True)
        elif plat == "linux":
            subprocess.run(["systemctl", "--user", "start", "agent-assistant.service"], check=True)
        elif plat == "windows":
            subprocess.run(["schtasks", "/run", "/tn", "AgentAssistant"], check=True)
        log("Service started")
    except subprocess.CalledProcessError as e:
        err(f"Failed to start service: {e}")

def stop_service():
    plat = get_platform()
    try:
        if plat == "darwin":
            subprocess.run(["launchctl", "stop", "com.agent.assistant"], check=True)
        elif plat == "linux":
            subprocess.run(["systemctl", "--user", "stop", "agent-assistant.service"], check=True)
        elif plat == "windows":
            subprocess.run(["schtasks", "/end", "/tn", "AgentAssistant"], check=True)
        log("Service stopped")
    except subprocess.CalledProcessError as e:
        err(f"Failed to stop service: {e}")

def restart_service():
    stop_service()
    start_service()
    log("Service restarted")

def status():
    if not is_installed():
        log("Agent Assistant is not installed")
        return
    
    log("Agent Assistant Status:")
    log(f"  Location: {INSTALL_DIR}")
    log(f"  Autostart: {'enabled' if check_autostart() else 'disabled'}")
    
    # Try to check if service is running by accessing the port
    try:
        import urllib.request
        response = urllib.request.urlopen(f"http://localhost:{DEFAULT_PORT}", timeout=2)
        if response.status == 200:
            log(f"  Service: running on port {DEFAULT_PORT}")
        else:
            log(f"  Service: not responding (port {DEFAULT_PORT})")
    except:
        log(f"  Service: not running (port {DEFAULT_PORT})")

def update():
    log("Updating application...")
    
    # Download latest files
    import urllib.request
    try:
        urllib.request.urlretrieve("https://raw.githubusercontent.com/kennysoul/agent-assistant/main/server.py", 
                                 str(INSTALL_DIR / "app" / "server.py"))
        urllib.request.urlretrieve("https://raw.githubusercontent.com/kennysoul/agent-assistant/main/index.html", 
                                 str(INSTALL_DIR / "app" / "index.html"))
        
        # Upgrade packages
        venv_python = INSTALL_DIR / "venv" / "bin" / "python"
        if not venv_python.exists():
            venv_python = INSTALL_DIR / "venv" / "Scripts" / "python.exe"
            
        subprocess.run([str(venv_python), "-m", "pip", "install", "--upgrade", 
                       "rapidocr_onnxruntime", "Pillow"], check=True)
        
        restart_service()
        log("Update complete!")
    except Exception as e:
        err(f"Update failed: {e}")

def uninstall():
    confirm = input("Are you sure you want to uninstall? This will remove all data. [y/N]: ")
    if confirm.lower() != 'y':
        return
    
    log("Uninstalling...")
    
    # Stop service
    try:
        if get_platform() == "darwin":
            subprocess.run(["launchctl", "unload", str(Path.home() / "Library" / "LaunchAgents" / "com.agent.assistant.plist")], 
                          stderr=subprocess.DEVNULL)
        elif get_platform() == "linux":
            subprocess.run(["systemctl", "--user", "stop", "agent-assistant.service"], stderr=subprocess.DEVNULL)
            subprocess.run(["systemctl", "--user", "disable", "agent-assistant.service"], stderr=subprocess.DEVNULL)
        elif get_platform() == "windows":
            subprocess.run(["schtasks", "/delete", "/tn", "AgentAssistant", "/f"], stderr=subprocess.DEVNULL)
    except:
        pass
    
    # Remove files
    if INSTALL_DIR.exists():
        shutil.rmtree(INSTALL_DIR)
    
    # Remove data
    clipboard_dir = Path("/tmp/clipboard") if get_platform() != "windows" else Path(os.environ.get("TEMP", "")) / "clipboard"
    if clipboard_dir.exists():
        shutil.rmtree(clipboard_dir)
    
    log("Uninstallation complete!")

def main():
    if len(sys.argv) < 2:
        print("Agent Assistant CLI")
        print("Usage: agent-cli <command>")
        print("Commands:")
        print("  status     - Show service status")
        print("  start      - Start the service")
        print("  stop       - Stop the service")
        print("  restart    - Restart the service")
        print("  update     - Update to latest version")
        print("  uninstall  - Uninstall completely")
        return
    
    command = sys.argv[1]
    
    if command == "status":
        status()
    elif command == "start":
        start_service()
    elif command == "stop":
        stop_service()
    elif command == "restart":
        restart_service()
    elif command == "update":
        update()
    elif command == "uninstall":
        uninstall()
    else:
        err(f"Unknown command: {command}")

if __name__ == "__main__":
    main()