#!/bin/bash
# Sends the app's CloudKit schema to iCloud *Development* from this Mac — the
# first half of the Console ritual (README → Data and sync). The second half,
# Deploy Schema Changes to Production, is only possible in the CloudKit
# Console: there's no API for it.
#
#   scripts/cloudkit/init-schema.sh
#
# Why a script: on this Mac Xcode has no Apple ID, so it can't sign a Debug
# build for iCloud, and the simulator isn't signed in to iCloud either. What
# the Mac does still have is an Apple Development certificate and a Mac
# development profile. So this builds the Mac app unsigned, signs it by hand
# with them, and runs it with -InitializeCloudKitSchema YES — the launch that
# opens only throwaway in-memory stores, never the real ones.
#
# The profile on this Mac is for the *release* app ID (com.bhavikjain.trackers),
# not Debug's .dev one, so the run shares the TestFlight app's sandbox
# container. That's safe for this launch only: it never opens a real store
# (CLAUDE.md explains why a normal Debug build with the release ID is not).
# If a Mac profile for com.bhavikjain.trackers.dev exists, it's used instead.
#
# Nothing here is left behind: the build lives in DerivedData and is deleted
# on exit, whatever happens.
#
# Overrides: SIGN_IDENTITY="Apple Development: …", PROFILE=/path/to/x.provisionprofile,
# TIMEOUT=seconds (default 300).

set -euo pipefail

TEAM=Y4M3S6H4NK
CONTAINER=iCloud.com.bhavikjain.trackers
TIMEOUT=${TIMEOUT:-300}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK="$HOME/Library/Developer/Xcode/DerivedData/Multitrack-schema-init"
LOG="$WORK/run.log"
APP_PID=""

cleanup() {
    [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

die() { echo "error: $*" >&2; exit 1; }

# MARK: - Signing identity and profile

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
fi
[[ -n "$SIGN_IDENTITY" ]] || die "no Apple Development certificate in the keychain. Xcode → Settings → Accounts → Manage Certificates makes one."

THIS_MAC=$(system_profiler SPHardwareDataType | awk -F': ' '/Provisioning UDID/ {print $2}')

# Prints "<bundle id> <path>" for the best Mac development profile: the
# .dev app ID first, then the release one; only ones that list this Mac,
# carry CloudKit and haven't expired.
find_profile() {
    local wanted best_release="" best_dev=""
    local plist
    plist=$(mktemp)
    for dir in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles"; do
        [[ -d "$dir" ]] || continue
        for file in "$dir"/*.provisionprofile; do
            [[ -f "$file" ]] || continue
            security cms -D -i "$file" > "$plist" 2>/dev/null || continue
            local app expiry
            app=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$plist" 2>/dev/null) || continue
            /usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.developer.icloud-services' "$plist" >/dev/null 2>&1 || continue
            /usr/libexec/PlistBuddy -c 'Print :ProvisionedDevices' "$plist" 2>/dev/null | grep -q "$THIS_MAC" || continue
            expiry=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$plist")
            [[ $(date -j -f '%a %b %d %T %Z %Y' "$expiry" +%s 2>/dev/null || echo 0) -gt $(date +%s) ]] || continue
            case "$app" in
                "$TEAM.com.bhavikjain.trackers.dev") best_dev=$file ;;
                "$TEAM.com.bhavikjain.trackers") best_release=$file ;;
            esac
        done
    done
    rm -f "$plist"
    if [[ -n "$best_dev" ]]; then echo "com.bhavikjain.trackers.dev $best_dev"
    elif [[ -n "$best_release" ]]; then echo "com.bhavikjain.trackers $best_release"
    fi
}

if [[ -n "${PROFILE:-}" ]]; then
    BUNDLE_ID=$(security cms -D -i "$PROFILE" | plutil -extract Entitlements.com\\.apple\\.application-identifier raw - | sed "s/^$TEAM\.//")
else
    read -r BUNDLE_ID PROFILE < <(find_profile) || true
fi
[[ -n "${PROFILE:-}" && -f "$PROFILE" ]] || die "no Mac development profile for com.bhavikjain.trackers(.dev) that lists this Mac ($THIS_MAC). Building the Mac app once in Xcode, signed in, makes one."

echo "Signing as:  $SIGN_IDENTITY"
echo "Profile:     $(basename "$PROFILE") ($BUNDLE_ID)"
[[ "$BUNDLE_ID" == "com.bhavikjain.trackers" ]] && echo "             release app ID — fine for this launch only, see the header"

# MARK: - Build (unsigned) and sign

mkdir -p "$WORK"
cd "$ROOT"
command -v xcodegen >/dev/null || die "xcodegen isn't installed (brew install xcodegen)"
xcodegen generate --quiet

echo "Building the Mac app (Debug, unsigned)…"
xcodebuild build -project bhavik-ios.xcodeproj -scheme bhavik-macOS -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath "$WORK/dd" \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" CODE_SIGNING_ALLOWED=NO -quiet > "$WORK/build.log" 2>&1 \
    || { grep -E 'error:' "$WORK/build.log" >&2; die "the build failed"; }

APP="$WORK/dd/Build/Products/Debug/Multitrack.app"
[[ -d "$APP" ]] || die "no app at $APP"

# Xcode won't sign with an Xcode-managed profile under manual signing ("is
# Xcode managed, but signing settings require a manually managed profile"),
# so it's done by hand, the way testflight.yml's mac job does it.
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
ENTITLEMENTS="$WORK/app.entitlements"
sed -e "s/\$(TeamIdentifierPrefix)\$(CFBundleIdentifier)/$TEAM.$BUNDLE_ID/g" \
    -e "s/\$(TeamIdentifierPrefix)/$TEAM./g" \
    App/Resources/App-macOS.entitlements > "$ENTITLEMENTS"
if grep -q '\$(' "$ENTITLEMENTS"; then
    die "App-macOS.entitlements has a \$(…) variable this script doesn't fill in: $(grep -o '\$([A-Za-z_]*)' "$ENTITLEMENTS" | sort -u | tr '\n' ' ')"
fi
# Restricted entitlements (iCloud, push) are only honoured when the
# signature also names the app and team, as Xcode's own signing does.
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" \
    -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENTITLEMENTS"

find "$APP/Contents" \( -name '*.dylib' -o -name '*.framework' \) -prune -print0 \
    | xargs -0 -I{} codesign --force --sign "$SIGN_IDENTITY" --timestamp=none {} >/dev/null 2>&1
codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS" --timestamp=none "$APP"
codesign --verify --strict "$APP" || die "the signature doesn't verify"

# MARK: - Run

echo "Sending the schema to $CONTAINER (Development)…"
# -ApplePersistenceIgnoreState: with the release app ID, the run inherits the
# TestFlight app's saved window state and opened no window at all — and the
# initializer runs from its window, so nothing happened. NSUnbufferedIO: the
# result is print()ed, and a pipe to a file held it back until exit.
NSUnbufferedIO=YES "$APP/Contents/MacOS/Multitrack" \
    -InitializeCloudKitSchema YES -ApplePersistenceIgnoreState YES > "$LOG" 2>&1 &
APP_PID=$!
disown "$APP_PID"   # no "Terminated: 15" from the shell when cleanup ends it

for ((elapsed = 0; elapsed < TIMEOUT; elapsed += 2)); do
    if grep -q '\[CloudKitSchemaInitializer\] Schema sent to Development' "$LOG"; then
        grep '\[CloudKitSchemaInitializer\]' "$LOG"
        echo
        echo "Done. Next, in the CloudKit Console (https://icloud.developer.apple.com):"
        echo "  $CONTAINER → Development: check the new record types/fields are there,"
        echo "  then Deploy Schema Changes to Production — before any TestFlight build ships them."
        exit 0
    fi
    if grep -q '\[CloudKitSchemaInitializer\] Failed' "$LOG"; then
        grep '\[CloudKitSchemaInitializer\]' "$LOG" >&2
        die "the schema run failed; nothing was changed in CloudKit"
    fi
    kill -0 "$APP_PID" 2>/dev/null || { cat "$LOG" >&2; die "the app quit before finishing"; }
    sleep 2
done
cat "$LOG" >&2
die "no result after ${TIMEOUT}s. Is this Mac signed in to iCloud (System Settings → Apple Account)?"
