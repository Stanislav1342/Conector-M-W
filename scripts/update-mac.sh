#!/bin/bash
set -euo pipefail

base="$(cd "$(dirname "$0")/.." && pwd)"
adopt=false
if [[ "${1:-}" == "--adopt-adhoc" ]]; then
    adopt=true
    shift
fi
source_app="${1:-$base/dist/Prilo.app}"
applications="${PRILO_INSTALL_DIR:-$HOME/Applications}"
installed="$applications/Prilo.app"
"$base/scripts/sign-mac.sh" verify "$source_app"

if [[ -L "$installed" ]]; then
    printf '%s\n' "Refusing to replace a symbolic link at $installed" >&2
    exit 1
fi
replace=false
if [[ -e "$installed" ]]; then
    if ! "$base/scripts/sign-mac.sh" verify "$installed" 2>/dev/null; then
        if [[ "$adopt" != true ]]; then
            printf '%s\n' "The installed app has another signing identity. For the old ad-hoc Prilo only, rerun with --adopt-adhoc." >&2
            exit 1
        fi
        /usr/bin/codesign --verify --strict "$installed"
        identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$installed/Contents/Info.plist")"
        details="$(/usr/bin/codesign -d --verbose=4 "$installed" 2>&1)"
        if [[ "$identifier" != "com.artlee12.prilo" ]] || ! grep -Fxq 'Signature=adhoc' <<< "$details"; then
            printf '%s\n' "The installed app is not an older ad-hoc Prilo build." >&2
            exit 1
        fi
    fi
    replace=true
    processes="$(ps -ax -o comm=)"
    if grep -Fxq "$installed/Contents/MacOS/Prilo" <<< "$processes"; then
        printf '%s\n' "Quit the installed copy of Prilo, then run the update again." >&2
        exit 1
    fi
fi

mkdir -p "$applications"
temporary="$(mktemp -d "$applications/.prilo-update.XXXXXX")"
candidate="$temporary/Prilo.app"
trap 'rm -rf "$temporary"' EXIT
ditto "$source_app" "$candidate"
"$base/scripts/sign-mac.sh" verify "$candidate"
python3 - "$candidate" "$installed" "$replace" <<'PYTHON'
import ctypes
import os
import sys

candidate, installed = map(os.fsencode, sys.argv[1:3])
rename = ctypes.CDLL(None, use_errno=True).renamex_np
rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
rename.restype = ctypes.c_int
# Both paths are in the same user Applications directory.
swap_existing, require_absent = 0x2, 0x4
mode = swap_existing if sys.argv[3] == "true" else require_absent
if rename(candidate, installed, mode) != 0:
    failure = ctypes.get_errno()
    raise OSError(failure, os.strerror(failure), os.fsdecode(installed))
PYTHON
printf '%s\n' "Installed Prilo at: $installed"
