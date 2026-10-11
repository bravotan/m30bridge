//
//  m30bridgeApp.swift
//  m30bridge
//
//  Created by Keisuke Urago on 2026/09/20.
//
// m30bridge — receives decoded M30 controller state over UDP (from
// m30_udp_sender.py running in the Linux VM) and publishes it to macOS
// as a real virtual HID gamepad via IOHIDUserDeviceCreateWithProperties.
//
// IMPORTANT: this requires the calling binary to be code-signed with the
// com.apple.developer.hid.virtual.device entitlement, or device creation
// silently returns NULL. See entitlements.plist and README.md.

import Foundation
import IOKit.hid
import Dispatch
import Darwin
import SwiftUI

@main
struct m30bridgeApp: App {
    init() {
        // バックグラウンドスレッドでHIDブリッジを起動
        // (runUDPListenerが無限ループでブロックするため、
        //  メインスレッドで直接呼ぶとUIが固まってしまう)
        DispatchQueue.global(qos: .userInitiated).async {
            print("Creating virtual HID gamepad device...")
            guard let device = createVirtualDevice() else {
                print("Failed to create virtual device. Exiting bridge thread.")
                return
            }
            print("Virtual device created and activated. It should now be visible to the system.")

            let port: UInt16 = 9999
            runUDPListener(port: port, device: device)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}


// MARK: - HID report descriptor
//
// 8-byte input report, no report ID:
//   byte0: 8 buttons (A,B,X,Y,LB,RB,view,menu)
//   byte1: 4 dpad buttons (up,down,left,right) + 4 bits padding
//   byte2: LT  (0-255)
//   byte3: RT  (0-255)
//   byte4-5: left stick X (signed 16-bit LE)
//   byte6-7: left stick Y (signed 16-bit LE)

let reportDescriptor: [UInt8] = [
    0x05, 0x01,        // Usage Page (Generic Desktop)
    0x09, 0x05,        // Usage (Game Pad)
    0xA1, 0x01,        // Collection (Application)

    0x05, 0x09,        //   Usage Page (Button)
    0x19, 0x01,        //   Usage Minimum (1)
    0x29, 0x08,        //   Usage Maximum (8)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x75, 0x01,        //   Report Size (1)
    0x95, 0x08,        //   Report Count (8)
    0x81, 0x02,        //   Input (Data,Var,Abs)   -- byte0: 8 buttons

    0x05, 0x09,        //   Usage Page (Button)
    0x19, 0x09,        //   Usage Minimum (9)
    0x29, 0x0C,        //   Usage Maximum (12)
    0x15, 0x00,        //   Logical Minimum (0)
    0x25, 0x01,        //   Logical Maximum (1)
    0x75, 0x01,        //   Report Size (1)
    0x95, 0x04,        //   Report Count (4)
    0x81, 0x02,        //   Input (Data,Var,Abs)   -- byte1 low nibble: dpad
    0x75, 0x01,        //   Report Size (1)
    0x95, 0x04,        //   Report Count (4)
    0x81, 0x03,        //   Input (Const,Var,Abs)  -- byte1 high nibble: pad

    0x05, 0x01,        //   Usage Page (Generic Desktop)
    0x09, 0x32,        //   Usage (Z)   -- LT
    0x09, 0x35,        //   Usage (Rz)  -- RT
    0x15, 0x00,        //   Logical Minimum (0)
    0x26, 0xFF, 0x00,  //   Logical Maximum (255)
    0x75, 0x08,        //   Report Size (8)
    0x95, 0x02,        //   Report Count (2)
    0x81, 0x02,        //   Input (Data,Var,Abs)   -- byte2,3: LT, RT

    0x09, 0x30,        //   Usage (X)
    0x09, 0x31,        //   Usage (Y)
    0x16, 0x00, 0x80,  //   Logical Minimum (-32768)
    0x26, 0xFF, 0x7F,  //   Logical Maximum (32767)
    0x75, 0x10,        //   Report Size (16)
    0x95, 0x02,        //   Report Count (2)
    0x81, 0x02,        //   Input (Data,Var,Abs)   -- byte4-7: stick X, Y

    0xC0,              // End Collection
]

// MARK: - Virtual device creation

func createVirtualDevice() -> IOHIDUserDevice? {
    let descriptorData = Data(reportDescriptor)

    let properties: [String: Any] = [
        kIOHIDReportDescriptorKey as String: descriptorData,
        kIOHIDVendorIDKey as String: 0x2DC8,
        kIOHIDProductIDKey as String: 0x200A,
        kIOHIDProductKey as String: "8BitDo M30 (bridged)",
        kIOHIDManufacturerKey as String: "m30usb-bridge",
    ]

    guard let device = IOHIDUserDeviceCreateWithProperties(
        kCFAllocatorDefault,
        properties as CFDictionary,
        0
    ) else {
        FileHandle.standardError.write("IOHIDUserDeviceCreateWithProperties returned NULL.\n".data(using: .utf8)!)
        FileHandle.standardError.write(
            "This usually means the binary isn't signed with the com.apple.developer.hid.virtual.device entitlement.\n"
                .data(using: .utf8)!
        )
        return nil
    }

    // Modern API requires scheduling on a dispatch queue and activating
    // before the device is live / before reports can be dispatched.
    let queue = DispatchQueue(label: "m30bridge.hiddevice")
    IOHIDUserDeviceSetDispatchQueue(device, queue)
    IOHIDUserDeviceActivate(device)

    return device
}

// MARK: - Report building

let buttonBits: [String: Int] = [
    "A": 0, "B": 1, "X": 2, "Y": 3,
    "shoulder_bit4": 4, "shoulder_bit5": 5,
    "view": 6, "menu": 7,
]

let dpadBits: [String: Int] = [
    "dpad_up": 0, "dpad_down": 1, "dpad_left": 2, "dpad_right": 3,
]

func buildReport(from state: [String: Any]) -> [UInt8] {
    let buttons = Set((state["buttons"] as? [String]) ?? [])

    var b0: UInt8 = 0
    for (name, bit) in buttonBits where buttons.contains(name) {
        b0 |= (1 << bit)
    }

    var b1: UInt8 = 0
    for (name, bit) in dpadBits where buttons.contains(name) {
        b1 |= (1 << bit)
    }

    let trigA = min(255, (state["trigA"] as? Int ?? 0) >> 2)
    let trigB = min(255, (state["trigB"] as? Int ?? 0) >> 2)
    let axisX = Int16(clamping: state["axisX"] as? Int ?? 0)
    let axisY = Int16(clamping: state["axisY"] as? Int ?? 0)

    var report: [UInt8] = [b0, b1, UInt8(trigA), UInt8(trigB)]
    withUnsafeBytes(of: axisX.littleEndian) { report.append(contentsOf: $0) }
    withUnsafeBytes(of: axisY.littleEndian) { report.append(contentsOf: $0) }
    return report
}

func sendReport(_ report: [UInt8], to device: IOHIDUserDevice) {
    let result = report.withUnsafeBufferPointer { ptr -> IOReturn in
        guard let base = ptr.baseAddress else { return kIOReturnError }
        return IOHIDUserDeviceHandleReportWithTimeStamp(
            device,
            mach_absolute_time(),
            base,
            ptr.count
        )
    }
    if result != kIOReturnSuccess {
        print("IOHIDUserDeviceHandleReportWithTimeStamp failed: \(String(format: "0x%08x", result))")
    }
}

// MARK: - UDP listener (raw BSD sockets, no external dependencies)

func runUDPListener(port: UInt16, device: IOHIDUserDevice) {
    let sock = socket(AF_INET, SOCK_DGRAM, 0)
    guard sock >= 0 else {
        perror("socket")
        exit(1)
    }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = INADDR_ANY

    let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            bind(sock, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        perror("bind")
        exit(1)
    }

    print("Listening on UDP port \(port). Ctrl+C to stop.\n")

    var buffer = [UInt8](repeating: 0, count: 4096)

    while true {
        let n = recv(sock, &buffer, buffer.count, 0)
        guard n > 0 else { continue }

        let data = Data(buffer[0..<n])
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            continue
        }

        if let type = json["type"] as? String, type == "guide" {
            let pressed = json["pressed"] as? Bool ?? false
            print("[guide] \(pressed ? "pressed" : "released")")
            continue
        }

        let report = buildReport(from: json)
        sendReport(report, to: device)
        let hex = report.map { String(format: "%02x", $0) }.joined()
        print("-> report \(hex)  \(json)")
    }
}
