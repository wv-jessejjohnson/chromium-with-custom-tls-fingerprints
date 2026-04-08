<#
.SYNOPSIS
    Fetches Chromium source, applies TLS fingerprint patches, and builds
    a custom chrome.exe for Windows x64.
.DESCRIPTION
    Steps performed:
      1. Verify prerequisites (depot_tools, MSVC)
      2. Determine Chromium revision compatible with the requested Playwright version
      3. Fetch Chromium source with gclient
      4. Apply patches from ../patches/
      5. Copy new source files from ../src/
      6. Generate build with GN
      7. Build with Ninja
      8. Copy output to ../dist/

    Estimated time:  first run ~3-5 h (source fetch + compile)
                     incremental ~20-40 min

.PARAMETER PlaywrightVersion
    Playwright Python package version to target (e.g. "1.44.0").
    Determines which Chromium revision to check out.
    Default: "1.44.0"

.PARAMETER BuildType
    "release" (default) or "debug".

.PARAMETER SourceDir
    Where to put the Chromium source checkout.
    Default: C:\chromium_src

.PARAMETER Jobs
    Number of parallel ninja jobs (default: number of logical processors).

.EXAMPLE
    .\build_chromium_windows.ps1 -PlaywrightVersion 1.44.0

.EXAMPLE
    .\build_chromium_windows.ps1 -BuildType debug -SourceDir D:\cr_src
#>

param(
    [string]$PlaywrightVersion = "1.44.0",
    [ValidateSet("release","debug")]
    [string]$BuildType = "release",
    [string]$SourceDir = "C:\chromium_src",
    [int]$Jobs = [Environment]::ProcessorCount
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SCRIPT_DIR   = Split-Path -Parent $MyInvocation.MyCommand.Path
$REPO_ROOT    = Split-Path -Parent $SCRIPT_DIR
$PATCHES_DIR  = Join-Path $REPO_ROOT "patches"
$SRC_DIR      = Join-Path $REPO_ROOT "src"
$DIST_DIR     = Join-Path $REPO_ROOT "dist"
$OUT_DIR      = Join-Path $SourceDir "src\out\CustomChromium"

# ── Helper ──────────────────────────────────────────────────────────────────
function Write-Step { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Fail       { param([string]$msg) Write-Host "FATAL: $msg" -ForegroundColor Red; exit 1 }

function Require-Command {
    param([string]$cmd, [string]$hint = "")
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        $h = if ($hint) { " ($hint)" } else { "" }
        Fail "$cmd not found$h. Run install_prerequisites_windows.ps1 first."
    }
}

# ── Playwright → Chromium revision table ─────────────────────────────────────
# Maps Playwright versions to the Chromium git revision (cr_rev) they bundle.
# Source: https://github.com/microsoft/playwright/blob/main/packages/playwright-core/browsers.json
$PLAYWRIGHT_CHROMIUM_REVISIONS = @{
    "1.44.0" = "1228965";  # Chromium 125.0.6422.14
    "1.43.0" = "1225249";  # Chromium 124.0.6367.78
    "1.42.0" = "1211"    ;  # Chromium 123.0.6312.4
    "1.41.0" = "1211"    ;
    "1.40.0" = "1204"    ;
}

# Chromium revision → branch/tag
$CHROMIUM_TAGS = @{
    "1228965" = "125.0.6422.14";
    "1225249" = "124.0.6367.78";
}

Write-Step "Configuration"
Write-Host "  Playwright version : $PlaywrightVersion"
Write-Host "  Build type         : $BuildType"
Write-Host "  Source directory   : $SourceDir"
Write-Host "  Output directory   : $OUT_DIR"
Write-Host "  Parallel jobs      : $Jobs"

# ── 1. Prerequisites ─────────────────────────────────────────────────────────
Write-Step "Checking prerequisites"
Require-Command "gclient"  "depot_tools"
Require-Command "git"
Require-Command "python"
if ($env:DEPOT_TOOLS_WIN_TOOLCHAIN -ne "0") {
    $env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
}

# ── 2. Determine Chromium version ────────────────────────────────────────────
Write-Step "Resolving Chromium version for Playwright $PlaywrightVersion"

# Try to read the revision from the installed playwright package first.
$playwrightBrowsersJson = $null
try {
    $pipShow = python -m pip show playwright 2>$null
    if ($pipShow) {
        $location = ($pipShow | Select-String "Location:") -replace "Location:\s*",""
        $browsersJson = Join-Path $location.Trim() "playwright\driver\package\browsers.json"
        if (Test-Path $browsersJson) {
            $playwrightBrowsersJson = Get-Content $browsersJson | ConvertFrom-Json
        }
    }
} catch {}

$chromiumRevision = $null
if ($playwrightBrowsersJson) {
    $chromiumEntry = $playwrightBrowsersJson.browsers | Where-Object { $_.name -eq "chromium" }
    if ($chromiumEntry) {
        $chromiumRevision = $chromiumEntry.revision
        Write-Host "  Found revision from installed Playwright: $chromiumRevision"
    }
}

if (-not $chromiumRevision) {
    $chromiumRevision = $PLAYWRIGHT_CHROMIUM_REVISIONS[$PlaywrightVersion]
    if (-not $chromiumRevision) {
        Write-Host "  WARNING: Unknown Playwright version, defaulting to revision 1225249 (Chromium 124)"
        $chromiumRevision = "1225249"
    }
    Write-Host "  Using revision from lookup table: $chromiumRevision"
}

# Resolve to a Chromium git tag/branch if available.
$chromiumTag = $CHROMIUM_TAGS[$chromiumRevision]
Write-Host "  Chromium tag       : $($chromiumTag ?? 'unknown (will use position)')"

# ── 3. Fetch Chromium source ─────────────────────────────────────────────────
Write-Step "Fetching Chromium source (this may take 30-60 min on first run)"

if (-not (Test-Path $SourceDir)) {
    New-Item -ItemType Directory -Path $SourceDir | Out-Null
}

Push-Location $SourceDir

# Write .gclient file if missing.
if (-not (Test-Path (Join-Path $SourceDir ".gclient"))) {
    Write-Host "  Writing .gclient configuration..."
    @"
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "custom_deps": {},
    "custom_vars": {},
  },
]
target_os = ["win"]
"@ | Set-Content ".gclient"
}

# Fetch or update.
if (-not (Test-Path (Join-Path $SourceDir "src"))) {
    Write-Host "  Running 'fetch chromium' (first run ~30-60 min)..."
    fetch chromium
    if ($LASTEXITCODE -ne 0) { Fail "'fetch chromium' failed" }
} else {
    Write-Host "  Source already present, updating..."
}

# Check out the specific revision.
Push-Location (Join-Path $SourceDir "src")
Write-Host "  Checking out Chromium for revision $chromiumRevision..."

# Use the Playwright revision directly (it maps to a chromium position).
if ($chromiumTag) {
    git fetch --tags origin "refs/tags/$chromiumTag" 2>&1 | Out-Null
    git checkout "refs/tags/$chromiumTag" 2>&1
} else {
    # Fall back to fetching by commit position (slower).
    git fetch origin 2>&1 | Out-Null
}

# Sync all dependencies (third_party, etc.).
Write-Host "  Running gclient sync (may take 20-40 min)..."
gclient sync --no-history --with_branch_heads --with_tags -D
if ($LASTEXITCODE -ne 0) { Fail "gclient sync failed" }

Pop-Location  # back to $SourceDir
Pop-Location  # back to original

# ── 4. Apply patches ─────────────────────────────────────────────────────────
Write-Step "Applying custom TLS fingerprint patches"
$chromiumSrcDir = Join-Path $SourceDir "src"

# ─ Chromium patches
$chromiumPatchDir = Join-Path $PATCHES_DIR "chromium"
Get-ChildItem -Path $chromiumPatchDir -Filter "*.patch" | Sort-Object Name | ForEach-Object {
    Write-Host "  Applying $($_.Name)..."
    Push-Location $chromiumSrcDir
    git apply --whitespace=fix $_.FullName
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: patch did not apply cleanly, trying with --reject..."
        git apply --reject --whitespace=fix $_.FullName
    }
    Pop-Location
}

# ─ BoringSSL patches
$boringsslPatchDir = Join-Path $PATCHES_DIR "boringssl"
$boringsslDir = Join-Path $chromiumSrcDir "third_party\boringssl\src"
if (Test-Path $boringsslDir) {
    Get-ChildItem -Path $boringsslPatchDir -Filter "*.patch" | Sort-Object Name | ForEach-Object {
        Write-Host "  Applying BoringSSL patch $($_.Name)..."
        Push-Location $boringsslDir
        git apply --whitespace=fix $_.FullName
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARNING: BoringSSL patch did not apply cleanly, trying --reject..."
            git apply --reject --whitespace=fix $_.FullName
        }
        Pop-Location
    }
}

# ── 5. Copy new source files ──────────────────────────────────────────────────
Write-Step "Copying new source files into Chromium tree"
$filesToCopy = @(
    @{ Src = "src\chromium\net\ssl\tls_fingerprint_config.h";
       Dst = "net\ssl\tls_fingerprint_config.h" },
    @{ Src = "src\chromium\net\ssl\tls_fingerprint_config.cc";
       Dst = "net\ssl\tls_fingerprint_config.cc" },
    @{ Src = "src\chromium\services\network\public\mojom\tls_fingerprint.mojom";
       Dst = "services\network\public\mojom\tls_fingerprint.mojom" }
)

foreach ($f in $filesToCopy) {
    $srcPath = Join-Path $REPO_ROOT $f.Src
    $dstPath = Join-Path $chromiumSrcDir $f.Dst
    $dstParent = Split-Path $dstPath -Parent
    if (-not (Test-Path $dstParent)) { New-Item -ItemType Directory -Path $dstParent | Out-Null }
    Write-Host "  $($f.Src) -> $($f.Dst)"
    Copy-Item $srcPath $dstPath -Force
}

# ── 6. Generate build ─────────────────────────────────────────────────────────
Write-Step "Generating build with GN"
Push-Location $chromiumSrcDir

$gnArgsFile = Join-Path $SCRIPT_DIR "gn_args\windows_$BuildType.gn"
if (-not (Test-Path $gnArgsFile)) {
    Fail "GN args file not found: $gnArgsFile"
}
$gnArgs = (Get-Content $gnArgsFile -Raw) -replace "`r`n","`n"

if (-not (Test-Path $OUT_DIR)) {
    New-Item -ItemType Directory -Path $OUT_DIR | Out-Null
}
Set-Content -Path (Join-Path $OUT_DIR "args.gn") -Value $gnArgs

gn gen $OUT_DIR
if ($LASTEXITCODE -ne 0) { Fail "gn gen failed" }

Pop-Location

# ── 7. Build with Ninja ───────────────────────────────────────────────────────
Write-Step "Building Chromium with Ninja ($Jobs jobs) — this takes 2-4 hours"
Push-Location $chromiumSrcDir

autoninja -C $OUT_DIR -j $Jobs chrome
if ($LASTEXITCODE -ne 0) { Fail "ninja build failed" }

Pop-Location

# ── 8. Copy outputs to dist/ ──────────────────────────────────────────────────
Write-Step "Copying outputs to $DIST_DIR"
if (-not (Test-Path $DIST_DIR)) { New-Item -ItemType Directory -Path $DIST_DIR | Out-Null }

$filesToDist = @(
    "chrome.exe",
    "chrome.dll",
    "chrome_elf.dll",
    "chrome_100_percent.pak",
    "chrome_200_percent.pak",
    "resources.pak",
    "icudtl.dat",
    "snapshot_blob.bin",
    "v8_context_snapshot.bin"
)

foreach ($f in $filesToDist) {
    $src = Join-Path $OUT_DIR $f
    if (Test-Path $src) {
        Write-Host "  Copying $f"
        Copy-Item $src $DIST_DIR -Force
    } else {
        Write-Host "  WARNING: $f not found in output, skipping"
    }
}

# Copy locales directory.
$localesDir = Join-Path $OUT_DIR "locales"
if (Test-Path $localesDir) {
    Copy-Item $localesDir (Join-Path $DIST_DIR "locales") -Recurse -Force
}

Write-Host "`n[SUCCESS] Build complete!" -ForegroundColor Green
Write-Host "  Chromium binary : $DIST_DIR\chrome.exe" -ForegroundColor Green
Write-Host ""
Write-Host "  Use with Playwright:"
Write-Host "    from playwright_tls import launch_browser"
Write-Host "    browser = await launch_browser(p, executable_path=r'$DIST_DIR\chrome.exe')"
