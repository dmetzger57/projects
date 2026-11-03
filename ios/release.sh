#!/bin/sh
# Archive Proj and upload it to App Store Connect (→ TestFlight).
# Requires a paid Apple Developer Program team selected in Xcode (Signing & Capabilities).
#
#   sh ios/release.sh                 # checks, archive, upload
#   sh ios/release.sh --export-only   # checks, archive, export .ipa to ios/build/export (no upload)
#
# Environment (all optional):
#   TEAM_ID        team to sign with (default: DEVELOPMENT_TEAM from the Xcode project)
#   BUILD_NUMBER   CFBundleVersion (default: date-based, e.g. 20261103.1530 — always increasing)
#   ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH
#                  App Store Connect API key; without it Xcode's signed-in account is used
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HERE/build"
DEST=upload
[ "${1:-}" = "--export-only" ] && DEST=export

TEAM=${TEAM_ID:-$(sed -n 's/.*DEVELOPMENT_TEAM = \([A-Z0-9]*\);.*/\1/p' "$HERE/Proj.xcodeproj/project.pbxproj" | head -1)}
BUILD=${BUILD_NUMBER:-$(date +%Y%m%d.%H%M)}
[ -n "$TEAM" ] || { echo "No team set: choose your team in Xcode → Proj target → Signing & Capabilities, or set TEAM_ID." >&2; exit 1; }

set --
if [ -n "${ASC_KEY_ID:-}" ]; then
  set -- -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"
fi

echo "==> Core checks"
(cd "$HERE/ProjKit" && swift run -q Checks | tail -1)

echo "==> Archiving build $BUILD (team $TEAM)"
rm -rf "$OUT"
mkdir -p "$OUT"
xcodebuild -project "$HERE/Proj.xcodeproj" -scheme Proj -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/Proj.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD" DEVELOPMENT_TEAM="$TEAM" \
  -allowProvisioningUpdates "$@" archive -quiet

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>destination</key><string>$DEST</string>
	<key>teamID</key><string>$TEAM</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>manageAppVersionAndBuildNumber</key><false/>
</dict>
</plist>
EOF

echo "==> $( [ "$DEST" = upload ] && echo Uploading to App Store Connect || echo Exporting .ipa )"
xcodebuild -exportArchive -archivePath "$OUT/Proj.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates "$@" -quiet

if [ "$DEST" = upload ]; then
  echo "Uploaded build $BUILD. It appears in App Store Connect → TestFlight after processing (usually 5–30 min)."
else
  echo "Exported to $OUT/export"
fi
