#!/bin/sh
# Builds the app and fan helper, then installs the app to /Applications.
set -e
cd "$(dirname "$0")"
DEST=/Applications
NAME="Jungwook's Mac Utility"
APP="build/$NAME.app"
[ ! -e "$DEST/MacUtility.app" ] || [ ! -e "$DEST/$NAME.app" ] || { echo "앱이 두 개 있습니다. 설치 위치를 먼저 확인하세요."; exit 1; }
swift build -c release
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources/Memes"
cp .build/release/MacUtility "$APP/Contents/MacOS/MacUtility"
rsync -a --delete .build/release/MacUtility_MacUtility.bundle/Memes/ "$APP/Contents/Resources/Memes/"
cp .build/release/macutility-fan build/macutility-fan
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.gimjungwook.macutility</string>
<key>CFBundleName</key><string>Jungwook's Mac Utility</string>
<key>CFBundleDisplayName</key><string>Jungwook's Mac Utility</string>
<key>CFBundleExecutable</key><string>MacUtility</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.26</string>
<key>CFBundleVersion</key><string>26</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
# A stable identity keeps the Accessibility permission across rebuilds; falls back to ad-hoc.
ID="Apple Development"
security find-identity -v -p codesigning | grep -q "$ID" || ID="-"
codesign --force --sign "$ID" "$APP"
codesign --force --sign - build/macutility-fan
pkill -TERM -x MacUtility 2>/dev/null || true
sleep 2
if [ -d "$DEST/MacUtility.app" ]; then
    mv "$DEST/MacUtility.app" "$DEST/$NAME.app"
fi
# Mirror the bundle, so files an older build left in the installed copy (an old widget, say) disappear.
rsync -a --delete "$APP/" "$DEST/$NAME.app/"
echo "built, installed $DEST/$NAME.app (signed: $ID)"
