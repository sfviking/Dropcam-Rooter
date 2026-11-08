#!/bin/sh
# Work around the firmware-217 libpthread startup probe that oopses in futex_wait.
# Patch a private copy only; never replace /lib/libpthread.so.0.
set -eu
SOURCE=${1:-/lib/libpthread-2.13.so}
DEST=${2:-/tmp/dropcam-rtsp/compat}
fail() { echo "[!] $*" >&2; exit 1; }
checksum() { cksum "$1" | awk '{print $1 " " $2}'; }
[ -f "$SOURCE" ] || fail "Missing $SOURCE"
[ "$(checksum "$SOURCE")" = '3432750128 88384' ] ||
    fail "Unrecognized libpthread build; refusing to patch. See wiki/Troubleshooting.md."
mkdir -p "$DEST"
# An existing output might be in use by a running streamer. Never truncate it.
if [ -e "$DEST/libpthread.so.0" ]; then
    [ "$(checksum "$DEST/libpthread.so.0")" = '3588202556 88384' ] ||
        fail "Unexpected existing compatibility library in $DEST"
    exit 0
fi
TEMP=$(mktemp "$DEST/.libpthread.XXXXXX")
trap 'rm -f "$TEMP"' EXIT HUP INT TERM
cp "$SOURCE" "$TEMP"
# ARM instruction at file offset 0x4590: svc 0 -> mvn r0, #37 (-ENOSYS).
# This marks FUTEX_CLOCK_REALTIME unsupported and selects glibc's fallback.
printf '\045\000\340\343' | dd of="$TEMP" bs=1 seek=17808 conv=notrunc 2>/dev/null
[ "$(checksum "$TEMP")" = '3588202556 88384' ] || fail 'Patched library verification failed'
chmod 755 "$TEMP"
mv "$TEMP" "$DEST/libpthread.so.0"
