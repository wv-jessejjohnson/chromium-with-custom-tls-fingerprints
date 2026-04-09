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

# --- Helper ------------------------------------------------------------------
function Write-Step { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Fail       { param([string]$msg) Write-Host "FATAL: $msg" -ForegroundColor Red; exit 1 }

function Require-Command {
    param([string]$cmd, [string]$hint = "")
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        $h = if ($hint) { " ($hint)" } else { "" }
        Fail "$cmd not found$h. Run install_prerequisites_windows.ps1 first."
    }
}

# --- Playwright version -> Chromium version string table ---------------------
# Maps Playwright Python versions to the Chromium release tag they ship with.
# Used only when the installed playwright package cannot be queried.
# Source: https://github.com/microsoft/playwright/blob/main/packages/playwright-core/browsers.json
$PLAYWRIGHT_CHROMIUM_VERSIONS = @{
    "1.44.0" = "125.0.6422.14";
    "1.43.0" = "124.0.6367.78";
    "1.42.0" = "123.0.6312.58";
    "1.41.0" = "122.0.6261.128";
    "1.40.0" = "121.0.6167.57";
}

Write-Step "Configuration"
Write-Host "  Playwright version : $PlaywrightVersion"
Write-Host "  Build type         : $BuildType"
Write-Host "  Source directory   : $SourceDir"
Write-Host "  Output directory   : $OUT_DIR"
Write-Host "  Parallel jobs      : $Jobs"

# --- 1. Prerequisites --------------------------------------------------------
Write-Step "Checking prerequisites"
Require-Command "gclient"  "depot_tools"
Require-Command "git"
Require-Command "python"
if ($env:DEPOT_TOOLS_WIN_TOOLCHAIN -ne "0") {
    $env:DEPOT_TOOLS_WIN_TOOLCHAIN = "0"
}

# --- 2. Determine Chromium version -------------------------------------------
Write-Step "Resolving Chromium version for Playwright $PlaywrightVersion"

# Playwright's browsers.json contains a 'browserVersion' field with the exact
# Chromium release string (e.g. "124.0.6367.78").  That string is a git tag
# in the Chromium repo, so we can check it out directly.
# The 'revision' field is Playwright's own internal build counter -- it is NOT
# related to Chromium's commit positions and must NOT be used for git checkout.

$chromiumVersion = $null

try {
    $pipShow = python -m pip show playwright 2>$null
    if ($pipShow) {
        $location = ($pipShow | Select-String "Location:") -replace "Location:\s*",""
        $browsersJson = Join-Path $location.Trim() "playwright\driver\package\browsers.json"
        if (Test-Path $browsersJson) {
            $json = Get-Content $browsersJson -Raw | ConvertFrom-Json
            $entry = $json.browsers | Where-Object { $_.name -eq "chromium" }
            if ($entry) {
                # Try both field name spellings used across Playwright versions.
                if ($entry.browserVersion) {
                    $chromiumVersion = $entry.browserVersion
                } elseif ($entry.browser_version) {
                    $chromiumVersion = $entry.browser_version
                }
                if ($chromiumVersion) {
                    Write-Host "  Found Chromium version from installed Playwright: $chromiumVersion"
                }
            }
        }
    }
} catch {}

if (-not $chromiumVersion) {
    $chromiumVersion = $PLAYWRIGHT_CHROMIUM_VERSIONS[$PlaywrightVersion]
    if (-not $chromiumVersion) {
        Write-Host "  WARNING: Unknown Playwright version, defaulting to Chromium 124.0.6367.78"
        $chromiumVersion = "124.0.6367.78"
    }
    Write-Host "  Using Chromium version from lookup table: $chromiumVersion"
}

Write-Host "  Chromium version   : $chromiumVersion"

# --- 3. Fetch Chromium source ------------------------------------------------
Write-Step "Fetching Chromium source (this may take 30-60 min on first run)"

if (-not (Test-Path $SourceDir)) {
    New-Item -ItemType Directory -Path $SourceDir | Out-Null
}

Push-Location $SourceDir

# Write .gclient if not already present.
# NOTE: we do NOT call 'fetch chromium' because fetch refuses to run when
# .gclient already exists. We manage .gclient ourselves and drive everything
# through 'gclient sync', which is exactly what 'fetch' does internally.
$gclientPath = Join-Path $SourceDir ".gclient"
if (-not (Test-Path $gclientPath)) {
    Write-Host "  Writing .gclient configuration..."
    # Use Out-File with ASCII encoding to avoid BOM / encoding issues.
    $gclientContent = 'solutions = [' + "`n" +
        '  {' + "`n" +
        '    "name": "src",' + "`n" +
        '    "url": "https://chromium.googlesource.com/chromium/src.git",' + "`n" +
        '    "managed": False,' + "`n" +
        '    "custom_deps": {},' + "`n" +
        '    "custom_vars": {' + "`n" +
        '        # Ensure ANGLE and its deps (including spirv-tools) are fetched.' + "`n" +
        '        "checkout_angle": True,' + "`n" +
        '    },' + "`n" +
        '  },' + "`n" +
        ']' + "`n" +
        'target_os = ["win"]' + "`n"
    [System.IO.File]::WriteAllText($gclientPath, $gclientContent,
        [System.Text.Encoding]::ASCII)
}

$chromiumSrcDir = Join-Path $SourceDir "src"

if (-not (Test-Path $chromiumSrcDir)) {
    # Initial checkout: gclient sync fetches the full source tree.
    Write-Host "  Initial source fetch via gclient sync (~30-60 min, -j 4)..."
    $savedPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $syncOk = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        gclient sync --no-history --with_branch_heads --with_tags -j 4
        if ($LASTEXITCODE -eq 0) { $syncOk = $true; break }
        if ($attempt -lt 3) {
            Write-Host "  gclient sync failed (attempt $attempt/3). Waiting 90 s..."
            Start-Sleep -Seconds 90
        }
    }
    $ErrorActionPreference = $savedPref
    if (-not $syncOk) { Fail "gclient sync (initial) failed after 3 attempts" }
} else {
    Write-Host "  Source already present."
}

# Check out the specific Chromium release tag that matches Playwright.
# Chromium tags are exactly the version string, e.g. "141.0.7390.37".
Push-Location $chromiumSrcDir
Write-Host "  Checking out Chromium $chromiumVersion..."

# git always writes progress/info to stderr. With $ErrorActionPreference='Stop'
# at the top of this script, PS would turn those lines into terminating errors.
# Save and restore the preference around every git call.
$savedPref = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

# Fetch just the one tag we need.
Write-Host "  Fetching tag $chromiumVersion from origin (may take a few minutes)..."
git fetch origin tag $chromiumVersion
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Tag fetch returned non-zero; trying full tags fetch as fallback..."
    git fetch --tags origin
    # Ignore exit code -- the checkout below will confirm whether we have it.
}

# NOTE: Chromium has ~400 000 files. Checking out a tag rewrites every file
# that differs from the current HEAD. This can take 10-30 minutes on HDD,
# 5-15 minutes on SSD. The terminal will appear frozen -- that is normal.
Write-Host ""
Write-Host "  Running: git checkout refs/tags/$chromiumVersion"
Write-Host "  Chromium has ~400 000 files. This step takes 5-30 min -- please wait."
Write-Host ""
git checkout "refs/tags/$chromiumVersion"
$checkoutCode = $LASTEXITCODE

$ErrorActionPreference = $savedPref

if ($checkoutCode -ne 0) {
    Fail "git checkout refs/tags/$chromiumVersion failed (exit $checkoutCode)"
}
Write-Host "  Checked out Chromium $chromiumVersion."

Pop-Location  # back to $SourceDir (where .gclient lives -- gclient must run here)

# Sync dependencies for the checked-out revision (third_party, BoringSSL, etc.).
# -j 4 limits parallel fetches; the default (16+) often triggers Google's 429
# rate limit when syncing Chromium's 200+ dependencies at once.
# Retry up to 3 times with a 90-second wait for transient 429 / network errors.
Write-Host "  Syncing dependencies for checked-out revision (~20-40 min)..."
Write-Host "  (Using -j 4 to avoid Google server rate limits)"
$savedPref = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$syncOk = $false
for ($attempt = 1; $attempt -le 3; $attempt++) {
    gclient sync --no-history --with_branch_heads --with_tags -D -j 4
    if ($LASTEXITCODE -eq 0) { $syncOk = $true; break }
    if ($attempt -lt 3) {
        Write-Host "  gclient sync failed (attempt $attempt/3). Waiting 90 s before retry..."
        Write-Host "  (This is usually a transient 429 rate-limit from Google's servers.)"
        Start-Sleep -Seconds 90
    }
}
$ErrorActionPreference = $savedPref
if (-not $syncOk) { Fail "gclient sync failed after 3 attempts" }

# Verify that third_party/spirv-tools was synced.  It is required by the root
# BUILD.gn and is not always fetched on the first gclient sync attempt when the
# server returns 429 rate-limit errors for individual deps.
$spirvToolsDir = Join-Path $chromiumSrcDir "third_party\spirv-tools\src"
if (-not (Test-Path $spirvToolsDir)) {
    Write-Host "  third_party/spirv-tools not found - re-running gclient sync..."
    $savedPref = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $retrySyncOk = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        gclient sync --no-history -D -j 4
        if ($LASTEXITCODE -eq 0) { $retrySyncOk = $true; break }
        if ($attempt -lt 3) {
            Write-Host "  Retry $attempt/3 failed. Waiting 60 s..."
            Start-Sleep -Seconds 60
        }
    }
    $ErrorActionPreference = $savedPref
    if (-not (Test-Path $spirvToolsDir)) {
        Fail ("third_party/spirv-tools still missing after re-sync. " +
              "Run 'gclient sync -j 4' manually from $SourceDir to fetch it.")
    }
}

Pop-Location  # back to original

# --- 4. Apply patches --------------------------------------------------------
Write-Step "Applying custom TLS fingerprint patches"
$chromiumSrcDir = Join-Path $SourceDir "src"

# Chromium patches
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

# BoringSSL patches
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

# --- 5. Copy new source files ------------------------------------------------
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

# --- 6. Generate build -------------------------------------------------------
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

# --- 7. Build with Ninja -----------------------------------------------------
Write-Step "Building Chromium with Ninja ($Jobs jobs) - this takes 2-4 hours"
Push-Location $chromiumSrcDir

autoninja -C $OUT_DIR -j $Jobs chrome
if ($LASTEXITCODE -ne 0) { Fail "ninja build failed" }

Pop-Location

# --- 8. Copy outputs to dist/ ------------------------------------------------
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
$binPath = $DIST_DIR + '\chrome.exe'
Write-Host "  Chromium binary : $binPath" -ForegroundColor Green
Write-Host ''
$exeDisplay = $DIST_DIR + '\chrome.exe'
Write-Host '  Use with Playwright:'
Write-Host '    from playwright_tls import BrowserWithTLS'
$pwLine = '    async with BrowserWithTLS(p, executable_path=' + $exeDisplay + ') as b: ...'
Write-Host $pwLine
