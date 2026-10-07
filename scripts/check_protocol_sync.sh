#!/usr/bin/env bash
#
# check_protocol_sync.sh
#
# The text protocol is defined in protocol/obs_protocol.h (C) and mirrored
# in macos-app/.../Models/ObsProtocol.swift. This check fails when a string
# literal from the C header is missing from the Swift implementation, which
# catches protocol drift between the firmware and the macOS app.
#
# Format strings (containing '%') are skipped: the Swift side does not use
# the C printf format, only the prefix/vocabulary.

set -euo pipefail

cd "$(dirname "$0")/.."

HEADER=protocol/obs_protocol.h
SWIFT=macos-app/obs-status-macos-ui/Models/ObsProtocol.swift

[ -f "$HEADER" ] || { echo "Missing $HEADER" >&2; exit 1; }
[ -f "$SWIFT" ] || { echo "Missing $SWIFT" >&2; exit 1; }

fail=0
while IFS= read -r literal; do
    [ -n "$literal" ] || continue
    case "$literal" in
        *%*) continue ;; # printf format string, not a protocol vocabulary string
    esac
    if ! grep -qF "$literal" "$SWIFT"; then
        echo "PROTOCOL OUT OF SYNC: \"$literal\" is defined in $HEADER but missing from $SWIFT" >&2
        fail=1
    fi
done < <(grep '^#define' "$HEADER" | grep -v 'FIRMWARE_VERSION' \
        | sed -n 's/.*"\([^"]*\)".*/\1/p' | sort -u)

if [ "$fail" -ne 0 ]; then
    echo "Protocol definitions have drifted; update ObsProtocol.swift (or the header) to match." >&2
    exit 1
fi

echo "Protocol definitions in sync: $HEADER <-> $SWIFT"
