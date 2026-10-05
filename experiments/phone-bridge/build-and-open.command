#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Build this on your Mac. This script does not use GitHub Actions." >&2; exit 1
fi
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  printf '\nApple developer tools are not installed. Run this once in Terminal:\n\n  xcode-select --install\n\nAfter installation, run this script again. No full Xcode app or paid account is required.\n'
  exit 1
fi
VERSION="$(/usr/bin/sw_vers -productVersion)"
if [[ "${VERSION%%.*}" -lt 12 ]]; then echo "This prototype targets macOS 12 or later." >&2; exit 1; fi
ARCH="$(uname -m)"
case "$ARCH" in x86_64|arm64) ;; *) echo "Unsupported Mac architecture." >&2; exit 1;; esac
if [[ "$(sysctl -in sysctl.proc_translated 2>/dev/null || true)" = "1" ]]; then
  echo "Open a native Terminal, not Terminal running under Rosetta." >&2; exit 1
fi
if /usr/bin/pgrep -x PhoneBridge >/dev/null 2>&1; then
  echo "Quit PhoneBridge from its menu-bar menu, then run this build again." >&2; exit 1
fi
/usr/bin/xcrun --find swiftc >/dev/null
mkdir -p .build
# Compile in a temporary directory; replace the install only after a successful build.
WORK="$(mktemp -d "$PWD/.build/phonebridge.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/PhoneBridge.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
echo "Building the local Mac helper for $ARCH. No packages or speech models are downloaded."
/usr/bin/xcrun swiftc -swift-version 5 -O -target "${ARCH}-apple-macosx12.0" \
  -sdk "$(/usr/bin/xcrun --show-sdk-path)" \
  Sources/BridgeCore.swift Sources/LANServer.swift Sources/PhoneBridge.swift \
  -framework AppKit -framework Network -framework ApplicationServices \
  -framework CoreImage -framework CryptoKit -framework Carbon -framework Security \
  -o "$APP/Contents/MacOS/PhoneBridge"
cp -R Web "$APP/Contents/Resources/Web"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>PhoneBridge</string>
<key>CFBundleDisplayName</key><string>PhoneBridge</string>
<key>CFBundleIdentifier</key><string>io.github.a54dh.phonebridge.prototype</string>
<key>CFBundleExecutable</key><string>PhoneBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Receive finished dictation text from your paired iPhone on your home Wi-Fi.</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
DEST="$HOME/Applications/PhoneBridge.app"
mkdir -p "$HOME/Applications"
if [[ -e "$DEST" ]]; then
  ID="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$ID" != "io.github.a54dh.phonebridge.prototype" || -L "$DEST" ]]; then
    echo "Refusing to overwrite an unrelated app at $DEST" >&2; exit 1
  fi
  rm -rf "$DEST"
fi
cp -R "$APP" "$DEST"
echo "Installed: $DEST"
echo "Start the receiver only on trusted home Wi-Fi. Open TextEdit for your first test."
/usr/bin/open "$DEST"
