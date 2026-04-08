"""
playwright_tls — Playwright wrapper for custom Chromium with TLS fingerprint control.

Quick start (async):
    from playwright.async_api import async_playwright
    from playwright_tls import BrowserWithTLS
    from playwright_tls.fingerprints import CHROME_124_WIN

    async with async_playwright() as p:
        async with BrowserWithTLS(p, executable_path="dist/chrome.exe") as browser:
            await browser.set_fingerprint(CHROME_124_WIN)
            page = await browser.new_page()
            await page.goto("https://tls.peet.ws/api/all")

Quick start (sync):
    from playwright.sync_api import sync_playwright
    from playwright_tls import BrowserWithTLSSync
    from playwright_tls.fingerprints import CHROME_124_WIN

    with sync_playwright() as p:
        with BrowserWithTLSSync(p, executable_path="dist/chrome.exe") as browser:
            browser.set_fingerprint(CHROME_124_WIN)
            page = browser.new_page()
            page.goto("https://tls.peet.ws/api/all")
"""

from playwright_tls.browser import BrowserWithTLS, BrowserWithTLSSync
from playwright_tls.fingerprints import (
    Fingerprint,
    CHROME_120_WIN,
    CHROME_124_WIN,
    CHROME_LATEST_WIN,
    EDGE_120_WIN,
    FIREFOX_121_WIN,
    FIREFOX_LATEST_WIN,
    SAFARI_17_MAC,
    CURL_8_WIN,
    ALL_PRESETS,
    get_preset,
)
from playwright_tls.ja3 import (
    parse_ja3,
    build_ja3,
    compute_ja3_hash,
    describe_ja3,
    ja3_to_cdp_params,
    is_grease,
    filter_grease,
)

__all__ = [
    # Browser wrappers
    "BrowserWithTLS",
    "BrowserWithTLSSync",
    # Fingerprint presets
    "Fingerprint",
    "CHROME_120_WIN",
    "CHROME_124_WIN",
    "CHROME_LATEST_WIN",
    "EDGE_120_WIN",
    "FIREFOX_121_WIN",
    "FIREFOX_LATEST_WIN",
    "SAFARI_17_MAC",
    "CURL_8_WIN",
    "ALL_PRESETS",
    "get_preset",
    # JA3 utilities
    "parse_ja3",
    "build_ja3",
    "compute_ja3_hash",
    "describe_ja3",
    "ja3_to_cdp_params",
    "is_grease",
    "filter_grease",
]

__version__ = "1.0.0"
