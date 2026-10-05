# PhoneBridge — iPhone browser → Mac text

**A first-use prototype, not an Intel build of EnviousWispr.** Dictate into an iPhone
Safari text field using the iPhone keyboard microphone, then send the finished text
to a small native Mac helper. The Mac does not run speech recognition.

**Current validation:** platform-independent Swift tests and JavaScript unit tests
pass locally. Native macOS framework compilation, Safari keyboard dictation,
real-device networking and automatic insertion have **not yet been verified**.
The first user's build/run is a validation step, not a claim of a tested Mac release.

## Start here

Keep GitHub Actions disabled. There is no workflow for this prototype and no need
to merge the Intel experiment or any other pull request.

1. Put the `phone-bridge-prototype` folder on your **Mac** (the source ZIP is enough).
2. Open **Terminal**. Type `bash ` (with a space), drag `build-and-open.command` from
   that folder into the Terminal window, and press Return. This avoids executable
   permission differences after unzipping. Do not run it on the iPhone.
3. If the script says developer tools are missing, run `xcode-select --install`,
   finish Apple's installer, then repeat step 2. This needs an Apple-provided Swift
   compiler, not the full Xcode app, Homebrew, Python, Node, a paid developer account,
   or a speech-model download. No tools are installed automatically.
4. The script builds for your Mac's native architecture, ad-hoc signs the app,
   installs it in `~/Applications/PhoneBridge.app`, and opens it. A rebuild may
   require re-approving Accessibility. It will not overwrite an unrelated app.

Targets **macOS 12+**, Intel or Apple Silicon, using Swift 5 language mode. An older
OS or an old compiler may require changes. On compiler failure, stop and share the
error: don't try random toolchain changes or enable Actions.

## First test: transfer only

1. Use the same **trusted home Wi-Fi/router** on both devices. Ethernet on the Mac
   is fine when the phone can reach it. Guest/client-isolated Wi-Fi may block this.
2. In the Mac helper, choose your private LAN address and click **Start on my trusted
   Wi-Fi**. Allow incoming connections/Local Network permission if macOS prompts.
   Do not disable the system firewall. The helper starts stopped, never at login.
3. Scan its QR code with the iPhone Camera, open the link in Safari, and approve
   **Allow this browser** in the Mac window. Keep the Safari page open.
4. On the phone, tap **Use Mac clipboard**, tap the large text field, and use the
   **iPhone keyboard microphone**. Dictate “Hello from my iPhone.” Stop dictation,
   review the words, and tap **Send to Mac**.
5. Open a blank TextEdit document on the Mac and press Command–V. The sentence should
   be in the clipboard. This isolates transfer from Accessibility/paste permissions.

## Second test: automatic insertion

1. In PhoneBridge, enable **automatic paste**. Grant the helper permission in
   System Settings → Privacy & Security → Accessibility (on Monterey:
   System Preferences → Security & Privacy → Privacy → Accessibility).
   Return to PhoneBridge and tick the checkbox again after granting permission.
2. Click **inside the blank TextEdit document**, leaving its caret active.
3. On the phone, tap **Use current Mac text field** (an already connected page may
   still label this button “Use Mac clipboard”; reconnect refreshes the label).
   Confirm that the page says **TextEdit**, not Mac clipboard.
4. Dictate a sentence, stop keyboard dictation, and tap **Send to Mac** within two
   minutes. Do not switch the selected Mac field between choosing it and sending.
5. Check the Mac document. A “paste shortcut sent” receipt means the shortcut was
   issued, not that the destination app has confirmed insertion. If it did not
   appear, the text is still on the Mac clipboard: press Command–V once.

Use normal text fields only. Known terminal apps, password fields, and fields the
helper cannot identify are intentionally unsupported for automatic paste. This is
not a universal terminal/web-shell detector; never choose a shell, password manager,
message-send button or other sensitive target. No Return/Enter key is ever generated.
For other apps, first use copy-only mode and paste manually.

## Important privacy boundary

**This prototype uses unencrypted HTTP, not HTTPS.** The random pairing token and
Mac approval prevent casual unpaired submissions; they **do not protect against
someone who can inspect or modify LAN traffic**. Such an attacker may read text or
steal the session token. Treat the QR link like a temporary password. Do not send
confidential material, use public/shared Wi-Fi, expose the port to the internet,
or set up port forwarding. This is not a secure LocalSend replacement.

The app binds only to the selected RFC1918 IPv4 address on an active `en*`/`bridge*`
interface and accepts private IPv4 clients. Binding is not a firewall or proof of
network trust. No Bonjour or external website is needed.

The helper/page do not record audio, call a speech API, create an account, send
analytics, save transcript history or contact a cloud service. Only explicitly sent
text travels through this bridge. Apple keyboard dictation is a separate system
feature: on-device/offline support depends on the iPhone, language and settings.
This app cannot force Apple dictation offline. The clipboard can also be synced by
Handoff/Universal Clipboard or recorded by your own clipboard manager. Browser,
OS, crash and swap behavior are outside a promise of “nothing is ever stored.”

Drafts and an uncertain send are kept in page memory only; refreshing or closing the
page loses them. Pairing credentials use tab-scoped sessionStorage, not localStorage;
browsers may restore a tab session. Every receiver restart rotates the secret.

## Delivery safeguards

- Explicit Mac approval for one browser per receiver session; 256-bit random secret.
- Host validation, exact same-Origin JSON POSTs, bearer/client checks, no CORS, no
  third-party assets, restrictive CSP, `no-store`, and no microphone/camera web APIs.
- Default is **clipboard only**. Automatic paste requires a separate local checkbox
  and macOS Accessibility permission.
- Selecting a destination creates a single-use two-minute ticket. Before posting
  Command–V, the app checks the frontmost process, focused accessibility element,
  allowed field role, secure input and held modifier keys. A changed target copies
  only; it never activates another app. This reduces, but cannot eliminate, OS-level
  focus races or app-specific behavior. Caret/selection position itself is not frozen.
- Final text is sent once, never streamed into a document. Retrying after a lost
  receipt uses the same ID, payload and ticket. The Mac remembers the receipt without
  keeping transcript contents in the ledger and does not paste that ID again.
- The ledger is bounded at 256 sends and never evicts IDs within a session. At the
  limit, restart/pair again. A stale session is rejected rather than replayed.
- Stop/quit closes connections and forgets pairing. Sessions stop after 30 minutes,
  on workspace sleep/session deactivation, and on the screen-lock notification.
- HTTP parsing is size-bounded, connections have ten-second deadlines, and the server
  has connection/rate limits. No chunked bodies, duplicate headers or pipelining.
- The normal Mac clipboard is overwritten and intentionally not restored: some apps
  read it asynchronously. The helper never synthesizes Return or automatically retries.

## When something does not work

**No private address:** connect the Mac to Wi-Fi/Ethernet and reopen the helper. With
multiple interfaces, choose the address on the same network as the iPhone. IPv6-only,
VPN-only and public-address networks are not supported by this first version.

**Safari cannot connect:** check the same router, receiver still running, approved
incoming connections and Local Network permission. The URL must remain `http://`,
not be rewritten to `https://`. Do not weaken Safari's general security settings.

**QR does not pair / session expired:** stop/restart the receiver, then scan its new
QR link. Opening just the IP address without its fragment token is not enough.

**Permission still missing:** add `~/Applications/PhoneBridge.app` to Accessibility,
then enable paste in the helper again. This is a local, ad-hoc-signed build, so
rebuilding can invalidate macOS's earlier trust decision. Do not disable Gatekeeper,
SIP or the firewall; no such workaround is required by this build script.

**No keyboard microphone:** enable Dictation in the iPhone's Keyboard settings and
use Apple's keyboard. The website deliberately has no custom microphone control.

**No receipt:** check the Mac first. Use **Retry the same send**, not a new send.
Restarting the Mac receiver loses its in-memory receipts and invalidates the old
secret. To change the draft after an uncertain send, explicitly choose **Stop
retrying — keep draft** only after checking the destination for duplicates.

**Target expired:** stop retrying/keep the draft, click the correct Mac field and
choose it again on the phone. The first test is a short sentence, not a long recording.

## Local developer checks (never GitHub Actions)

`bash test-local.sh` compiles/runs the real shared protocol tests and parses the
native source. Node, when present, runs the real browser state unit tests. No
packages are downloaded. Native UI/Network/Accessibility code is **not** type-checked
on Linux; the real Mac build is the next gate.

`python3 Tests/browser-smoke.py` is an optional Playwright/Chromium UI smoke test
with **mock API responses**, not a phone-to-Mac test. It requires a separately
installed Playwright browser. It was not completed in this environment because the
available browser blocked loopback navigation by administrator policy. No browser
policy was changed. A mock UI pass would still not validate iPhone Safari dictation.

See `VALIDATION.md` for the tested/not-tested boundary and manual acceptance checks.
No `.github` file, EnviousWispr source, existing experiment, updater, signing
configuration or app dependency is changed by this standalone addition.

## Next version — only after this interaction is useful

Validate the two-device flow first. Before real/private daily use, add authenticated
encrypted transport with a reviewed trust setup, broaden native-app compatibility,
and test interruptions and long dictations. A native iPhone companion can later
provide a custom recording UI and a controlled offline recognition path.

License: GPL-3.0, matching the parent repository. See `LICENSE` (or `../../LICENSE`
in the fork). This prototype adds no third-party libraries.

Primary platform references:
- https://support.apple.com/guide/iphone/dictate-text-iph2c0651d2/ios
- https://developer.apple.com/documentation/network/nwlistener
- https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions
- https://developer.apple.com/documentation/bundleresources/information-property-list/nslocalnetworkusagedescription
- https://developer.mozilla.org/en-US/docs/Web/API/Crypto/getRandomValues
