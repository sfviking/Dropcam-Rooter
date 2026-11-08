#!/bin/sh
export PATH=/sbin:/usr/sbin:/usr/local/bin:/usr/bin:/bin

# Keep one watchdog descriptor open; closing it every ten seconds produces
# "Not stopping watchdog, V first!" messages. Start before network setup.
(
  exec 3>/dev/watchdog
  while true; do
    printf '0' >&3
    sleep 10
  done
) &

# Start telnetd on standard port with shell login
/usr/sbin/telnetd -l /bin/sh &

# Generate SSH host key if it doesn't exist, then start dropbear
if [ ! -f /mnt/dropcam/dropbear_host_key ]; then
  /bin/dropbearkey -t rsa -f /mnt/dropcam/dropbear_host_key
fi
/sbin/dropbear -B -r /mnt/dropcam/dropbear_host_key

# Enable USB Ethernet interface for local diagnostics over USB cable
modprobe g_ether
ifconfig usb0 192.168.75.2 up

# Create a dummy connect script that sleeps forever to avoid CPU load
cat << 'EOF' > /tmp/dummy_connect
#!/bin/sh
while true; do
  sleep 3600
done
EOF
chmod +x /tmp/dummy_connect

# Bind-mount the dummy script over the stock Nest connect client
mount -o bind /tmp/dummy_connect /usr/bin/connect

# Locate and wrap wpa_supplicant to strip the blocking -W flag dynamically on boot
if [ -f /sbin/wpa_supplicant ]; then
  WPA_PATH="/sbin/wpa_supplicant"
elif [ -f /usr/sbin/wpa_supplicant ]; then
  WPA_PATH="/usr/sbin/wpa_supplicant"
else
  WPA_PATH="/usr/bin/wpa_supplicant"
fi

cp "$WPA_PATH" /tmp/wpa_supplicant_real
cat << 'EOF' > /tmp/wpa_supplicant_wrapper
#!/bin/sh
# Rotate the original arguments once, dropping -W without eval/re-parsing.
remaining=$#
while [ "$remaining" -gt 0 ]; do
  arg=$1
  shift
  if [ "$arg" != "-W" ]; then
    set -- "$@" "$arg"
  fi
  remaining=$((remaining - 1))
done
exec /tmp/wpa_supplicant_real "$@"
EOF
chmod +x /tmp/wpa_supplicant_wrapper

# Bind-mount our wrapper over the system binary path
mount -o bind /tmp/wpa_supplicant_wrapper "$WPA_PATH"

# bootstrap.sh starts the supplicant after this hook returns. Starting a
# second instance here races it: failed duplicate startup can leave wlan0 down.
(
  while [ ! -e /sys/class/net/wlan0 ]; do sleep 1; done
  attempts=0
  until wpa_cli -i wlan0 ping 2>/dev/null | grep -q PONG; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
      echo 'No stock Wi-Fi supplicant after 60 seconds' >/tmp/wifi-start.log
      exit 1
    fi
    sleep 1
  done
  ifconfig wlan0 up
  iw dev wlan0 set power_save off
  udhcpc -i wlan0 -b -R
) >/tmp/wifi-start.log 2>&1 &

# Enable only after a successful manual stream test. A failed start leaves
# shell/network access available; it is not retried in a reboot loop.
if [ -f /mnt/dropcam/enable_rtsp ] && [ -f /mnt/dropcam/start_rtsp.sh ]; then
  (
    sleep 5
    sh /mnt/dropcam/start_rtsp.sh
  ) >/tmp/rtsp-start.log 2>&1 &
fi
