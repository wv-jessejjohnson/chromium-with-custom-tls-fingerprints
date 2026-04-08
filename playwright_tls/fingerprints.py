"""
Pre-defined TLS fingerprint presets for common browsers on Windows.

Each preset is a JA3 string captured from the actual browser.
Use with ``BrowserWithTLS.set_fingerprint(preset)`` or
``set_ja3(page_or_context, preset.ja3)``.

Sources:
  - https://tls.peet.ws
  - https://ja3er.com
  - Captured via Wireshark on clean browser installs (Windows 11)
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass(frozen=True)
class Fingerprint:
    """A named TLS fingerprint preset."""
    name: str
    ja3: str
    ja3_hash: str
    description: str
    permute_extensions: bool = False  # whether the browser randomises ext order

    def __str__(self) -> str:
        return f"{self.name} [{self.ja3_hash}]"


# ---------------------------------------------------------------------------
# Chrome (Windows) — most common target
# ---------------------------------------------------------------------------

# Chrome 120 / Windows 11 (standard)
CHROME_120_WIN = Fingerprint(
    name="Chrome 120 Windows",
    ja3=(
        "771,"
        "4865-4866-4867-49195-49199-49196-49200-52393-52392-49171-49172-156-157-47-53,"
        "0-23-65281-10-11-35-16-5-13-18-51-45-43-27-21,"
        "29-23-24,"
        "0"
    ),
    ja3_hash="b32309a26951912be7dba376398abc3b",
    description="Google Chrome 120 on Windows 11 x64",
    permute_extensions=True,  # Chrome 110+ permutes extension order
)

# Chrome 124 / Windows 11 (with ALPS / application_settings extension)
CHROME_124_WIN = Fingerprint(
    name="Chrome 124 Windows",
    ja3=(
        "771,"
        "4865-4866-4867-49195-49199-49196-49200-52393-52392-49171-49172-156-157-47-53,"
        "0-23-65281-10-11-35-16-5-13-18-51-45-43-27-17513-21,"
        "29-23-24,"
        "0"
    ),
    ja3_hash="8e4578c7ab77a0d5bb166a641e9d4e0a",
    description="Google Chrome 124 on Windows 11 x64 (includes ALPS extension 17513)",
    permute_extensions=True,
)

# Alias for latest stable Chrome
CHROME_LATEST_WIN = CHROME_124_WIN

# ---------------------------------------------------------------------------
# Firefox (Windows)
# ---------------------------------------------------------------------------

FIREFOX_121_WIN = Fingerprint(
    name="Firefox 121 Windows",
    ja3=(
        "771,"
        "4865-4867-4866-49195-49199-52393-52392-49196-49200-49162-49161-49171-49172-"
        "156-157-47-53,"
        "0-23-65281-10-11-35-16-5-13-28-21,"
        "29-23-24-25-256-257,"
        "0"
    ),
    ja3_hash="579ccef312d18482fc42e2b822ca2430",
    description="Mozilla Firefox 121 on Windows 11 x64",
    permute_extensions=False,
)

FIREFOX_LATEST_WIN = FIREFOX_121_WIN

# ---------------------------------------------------------------------------
# Edge (Windows) — Chromium-based, very similar to Chrome
# ---------------------------------------------------------------------------

EDGE_120_WIN = Fingerprint(
    name="Edge 120 Windows",
    ja3=(
        "771,"
        "4865-4866-4867-49195-49199-49196-49200-52393-52392-49171-49172-156-157-47-53,"
        "0-23-65281-10-11-35-16-5-13-18-51-45-43-27-21,"
        "29-23-24,"
        "0"
    ),
    ja3_hash="b32309a26951912be7dba376398abc3b",
    description="Microsoft Edge 120 on Windows 11 x64",
    permute_extensions=True,
)

# ---------------------------------------------------------------------------
# Safari (macOS/iOS) — for mobile user-agent emulation
# ---------------------------------------------------------------------------

SAFARI_17_MAC = Fingerprint(
    name="Safari 17 macOS",
    ja3=(
        "771,"
        "4865-4866-4867-49196-49195-52393-49200-49199-52392-49162-49161-49172-49171-"
        "157-156-53-47-49160-49170-10,"
        "0-23-65281-10-11-16-5-13-18-51-45-43-27-21,"
        "29-23-24-25,"
        "0"
    ),
    ja3_hash="773906b0efdefa24a7f2b8eb6985bf37",
    description="Apple Safari 17 on macOS Sonoma",
    permute_extensions=False,
)

# ---------------------------------------------------------------------------
# Curl (for testing anti-bot detection)
# ---------------------------------------------------------------------------

CURL_8_WIN = Fingerprint(
    name="curl 8 Windows",
    ja3=(
        "771,"
        "4866-4867-4865-49196-49200-159-52393-52392-52394-49195-49199-158-49188-"
        "49192-107-49187-49191-103-49162-49172-57-49161-49171-51-157-156-61-60-53-47,"
        "0-23-65281-10-11-35-16-5-13-51-45-43-21,"
        "29-23-24-25-256-257,"
        "0"
    ),
    ja3_hash="d4e5b18d6b55c71db6b0b5e6d918c97e",
    description="curl 8.x on Windows (no browser spoofing, useful as baseline)",
    permute_extensions=False,
)

# ---------------------------------------------------------------------------
# Convenience collections
# ---------------------------------------------------------------------------

ALL_PRESETS = [
    CHROME_120_WIN,
    CHROME_124_WIN,
    FIREFOX_121_WIN,
    EDGE_120_WIN,
    SAFARI_17_MAC,
    CURL_8_WIN,
]

PRESETS_BY_NAME = {p.name: p for p in ALL_PRESETS}
PRESETS_BY_HASH = {p.ja3_hash: p for p in ALL_PRESETS}


def get_preset(name_or_hash: str) -> Optional[Fingerprint]:
    """Look up a preset by name or JA3 hash."""
    return PRESETS_BY_NAME.get(name_or_hash) or PRESETS_BY_HASH.get(name_or_hash)
