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

## 6. Camera reboots when local video starts

On a Dropcam Pro (hardware revision 3, firmware 217), sensor detection and DSP microcode loading succeeded. The next failure occurred during thread library startup. The streaming process hit a kernel fault before it could configure the encoder. `prepare_rtsp_compat.sh` creates a checksum-verified copy of the matching library in RAM and `start_rtsp.sh` uses it for the media processes. The helper stops on an unfamiliar library build.

On a camera with an existing administrative shell, place `start_rtsp.sh` and `prepare_rtsp_compat.sh` together under `/mnt/dropcam`. Run `sh /mnt/dropcam/start_rtsp.sh` and open `rtsp://<camera-ip>/stream1` in VLC. The launcher chooses the sensor-specific stock config. `mediaserver -a` starts the encoder, image processing, and RTSP processes itself.

The updated `ie_auto.sh` supports automatic startup when `/mnt/dropcam/enable_rtsp` exists. Removing this marker disables streaming on the next boot. Startup diagnostics are in `/tmp/rtsp-start.log`, `/tmp/dropcam-rtsp/`, and `/tmp/wifi-start.log`.

The tested Pro rejoined Wi-Fi and served H.264 video at 1280×720 after reboot. On the tested network, UDP playback over Wi-Fi was smoother than interleaved TCP. Use TCP when forwarding RTSP through an SSH tunnel. On Pro revision 3 with firmware 217, a daytime scene with pink foliage and sky was caused by the infrared cut filter resting in its night position. The launcher now applies the stock daytime filter pulse when video starts. This selects daytime color on startup. Automatic night switching is not implemented.
