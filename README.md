# m30bridge

[日本語版 / Japanese](README.ja.md)

A macOS app that exposes the **8BitDo M30 Wired Controller for Xbox** (USB `2dc8:200a`) as a virtual HID gamepad. macOS has no native driver for this controller, so this project reverse-engineers its USB protocol and republishes it as a standard gamepad that emulators and games can see.

## How it works

Reading the controller directly with libusb on macOS only returns periodic "heartbeat" reports, never the real button state (the same code works instantly on Linux; the root cause is not fully understood). As a workaround, the raw USB reading happens in a Linux VM and the decoded state is forwarded to the Mac over UDP.

```
M30 (USB) -> Linux VM (UTM)                         macOS
             m30_udp_sender.py  --- UDP / JSON --->  m30bridge (Swift app)
             (libusb1, decoding,    port 9999        IOHIDUserDevice
              init handshake)                        -> virtual gamepad
```

- **`m30bridge` (Swift/SwiftUI app)** listens on UDP port 9999, builds an HID report from each message, and sends it through `IOHIDUserDeviceCreateWithProperties` / `IOHIDUserDeviceHandleReportWithTimeStamp`.
- **`m30_udp_sender.py` (runs in the Linux VM)** reads the controller with libusb1 using continuously resubmitted interrupt transfers, decodes the 36-byte report, and sends changes as JSON.

## Requirements

- Apple Silicon or Intel Mac, with an Apple Developer Program membership
- The restricted entitlement **`com.apple.developer.hid.virtual.device`**, which must be requested from Apple (Developer portal -> Identifiers -> your App ID -> Capability Requests -> HID Virtual Device) and approved before the app can create a virtual device
- Xcode (the entitlement needs a provisioning profile, so it must be built as an **app target**; a bare SwiftPM executable cannot carry it and is killed at launch)
- A Linux VM with USB passthrough, e.g. UTM + Ubuntu, with `python3` and `libusb1` (`pip install libusb1`)

## Build and run (Mac)

1. Open the project in Xcode and set your own Team and Bundle Identifier.
2. Signing & Capabilities: add **HID Virtual Device** (available after Apple approves your request). Remove **App Sandbox**, or enable *Incoming Connections (Server)*; otherwise `bind()` on the UDP port fails with `Operation not permitted`.
3. Run. The console should print:
   ```
   Creating virtual HID gamepad device...
   Virtual device created and activated. It should now be visible to the system.
   Listening on UDP port 9999. Ctrl+C to stop.
   ```
4. The virtual device appears as **8BitDo M30 (bridged)** in apps such as OpenEmu.

Note: in our testing, creating the virtual device failed (`IOServiceOpen` error, `IOHIDUserDeviceCreateWithProperties returned NULL`) when the physical controller was not connected, and succeeded once it was.

## Run the sender (Linux VM)

1. Pass the M30 through to the VM (UTM: USB menu).
2. Run as root (the script detaches the kernel `xpad` driver itself):
   ```
   sudo python3 m30_udp_sender.py --host 192.168.64.1 --port 9999
   ```
   `192.168.64.1` is the usual Mac address on UTM's shared network; check with `ip route | grep default` inside the VM.
3. On start the script sends the init handshake (below) and prints `Sent init/LED handshake.`, after which the controller's center LED turns solid instead of blinking.

## UDP message format

```json
{"type": "gamepad", "buttons": ["A", "dpad_up"], "trigA": 0, "trigB": 0, "axisX": 0, "axisY": 0}
{"type": "guide", "pressed": true}
```

Button names: `A B X Y menu view dpad_up dpad_down dpad_left dpad_right shoulder_bit4 shoulder_bit5`. `trigA` / `trigB` are 16-bit unsigned trigger values; `axisX` / `axisY` are 16-bit signed D-pad analog values.

## What we learned about the device

- Vendor-specific USB class (`0xFF / 0x47 / 0xD0`), Xbox 360 style but with its own report layout. Endpoints on interface 0: `0x81` IN and `0x01 OUT` (interrupt, 64 bytes).
- Main input report: 36 bytes starting `20 00`. A separate 6-byte report carries the Xbox (guide) button.
- Right after enumeration the Linux `xpad` driver sends three interrupt OUT reports to endpoint `0x01`, captured with usbmon. Replaying them is what makes the LED go solid:
  ```
  05 20 00 01 00
  0a 20 01 03 00 01 14
  06 20 02 02 01 00
  ```
- With the rear switch set to the left, the LSB/RSB buttons do not report; switch positions change which bits are used.
- On Linux, `xpad` only polls the device once something opens `/dev/input/js0`.

## Limitations and ideas

- Requires the Linux VM today. Reading the device natively on macOS through IOKit (`IOUSBHost`) instead of libusb has not been tried.
- Guide button forwarding and trigger/axis scaling still need polish.
- Input goes through the normal OS HID path, so timing is not deterministic; this is not suited to frame-exact TAS-style playback.

## License

MIT
