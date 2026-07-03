#!/bin/zsh
# Builds LocalFlow.app — a proper bundle so macOS TCC permissions
# (Microphone, Accessibility, Input Monitoring) attach to the app itself.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=LocalFlow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/LocalFlow "$APP/Contents/MacOS/LocalFlow"
# cat, not cp: the source icns carries a SIP-protected provenance xattr that
# xattr -cr can't remove and codesign rejects as "detritus".
cat AppIcon.icns > "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LocalFlow</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.mattrobertson.localflow</string>
    <key>CFBundleName</key>
    <string>LocalFlow</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>LocalFlow records your voice while you hold the dictation key, transcribes it entirely on this Mac, and types the result. Audio never leaves your machine.</string>
</dict>
</plist>
PLIST

# Prefer a real signing identity (e.g. a self-signed "LocalFlow Dev" cert or
# an Apple Development certificate) — it gives the app a stable identity so
# TCC permission grants survive rebuilds. Ad-hoc fallback breaks grants on
# every build.
# Strip extended attributes/resource forks — real identities refuse to sign
# bundles carrying Finder metadata.
xattr -cr "$APP"

IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NR==1 && /"/{print $2}')
if [[ -n "${IDENTITY:-}" ]]; then
    codesign --force --deep --sign "$IDENTITY" "$APP"
    echo "Signed with identity: $IDENTITY"
else
    codesign --force --deep --sign - "$APP"
    echo "Signed ad-hoc (permissions will reset on each rebuild)"
fi
# Install the freshly built app into /Applications (same signature + bundle
# ID, so TCC grants carry over).
ditto "$APP" /Applications/LocalFlow.app
echo "Built $APP and installed to /Applications/LocalFlow.app"
