#!/bin/sh
#
# Ambarella A5s RTSP Streaming Initialization Script
# Run this script directly on the Dropcam to start the local RTSP video stream.
#
# IMPORTANT (discovered on a Dropcam Pro / ar0330, hwver=3):
#   * The rooted boot environment leaves /sbin out of PATH, so init.sh cannot
#     find `modprobe` and the IAV video driver never loads. We fix PATH below.
#   * busybox modprobe fails to resolve module dependencies ("can't open
#     extra/imgproc.ko") unless modules.dep is regenerated and CWD is the
#     modules dir. We run `depmod -a` from there below.
#   * The encoder config is SENSOR-SPECIFIC. The Dropcam HD (ov9710) uses
#     vin_mode 65524 (720p); the Dropcam Pro (ar0330) MUST use vin_mode 30
#     (2304x1296) — the stock config at /etc/dropcam/encode-crownroyal.cfg.
#     Feeding the HD's 720p vin_mode to the ar0330 makes mediaserver program
#     the VIN into an instant hardware fault/reset.
#   * RTSP on port 554 is served by the separate `rtsp_server` binary, which
#     must be started AFTER mediaserver (not just killed).
#
# KNOWN REMAINING BLOCKER (Dropcam Pro): even with the correct sensor config,
# `mediaserver` triggers a kernel NULL-pointer-dereference oops in the Ambarella
# video driver under the rooted/neutered boot (the stock boot's full init
# sequence, which the driver depends on, is not fully replicated here). The box
# then watchdog-resets a few seconds after mediaserver starts. Finishing this
# needs the camera's physical serial console and reconstruction of the stock
# a5s_boot/connect init order. See wiki/Troubleshooting.md section 6.

# Make modprobe/insmod/depmod reachable (the rooted boot strips /sbin from PATH)
export PATH=/sbin:/usr/sbin:/usr/local/bin:/usr/bin:/bin

# 1. Determine camera hardware version and image sensor
HWVER=1
if [ -f /mnt/dropcam/hwver ]; then
    HWVER=$(cat /mnt/dropcam/hwver)
fi

if [ "$HWVER" = "1" ] || [ "$HWVER" = "2" ]; then
    SENSOR="ov9710"
    STOCK_CFG="/etc/dropcam/encode.cfg"
    echo "[+] Hardware Profile: Dropcam HD (Version $HWVER) -> Sensor: $SENSOR (720p)"
else
    SENSOR="ar0330"
    STOCK_CFG="/etc/dropcam/encode-crownroyal.cfg"
    echo "[+] Hardware Profile: Dropcam Pro (Version $HWVER) -> Sensor: $SENSOR (1080p/2304x1296)"
fi

# 2. Regenerate module dependencies, then load sensor drivers + DSP microcode.
#    depmod from the modules dir fixes busybox modprobe's relative-path failures.
echo "[+] Regenerating module dependencies (depmod)..."
( cd /lib/modules/"$(uname -r)" 2>/dev/null && depmod -a 2>/dev/null )

echo "[+] Initializing Ambarella IAV subsystem and loading $SENSOR driver..."
/usr/local/bin/init.sh --"$SENSOR"
echo "    init.sh returned rc=$?"

# 3. Choose the encoder config. Prefer the stock, sensor-matched config; only
#    fall back to a generated 720p config (HD-oriented) if the stock one is
#    missing. Using the wrong vin_mode for the sensor hard-resets the camera.
if [ -f "$STOCK_CFG" ]; then
    ENCODE_CFG="$STOCK_CFG"
    echo "[+] Using stock sensor-matched encoder config: $ENCODE_CFG"
else
    ENCODE_CFG="/mnt/dropcam/encode.cfg"
    echo "[!] Stock config $STOCK_CFG not found; generating 720p fallback (HD only!)"
    if [ ! -f "$ENCODE_CFG" ]; then
        cat << 'EOF' > "$ENCODE_CFG"
vin_mode		= 65524
vin_framerate	= 17083750
vout_type		= 1
vout_mode		= 65520
vin_mirror		= 0
vin_bayer		= 1

# Stream 0 Settings (720p High Definition - VBR with 1.5 Mbps max limit)
s0_type		= 1
s0_width		= 1280
s0_height		= 720
s0_brc			= 1
s0_vbr_min_bps	= 500000
s0_vbr_max_bps	= 1500000
s0_N			= 30
s0_start		= 1

s1_type		= 0
s2_type		= 0
s3_type		= 0
EOF
    fi
fi

# 4. Terminate any running encoder/RTSP server processes
echo "[+] Cleaning up existing server instances..."
killall -9 rtsp_server mediaserver image_server tcp_stream_server 2>/dev/null
sleep 1

# 5. Start the local media encoder, then the RTSP server (port 554).
echo "[+] Starting mediaserver..."
/usr/local/bin/mediaserver -a -f "$ENCODE_CFG" &
sleep 4

echo "[+] Starting rtsp_server (serves rtsp://<ip>/stream1 on port 554)..."
/usr/local/bin/rtsp_server &
sleep 2

echo "[✓] Setup complete! You can play this stream at:"
WLAN0_IP=$(ifconfig wlan0 2>/dev/null | grep 'inet addr' | awk -F: '{print $2}' | awk '{print $1}')
if [ -n "$WLAN0_IP" ]; then
    echo "    rtsp://$WLAN0_IP/stream1"
else
    echo "    rtsp://<camera_ip>/stream1   (e.g. rtsp://192.168.75.2/stream1 over the USB gadget)"
fi
