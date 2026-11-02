#!/bin/zsh
# Builds a Developer ID–signed, notarized Prism and packages it as a DMG and a zip in dist/, with the zip signed
# for Sparkle (the EdDSA key in the login Keychain, made by Sparkle's generate_keys). scripts/publish.sh ships it.
# Notarization uses the Apple ID signed into Xcode (Settings › Accounts); no notarytool profile needed.
set -euo pipefail
cd "$(dirname "$0")/../Prism"

VERSION=$(awk -F'"' '/MARKETING_VERSION/{print $2; exit}' project.yml)
BUILD=../build/release
DIST=../dist
rm -rf "$BUILD" && mkdir -p "$BUILD" "$DIST"

echo "▸ Generating project"
xcodegen generate >/dev/null

echo "▸ Archiving Prism $VERSION"
xcodebuild -project Prism.xcodeproj -scheme Prism -configuration Release \
  -derivedDataPath ../.build/Release -archivePath "$BUILD/Prism.xcarchive" archive -quiet

cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>XNRZ2YX628</string>
</dict></plist>
PLIST

echo "▸ Uploading for notarization"
xcodebuild -exportArchive -archivePath "$BUILD/Prism.xcarchive" -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -exportPath "$BUILD/export" -allowProvisioningUpdates -quiet

echo "▸ Waiting for Apple's notary service"
for attempt in {1..180}; do
  if xcodebuild -exportNotarizedApp -archivePath "$BUILD/Prism.xcarchive" -exportPath "$BUILD/notarized" >/dev/null 2>&1; then break; fi
  sleep 20
done
APP="$BUILD/notarized/Prism.app"
[[ -d "$APP" ]] || { echo "Notarization didn't finish in time." >&2; exit 1; }
xcrun stapler validate "$APP" >/dev/null
spctl -a -t exec "$APP"

echo "▸ Packaging"
rm -f "$DIST/Prism-$VERSION.zip" "$DIST/Prism-$VERSION.dmg"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$DIST/Prism-$VERSION.zip"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/" && ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Prism" -srcfolder "$STAGE" -ov -format UDZO -fs APFS "$DIST/Prism-$VERSION.dmg" >/dev/null 2>&1
rm -rf "$STAGE"
"../.build/Release/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update" "$DIST/Prism-$VERSION.zip" > "$DIST/Prism-$VERSION.sig"
echo "✓ dist/Prism-$VERSION.dmg and .zip (notarized, stapled; zip signed for updates)"

echo "▸ Installing to /Applications"
osascript -e 'quit app id "com.mattfalconer.Prism"' >/dev/null 2>&1 || true
pkill -x Prism 2>/dev/null || true
rm -rf /Applications/Prism.app
ditto "$APP" /Applications/Prism.app
echo "✓ Installed /Applications/Prism.app ($VERSION)"
