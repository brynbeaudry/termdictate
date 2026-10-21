#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP="build/TermDictate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/release/TermDictate" "$APP/Contents/MacOS/TermDictate"
cp "Info.plist" "$APP/Contents/Info.plist"

# A stable signing identity keeps the Accessibility grant valid across rebuilds;
# ad-hoc signatures change with every build and macOS treats each as a new app.
IDENTITY="TermDictate Local Signing"
if ! security find-identity -p codesigning | grep -q "\"$IDENTITY\""; then
    IDENTITY="-"
    echo "No \"TermDictate Local Signing\" certificate found; signing ad-hoc." >&2
fi
codesign --force --deep --sign "$IDENTITY" --identifier com.brynbeaudry.termdictate "$APP"

echo "Built $APP"
echo
echo "First run: open '$APP', then grant Accessibility, Microphone, and Speech"
echo "Recognition access when macOS prompts (System Settings > Privacy & Security)."
echo "After granting, relaunch: open '$APP'"
