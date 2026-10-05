"""Optional Chromium UI checks. API responses are mocked, NOT a native Mac test.
Run: python3 Tests/browser-smoke.py (requires Playwright and its Chromium browser).
"""
import functools
import http.server
import json
import pathlib
import os
import threading
from playwright.sync_api import sync_playwright, expect

root = pathlib.Path(__file__).resolve().parents[1]
class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_args):
        pass
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0),
    functools.partial(QuietHandler, directory=str(root / "Web")))
threading.Thread(target=server.serve_forever, daemon=True).start()
try:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True, executable_path=os.environ.get("PHONEBRIDGE_CHROMIUM"))
        context = browser.new_context(viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True)
        page = context.new_page()
        sent = []
        fail_once = [False]
        def api(route):
            path = route.request.url.split("/api/")[-1]
            if path == "connect":
                result = {"paired": True}
            elif path == "status":
                result = {"paired": True, "mode": "paste"}
            elif path == "arm":
                result = {"ticket": "a" * 32, "target": "TextEdit", "mode": "paste"}
            elif path == "send":
                payload = route.request.post_data_json
                sent.append(payload)
                if fail_once[0]:
                    fail_once[0] = False
                    route.abort(); return
                result = {"id": payload["id"], "result": "paste_requested", "message": "Paste shortcut sent to TextEdit. Check your Mac."}
            else:
                raise AssertionError(path)
            route.fulfill(status=200, content_type="application/json", body=json.dumps(result))
        page.route("**/api/**", api)
        page.goto(f"http://127.0.0.1:{server.server_port}/#{'b'*64}")
        expect(page.locator("#arm")).to_be_enabled()
        assert "#" not in page.url, "QR token removed from visible URL"
        page.locator("#arm").click()
        expect(page.locator("#target")).to_contain_text("TextEdit")
        page.locator("#draft").fill("Hello from my iPhone. مرحبا 👋")
        expect(page.locator("#send")).to_be_enabled()
        page.locator("#send").click()
        expect(page.locator("#draft")).to_have_value("")
        expect(page.locator("#result")).to_contain_text("Paste shortcut sent")
        assert len(sent) == 1
        page.locator("#arm").click()
        page.locator("#draft").fill("Preserve this draft after a lost receipt.")
        fail_once[0] = True
        page.locator("#send").click()
        expect(page.locator("#result")).to_contain_text("No receipt received")
        expect(page.locator("#draft")).to_have_value("Preserve this draft after a lost receipt.")
        expect(page.locator("#arm")).to_be_disabled()
        expect(page.locator("#send")).to_have_text("Retry the same send")
        page.locator("#send").click()
        expect(page.locator("#draft")).to_have_value("")
        assert sent[1] == sent[2], "retry must preserve exact ID, target and text"
        assert page.evaluate("document.documentElement.scrollWidth <= window.innerWidth")
        # Leave a representative draft in the UI screenshot, without sending it.
        page.locator("#arm").click()
        page.locator("#draft").fill("Let's try sending these words from my iPhone to my Mac.")
        page.locator("h1").scroll_into_view_if_needed()
        (root / ".build").mkdir(exist_ok=True)
        page.screenshot(path=str(root / ".build/browser-preview.png"), full_page=True)
        browser.close()
    print("PASS: mobile-width Chromium UI, pairing state, target selection, send, lost-receipt retry and draft retention (mock API)")
finally:
    server.shutdown()
