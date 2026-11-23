#!/bin/bash
set -euo pipefail

base="$(cd "$(dirname "$0")/.." && pwd)"
adopt=false
if [[ "${1:-}" == "--adopt-adhoc" ]]; then
    adopt=true
    shift
fi
source_app="${1:-$base/dist/Conector-M-W.app}"
applications="${CONECTOR_INSTALL_DIR:-$base/app}"
installed="$applications/Conector-M-W.app"
"$base/scripts/sign-mac.sh" verify "$source_app"

if [[ -L "$installed" ]]; then
    printf '%s\n' "Refusing to replace a symbolic link at $installed" >&2
    exit 1
fi
replace=false
if [[ -e "$installed" ]]; then
    if ! "$base/scripts/sign-mac.sh" verify "$installed" 2>/dev/null; then
        if [[ "$adopt" != true ]]; then
            printf '%s\n' "The installed app has another signing identity. For an older ad-hoc build only, rerun with --adopt-adhoc." >&2
            exit 1
        fi
        /usr/bin/codesign --verify --strict "$installed"
        identifier="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$installed/Contents/Info.plist")"
        details="$(/usr/bin/codesign -d --verbose=4 "$installed" 2>&1)"
        if [[ "$identifier" != "com.stanislav1342.conector-m-w" ]] || ! grep -Fxq 'Signature=adhoc' <<< "$details"; then
            printf '%s\n' "The installed app is not an older ad-hoc Conector-M-W build." >&2
            exit 1
        fi
    fi
    replace=true
    processes="$(ps -ax -o comm=)"
    if grep -Fxq "$installed/Contents/MacOS/Conector-M-W" <<< "$processes"; then
        printf '%s\n' "Quit the installed copy of Conector-M-W, then run the update again." >&2
        exit 1
    fi
fi

mkdir -p "$applications"
temporary="$(mktemp -d "$applications/.conector-update.XXXXXX")"
candidate="$temporary/Conector-M-W.app"
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
printf '%s\n' "Installed Conector-M-W at: $installed"
