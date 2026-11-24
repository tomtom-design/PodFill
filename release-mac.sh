#!/bin/bash
# Builds, signs (Developer ID), notarizes and staples PodFill.app, then attaches PodFill-macOS.zip to the GitHub
# Release for <tag> (creating the release if CI hasn't yet).
#
#   ./release-mac.sh v1.0.0
#
# One-time setup on the release Mac:
#   - a "Developer ID Application" certificate in the login keychain (Xcode > Settings > Accounts > Manage
#     Certificates, or developer.apple.com). Override the pick with PODFILL_SIGN_IDENTITY="<name or SHA-1>".
#   - notary credentials saved as the "PodFill" keychain profile:
#       xcrun notarytool store-credentials PodFill --apple-id <you@example.com> --team-id <TEAMID>
#     (uses an app-specific password from account.apple.com)
#   - gh, logged in to GitHub (gh auth login).
set -euo pipefail

TAG="${1:-}"
PROFILE="PodFill"
cd "$(dirname "$0")"
# shellcheck source=build.sh
source ./build.sh

fail() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "== $*"; }

# --- Preflight: everything that can be checked before building ---------------------------------------------------

[[ -n "$TAG" ]] || fail "usage: $0 <tag>   (for example: $0 v1.0.0)"
[[ "$TAG" == v* ]] || fail "tag '$TAG' should look like v1.0.0"

if [[ -n "${PODFILL_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$PODFILL_SIGN_IDENTITY"
    security find-identity -v -p codesigning | grep -qF "$IDENTITY" \
        || fail "PODFILL_SIGN_IDENTITY='$IDENTITY' is not a valid code-signing identity in your keychain."
else
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*\([0-9A-F]\{40\}\) "\(Developer ID Application: .*\)"$/\1/p' | head -1)"
    [[ -n "$IDENTITY" ]] || fail "no 'Developer ID Application' signing identity in your keychain.
       Create one (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application),
       or set PODFILL_SIGN_IDENTITY. 'security find-identity -v -p codesigning' lists what you have."
fi
echo "Signing identity: $(security find-identity -v -p codesigning | grep -F "$IDENTITY" | head -1 | sed 's/^ *[0-9]*) //')"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null \
    || fail "tag $TAG does not exist. Create and push it first: git tag $TAG && git push origin $TAG"
[[ "$(git rev-parse HEAD)" == "$(git rev-parse "$TAG^{commit}")" ]] \
    || fail "HEAD is not at $TAG. Check it out first (git checkout $TAG) so the app matches the tag."
[[ -z "$(git status --porcelain --untracked-files=no)" ]] \
    || fail "the working tree has uncommitted changes; the release must be built from the tag as committed."

command -v gh >/dev/null || fail "gh (GitHub CLI) is not installed: brew install gh"
gh auth status >/dev/null 2>&1 || fail "gh is not logged in: gh auth login"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 \
    || fail "notarytool keychain profile '$PROFILE' is missing or its credentials don't work.
       Save it once: xcrun notarytool store-credentials $PROFILE --apple-id <you@example.com> --team-id <TEAMID>"

# --- Build ----------------------------------------------------------------------------------------------------------

VERSION="${TAG#v}"
ZIP="$PODFILL_DIST/PodFill-macOS.zip"

step "Universal build"
BIN="$(podfill_build_universal)"
APP="$(podfill_assemble_app "$BIN" "$VERSION")"

# Hardened runtime, secure timestamp. No entitlements: the app only spawns other programs (pipx, spotdl, ffmpeg),
# which the hardened runtime does not restrict; it never loads third-party code into its own process.
step "Sign"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep --verbose=2 "$APP"
codesign --display --verbose=2 "$APP" 2>&1 | grep -E '^(Authority|TeamIdentifier|Timestamp|Runtime Version|flags)' || true

step "Notarize"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
RESULT="$PODFILL_DIST/notarize-result.json"
# Don't let a non-zero exit (rejected upload) skip the log below.
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait --output-format json | tee "$RESULT" || true
echo
STATUS="$(plutil -extract status raw -o - "$RESULT" 2>/dev/null || echo unknown)"
SUBMISSION="$(plutil -extract id raw -o - "$RESULT" 2>/dev/null || echo "")"
if [[ "$STATUS" != "Accepted" ]]; then
    echo "Notarization status: $STATUS" >&2
    [[ -n "$SUBMISSION" ]] && xcrun notarytool log "$SUBMISSION" --keychain-profile "$PROFILE" >&2
    fail "notarization did not succeed (see the log above)."
fi

step "Staple"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"      # re-zip so the download carries the stapled ticket
spctl -a -vvv -t exec "$APP"

step "Upload to the $TAG release"
if gh release view "$TAG" >/dev/null 2>&1; then
    gh release upload "$TAG" "$ZIP" --clobber
elif ! gh release create "$TAG" "$ZIP" --title "PodFill $TAG" --generate-notes --verify-tag; then
    # CI may have created it in the meantime.
    gh release upload "$TAG" "$ZIP" --clobber
fi
echo "Done: $ZIP attached to release $TAG."
