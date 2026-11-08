#!/bin/bash
set -e

echo "============================================="
echo "  Dropcam A5s 'Coconut' USB Rooting Utility  "
echo "============================================="

# 1. Ask user for Wi-Fi credentials
read -p "Enter your Wi-Fi SSID: " WIFI_SSID
read -p "Enter your Wi-Fi Password: " WIFI_PASS

# Determine workspace directories
WORKSPACE_DIR="workspace/adc_extracted"
OUTPUT_DIR="workspace/output"

# Determine path context
if [ -f "../gpboot.c" ]; then
    PARENT_DIR=".."
else
    PARENT_DIR="gopro-usb-tools"
fi

# ---------------------------------------------------------------------------
# telnet_exec: feed commands to the camera's telnet shell and block until they
# actually finish, instead of guessing with fixed `sleep` delays.
#
# It appends a unique sentinel `echo` after the supplied commands and reads the
# session output until that sentinel appears, then tears the connection down.
# Because the remote /bin/sh runs commands synchronously, the sentinel cannot
# print until every preceding command (including a multi-second `nandwrite`)
# has returned -- which removes both the wasted wait on fast links and, more
# importantly, the risk of closing telnet mid-flash and bricking the camera.
#
# Usage:  telnet_exec HOST [TIMEOUT_SECS] <<'CMDS'
#            command one
#            command two
#          CMDS
# Stdout is the session transcript with the sentinel line stripped.
# ---------------------------------------------------------------------------
telnet_exec() {
    local host="$1"
    local timeout_secs="${2:-60}"
    local marker="__RC_DONE_$$_${RANDOM}__"
    local cmds
    cmds="$(cat)"

    {
        sleep 1            # let busybox telnetd finish option negotiation
        printf '%s\n' "$cmds"
        printf 'echo %s\n' "$marker"
        printf 'exit\n'
    } | timeout "$timeout_secs" telnet "$host" 2>/dev/null | {
        while IFS= read -r line; do
            case "$line" in
                *"$marker"*) break ;;
                *) printf '%s\n' "$line" ;;
            esac
        done
    }
    return 0
}

# 2. Boot the camera into RAM first to access the storage
echo ""
echo "=== Step 1: Boot Camera into RAM ==="
echo "Choose an option:"
echo "  1) Boot camera into RAM via USB bootloader (Default)"
echo "  2) Skip bootloader (Camera is already booted in RAM, connect directly)"
read -p "Select option [1/2]: " BOOT_OPTION

if [ "$BOOT_OPTION" != "2" ]; then
    while true; do
        echo "1. Connect your Dropcam via USB in Bootloader Mode."
        read -p "   Press Enter once connected to start booting..."
        echo "[+] Booting temporary Linux kernel into RAM..."
        
        BOOT_SUCCESS=0
        if [ -f "../gpboot.c" ]; then
            (cd .. && sudo ./gpboot --linux) && BOOT_SUCCESS=1 || BOOT_SUCCESS=0
        else
            (cd gopro-usb-tools && sudo ./gpboot --linux) && BOOT_SUCCESS=1 || BOOT_SUCCESS=0
        fi

        if [ $BOOT_SUCCESS -eq 1 ]; then
            echo "  [✓] Camera booted successfully!"
            break
        fi

        echo ""
        echo "[!] Error: Failed to boot camera (USB device not found or permission issue)."
        read -p "Would you like to try again? [y/n]: " TRY_AGAIN
        if [ "$TRY_AGAIN" != "y" ] && [ "$TRY_AGAIN" != "Y" ]; then
            echo "Exiting."
            exit 1
        fi
    done
else
    echo "[+] Skipping bootloader, attempting to connect directly..."
fi

echo "[+] Waiting for virtual Ethernet interface to initialize on host..."
USB_IFACE=""
MAX_RETRIES=30
for ((i=1; i<=MAX_RETRIES; i++)); do
    # Search for network interfaces matching usb or enp... (excluding loopback)
    USB_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E "^usb|^enp|^enx" | head -n 1) || true
    if [ -n "$USB_IFACE" ]; then
        echo "  [✓] Detected USB Ethernet interface: $USB_IFACE"
        break
    fi
    sleep 2
done

if [ -z "$USB_IFACE" ]; then
    echo "[!] Error: Could not detect any USB network interface after 30 seconds."
    echo "    Please verify connections, or manually set your IP to 10.9.9.2/24."
    exit 1
fi

# Configure host IP
# Find and remove conflicting IP from any other interface (due to random MAC on reboot)
CONFLICT_IFACE=$(ip -o addr show | grep "10.9.9.2" | awk '{print $2}')
if [ -n "$CONFLICT_IFACE" ] && [ "$CONFLICT_IFACE" != "$USB_IFACE" ]; then
    echo "[+] Removing conflicting IP 10.9.9.2 from old interface $CONFLICT_IFACE..."
    sudo ip addr del 10.9.9.2/24 dev "$CONFLICT_IFACE" || true
fi
# Disable NetworkManager on this interface to prevent DHCP overrides
if command -v nmcli &> /dev/null; then
    echo "[+] Disabling NetworkManager control on interface $USB_IFACE..."
    sudo nmcli device set "$USB_IFACE" managed no || true
fi
# Check if active interface already has this IP assigned
if ! ip -o addr show dev "$USB_IFACE" | grep -q "10.9.9.2"; then
    echo "[+] Configuring host IP 10.9.9.2 on interface $USB_IFACE (requires sudo)..."
    sudo ip addr add 10.9.9.2/24 dev "$USB_IFACE"
else
    echo "  [✓] Host IP 10.9.9.2 is already configured on interface $USB_IFACE."
fi
sudo ip link set "$USB_IFACE" up || true

# Wait until the camera (10.9.9.1) is pingable
echo "[+] Waiting for camera at 10.9.9.1 to respond to ping..."
PING_RETRIES=20
PING_SUCCESS=0
for ((i=1; i<=PING_RETRIES; i++)); do
    if ping -c 1 -W 1 10.9.9.1 &> /dev/null; then
        echo "  [✓] Camera is online and pingable!"
        PING_SUCCESS=1
        break
    fi
    echo "  ... waiting for link (attempt $i/$PING_RETRIES)"
    sleep 2
done

if [ $PING_SUCCESS -eq 0 ]; then
    echo "[!] Error: Camera at 10.9.9.1 is unreachable."
    echo "    Please verify the network settings on interface $USB_IFACE."
    exit 1
fi

# 3. Pull the stock configuration partition automatically from the camera
echo "[+] Starting local receiver port on host..."
# Start listener on host in background (-l PORT form works for both
# netcat-openbsd and nmap-ncat, the two variants setup.sh installs).
rm -f "$PARENT_DIR/adc_stock.bin"
nc -l 1234 > "$PARENT_DIR/adc_stock.bin" &
NC_PID=$!

echo "[+] Initializing NAND driver and dumping stock configuration partition from camera..."
# dd blocks until the whole partition is streamed; telnet_exec returns only
# once the remote dd|nc pipeline has finished, so no blind sleeps are needed.
telnet_exec 10.9.9.1 180 <<'EOF' >/dev/null
echo ambarella-nand > /sys/bus/platform/drivers/ambarella-nand/bind
dd if=/dev/mtd9 bs=4096 | nc 10.9.9.2 1234
EOF

# Wait for the transfer process to complete
wait "$NC_PID" || true

# Sanity-check the dump before we rely on it as the flash template.
DUMP_SIZE=$(wc -c < "$PARENT_DIR/adc_stock.bin" | tr -d ' ')
if [ "${DUMP_SIZE:-0}" -lt 131072 ]; then
    echo "[!] Error: stock dump is only ${DUMP_SIZE:-0} bytes -- the transfer failed."
    echo "    Check the USB link and retry. Nothing has been written to the camera."
    exit 1
fi
echo "  [✓] Configuration partition dumped ($DUMP_SIZE bytes) to host."

# 4. Extract configuration partition template
echo "[+] Extracting stock configuration partition template..."
# Locate or set up jefferson JFFS2 extraction tool
JEFFERSON=$(command -v jefferson || true)
if [ -z "$JEFFERSON" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -x "$SCRIPT_DIR/venv/bin/jefferson" ]; then
        JEFFERSON="$SCRIPT_DIR/venv/bin/jefferson"
    elif [ -x "$HOME/.local/bin/jefferson" ]; then
        JEFFERSON="$HOME/.local/bin/jefferson"
    elif [ -n "$SUDO_USER" ] && [ -x "/home/$SUDO_USER/.local/bin/jefferson" ]; then
        JEFFERSON="/home/$SUDO_USER/.local/bin/jefferson"
    else
        echo "    Setting up Python virtual environment for jefferson..."
        python3 -m venv "$SCRIPT_DIR/venv"
        "$SCRIPT_DIR/venv/bin/pip" install jefferson
        JEFFERSON="$SCRIPT_DIR/venv/bin/jefferson"
    fi
fi
rm -rf "$WORKSPACE_DIR"
"$JEFFERSON" -d "$WORKSPACE_DIR" "$PARENT_DIR/adc_stock.bin"

# 5. Create modified wpa_supplicant.conf
echo "[+] Configuring Wi-Fi profile..."
cat << EOF > "$WORKSPACE_DIR/wpa_supplicant.conf"
ctrl_interface=/var/run/wpa_supplicant
update_config=1

network={
	ssid="$WIFI_SSID"
	psk="$WIFI_PASS"
	key_mgmt=WPA-PSK
}
EOF

# 6. Create passwordless shadow file
echo "[+] Clearing root password..."
cat << EOF > "$WORKSPACE_DIR/shadow"
root::10933:0:99999:7:::
bin:*:10933:0:99999:7:::
daemon:*:10933:0:99999:7:::
adm:*:10933:0:99999:7:::
lp:*:10933:0:99999:7:::
sync:*:10933:0:99999:7:::
shutdown:*:10933:0:99999:7:::
halt:*:10933:0:99999:7:::
uucp:*:10933:0:99999:7:::
operator:*:10933:0:99999:7:::
nobody:*:10933:0:99999:7:::
default::10933:0:99999:7:::
EOF

# 7. Copy the ie_auto.sh bootloader hook script
echo "[+] Injecting integration engineering execution hook (ie_auto.sh)..."
cp ie_auto.sh "$WORKSPACE_DIR/ie_auto.sh"
chmod +x "$WORKSPACE_DIR/ie_auto.sh"

# 8. Compile the JFFS2 partition image
echo "[+] Compiling new JFFS2 image..."
mkfs.jffs2 -d "$WORKSPACE_DIR" -o "$OUTPUT_DIR/adc_new.bin" -e 0x20000 --pad=3145728 -l
HOST_MD5=$(md5sum "$OUTPUT_DIR/adc_new.bin" | awk '{print $1}')
echo "  [✓] Image compiled successfully at: $OUTPUT_DIR/adc_new.bin (md5: $HOST_MD5)"

# 9. Transfer the modified configuration back to the camera
echo "[+] Starting local sender port on host..."
# Start sender listener on host in background
nc -l 1234 < "$OUTPUT_DIR/adc_new.bin" &
NC_PID=$!

echo "[+] Transferring configuration image to camera..."
telnet_exec 10.9.9.1 180 <<'EOF' >/dev/null
nc 10.9.9.2 1234 > /tmp/adc_new.bin
EOF

# Wait for the transfer to complete
wait "$NC_PID" || true
echo "  [✓] Image transferred to camera (/tmp/adc_new.bin)."

# Verify the image on the camera BEFORE erasing flash. A corrupt USB transfer
# that gets written to mtd9 would brick the camera; bailing here leaves the
# existing (bootable) config partition untouched.
echo "[+] Verifying transferred image against host md5 ($HOST_MD5)..."
VERIFY_OUT=$(telnet_exec 10.9.9.1 60 <<EOF
if md5sum /tmp/adc_new.bin 2>/dev/null | grep -qi '^$HOST_MD5 '; then
  echo RC_MD5_OK
else
  echo RC_MD5_FAIL
  md5sum /tmp/adc_new.bin 2>/dev/null || wc -c /tmp/adc_new.bin
fi
EOF
)
if ! printf '%s\n' "$VERIFY_OUT" | grep -q RC_MD5_OK; then
    echo "[!] Error: image on camera does not match host image (corrupt transfer)."
    echo "    Aborting BEFORE erasing flash so the camera stays bootable. Retry."
    printf '%s\n' "$VERIFY_OUT" | sed 's/^/      /'
    exit 1
fi
echo "  [✓] Image verified on camera (md5 matches)."

# 10. Erase and write flash on the Dropcam
echo "[+] Executing flash update on Dropcam (do NOT unplug until this finishes)..."
# erase && write are chained so a failed erase never proceeds to a write, and
# telnet_exec holds the session open until nandwrite+sync have truly returned.
FLASH_OUT=$(telnet_exec 10.9.9.1 300 <<'EOF'
if /usr/sbin/flash_eraseall /dev/mtd9 && /usr/sbin/nandwrite -p /dev/mtd9 /tmp/adc_new.bin; then
  sync
  echo RC_FLASH_OK
else
  echo RC_FLASH_FAIL
fi
EOF
)
printf '%s\n' "$FLASH_OUT" | sed 's/^/      /'
if ! printf '%s\n' "$FLASH_OUT" | grep -q RC_FLASH_OK; then
    echo ""
    echo "[!] Error: flashing did not report success -- the config partition may be"
    echo "    in an inconsistent state. The RAM kernel is still booted, so re-run the"
    echo "    flash step now; do NOT reboot the camera until a write completes cleanly."
    exit 1
fi

echo ""
echo "[✓] Flashing process complete and verified!"
echo "    Please unplug the camera and plug it back in to boot normally."
echo "    The camera will be accessible on your local network at port 23 (Telnet)."

