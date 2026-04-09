"""
Playwright wrapper that launches the custom Chromium build and provides
a high-level API for setting TLS fingerprints via CDP.

Usage (async):

    import asyncio
    from playwright.async_api import async_playwright
    from playwright_tls import BrowserWithTLS
    from playwright_tls.fingerprints import CHROME_124_WIN

    async def main():
        async with async_playwright() as p:
            async with BrowserWithTLS(p, executable_path="dist/chrome.exe") as browser:
                await browser.set_fingerprint(CHROME_124_WIN)
                page = await browser.new_page()
                await page.goto("https://tls.peet.ws/api/all")
                print(await page.text_content("body"))

    asyncio.run(main())

Usage (sync):

    from playwright.sync_api import sync_playwright
    from playwright_tls import BrowserWithTLSSync
    from playwright_tls.fingerprints import CHROME_124_WIN

    with sync_playwright() as p:
        with BrowserWithTLSSync(p, executable_path="dist/chrome.exe") as browser:
            browser.set_fingerprint(CHROME_124_WIN)
            page = browser.new_page()
            page.goto("https://tls.peet.ws/api/all")
"""

from __future__ import annotations

import os
from typing import Any, Dict, List, Optional, Union

from playwright_tls.fingerprints import Fingerprint
from playwright_tls.ja3 import ja3_to_cdp_params, parse_ja3


# CDP command name exposed by our custom Chromium build.
_CDP_SET_FINGERPRINT   = "Emulation.setTLSFingerprint"
_CDP_RESET_FINGERPRINT = "Emulation.resetTLSFingerprint"


# ---------------------------------------------------------------------------
# Async wrapper
# ---------------------------------------------------------------------------

class BrowserWithTLS:
    """Async context-manager wrapper around a Playwright Browser.

    Launches the custom Chromium binary and wires up TLS fingerprint
    control via Chrome DevTools Protocol.

    Parameters
    ----------
    playwright:
        The ``async_playwright()`` context object.
    executable_path:
        Path to the custom ``chrome.exe``.  Defaults to
        ``dist/chrome.exe`` relative to the current working directory.
    launch_args:
        Extra Chromium command-line flags (list of strings).
    headless:
        Whether to launch headless (default: True).
    **launch_kwargs:
        Any additional keyword arguments forwarded to
        ``playwright.chromium.launch()``.
    """

    def __init__(
        self,
        playwright: Any,
        executable_path: Optional[str] = None,
        launch_args: Optional[List[str]] = None,
        headless: bool = True,
        **launch_kwargs: Any,
    ) -> None:
        self._playwright = playwright
        self._executable_path = executable_path or _default_executable()
        self._launch_args = launch_args or []
        self._headless = headless
        self._launch_kwargs = launch_kwargs
        self._browser: Optional[Any] = None

    # ── Context manager ──────────────────────────────────────────────────────

    async def __aenter__(self) -> "BrowserWithTLS":
        await self.launch()
        return self

    async def __aexit__(self, *_: Any) -> None:
        await self.close()

    # ── Lifecycle ────────────────────────────────────────────────────────────

    async def launch(self) -> None:
        """Launch the custom Chromium browser."""
        args = [
            "--no-sandbox",
            "--disable-blink-features=AutomationControlled",
        ] + self._launch_args

        self._browser = await self._playwright.chromium.launch(
            executable_path=self._executable_path,
            headless=self._headless,
            args=args,
            **self._launch_kwargs,
        )

    async def close(self) -> None:
        """Close the browser."""
        if self._browser:
            await self._browser.close()
            self._browser = None

    # ── Fingerprint control ──────────────────────────────────────────────────

    async def set_fingerprint(
        self,
        fingerprint: Union[Fingerprint, str],
        context: Optional[Any] = None,
    ) -> None:
        """Set a TLS fingerprint on a browser context (or a fresh one).

        Parameters
        ----------
        fingerprint:
            A ``Fingerprint`` preset or a raw JA3 string.
        context:
            An existing Playwright ``BrowserContext``.  If *None*, applies
            to the default context via a temporary page's CDP session.
        """
        if isinstance(fingerprint, str):
            ja3_str = fingerprint
            permute = False
        else:
            ja3_str = fingerprint.ja3
            permute = fingerprint.permute_extensions

        cdp_params = ja3_to_cdp_params(ja3_str)
        if permute:
            cdp_params["permuteExtensions"] = True
            # When permuting, don't send a fixed extensionOrder.
            cdp_params.pop("extensionOrder", None)

        await self._send_cdp(context, _CDP_SET_FINGERPRINT, cdp_params)

    async def set_ja3(
        self,
        ja3_string: str,
        context: Optional[Any] = None,
        permute_extensions: bool = False,
    ) -> None:
        """Set TLS fingerprint from a raw JA3 string."""
        cdp_params = ja3_to_cdp_params(ja3_string)
        if permute_extensions:
            cdp_params["permuteExtensions"] = True
            cdp_params.pop("extensionOrder", None)
        await self._send_cdp(context, _CDP_SET_FINGERPRINT, cdp_params)

    async def reset_fingerprint(self, context: Optional[Any] = None) -> None:
        """Revert TLS fingerprint to Chromium defaults."""
        await self._send_cdp(context, _CDP_RESET_FINGERPRINT, {})

    async def set_fingerprint_params(
        self,
        *,
        cipher_suites: Optional[List[int]] = None,
        supported_groups: Optional[List[int]] = None,
        extension_order: Optional[List[int]] = None,
        permute_extensions: bool = False,
        min_version: Optional[int] = None,
        max_version: Optional[int] = None,
        context: Optional[Any] = None,
    ) -> None:
        """Set individual TLS parameters directly (without a JA3 string).

        This is useful when you want fine-grained control over only some
        parameters (e.g. just the cipher suite list).
        """
        params: Dict[str, Any] = {}
        if cipher_suites is not None:
            params["cipherSuites"] = cipher_suites
        if supported_groups is not None:
            params["supportedGroups"] = supported_groups
        if extension_order is not None and not permute_extensions:
            params["extensionOrder"] = extension_order
        if permute_extensions:
            params["permuteExtensions"] = True
        if min_version is not None:
            params["minVersion"] = min_version
        if max_version is not None:
            params["maxVersion"] = max_version
        if not params:
            return
        await self._send_cdp(context, _CDP_SET_FINGERPRINT, params)

    # ── Browser delegation ───────────────────────────────────────────────────

    async def new_context(self, **kwargs: Any) -> Any:
        """Create a new browser context."""
        _require_browser(self._browser)
        return await self._browser.new_context(**kwargs)

    async def new_page(self, **kwargs: Any) -> Any:
        """Create a new page in the default browser context."""
        _require_browser(self._browser)
        return await self._browser.new_page(**kwargs)

    @property
    def browser(self) -> Any:
        """The underlying Playwright Browser object."""
        _require_browser(self._browser)
        return self._browser

    # ── Internal ─────────────────────────────────────────────────────────────

    async def _send_cdp(
        self,
        context: Optional[Any],
        method: str,
        params: Dict,
    ) -> None:
        """Open a CDP session and send *method* with *params*.

        If *context* is provided, opens a session on that context.
        Otherwise creates a temporary page, sends the command, and closes it.
        """
        _require_browser(self._browser)

        if context is not None:
            # Context-level CDP session (preferred).
            session = await context.new_cdp_session(
                await context.new_page()
            )
            try:
                await session.send(method, params)
            finally:
                await session.detach()
        else:
            # Temporary page-level CDP session.
            ctx = await self._browser.new_context()
            page = await ctx.new_page()
            session = await page.context.new_cdp_session(page)
            try:
                await session.send(method, params)
            finally:
                await session.detach()
                await ctx.close()


# ---------------------------------------------------------------------------
# Sync wrapper (thin wrapper around async using Playwright's own sync API)
# ---------------------------------------------------------------------------

class BrowserWithTLSSync:
    """Synchronous context-manager wrapper around a Playwright Browser.

    Parameters
    ----------
    playwright:
        The ``sync_playwright()`` context object.
    executable_path:
        Path to the custom ``chrome.exe``.
    launch_args:
        Extra Chromium command-line flags.
    headless:
        Whether to launch headless (default: True).
    **launch_kwargs:
        Additional keyword arguments forwarded to
        ``playwright.chromium.launch()``.
    """

    def __init__(
        self,
        playwright: Any,
        executable_path: Optional[str] = None,
        launch_args: Optional[List[str]] = None,
        headless: bool = True,
        **launch_kwargs: Any,
    ) -> None:
        self._playwright = playwright
        self._executable_path = executable_path or _default_executable()
        self._launch_args = launch_args or []
        self._headless = headless
        self._launch_kwargs = launch_kwargs
        self._browser: Optional[Any] = None

    def __enter__(self) -> "BrowserWithTLSSync":
        self.launch()
        return self

    def __exit__(self, *_: Any) -> None:
        self.close()

    def launch(self) -> None:
        args = [
            "--no-sandbox",
            "--disable-blink-features=AutomationControlled",
        ] + self._launch_args
        self._browser = self._playwright.chromium.launch(
            executable_path=self._executable_path,
            headless=self._headless,
            args=args,
            **self._launch_kwargs,
        )

    def close(self) -> None:
        if self._browser:
            self._browser.close()
            self._browser = None

    def set_fingerprint(
        self,
        fingerprint: Union[Fingerprint, str],
        context: Optional[Any] = None,
    ) -> None:
        if isinstance(fingerprint, str):
            ja3_str = fingerprint
            permute = False
        else:
            ja3_str = fingerprint.ja3
            permute = fingerprint.permute_extensions
        cdp_params = ja3_to_cdp_params(ja3_str)
        if permute:
            cdp_params["permuteExtensions"] = True
            cdp_params.pop("extensionOrder", None)
        self._send_cdp(context, _CDP_SET_FINGERPRINT, cdp_params)

    def set_ja3(
        self,
        ja3_string: str,
        context: Optional[Any] = None,
        permute_extensions: bool = False,
    ) -> None:
        cdp_params = ja3_to_cdp_params(ja3_string)
        if permute_extensions:
            cdp_params["permuteExtensions"] = True
            cdp_params.pop("extensionOrder", None)
        self._send_cdp(context, _CDP_SET_FINGERPRINT, cdp_params)

    def reset_fingerprint(self, context: Optional[Any] = None) -> None:
        self._send_cdp(context, _CDP_RESET_FINGERPRINT, {})

    def new_context(self, **kwargs: Any) -> Any:
        _require_browser(self._browser)
        return self._browser.new_context(**kwargs)

    def new_page(self, **kwargs: Any) -> Any:
        _require_browser(self._browser)
        return self._browser.new_page(**kwargs)

    @property
    def browser(self) -> Any:
        _require_browser(self._browser)
        return self._browser

    def _send_cdp(
        self,
        context: Optional[Any],
        method: str,
        params: Dict,
    ) -> None:
        _require_browser(self._browser)
        if context is not None:
            page = context.new_page()
            session = context.new_cdp_session(page)
            try:
                session.send(method, params)
            finally:
                session.detach()
        else:
            ctx = self._browser.new_context()
            page = ctx.new_page()
            session = ctx.new_cdp_session(page)
            try:
                session.send(method, params)
            finally:
                session.detach()
                ctx.close()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _default_executable() -> str:
    """Return the default path to the custom chrome.exe."""
    base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(base, "dist", "chrome.exe")


def _require_browser(browser: Optional[Any]) -> None:
    if browser is None:
        raise RuntimeError(
            "Browser is not launched. Call launch() or use as context manager."
        )
