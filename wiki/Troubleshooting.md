# Troubleshooting Guide

This page covers common errors encountered during the installation and management phases, along with their resolutions.

---

## 1. Error: "Could not find the camera USB device"
This error is output by the `gpboot` utility when it cannot communicate with the Ambarella USB bootloader interface.
*   **Resolution:**
    1. Verify that the Micro-USB cable is connected directly to a high-power USB port on your PC (avoid unpowered hubs).
    2. Check `dmesg` or `lsusb` to see if the device is enumerating.
    3. Ensure you are holding down the physical bootloader button on the back of the camera *while* plugging in the cable.

---

## 2. Error: "ipv4: Address already assigned"
This occurs on the host system because the camera's USB Ethernet interface (`usb0`) generates a random MAC address on every boot. This causes Linux to treat it as a new network interface name, leaving the static IP bound to a now-disconnected interface.
*   **Resolution:** Our updated scripts automatically scan for this conflict and delete the old IP registration. If you still encounter routing issues, run:
    ```bash
    sudo ip addr flush dev <old_interface_name>
    ```

---

## 3. Error: "Destination path already exists" (jefferson parser)
This error is thrown by the `jefferson` filesystem extractor if the target extraction directory (`workspace/adc_extracted`) is not empty.
*   **Resolution:**
    The script automatically attempts to clean up this directory. If it fails due to file ownership permissions (files previously written by root), run this command on your host PC to regain ownership:
    ```bash
    sudo chown -R $USER:$USER workspace/
    ```

---

## 4. Telnet fails with "Connection refused"
This occurs if the host IP routing is incorrect or if the interface is being managed by NetworkManager.
*   **Resolution:**
    If you are running a system with NetworkManager (like Pop!_OS or Ubuntu), NetworkManager will attempt to run DHCP on the USB Ethernet interface, eventually timing out and disabling the link. Our scripts run `sudo nmcli device set <interface> managed no` to prevent this. Ensure NetworkManager is not overriding your static IP (`192.168.75.1` or `10.9.9.2`).

---

## 5. Wi-Fi has "NO-CARRIER" state or fails to connect
If the camera boots up but fails to connect to the Wi-Fi AP:
1. Verify that your router supports the 2.4GHz band (some older Atheros chips have poor support for modern 5GHz beamforming configurations).
2. Check if the SSID has special characters or trailing spaces.
3. Make sure the `-W` flag has been stripped successfully in your active `/mnt/dropcam/ie_auto.sh` boot script.

---

## 6. Camera reboots (or hard-resets) when starting the video stream

Symptom: shortly after running `start_rtsp.sh` / `mediaserver`, the camera
reboots (the USB `g_ether` interface re-enumerates with a new MAC, `/tmp` is
wiped, uptime resets). Root-caused on a Dropcam Pro (ar0330, `hwver=3`). Work
through these in order — each was a distinct, real failure:

1. **`init.sh: modprobe: not found` / "Modprobe IAV failed!"** — the rooted boot
   leaves `/sbin` out of `PATH`, so the IAV video kernel module never loads and
   `mediaserver` then faults on uninitialized hardware. Fix: run with
   `PATH=/sbin:/usr/sbin:/usr/local/bin:/usr/bin:/bin` (now done in
   `start_rtsp.sh`).

2. **`insmod: can't open 'extra/imgproc.ko'` / "Insmod failed"** — busybox
   `modprobe` fails to resolve module dependencies from relative paths. Fix:
   `cd /lib/modules/$(uname -r) && depmod -a` before `init.sh` (now done).

3. **Instant hard-reset the moment `mediaserver` starts** — the encoder config
   is sensor-specific. The HD (ov9710) uses `vin_mode 65524` (720p); the Pro
   (ar0330) MUST use `vin_mode 30` (2304x1296). The stock per-sensor configs
   live at `/etc/dropcam/encode.cfg` (HD) and
   `/etc/dropcam/encode-crownroyal.cfg` (Pro — "crownroyal" is the Pro
   codename). Feeding the HD's `vin_mode` to the ar0330 programs the VIN into an
   immediate hardware fault. `start_rtsp.sh` now auto-selects the stock config.

4. **Port 554 never opens** — RTSP is served by the separate `rtsp_server`
   binary, which must be *started* after `mediaserver` (the old scripts only
   `killall`-ed it). Now started by `start_rtsp.sh`.

5. **Remaining blocker (Pro):** even with 1–4 fixed (sensor detected —
   `MT9T002 sensor ID is 0x2604` — and DSP microcode loaded), `mediaserver`
   triggers a **kernel NULL-pointer-dereference oops** in the Ambarella video
   driver (`Unable to handle kernel NULL pointer dereference at virtual address
   00000000`, `Process mediaserver`), and the hardware watchdog resets the box a
   few seconds later. This is because the rooted/neutered boot does not fully
   replicate the stock `a5s_boot`/`connect` initialization sequence the driver
   depends on. Fixing it needs the camera's **physical serial console** (to read
   the full oops PC/backtrace live) and reconstruction of the stock init order —
   it is not fixable from an `encode.cfg` or any userspace tweak.

### Note: the hardware watchdog is NOT the cause of these reboots
`ie_auto.sh` feeds `/dev/watchdog` and the camera is stable for hours at idle
and for 4+ minutes after a clean `init.sh` with no `mediaserver`. The resets
above are the `mediaserver` kernel fault, not watchdog starvation.

### Diagnostic tips used to pin this down
* The camera's busybox `md5sum` applet is **broken** (returns wrong hashes);
  verify transfers with `cksum` instead (confirmed correct via `cksum "abc"`).
* busybox `wget` on the camera intermittently corrupts/segfaults on large files;
  `scp -O` over dropbear is reliable. dropbear accepts root with **any**
  password, which is a far more stable control channel than the auth-less
  `telnetd -l /bin/sh` (whose shell was observed dying on connect).
* To capture a kernel oops that a reboot would otherwise wipe, stream it off the
  device live: on the camera `cat /proc/kmsg | nc <host> 9999`, on the host
  `nc -l 9999 > kmsg.log`. Writing logs to NAND (`/mnt/dropcam`) with frequent
  `sync` can itself provoke `ambarella-nand ... timeout` under load — prefer
  network streaming or tmpfs for diagnostics.
