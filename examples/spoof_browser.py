"""
Full browser spoofing example: match TLS + User-Agent + JS fingerprint
of Chrome 124 on Windows to pass bot-detection checks.

Run:
    python examples/spoof_browser.py --url https://bot.sannysoft.com --exe dist/chrome.exe
"""

import asyncio
import argparse

from playwright.async_api import async_playwright

from playwright_tls import BrowserWithTLS, CHROME_124_WIN

# Chrome 124 / Windows 11 user-agent
CHROME_124_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)

# Inject JS to mask automation signals.
STEALTH_SCRIPT = """
() => {
    // Remove webdriver flag
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });

    // Spoof languages
    Object.defineProperty(navigator, 'languages', {
        get: () => ['en-US', 'en'],
    });

    // Spoof platform
    Object.defineProperty(navigator, 'platform', { get: () => 'Win32' });

    // Spoof plugins count (non-zero like a real browser)
    Object.defineProperty(navigator, 'plugins', {
        get: () => [1, 2, 3, 4, 5],
    });

    // Chrome runtime object
    if (!window.chrome) {
        window.chrome = { runtime: {} };
    }
}
"""


async def main(target_url: str, exe_path: str, headless: bool) -> None:
    async with async_playwright() as p:
        async with BrowserWithTLS(
            p,
            executable_path=exe_path,
            headless=headless,
            launch_args=["--disable-infobars"],
        ) as browser:

            # ── Set TLS fingerprint ──────────────────────────────────────────
            # Chrome 124 permutes extensions, so we enable permutation
            # rather than locking to a fixed extension order.
            await browser.set_fingerprint(CHROME_124_WIN)

            # ── Create context with matching HTTP headers ─────────────────────
            context = await browser.new_context(
                user_agent=CHROME_124_UA,
                locale="en-US",
                timezone_id="America/New_York",
                viewport={"width": 1920, "height": 1080},
                color_scheme="no-preference",
            )

            # ── Apply JS stealth patches to every new page ────────────────────
            await context.add_init_script(STEALTH_SCRIPT)

            # ── Navigate ─────────────────────────────────────────────────────
            page = await context.new_page()
            print(f"Navigating to {target_url} ...")
            await page.goto(target_url, wait_until="networkidle")

            # Take a screenshot to review results.
            screenshot_path = "spoof_result.png"
            await page.screenshot(path=screenshot_path, full_page=True)
            print(f"Screenshot saved to {screenshot_path}")

            # Print page title and any bot-detection results.
            title = await page.title()
            print(f"Page title: {title}")

            # Check for common bot-detection indicators.
            webdriver_detected = await page.evaluate(
                "() => navigator.webdriver === true"
            )
            print(f"webdriver detected: {webdriver_detected}")

            await context.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Full browser spoof demo")
    parser.add_argument("--url", default="https://bot.sannysoft.com")
    parser.add_argument("--exe", default="dist/chrome.exe")
    parser.add_argument("--no-headless", action="store_true")
    args = parser.parse_args()

    asyncio.run(main(args.url, args.exe, headless=not args.no_headless))
