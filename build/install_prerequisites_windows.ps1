#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Installs build prerequisites for custom Chromium on Windows.
.DESCRIPTION
    Installs:
      - Visual Studio 2022 Build Tools (with required components)
      - Windows SDK 10.0.22621
      - depot_tools (Google's Chromium build toolchain)
      - Python 3 (required by depot_tools/GN)
      - Git for Windows
    Run once before running build_chromium_windows.ps1.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DEPOT_TOOLS_DIR = "C:\depot_tools"

# --- Helper ------------------------------------------------------------------
function Write-Step { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Check-Command { param([string]$cmd) return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }

# --- 1. Git ------------------------------------------------------------------
Write-Step "Checking Git"
if (-not (Check-Command "git")) {
    Write-Host "  Installing Git for Windows via winget..."
    winget install --id Git.Git -e --source winget --silent
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
}
git --version

# --- 2. Python 3 -------------------------------------------------------------
Write-Step "Checking Python 3"
if (-not (Check-Command "python3") -and -not (Check-Command "python")) {
    Write-Host "  Installing Python 3.11 via winget..."
    winget install --id Python.Python.3.11 -e --source winget --silent
    $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("PATH","User")
}
python --version

# --- 3. Visual Studio 2022 Build Tools ---------------------------------------
Write-Step "Checking Visual Studio 2022 Build Tools"
$vsInstallPath  = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools"
$vsInstallPath2 = "C:\Program Files\Microsoft Visual Studio\2022\Community"
$vsInstallPath3 = "C:\Program Files\Microsoft Visual Studio\2022\Enterprise"
$vsInstallPath4 = "C:\Program Files\Microsoft Visual Studio\2022\Professional"

$vsFound = (Test-Path $vsInstallPath)  -or (Test-Path $vsInstallPath2) -or
           (Test-Path $vsInstallPath3) -or (Test-Path $vsInstallPath4)

if (-not $vsFound) {
    Write-Host "  Downloading VS 2022 Build Tools installer..."
    $vsUrl = "https://aka.ms/vs/17/release/vs_buildtools.exe"
    $vsInstaller = "$env:TEMP\vs_buildtools.exe"
    Invoke-WebRequest -Uri $vsUrl -OutFile $vsInstaller

    Write-Host "  Installing VS 2022 Build Tools (this may take 10-20 minutes)..."
    # Required workloads for Chromium:
    #   Microsoft.VisualStudio.Workload.VCTools
    #   Microsoft.VisualStudio.Component.Windows10SDK.22621
    #   Microsoft.VisualStudio.Component.VC.ATL
    Start-Process -FilePath $vsInstaller -Wait -ArgumentList @(
        "--quiet", "--wait", "--norestart",
        "--add", "Microsoft.VisualStudio.Workload.VCTools",
        "--add", "Microsoft.VisualStudio.Component.Windows10SDK.22621",
        "--add", "Microsoft.VisualStudio.Component.VC.ATL",
        "--add", "Microsoft.VisualStudio.Component.VC.ATLMFC",
        "--add", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "--includeRecommended"
    )
    Remove-Item $vsInstaller -Force
} else {
    Write-Host "  Visual Studio 2022 already present."
}

# --- 4. depot_tools ----------------------------------------------------------
Write-Step "Installing depot_tools to $DEPOT_TOOLS_DIR"
if (-not (Test-Path $DEPOT_TOOLS_DIR)) {
    git clone "https://chromium.googlesource.com/chromium/tools/depot_tools.git" $DEPOT_TOOLS_DIR
} else {
    Write-Host "  depot_tools already present, updating..."
    Push-Location $DEPOT_TOOLS_DIR
    git pull --ff-only
    Pop-Location
}

# Add depot_tools to PATH for this session and permanently.
if ($env:PATH -notlike "*$DEPOT_TOOLS_DIR*") {
    $env:PATH = "$DEPOT_TOOLS_DIR;$env:PATH"
    [System.Environment]::SetEnvironmentVariable(
        "PATH",
        "$DEPOT_TOOLS_DIR;" + [System.Environment]::GetEnvironmentVariable("PATH","Machine"),
        "Machine"
    )
}

# Required depot_tools env vars for Windows.
[System.Environment]::SetEnvironmentVariable("DEPOT_TOOLS_WIN_TOOLCHAIN", "0", "Machine")
$env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"

# --- 5. Verify gclient -------------------------------------------------------
Write-Step "Verifying gclient"
gclient --version

Write-Host "`n[OK] All prerequisites installed." -ForegroundColor Green
Write-Host "     Open a NEW terminal and run: .\build\build_chromium_windows.ps1" -ForegroundColor Green
