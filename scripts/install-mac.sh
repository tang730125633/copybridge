#!/bin/sh
set -eu
APP="$HOME/Applications/CopyBridge.app"
LABEL=local.copybridge.mac
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
[ -x "$APP/Contents/MacOS/CopyBridge" ]
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/CopyBridge</string></array>
<key>RunAtLoad</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
</dict></plist>
EOF
chmod 600 "$PLIST"
ln -s "$APP" "$HOME/Desktop/CopyBridge.app" 2>/dev/null || test -L "$HOME/Desktop/CopyBridge.app"
printf '%s\n' 'Login configuration and desktop launch link prepared. Enable with launchctl bootstrap in the current GUI session.'
