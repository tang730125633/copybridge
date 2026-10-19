#!/bin/sh
set -eu
LABEL=local.copybridge.mac
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ -f "$PLIST" ]; then mv "$PLIST" "$PLIST.disabled"; fi
if [ -L "$HOME/Desktop/CopyBridge.app" ]; then rm "$HOME/Desktop/CopyBridge.app"; fi
printf '%s\n' 'Login startup disabled; application, received files, protected credentials and logs are preserved. Quit any manually opened CopyBridge from its menu.'
