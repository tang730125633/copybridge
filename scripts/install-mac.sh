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
<key>ProgramArguments</key><array><string>$APP/Contents/MacOS/CopyBridge</string><string>--background</string></array>
<key>RunAtLoad</key><true/>
<key>ThrottleInterval</key><integer>10</integer>
</dict></plist>
EOF
chmod 600 "$PLIST"
LINK="$HOME/Desktop/CopyBridge.app"
if [ ! -e "$LINK" ] && [ ! -L "$LINK" ]; then
  ln -s "$APP" "$LINK"
elif [ ! -L "$LINK" ] || [ "$(readlink "$LINK")" != "$APP" ]; then
  printf '%s\n' 'An existing desktop item was preserved; create the launch link manually.' >&2
  exit 1
fi
printf '%s\n' 'Login configuration and desktop launch link prepared. Enable with launchctl bootstrap in the current GUI session.'
