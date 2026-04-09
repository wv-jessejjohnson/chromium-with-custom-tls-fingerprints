"""
Enumerate all presets and verify each one against tls.peet.ws.

Run:
    python examples/check_fingerprint.py --exe dist/chrome.exe
"""

import asyncio
import argparse
import json

from playwright.async_api import async_playwright

from playwright_tls import BrowserWithTLS, ALL_PRESETS, compute_ja3_hash


async def check_preset(browser: BrowserWithTLS, preset) -> bool:
    """Apply preset, load tls.peet.ws, compare reported JA3 hash."""
    await browser.set_fingerprint(preset)

    ctx  = await browser.new_context()
    page = await ctx.new_page()
    try:
        await page.goto("https://tls.peet.ws/api/all", timeout=15_000)
        body = await page.text_content("body")
        data = json.loads(body)
        reported_hash = data.get("tls", {}).get("ja3_hash", "")
        match = reported_hash == preset.ja3_hash
        status = "PASS" if match else "FAIL"
        print(f"  [{status}] {preset.name:30s}  "
              f"expected={preset.ja3_hash}  got={reported_hash}")
        return match
    except Exception as exc:
        print(f"  [ERR ] {preset.name:30s}  {exc}")
        return False
    finally:
        await ctx.close()


async def main(exe_path: str) -> None:
    passed = 0
    failed = 0

    async with async_playwright() as p:
        async with BrowserWithTLS(p, executable_path=exe_path) as browser:
            print(f"Checking {len(ALL_PRESETS)} fingerprint presets...\n")
            for preset in ALL_PRESETS:
                ok = await check_preset(browser, preset)
                if ok:
                    passed += 1
                else:
                    failed += 1

    print(f"\nResults: {passed} passed, {failed} failed out of {len(ALL_PRESETS)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", default="dist/chrome.exe")
    args = parser.parse_args()
    asyncio.run(main(args.exe))
