#!/bin/sh
# Builds an installer package for the Mac app: dist/Proj-<version>.pkg, which puts Proj.app in /Applications.
#   sh ios/Mac/make_pkg.sh <path to the Release Proj.app>
# Signed with a "Developer ID Installer" certificate when you have one (paid Apple Developer Program),
# otherwise unsigned: it installs fine here; on another Mac, approve it in System Settings › Privacy & Security.
set -eu
APP=${1:?usage: make_pkg.sh path/to/Proj.app}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
VERSION=$(cat "$REPO/VERSION")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")
OUT="$REPO/dist"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

codesign --verify --deep --strict "$APP"
mkdir -p "$WORK/root" "$OUT"
ditto "$APP" "$WORK/root/Proj.app"

# Install exactly into /Applications: without this, Installer "upgrades" any other copy of the app it
# finds (e.g. one in a build folder) instead.
pkgbuild --analyze --root "$WORK/root" "$WORK/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c 'Add :0:BundleIsRelocatable bool false' "$WORK/components.plist"

pkgbuild --root "$WORK/root" --component-plist "$WORK/components.plist" --install-location /Applications \
  --identifier com.dmetzger57.proj.app --version "$VERSION" "$WORK/Proj-app.pkg" >/dev/null

cat > "$WORK/distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Proj $VERSION</title>
    <options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"/>
    <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
    <volume-check>
        <allowed-os-versions><os-version min="15.0"/></allowed-os-versions>
    </volume-check>
    <welcome mime-type="text/plain"><![CDATA[Proj $VERSION (build $BUILD) for the Mac.

This installs Proj in your Applications folder. On first launch, choose your Projects folder (Documents › Projects).]]></welcome>
    <choices-outline><line choice="default"><line choice="app"/></line></choices-outline>
    <choice id="default"/>
    <choice id="app" visible="false"><pkg-ref id="com.dmetzger57.proj.app"/></choice>
    <pkg-ref id="com.dmetzger57.proj.app" version="$VERSION" onConclusion="none">Proj-app.pkg</pkg-ref>
</installer-gui-script>
EOF

PKG="$OUT/Proj-$VERSION.pkg"
SIGN=$(security find-identity -v -p basic 2>/dev/null | awk -F'"' '/Developer ID Installer/{print $2; exit}')
if [ -n "$SIGN" ]; then
  productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK" --sign "$SIGN" "$PKG" >/dev/null
  echo "built $PKG (signed: $SIGN)"
else
  productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK" "$PKG" >/dev/null
  echo "built $PKG (unsigned: no Developer ID Installer certificate)"
fi
