# Chromium with Custom TLS Fingerprints

A custom Windows Chromium build that exposes a Chrome DevTools Protocol (CDP) command
to configure TLS ClientHello parameters (JA3/JA3N fingerprint spoofing) at runtime,
paired with a Python `playwright_tls` package for use with Playwright.

## What this does

Every browser has a distinct **TLS fingerprint** — a signature derived from the
ClientHello message it sends when opening an HTTPS connection.  The most common
fingerprinting method is **JA3**, which hashes:

```
SSLVersion, CipherSuites, Extensions, EllipticCurves, EllipticCurvePointFormats
```

Many bot-detection systems (Cloudflare, Akamai, DataDome, etc.) use TLS fingerprints
to identify automated traffic.  This project patches Chromium so you can set any
TLS fingerprint you like — matching Chrome, Firefox, Safari, or a custom value —
without restarting the browser.

### What is patched

| Layer | Change |
|---|---|
| `net/ssl/tls_fingerprint_config.{h,cc}` | New `TLSFingerprintParams` struct + thread-safe `TLSFingerprintManager` singleton |
| `net/socket/ssl_client_socket_impl.cc` | Reads manager on every new SSL connection and applies cipher suites, groups, version limits, extension order |
| `third_party/boringssl/src/ssl/extensions.cc` | New `SSL_set_extension_order()` API for fixed-order ClientHello extensions |
| `services/network/…/tls_fingerprint.mojom` | Mojo IPC interface so browser process can push settings to network service |
| `browser_protocol.pdl` + `emulation_handler.cc` | New CDP commands `Emulation.setTLSFingerprint` / `Emulation.resetTLSFingerprint` |

### What can be controlled

- **Cipher suites** — order and selection (TLS 1.2 and TLS 1.3)
- **Supported groups / elliptic curves** — e.g. x25519, P-256, P-384
- **TLS version** (min/max)
- **Extension order** in ClientHello — exact position of each extension type
- **Extension permutation** — per-connection random shuffle (like Chrome 110+)
- **JA3 string** — one-shot convenience input that sets all of the above

---

## Repository layout

```
├── patches/
│   ├── chromium/          # git-apply patches for Chromium source
│   │   ├── 0001-net-ssl-build-add-tls-fingerprint-config.patch
│   │   ├── 0002-net-ssl-socket-apply-tls-fingerprint.patch
│   │   ├── 0003-services-network-tls-fingerprint-service.patch
│   │   └── 0004-cdp-emulation-set-tls-fingerprint.patch
│   └── boringssl/         # git-apply patches for third_party/boringssl
│       └── 0001-ssl-extension-ordering.patch
│
├── src/
│   └── chromium/          # New source files to copy into Chromium tree
│       ├── net/ssl/tls_fingerprint_config.{h,cc}
│       └── services/network/public/mojom/tls_fingerprint.mojom
│
├── build/
│   ├── install_prerequisites_windows.ps1   # one-time setup (run as Admin)
│   ├── build_chromium_windows.ps1          # main build script
│   └── gn_args/
│       ├── windows_release.gn
│       └── windows_debug.gn
│
├── playwright_tls/        # Python package
│   ├── __init__.py
│   ├── browser.py         # BrowserWithTLS (async) / BrowserWithTLSSync
│   ├── fingerprints.py    # preset JA3 fingerprints (Chrome, Firefox, …)
│   └── ja3.py             # JA3 parsing, hashing, CDP conversion
│
├── examples/
│   ├── basic_usage.py
│   ├── check_fingerprint.py
│   └── spoof_browser.py
│
└── pyproject.toml
```

---

## Building (Windows)

### Requirements

- Windows 10 / 11 x64
- ~250 GB free disk space (Chromium source + build artefacts)
- ~16 GB RAM recommended
- Internet connection for initial source fetch

### Step 1 — Install prerequisites (one time)

Open PowerShell **as Administrator** and run:

```powershell
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
.\build\install_prerequisites_windows.ps1
```

This installs: Git, Python 3, Visual Studio 2022 Build Tools, and Google depot_tools.

### Step 2 — Build

Close and reopen PowerShell (so PATH changes take effect), then:

```powershell
.\build\build_chromium_windows.ps1 -PlaywrightVersion 1.44.0
```

The script will:
1. Fetch the Chromium revision that matches Playwright 1.44.0
2. Apply all patches from `patches/`
3. Copy new source files from `src/`
4. Generate the build with GN
5. Compile with Ninja (~2–4 hours on a 16-core machine)
6. Copy the output to `dist/`

#### Parameters

| Parameter | Default | Description |
|---|---|---|
| `-PlaywrightVersion` | `1.44.0` | Target Playwright version (determines Chromium revision) |
| `-BuildType` | `release` | `release` or `debug` |
| `-SourceDir` | `C:\chromium_src` | Where to check out Chromium (~200 GB) |
| `-Jobs` | CPU count | Parallel ninja jobs |

### Step 3 — Install Python wrapper

```powershell
pip install playwright
pip install -e .
```

---

## Usage

### Async (recommended)

```python
import asyncio
from playwright.async_api import async_playwright
from playwright_tls import BrowserWithTLS, CHROME_124_WIN

async def main():
    async with async_playwright() as p:
        async with BrowserWithTLS(p, executable_path=r"dist\chrome.exe") as browser:

            # Set Chrome 124 TLS fingerprint (includes extension permutation)
            await browser.set_fingerprint(CHROME_124_WIN)

            page = await browser.new_page()
            await page.goto("https://tls.peet.ws/api/all")
            print(await page.text_content("body"))

asyncio.run(main())
```

### Sync

```python
from playwright.sync_api import sync_playwright
from playwright_tls import BrowserWithTLSSync, CHROME_124_WIN

with sync_playwright() as p:
    with BrowserWithTLSSync(p, executable_path=r"dist\chrome.exe") as browser:
        browser.set_fingerprint(CHROME_124_WIN)
        page = browser.new_page()
        page.goto("https://tls.peet.ws/api/all")
        print(page.text_content("body"))
```

### Set a raw JA3 string

```python
JA3 = (
    "771,"
    "4865-4866-4867-49195-49199-49196-49200-52393-52392-49171-49172-156-157-47-53,"
    "0-23-65281-10-11-35-16-5-13-18-51-45-43-27-21,"
    "29-23-24,"
    "0"
)
await browser.set_ja3(JA3)
```

### Set individual parameters

```python
await browser.set_fingerprint_params(
    cipher_suites=[0x1301, 0x1302, 0x1303, 0xC02B, 0xC02F],
    supported_groups=[29, 23, 24],
    permute_extensions=True,
    max_version=0x0304,  # TLS 1.3
)
```

### Reset to Chromium defaults

```python
await browser.reset_fingerprint()
```

### List available presets

```python
from playwright_tls import ALL_PRESETS
for p in ALL_PRESETS:
    print(p)
```

Output:
```
Chrome 120 Windows [b32309a26951912be7dba376398abc3b]
Chrome 124 Windows [8e4578c7ab77a0d5bb166a641e9d4e0a]
Firefox 121 Windows [579ccef312d18482fc42e2b822ca2430]
Edge 120 Windows [b32309a26951912be7dba376398abc3b]
Safari 17 macOS [773906b0efdefa24a7f2b8eb6985bf37]
curl 8 Windows [d4e5b18d6b55c71db6b0b5e6d918c97e]
```

---

## How it works (technical detail)

### TLS fingerprint flow

```
Playwright (Python)
  │  CDP: Emulation.setTLSFingerprint({ja3String: "771,..."})
  ▼
Browser process (chrome.exe)
  │  EmulationHandler::SetTLSFingerprint()
  │  → ParseJA3String() → TLSFingerprintParams
  │  → Mojo IPC: TLSFingerprintService::SetParams()
  ▼
Network service process
  │  TLSFingerprintServiceImpl::SetParams()
  │  → TLSFingerprintManager::SetParams()  [global singleton, thread-safe]
  ▼
SSLClientSocketImpl::Init()   (called for every new HTTPS connection)
  │  ApplyTLSFingerprintIfEnabled()
  │  → SSL_set_cipher_list() / SSL_set_ciphersuites()
  │  → SSL_set1_groups()
  │  → SSL_set_min/max_proto_version()
  │  → SSL_set_extension_order()  [BoringSSL patch]
  │    or SSL_set_permute_extensions()
  ▼
BoringSSL → TLS ClientHello with custom fingerprint
```

### JA3 format

```
771,4865-4866-4867-...,0-23-65281-...,29-23-24,0
 │   └── cipher suites  └── extensions  └─ curves └ point fmts
 └── TLS version (decimal)
```

All values are IANA decimal integers.  GREASE values are stripped automatically.

### Extension ordering

Chrome 110+ uses `SSL_set_permute_extensions()` to randomise extension order per
connection (making JA3 hashes non-deterministic).  This project exposes:

- `permuteExtensions: true` — match Chrome 110+ behaviour  
- `extensionOrder: [0, 23, 65281, ...]` — fixed order (for older browser emulation)

The BoringSSL patch (`patches/boringssl/0001-ssl-extension-ordering.patch`) adds
`SSL_set_extension_order()` which iterates `kExtensions[]` in caller-specified order
before appending remaining extensions.

---

## Verification

After building, run:

```powershell
python examples/basic_usage.py --exe dist\chrome.exe
```

Then visit `https://tls.peet.ws` or `https://ja3er.com` manually to cross-check the
reported JA3 hash.

---

## Applying patches manually

If you prefer to apply patches by hand (e.g. for a different Chromium version):

```powershell
cd C:\chromium_src\src

# Copy new source files
Copy-Item ..\..\src\chromium\net\ssl\tls_fingerprint_config.h      net\ssl\
Copy-Item ..\..\src\chromium\net\ssl\tls_fingerprint_config.cc     net\ssl\
Copy-Item ..\..\src\chromium\services\network\public\mojom\tls_fingerprint.mojom `
          services\network\public\mojom\

# Apply Chromium patches
git apply ..\..\patches\chromium\0001-net-ssl-build-add-tls-fingerprint-config.patch
git apply ..\..\patches\chromium\0002-net-ssl-socket-apply-tls-fingerprint.patch
git apply ..\..\patches\chromium\0003-services-network-tls-fingerprint-service.patch
git apply ..\..\patches\chromium\0004-cdp-emulation-set-tls-fingerprint.patch

# Apply BoringSSL patch
cd third_party\boringssl\src
git apply ..\..\..\..\..\patches\boringssl\0001-ssl-extension-ordering.patch
cd ..\..\..
```

> **Tip:** If a patch does not apply cleanly (different Chromium version), use it as
> a reference to make the equivalent changes manually.  The patch comments describe
> exactly what each change does.

---

## Notes and limitations

- **Extension order vs. permutation**: Chrome 110+ permutes extensions randomly.
  Using a fixed `extensionOrder` may look suspicious on modern Chrome-detection
  systems. Use `permute_extensions=True` to match real Chrome behaviour.

- **EC point formats**: BoringSSL only advertises the uncompressed format (0).
  Custom `ec_point_formats` values other than `[0]` are logged but not applied.

- **ALPN / HTTP/2**: ALPN extension content (h2, http/1.1) is controlled separately
  by Chromium's protocol negotiation layer and is not affected by this patch.

- **Build time**: A full release build requires 2–4 hours on a 16-core machine and
  ~250 GB of disk space.  Use `-BuildType debug` for faster iteration (component
  build, symbols enabled, no PGO).

- **Playwright compatibility**: The build script automatically checks out the
  Chromium revision matching your Playwright version.  If you upgrade Playwright,
  rebuild with `-PlaywrightVersion <new version>`.
