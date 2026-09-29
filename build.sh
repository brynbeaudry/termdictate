#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/TermDictate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/TermDictate" "$APP/Contents/MacOS/TermDictate"
cp "Info.plist" "$APP/Contents/Info.plist"

codesign --force --deep --sign - --identifier com.brynbeaudry.termdictate "$APP"

echo "Built $APP"
echo
echo "First run: open '$APP', then grant Accessibility, Microphone, and Speech"
echo "Recognition access when macOS prompts (System Settings > Privacy & Security)."
echo "After granting, relaunch: open '$APP'"
