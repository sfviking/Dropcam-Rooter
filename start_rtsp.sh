#!/bin/sh
# Run on the camera. Logs and the private compatibility library live in RAM.
set -eu
export PATH=/sbin:/usr/sbin:/usr/local/bin:/usr/bin:/bin
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
RUN_DIR=/tmp/dropcam-rtsp
fail() { echo "[!] $*" >&2; exit 1; }

[ -r /mnt/dropcam/hwver ] || fail 'Missing hardware revision; refusing to guess a sensor.'
HWVER=$(cat /mnt/dropcam/hwver)
case "$HWVER" in
    1|2) SENSOR=ov9710; ENCODE_CFG=/etc/dropcam/encode.cfg ;;
    3|4|5) SENSOR=ar0330; ENCODE_CFG=/etc/dropcam/encode-crownroyal.cfg ;;
    *) fail "Unsupported hardware revision: $HWVER" ;;
esac
[ -r "$ENCODE_CFG" ] || fail "Missing sensor-matched configuration: $ENCODE_CFG"
for program in init.sh mediaserver encode_server image_server rtsp_server; do
    [ -x "/usr/local/bin/$program" ] || fail "Missing /usr/local/bin/$program"
done
mkdir -p "$RUN_DIR"
mkdir "$RUN_DIR/start.lock" 2>/dev/null || fail "Another startup is in progress ($RUN_DIR/start.lock)."
trap 'rmdir "$RUN_DIR/start.lock"' EXIT HUP INT TERM

listening() { netstat -lnt 2>/dev/null | awk '$4 ~ /:554$/ && $6 == "LISTEN" { found=1 } END { exit !found }'; }
healthy() {
    pidof mediaserver >/dev/null && pidof encode_server >/dev/null &&
        pidof image_server >/dev/null && pidof rtsp_server >/dev/null && listening
}
if healthy; then
    echo '[+] Streaming processes are already running on port 554.'
    exit 0
fi
for program in mediaserver encode_server image_server rtsp_server; do
    if pidof "$program" >/dev/null; then
        fail "Partial streaming stack ($program is running). Reboot before retrying; logs: $RUN_DIR"
    fi
done

# This tested firmware needs a private libpthread copy. An unknown build fails
# closed instead of risking another kernel oops. No global LD_LIBRARY_PATH.
sh "$SCRIPT_DIR/prepare_rtsp_compat.sh" /lib/libpthread-2.13.so "$RUN_DIR/compat"
echo "[+] Initializing hwver=$HWVER sensor=$SENSOR"
# Both depmod AND init must run in this directory: old BusyBox module paths
# can be relative. Do not reload an already initialized video subsystem.
if [ ! -d /sys/module/iav ]; then
    ( cd "/lib/modules/$(uname -r)" && depmod -a && init.sh --"$SENSOR" ) >"$RUN_DIR/init.log" 2>&1 ||
        fail "Video initialization failed; see $RUN_DIR/init.log"
else
    [ -d "/sys/module/$SENSOR" ] || {
        [ "$SENSOR" = ar0330 ] && [ -d /sys/module/mt9t002 ];
    } || fail 'IAV is loaded without the expected sensor; reboot before retrying.'
fi
[ -c /dev/iav ] || fail 'Video device /dev/iav was not created.'

# Firmware 217, Pro revision 3: stock a5s_boot.sh maps ENABLE=88, MODE=89.
# ir.bin selects mode 0 for day, waits 10 ms, then pulses ENABLE low for 750 ms.
set_day_filter() (
    set -e
    gpio=/sys/class/gpio
    for pin in 88 89; do
        [ -d "$gpio/gpio$pin" ] || echo "$pin" > "$gpio/export"
    done
    echo high > "$gpio/gpio88/direction"  # idle before changing polarity
    trap 'echo 1 > "$gpio/gpio88/value"' EXIT
    trap 'exit 1' HUP INT TERM
    echo 0 > /sys/class/backlight/pwm-backlight.0/brightness
    echo low > "$gpio/gpio89/direction"
    usleep 10000
    echo 0 > "$gpio/gpio88/value"
    usleep 750000
    # EXIT returns ENABLE to idle. The filter mechanically latches in position.
)

if [ "$HWVER" = 3 ] && [ "$(cat /version 2>/dev/null)" = 217 ]; then
    set_day_filter
fi

# -a starts encode_server, image_server AND rtsp_server. A second RTSP daemon
# competes for port 554. Inherit the private library in all three children.
LD_LIBRARY_PATH="$RUN_DIR/compat" nohup /usr/local/bin/mediaserver -a -f "$ENCODE_CFG" \
    >"$RUN_DIR/media.log" 2>&1 </dev/null &
COUNT=0
while [ "$COUNT" -lt 15 ]; do
    sleep 1
    if healthy; then
        echo '[+] Encoder, image processing and RTSP are running.'
        echo '[+] Open this stream in VLC or ffmpeg (use UDP over Wi-Fi):'
        CAMERA_IP=$(ifconfig wlan0 2>/dev/null | awk -F'inet addr:' 'NF>1 {split($2,a," "); print a[1]}')
        echo "    rtsp://${CAMERA_IP:-192.168.75.2}/stream1"
        echo "[+] Logs: $RUN_DIR (cleared on reboot)"
        exit 0
    fi
    COUNT=$((COUNT + 1))
done
fail "Streaming processes did not become ready; see $RUN_DIR/media.log"
