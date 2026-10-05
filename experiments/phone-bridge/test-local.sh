#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
swiftc -swift-version 5 Sources/BridgeCore.swift Tests/main.swift -o .build/core-tests
.build/core-tests
# Parsing is NOT macOS framework type-checking. Native compilation is a separate gate.
swiftc -frontend -parse Sources/BridgeCore.swift Sources/LANServer.swift Sources/PhoneBridge.swift
bash -n build-and-open.command
if command -v node >/dev/null; then
  node --check Web/app.js
  node Tests/web.test.cjs
else
  echo "Node not installed; browser unit tests skipped. The app does not require Node."
fi
