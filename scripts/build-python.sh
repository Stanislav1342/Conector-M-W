#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
if [ -d "$root/.local/llvm-mingw/bin" ]; then
    export PATH="$root/.local/llvm-mingw/bin:$PATH"
fi
version="$(plutil -extract CFBundleShortVersionString raw mac/Info.plist)"
package_version="${CONECTOR_PYTHON_VERSION:-${PRILO_PYTHON_VERSION:-$version}}"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
output="$root/dist/python"
mkdir -p "$output"

for target in "${@:-amd64}"; do
    case "$target" in
        amd64) tag=win_amd64; compiler="${CONECTOR_CC_AMD64:-${PRILO_CC_AMD64:-x86_64-w64-mingw32-clang}}" ;;
        arm64) tag=win_arm64; compiler="${CONECTOR_CC_ARM64:-${PRILO_CC_ARM64:-aarch64-w64-mingw32-clang}}" ;;
        *) echo "Unsupported target: $target" >&2; exit 2 ;;
    esac
    tree="$stage/$tag"
    info="$tree/prilo_receiver-$package_version.dist-info"
    mkdir -p "$info/licenses" "$tree/prilo_receiver"
    cp python/prilo_receiver/*.py "$tree/prilo_receiver/"
    (
        cd windows
        export GOOS=windows GOARCH="$target" CGO_ENABLED=1 CC="$compiler"
        go build -buildmode=c-shared -tags conector_library -trimpath \
            -ldflags "-X main.version=$package_version -linkmode=external -extldflags=-static" \
            -o "$tree/prilo_receiver/prilo_receiver.dll" .
        go_root="$(go env GOROOT)"
        go_license="$go_root/LICENSE"
        if [ ! -f "$go_license" ]; then go_license="$go_root/../LICENSE"; fi
        cp "$go_license" "$info/licenses/Go-LICENSE"
        go list -deps -tags conector_library -f '{{with .Module}}{{if not .Main}}{{.Path}} {{.Dir}}{{end}}{{end}}' . |
            sort -u | while read -r module directory; do
                [ -n "$module" ] || continue
                for filename in LICENSE LICENSE.md LICENSE.txt NOTICE NOTICE.txt; do
                    if [ -f "$directory/$filename" ]; then
                        cp "$directory/$filename" "$info/licenses/${module//\//_}-$filename"
                    fi
                done
            done
    )
    rm -f "$tree/prilo_receiver/prilo_receiver.h"
    cat > "$info/METADATA" <<METADATA
Metadata-Version: 2.4
Name: prilo-receiver
Version: $package_version
Summary: Native Windows receiver for Conector-M-W
Requires-Python: >=3.9
Project-URL: Source, https://github.com/Stanislav1342/Conector-M-W
Description-Content-Type: text/markdown
METADATA
    for license in "$info"/licenses/*; do
        printf 'License-File: %s\n' "$(basename "$license")" >> "$info/METADATA"
    done
    printf '\n' >> "$info/METADATA"
    cat python/README.md >> "$info/METADATA"
    cat > "$info/WHEEL" <<WHEEL
Wheel-Version: 1.0
Generator: Conector-M-W
Root-Is-Purelib: false
Tag: py3-none-$tag
WHEEL
    "${CONECTOR_PYTHON:-${PRILO_PYTHON:-python3}}" -m wheel pack "$tree" --dest-dir "$output"
done
