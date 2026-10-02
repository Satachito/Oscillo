#!/bin/bash
# Builds the Mac App Store package: PiLyzer.app, Universal, in the App Sandbox,
# signed for the store and wrapped in an installer package for Transporter.
#
#   ./Scripts/make-appstore.sh
#
# PROFILE is the Mac App Store provisioning profile for tokyo.828.pilyzer,
# downloaded from developer.apple.com. It is looked for in _appstore/ at the
# top of the repository, which git ignores: the profile is not committed. The two certificates are looked up in
# the keychain — "Apple Distribution" for the app, "3rd Party Mac Developer
# Installer" (shown as Mac Installer Distribution) for the package — or named
# with APP_IDENTITY and INSTALLER_IDENTITY. BUILD is the build number App Store
# Connect sees; it must grow with every upload, so it defaults to the time.
set -euo pipefail

cd "$(dirname "$0")/.."
PROFILE="${PROFILE:-../_appstore/PiLyzer_Mac_App_Store.provisionprofile}"
[ -f "$PROFILE" ] || { echo "No profile at $PROFILE" >&2; exit 1; }
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"

identity() {  # the first valid identity in the keychain whose name starts with $1
    security find-identity -v | sed -n "s/.*\"\($1[^\"]*\)\".*/\1/p" | head -1
}
APP_IDENTITY="${APP_IDENTITY:-$(identity 'Apple Distribution')}"
APP_IDENTITY="${APP_IDENTITY:-$(identity '3rd Party Mac Developer Application')}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-$(identity '3rd Party Mac Developer Installer')}"
[ -n "$APP_IDENTITY" ] || { echo 'No "Apple Distribution" certificate in the keychain (Xcode → Settings → Accounts → Manage Certificates).' >&2; exit 1; }
[ -n "$INSTALLER_IDENTITY" ] || { echo 'No "Mac Installer Distribution" certificate in the keychain (Xcode → Settings → Accounts → Manage Certificates).' >&2; exit 1; }

# What the profile allows: this app, this team, the Mac App Store.
WORK="build/appstore"
rm -rf "$WORK"; mkdir -p "$WORK"
security cms -D -i "$PROFILE" > "$WORK/profile.plist"
APP_ID=$(plutil -extract Entitlements.com\\.apple\\.application-identifier raw -o - "$WORK/profile.plist")
TEAM=$(plutil -extract Entitlements.com\\.apple\\.developer\\.team-identifier raw -o - "$WORK/profile.plist")
[ "$APP_ID" = "$TEAM.tokyo.828.pilyzer" ] || { echo "The profile is for $APP_ID, not $TEAM.tokyo.828.pilyzer" >&2; exit 1; }
if plutil -extract ProvisionedDevices raw -o - "$WORK/profile.plist" >/dev/null 2>&1; then
    echo "The profile lists devices: it is a development profile, not a Mac App Store one" >&2; exit 1
fi

# The same bundle the GitHub release carries, built for both architectures.
UNIVERSAL=1 ./Scripts/make-app.sh
APP="$WORK/PiLyzer.app"
ditto build/PiLyzer.app "$APP"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"

# The sandbox entitlements, plus the identity the store checks against the profile.
cp Scripts/PiLyzer.entitlements "$WORK/entitlements.plist"
plutil -insert com\\.apple\\.application-identifier -string "$APP_ID" "$WORK/entitlements.plist"
plutil -insert com\\.apple\\.developer\\.team-identifier -string "$TEAM" "$WORK/entitlements.plist"

echo "==> Signing with $APP_IDENTITY"
codesign --force --timestamp --options runtime --sign "$APP_IDENTITY" \
    --entitlements "$WORK/entitlements.plist" "$APP"
codesign --verify --deep --strict "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
PKG="build/PiLyzer-$VERSION-$BUILD.pkg"
echo "==> Packaging with $INSTALLER_IDENTITY"
productbuild --component "$APP" /Applications --sign "$INSTALLER_IDENTITY" "$PKG"
pkgutil --check-signature "$PKG" | head -3

echo "==> Done: $PKG (version $VERSION, build $BUILD) — drag it into Transporter"
