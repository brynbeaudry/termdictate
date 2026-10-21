# TermDictate

macOS dictation doesn't work in Terminal.app — the Dictation shortcut starts an audio session but
Terminal never implements the text-insertion protocol Dictation relies on, so nothing gets typed.
TermDictate is a small menu-bar agent that watches for the same right-Command double-tap gesture and, only while
Terminal is frontmost, runs its own on-device speech recognition and types the result in via
synthetic keystrokes instead.

- Only activates when Terminal.app is frontmost; native Dictation still works normally everywhere else.
- Uses Apple's on-device Speech framework — no bundled models, works offline.
- Live-corrects the current sentence as recognition refines its guess (like real Dictation), but
  locks in each utterance once you pause so a later utterance can never wipe out an earlier one.
- Always appends at wherever the keystroke stream currently is — it does not support inserting at
  an arbitrarily repositioned cursor mid-session (see "Known limitations" below).

## Install

Requires Xcode Command Line Tools (`xcode-select -p` to check) and macOS 13+.

```
git clone <this repo> term-dictate
cd term-dictate
./build.sh
```

This builds `build/TermDictate.app`. Launch it with:

```
open build/TermDictate.app
```

On first launch it'll ask for Accessibility access (needed to detect the right-Command double-tap and to type into
Terminal) and open System Settings for you — grant it there. It'll then request Microphone and
Speech Recognition access. Once granted, it stays running as a menu-bar mic icon.

**Signing:** macOS ties the Accessibility grant to the app's code signature. `build.sh` signs with
a "TermDictate Local Signing" certificate from your login keychain if one exists, which keeps the
signature stable so the grant survives rebuilds. Without it, the app is signed ad-hoc, every
rebuild looks like a new app, and you'll need to remove and re-add TermDictate in System Settings >
Privacy & Security > Accessibility after each build. To create the certificate once:

```
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 \
  -subj "/CN=TermDictate Local Signing" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning"
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -out id.p12 -passout pass:td
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P td -T /usr/bin/codesign
rm key.pem cert.pem id.p12
```

### Run at login

To have it start automatically, create a LaunchAgent:

```
cat > ~/Library/LaunchAgents/com.brynbeaudry.termdictate.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.brynbeaudry.termdictate</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>/path/to/term-dictate/build/TermDictate.app</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.brynbeaudry.termdictate.plist
```

## Usage

In Terminal, double-tap right `⌘` to start listening (menu bar icon fills in), speak, double-tap right `⌘`
again to stop. Pausing between sentences is fine — it keeps listening continuously and starts a
fresh recognition pass under the hood without you noticing.

Set System Settings > Keyboard > Dictation > Shortcut to "Press Right Command Key Twice" so native
Dictation uses the same gesture in every other app. This works on any keyboard, including
third-party ones whose fn key never reaches macOS.

## Known limitations

- **No mid-line cursor-aware insertion.** Terminal.app's Accessibility API can read the cursor
  position, but repositioning it via that same API doesn't reliably redirect where synthetic
  keystrokes land — Accessibility IPC and HID keystroke injection are independent pathways that
  don't synchronize with each other. So dictated text always lands wherever the keystroke stream
  is already at; moving the cursor mid-session doesn't redirect new dictation there.
- **Occasional mid-utterance punctuation flicker.** While an utterance is still in progress (before
  a pause), the recognizer can revise its own punctuation guess, so a period/comma can briefly
  appear then disappear. Once a pause locks the utterance in, it's permanent. This is the trade-off
  for also fixing a worse bug where a very long pause could silently drop an entire earlier
  sentence.
- Only tested against Terminal.app; other terminal emulators (iTerm2, etc.) aren't targeted since
  the right-Command interception only checks for Terminal's bundle ID.
