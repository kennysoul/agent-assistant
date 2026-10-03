# Agent Assistant Installer for Windows
# Usage: powershell -Command "iex (irm https://raw.githubusercontent.com/kennysoul/agent-assistant/main/install.ps1)"

param(
    [string]$InstallDir = "$env:USERPROFILE\opt\agent-assistant",
    [string]$PythonRelease = "20261001",
    [string]$PythonVersion = "3.14.8",
    [string]$RepoUrl = "https://github.com/kennysoul/agent-assistant"
)

$DEFAULT_PORT = 9191

function Write-Log {
    param([string]$Message)
    Write-Host "[$(Get-Date -Format "HH:mm:ss")] $Message"
}

function Write-ErrorAndExit {
    param([string]$Message)
    Write-Error $Message
    exit 1
}

# ── Platform Detection ────────────────────────────────────────────────────────
function Detect-Platform {
    $Arch = (Get-CimInstance Win32_Processor).Architecture
    switch ($Arch) {
        9 { $PyPlatform = "x86_64-pc-windows-msvc-shared" }  # x64
        12 { $PyPlatform = "aarch64-pc-windows-msvc-shared" } # ARM64
        default { Write-ErrorAndExit "Unsupported architecture: $Arch" }
    }
    
    # Construct URL with proper encoding for the plus sign
    $PythonUrl = "https://github.com/astral-sh/python-build-standalone/releases/download/${PythonRelease}/cpython-${PythonVersion}%2B${PythonRelease}-${PyPlatform}-install_only.zip"
    return $PyPlatform, $PythonUrl
}

# ── Installation Functions ────────────────────────────────────────────────────
function Download-Python {
    param([string]$PyPlatform, [string]$PythonUrl)
    
    Write-Log "Downloading Python ($PythonVersion)..."
    
    if (!(Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir | Out-Null }
    $TempZip = "$InstallDir\python_temp.zip"
    
    Invoke-WebRequest -Uri $PythonUrl -OutFile $TempZip
    Expand-Archive -Path $TempZip -DestinationPath "$InstallDir\python" -Force
    Remove-Item $TempZip
    Write-Log "Python installed to $InstallDir\python\"
}

function Create-Venv {
    Write-Log "Creating virtual environment..."
    & "$InstallDir\python\python.exe" -m venv "$InstallDir\venv"
    & "$InstallDir\venv\Scripts\python.exe" -m pip install --upgrade pip
}

function Install-Deps {
    Write-Log "Installing dependencies..."
    & "$InstallDir\venv\Scripts\python.exe" -m pip install rapidocr_onnxruntime Pillow
}

function Clone-App {
    Write-Log "Cloning application..."
    if (!(Test-Path "$InstallDir\app")) { New-Item -ItemType Directory -Path "$InstallDir\app" | Out-Null }
    
    Invoke-WebRequest -Uri "$RepoUrl/raw/main/server.py" -OutFile "$InstallDir\app\server.py"
    Invoke-WebRequest -Uri "$RepoUrl/raw/main/index.html" -OutFile "$InstallDir\app\index.html"
}

# ── Autostart Functions ───────────────────────────────────────────────────────
function Configure-Autostart {
    param([bool]$Enable = $true)
    
    if (!$Enable) { return }
    
    Configure-ScheduledTask
}

function Configure-ScheduledTask {
    $TaskName = "AgentAssistant"
    
    # Remove existing task
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    
    # Create new task
    $Action = New-ScheduledTaskAction -Execute "$InstallDir\venv\Scripts\python.exe" -Argument "$InstallDir\app\server.py" -WorkingDirectory "$InstallDir\app"
    $Trigger = New-ScheduledTaskTrigger -AtLogOn
    $Settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings -Principal $Principal | Out-Null
    Write-Log "Configured Scheduled Task autostart"
}

# ── Alias Functions ───────────────────────────────────────────────────────────
function Setup-Alias {
    $ProfilePath = $PROFILE
    if (!$ProfilePath) { 
        $ProfilePath = "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
    }
    
    $AliasLine = "Set-Alias -Name agent-assistant -Value '$InstallDir\venv\Scripts\python.exe'"
    
    if (!(Test-Path (Split-Path $ProfilePath))) {
        New-Item -ItemType Directory -Path (Split-Path $ProfilePath) | Out-Null
    }
    
    if (!(Select-String -Path $ProfilePath -Pattern $AliasLine -SimpleMatch -Quiet)) {
        Add-Content -Path $ProfilePath -Value ""
        Add-Content -Path $ProfilePath -Value "# Agent Assistant CLI"
        Add-Content -Path $ProfilePath -Value $AliasLine
        Write-Log "Added alias to $ProfilePath"
        Write-Log "Run 'Import-Module \$PROFILE' or restart PowerShell to use 'agent-assistant' command"
    } else {
        Write-Log "Alias already exists in $ProfilePath"
    }
}

# ── Menu Functions ────────────────────────────────────────────────────────────
function Show-Menu {
    Write-Host ""
    Write-Host "📋 Agent Assistant already installed"
    Write-Host "   Location:     $InstallDir"
    Write-Host "   Python:       $PythonVersion"
    Write-Host "   Autostart:    $(Check-Autostart)"
    Write-Host ""
    Write-Host "What would you like to do?"
    Write-Host "  1. Update (pull latest code + upgrade packages)"
    Write-Host "  2. Toggle autostart"
    Write-Host "  3. Upgrade Python"
    Write-Host "  4. Uninstall completely"
    Write-Host "  5. Exit"
    Write-Host ""
    
    $Choice = Read-Host "Choose an option [1-5]"
    switch ($Choice) {
        "1" { Update-App }
        "2" { Toggle-Autostart }
        "3" { Upgrade-Python }
        "4" { Uninstall }
        "5" { exit 0 }
        default { Write-Host "Invalid option"; Show-Menu }
    }
}

function Check-Autostart {
    try {
        $Task = Get-ScheduledTask -TaskName "AgentAssistant" -ErrorAction Stop
        if ($Task.State -eq "Ready") {
            return "enabled"
        } else {
            return "disabled"
        }
    } catch {
        return "disabled"
    }
}

function Update-App {
    Write-Log "Updating application..."
    Clone-App
    & "$InstallDir\venv\Scripts\python.exe" -m pip install --upgrade rapidocr_onnxruntime Pillow
    Restart-Service
    Write-Log "Update complete!"
}

function Toggle-Autostart {
    $Current = Check-Autostart
    if ($Current -eq "enabled") {
        Disable-Autostart
        Write-Log "Autostart disabled"
    } else {
        Enable-Autostart
        Write-Log "Autostart enabled"
    }
}

function Enable-Autostart {
    Configure-Autostart -Enable $true
}

function Disable-Autostart {
    Unregister-ScheduledTask -TaskName "AgentAssistant" -Confirm:$false -ErrorAction SilentlyContinue
}

function Restart-Service {
    Stop-ScheduledTask -TaskName "AgentAssistant" -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName "AgentAssistant" -ErrorAction SilentlyContinue
}

function Upgrade-Python {
    $BackupDir = "$InstallDir\python_backup_$(Get-Date -Format 'yyyyMMddHHmmss')"
    Write-Log "Backing up current Python to $BackupDir..."
    Move-Item "$InstallDir\python" $BackupDir
    
    try {
        $PyPlatformResult = Detect-Platform
        $PyPlatform = $PyPlatformResult[0]
        $PythonUrl = $PyPlatformResult[1]
        Download-Python -PyPlatform $PyPlatform -PythonUrl $PythonUrl
        Create-Venv
        Install-Deps
        Remove-Item $BackupDir -Recurse
        Write-Log "Python upgrade successful!"
        Restart-Service
    } catch {
        Write-Log "Python upgrade failed, restoring backup..."
        if (Test-Path "$InstallDir\python") { Remove-Item "$InstallDir\python" -Recurse }
        Move-Item $BackupDir "$InstallDir\python"
        Write-ErrorAndExit "Python upgrade failed, restored to previous version"
    }
}

function Uninstall {
    $Confirm = Read-Host "Are you sure you want to uninstall? This will remove all data. [y/N]"
    if ($Confirm -ne "y" -and $Confirm -ne "Y") { return }
    
    Write-Log "Uninstalling..."
    Disable-Autostart
    if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse }
    if (Test-Path "$env:TEMP\clipboard") { Remove-Item "$env:TEMP\clipboard" -Recurse }
    
    # Remove alias from profile
    $ProfilePath = $PROFILE
    if (!$ProfilePath) { 
        $ProfilePath = "$env:USERPROFILE\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1"
    }
    
    if (Test-Path $ProfilePath) {
        $Content = Get-Content $ProfilePath
        $NewContent = $Content | Where-Object { $_ -notmatch "# Agent Assistant CLI" -and $_ -notmatch "Set-Alias -Name agent-assistant" }
        Set-Content $ProfilePath $NewContent
    }
    
    Write-Log "Uninstallation complete!"
}

# ── Main ──────────────────────────────────────────────────────────────────────
function Main {
    $PyPlatformResult = Detect-Platform
    $PyPlatform = $PyPlatformResult[0]
    $PythonUrl = $PyPlatformResult[1]
    
    # Check if already installed
    if (Test-Path "$InstallDir\python\python.exe") {
        Show-Menu
        return
    }
    
    # Fresh installation
    Write-Host "📋 Agent Assistant Installer"
    Write-Host "────────────────────────────────"
    Write-Host "Platform:   Windows/$PyPlatform"
    Write-Host "Python:     $PythonVersion (standalone)"
    Write-Host ""
    
    $EnableAutostart = Read-Host "Enable autostart? [Y/n]"
    if ($EnableAutostart -eq "") { $EnableAutostart = "Y" }
    $EnableAutostart = $EnableAutostart -match "^[Yy]$"
    
    # Execute installation steps
    Download-Python -PyPlatform $PyPlatform -PythonUrl $PythonUrl
    Create-Venv
    Install-Deps
    Clone-App
    Configure-Autostart -Enable $EnableAutostart
    Setup-Alias
    
    Write-Host ""
    Write-Host "✅ Installation complete!"
    Write-Host ""
    Write-Host "  → http://localhost:$DEFAULT_PORT"
    Write-Host "  → Run 'Import-Module \$PROFILE' to use 'agent-assistant' command"
    Write-Host "  → For advanced management, re-run this installer"
}

# Run main
Main