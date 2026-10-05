# Validation record — 2026-10-05

## Completed locally, without GitHub Actions

- Swift 6.2.1 / Linux, Swift 5 language mode: **148 passing assertions** against the
  exact shared `BridgeCore.swift` used by the Mac helper. Includes fragmented HTTP,
  UTF-8 text, duplicate headers, framing/size bounds, private-address validation,
  origin/host/token/client checks, text limits, immutable retry receipts and the
  no-eviction session cap.
- Node 22: browser `SendState` and cryptographic ID unit tests passed. These use the
  shipped `app.js` module, not a separate implementation.
- Swift source syntax parse, JavaScript syntax check and build-script Bash syntax
  check passed. Parsing does not establish that macOS framework APIs type-check.
- A Linux invocation of the user build script is rejected before modifying anything.

## Not verified

- Native macOS build and link against Apple SDKs.
- AppKit layout, LAN Network.framework listener, IP selection and QR scanning.
- iPhone Safari page behavior, keyboard dictation and iOS local-network prompts.
- Accessibility trust and actual insertion into any application.
- Sleep/lock/network transitions on real hardware.
- Safari/browser UI testing. An optional Playwright/Chromium test is included but
  could not complete here: managed Chromium blocked loopback navigation. No policy
  was changed. The available Playwright-managed browser was absent and its download
  also unavailable. This does not count as a UI pass or as an application failure.
- Authenticated transport encryption: **not implemented**. This is an explicit
  trusted-home-LAN prototype boundary, not a pending claim of security.

## Manual gates on the user's devices

1. Build locally. If compilation fails, preserve the error; do not enable Actions.
2. Start, scan, approve. Send harmless text in copy-only mode, then manually paste in
   a blank TextEdit document. Record OS/iPhone versions and whether text matches.
3. Grant Accessibility, enable paste, click TextEdit's text area, choose it on the
   phone, and send a different sentence. Confirm exactly one insertion.
4. Choose TextEdit, then switch the Mac to another app before sending. Expect only
   a clipboard copy and a warning; no automatic insertion in the other app.
5. Expire an armed target (>2 minutes). Expect rejection and preservation of draft.
6. Interrupt a send/receipt and retry it. Within the same receiver session, verify
   no duplicate insertion. After a receiver restart, old credentials must fail.
7. Stop receiving and verify the phone cannot send. Check sleep and locking too.
8. Only after these pass, try the user's actual destination apps in non-sensitive
   documents. A posted paste shortcut is not an application acknowledgement.

No performance, full offline-recognition, secure-transfer or universal-app claim is
made. The first milestone is a harmless sentence in TextEdit, not a shipped product.
