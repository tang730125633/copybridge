#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
APP="$ROOT/build/macos/CopyBridge.app"
mkdir -p "$APP/Contents/MacOS"
swiftc -swift-version 5 -O -framework AppKit -framework CryptoKit -framework Security -framework ImageIO -framework UniformTypeIdentifiers "$ROOT/apps/macos/CopyBridge.swift" -o "$APP/Contents/MacOS/CopyBridge"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.copybridge.mac</string>
<key>CFBundleName</key><string>CopyBridge</string>
<key>CFBundleExecutable</key><string>CopyBridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSLocalNetworkUsageDescription</key><string>在已配对的 Mac 与 Windows 之间同步新复制的内容。</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/CopyBridge" --self-test
shasum -a 256 "$APP/Contents/MacOS/CopyBridge"
