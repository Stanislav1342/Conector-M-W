#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
app="$PWD/dist/Conector-M-W.app"
mkdir -p dist
cache="$(mktemp -d "$PWD/dist/.conector-build.XXXXXX")"
trap 'rm -rf "$cache"' EXIT
staged="$cache/Conector-M-W.app"
iconset="$cache/Conector.iconset"
mkdir -p "$staged/Contents/MacOS" "$staged/Contents/Resources" "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" mac/ConectorIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" mac/ConectorIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$staged/Contents/Resources/Conector.icns"
cp mac/Info.plist "$staged/Contents/Info.plist"
sdk="${SDKROOT:-$(xcrun --show-sdk-path)}"
if [ -z "${SDKROOT:-}" ]; then
    dev_dir="$(xcode-select -p 2>/dev/null || true)"
    if [ "$dev_dir" = "/Library/Developer/CommandLineTools" ] \
        && [ ! -e "$dev_dir/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ] \
        && [ -d "$dev_dir/SDKs/MacOSX26.sdk" ]; then
        sdk="$dev_dir/SDKs/MacOSX26.sdk"
    fi
fi
swiftc -swift-version 5 -O -sdk "$sdk" -target arm64-apple-macos14.0 -module-cache-path "$cache" \
    mac/*.swift -o "$staged/Contents/MacOS/Conector-M-W"
scripts/sign-mac.sh sign "$staged"
ditto -c -k --keepParent "$staged" "$cache/Conector-M-W-Mac.zip"
if [ -e "$app" ]; then mv "$app" "$cache/previous.app"; fi
if ! mv "$staged" "$app"; then
    if [ -e "$cache/previous.app" ]; then mv "$cache/previous.app" "$app"; fi
    exit 1
fi
mv "$cache/Conector-M-W-Mac.zip" dist/Conector-M-W-Mac.zip
if [ "${1:-}" = "--mac-only" ]; then exit 0; fi
version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw mac/Info.plist)"
repository="$(/usr/bin/plutil -extract ConectorUpdateRepository raw mac/Info.plist)"
(
    export GOCACHE="${CONECTOR_GO_CACHE:-$cache/go}"
    cd windows
    flags="-H=windowsgui -X main.version=$version -X main.updateRepo=$repository"
    GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags="$flags" -o ../dist/ConectorMWReceiver.exe .
    GOOS=windows GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags="$flags" -o ../dist/ConectorMWReceiver-arm64.exe .
)
if command -v npm >/dev/null 2>&1; then
    npm pack ./homebridge --offline --cache "${CONECTOR_NPM_CACHE:-$cache/npm}" --pack-destination dist
fi
