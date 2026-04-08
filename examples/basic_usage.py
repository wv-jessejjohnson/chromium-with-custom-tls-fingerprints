"""
Basic usage example: set a Chrome 124 TLS fingerprint and verify it.

Run:
    python examples/basic_usage.py --exe dist/chrome.exe
"""

import asyncio
import argparse
import json

from playwright.async_api import async_playwright

from playwright_tls import BrowserWithTLS, CHROME_124_WIN, describe_ja3


async def main(exe_path: str, headless: bool) -> None:
    print("Fingerprint to be applied:")
    print(describe_ja3(CHROME_124_WIN.ja3))
    print()

    async with async_playwright() as p:
        async with BrowserWithTLS(
            p,
            executable_path=exe_path,
            headless=headless,
        ) as browser:
            # Apply Chrome 124 TLS fingerprint globally.
            await browser.set_fingerprint(CHROME_124_WIN)

            # Open a page and check the fingerprint via tls.peet.ws.
            page = await browser.new_page()
            print("Navigating to https://tls.peet.ws/api/all ...")
            response = await page.goto("https://tls.peet.ws/api/all")

            body = await page.text_content("body")
            data = json.loads(body)

            # Extract TLS info from the response.
            tls = data.get("tls", {})
            ja3_reported = tls.get("ja3", "not found")
            ja3_hash_reported = tls.get("ja3_hash", "not found")

            print(f"\n[Result]")
            print(f"  JA3 hash (server saw) : {ja3_hash_reported}")
            print(f"  JA3 string            : {ja3_reported}")
            print(f"  Expected hash         : {CHROME_124_WIN.ja3_hash}")
            print()

            match = ja3_hash_reported == CHROME_124_WIN.ja3_hash
            if match:
                print("  PASS — fingerprint matches Chrome 124!")
            else:
                print("  MISMATCH — check patch application and build.")
                # Show diff for debugging.
                from playwright_tls.ja3 import parse_ja3
                expected = parse_ja3(CHROME_124_WIN.ja3)
                actual   = parse_ja3(ja3_reported) if ja3_reported != "not found" else {}
                print(f"  Expected ciphers : {expected.get('cipher_suites')}")
                print(f"  Actual ciphers   : {actual.get('cipher_suites')}")
                print(f"  Expected exts    : {expected.get('extensions')}")
                print(f"  Actual exts      : {actual.get('extensions')}")

            await page.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="TLS fingerprint basic test")
    parser.add_argument(
        "--exe",
        default="dist/chrome.exe",
        help="Path to custom chrome.exe (default: dist/chrome.exe)",
    )
    parser.add_argument("--no-headless", action="store_true")
    args = parser.parse_args()

    asyncio.run(main(args.exe, headless=not args.no_headless))
