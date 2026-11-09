#!/bin/bash
# Builds build/GhosttyBar.app: universal binary (arm64 + x86_64), Info.plist, ad-hoc signature.
#   ARCHS="arm64" ./build.sh    # one architecture only (faster)
#   STRICT=1 ./build.sh         # treat warnings as errors (CI)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(cat VERSION)"
BUNDLE_ID="com.github.tony-schumacher.GhosttyBar"
MIN_MACOS="14.0"
ARCHS="${ARCHS:-arm64 x86_64}"
APP="build/GhosttyBar.app"
OBJ="build/obj"

FLAGS=(-O -swift-version 6
       -framework AppKit -framework SwiftUI -framework Carbon
       -framework UserNotifications -framework ServiceManagement)
if [ "${STRICT:-0}" = 1 ]; then FLAGS+=(-warnings-as-errors); fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$OBJ"

# SwiftUI in the macOS 27 SDK declares @State as a macro (SwiftUICore.swiftinterface).
# swiftc needs the SwiftUIMacros plugin to expand the macro. The Command Line Tools 27.0
# do not ship the plugin (CommandLineTools/usr/lib/swift/host/plugins, 2026-11-09), so
# swiftc fails on every @State.
# build.sh first checks that swiftc compiles @State with the default SDK. If swiftc fails,
# build.sh tries the installed SDKs from newest to oldest and builds with the first SDK
# where @State compiles. When SDKROOT is set, build.sh skips the check and swiftc uses the
# SDK in SDKROOT.
if [ -z "${SDKROOT:-}" ]; then
    cat > "$OBJ/state-check.swift" <<'SWIFT'
import SwiftUI
struct StateCheck: View {
    @State private var on = false
    var body: some View { EmptyView() }
}
SWIFT
    state_compiles() {
        swiftc -typecheck -swift-version 6 -target "${ARCHS%% *}-apple-macos$MIN_MACOS" \
            -module-cache-path "$OBJ/module-cache" "$@" "$OBJ/state-check.swift" 2>/dev/null
    }
    if ! state_compiles; then
        SDK_FOUND=0
        for sdk in $(find "$(dirname "$(xcrun --show-sdk-path)")" -maxdepth 1 -type d \
                          -name 'MacOSX[0-9]*.sdk' | sort -rV); do
            if state_compiles -sdk "$sdk"; then
                FLAGS+=(-sdk "$sdk")
                SDK_FOUND=1
                echo "Building with $(basename "$sdk"), because swiftc cannot compile @State with the default SDK"
                break
            fi
        done
        if [ "$SDK_FOUND" = 0 ]; then
            echo "swiftc cannot compile @State with any installed macOS SDK. Set SDKROOT to a macOS 26 SDK, because @State compiles with MacOSX26.5.sdk." >&2
        fi
    fi
fi

BINS=()
for arch in $ARCHS; do
    echo "Compiling $arch"
    swiftc "${FLAGS[@]}" -target "$arch-apple-macos$MIN_MACOS" \
        -module-cache-path "$OBJ/module-cache" \
        -o "$OBJ/GhosttyBar-$arch" Sources/GhosttyBar/*.swift
    BINS+=("$OBJ/GhosttyBar-$arch")
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/GhosttyBar"

cat > "$APP/Contents/Info.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>GhosttyBar</string>
    <key>CFBundleDisplayName</key><string>GhosttyBar</string>
    <key>CFBundleExecutable</key><string>GhosttyBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © Tony Schumacher. MIT License.</string>
    <key>NSAppleEventsUsageDescription</key><string>GhosttyBar reads your Ghostty tabs and jumps to the one you pick.</string>
</dict>
</plist>
PL

codesign --sign - --force --identifier "$BUNDLE_ID" "$APP"
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/GhosttyBar"))"
