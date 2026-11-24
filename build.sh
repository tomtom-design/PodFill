#!/bin/bash
# Builds dist/PodFill.app. Needs only the Command Line Tools.
#
#   ./build.sh               ad-hoc signed app for this Mac's architecture (local use)
#   ./build.sh --universal   same, but one binary for Apple Silicon and Intel
#
# release-mac.sh sources this file and reuses the functions below, then signs with Developer ID.
# PODFILL_DIST overrides the output folder (default: dist).
set -euo pipefail

PODFILL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PODFILL_DIST="${PODFILL_DIST:-$PODFILL_ROOT/dist}"
PODFILL_MIN_MACOS="14.0"   # keep in sync with Package.swift (.macOS(.v14)) and LSMinimumSystemVersion

# Builds the release binary for this Mac's architecture and prints its path.
podfill_build_native() {
    (cd "$PODFILL_ROOT" && swift build -c release --product PodFill >&2)
    echo "$(cd "$PODFILL_ROOT" && swift build -c release --show-bin-path)/PodFill"
}

# Builds arm64 and x86_64 separately (per --triple, which works with the Command Line Tools; the multi --arch
# form needs Xcode's xcbuild), joins them with lipo, checks both slices are there, and prints the path.
# Each architecture gets its own scratch path: recent SwiftPM writes every triple to the same Products folder.
podfill_build_universal() {
    local slices=() arch triple scratch bin out
    for arch in arm64 x86_64; do
        triple="$arch-apple-macosx$PODFILL_MIN_MACOS"
        scratch="$PODFILL_ROOT/.build/release-$arch"
        (cd "$PODFILL_ROOT" && swift build -c release --product PodFill --triple "$triple" --scratch-path "$scratch" >&2)
        bin="$(cd "$PODFILL_ROOT" && swift build -c release --triple "$triple" --scratch-path "$scratch" --show-bin-path)/PodFill"
        lipo -info "$bin" >&2
        slices+=("$bin")
    done
    out="$PODFILL_ROOT/.build/universal/PodFill"
    mkdir -p "$(dirname "$out")"
    lipo -create -output "$out" "${slices[@]}"
    local info
    info="$(lipo -info "$out")"
    echo "$info" >&2
    if [[ "$info" != *x86_64* || "$info" != *arm64* ]]; then
        echo "error: $out is not a universal binary" >&2
        return 1
    fi
    echo "$out"
}

# podfill_assemble_app <binary> [version]: writes $PODFILL_DIST/PodFill.app (unsigned) and prints its path.
podfill_assemble_app() {
    local bin="$1" version="${2:-1.0}"
    local app="$PODFILL_DIST/PodFill.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin" "$app/Contents/MacOS/PodFill"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PodFill</string>
    <key>CFBundleDisplayName</key><string>PodFill</string>
    <key>CFBundleIdentifier</key><string>design.tomtom.podfill</string>
    <key>CFBundleExecutable</key><string>PodFill</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>LSMinimumSystemVersion</key><string>$PODFILL_MIN_MACOS</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
    plutil -lint "$app/Contents/Info.plist" >&2
    echo "$app"
}

podfill_sign_adhoc() {
    codesign --force --deep -s - "$1"
    codesign --verify --deep --strict "$1"
}

# Run as a script (not sourced): local ad-hoc build.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        "") bin="$(podfill_build_native)" ;;
        --universal) bin="$(podfill_build_universal)" ;;
        *) echo "usage: $0 [--universal]" >&2; exit 2 ;;
    esac
    app="$(podfill_assemble_app "$bin")"
    podfill_sign_adhoc "$app"
    echo "Built and signed (ad-hoc): $app"
fi
