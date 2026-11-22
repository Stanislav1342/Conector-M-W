#!/bin/bash
# Publishes a new Prilo version on GitHub Releases.
# Usage: scripts/release.sh 0.9.1 [notes.md]
# The Mac app and the Windows receiver find the release through the GitHub API
# and offer the update; other people download the files from the release page.
set -euo pipefail

cd "$(dirname "$0")/.."
version="${1:-}"
notes="${2:-}"
if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; then
    echo "Usage: scripts/release.sh X.Y.Z [notes.md]" >&2
    exit 1
fi
tag="v$version"
plist=mac/Info.plist

command -v gh >/dev/null || { echo "Install GitHub CLI: brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Log in first: gh auth login" >&2; exit 1; }
repository="$(/usr/bin/plutil -extract PriloUpdateRepository raw "$plist")"
[[ "$repository" == */* && "$repository" != OWNER/* ]] || { echo "Set PriloUpdateRepository in $plist" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first." >&2; exit 1; }
[[ "$(git branch --show-current)" == main ]] || { echo "Release from the main branch." >&2; exit 1; }
if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "Tag $tag already exists." >&2
    exit 1
fi
if [[ -n "$notes" && ! -f "$notes" ]]; then
    echo "Notes file $notes not found." >&2
    exit 1
fi

previous="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$plist")"
build="$(/usr/bin/plutil -extract CFBundleVersion raw "$plist")"
python3 - "$previous" "$version" <<'PYTHON'
import sys
old, new = (tuple(int(p) for p in v.split(".")) for v in sys.argv[1:3])
width = max(len(old), len(new))
pad = lambda v: v + (0,) * (width - len(v))
if pad(new) <= pad(old):
    sys.exit(f"New version {sys.argv[2]} must be higher than {sys.argv[1]}.")
PYTHON

/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$plist"
/usr/bin/plutil -replace CFBundleVersion -string "$((build + 1))" "$plist"
restore() { git checkout -- "$plist"; }
trap restore ERR

scripts/check.sh
./build.sh
for file in dist/Prilo-Mac.zip dist/PriloReceiver.exe dist/PriloReceiver-arm64.exe; do
    [[ -s "$file" ]] || { echo "Missing $file" >&2; exit 1; }
done
[[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw dist/Prilo.app/Contents/Info.plist)" == "$version" ]]

git add "$plist"
git commit -m "chore: release $tag"
trap - ERR
git tag -a "$tag" -m "Prilo $version"
git push origin main "$tag"

assets=(dist/Prilo-Mac.zip dist/PriloReceiver.exe dist/PriloReceiver-arm64.exe)
for package in dist/homebridge-prilo-*.tgz; do
    [[ -e "$package" ]] && assets+=("$package")
done
if [[ -n "$notes" ]]; then
    gh release create "$tag" "${assets[@]}" --repo "$repository" --title "Prilo $version" --notes-file "$notes"
else
    gh release create "$tag" "${assets[@]}" --repo "$repository" --title "Prilo $version" --generate-notes
fi
echo "Published $tag: https://github.com/$repository/releases/tag/$tag"
