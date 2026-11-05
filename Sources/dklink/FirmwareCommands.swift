import Foundation
import DKCore

// dklink firmware: package inspection, device status, and the update
// sequence as Microsoft's updater performs it.

private func version(_ v: k4a_version_t) -> String { "\(v.major).\(v.minor).\(v.iteration)" }

private func describe(_ package: openk4a_firmware_package_t) {
    print("package \(package.package_valid ? "valid" : "INVALID"), crc \(package.crc_valid ? "ok" : "BAD")")
    if !package.package_valid {
        var why = package.why
        print("  reason: \(withUnsafePointer(to: &why) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) })")
    }
    print("  rgb firmware:   \(version(package.rgb))")
    print("  depth firmware: \(version(package.depth))")
    print("  audio firmware: \(version(package.audio))")
    let configs = withUnsafeBytes(of: package.depth_config) { raw -> [k4a_version_t] in
        let all = raw.bindMemory(to: k4a_version_t.self)
        return (0..<Int(package.depth_config_count)).map { all[$0] }
    }
    print("  depth configs:  " + configs.map { "\($0.major).\($0.minor)" }.joined(separator: ", "))
    print("  build: \(package.build_config == K4A_FIRMWARE_BUILD_RELEASE ? "release" : "debug"), signature: \(signatureName(package.signature_type)), certificate: \(signatureName(package.certificate_type))")
}

private func signatureName(_ s: k4a_firmware_signature_t) -> String {
    switch s {
    case K4A_FIRMWARE_SIGNATURE_MSFT: return "Microsoft"
    case K4A_FIRMWARE_SIGNATURE_TEST: return "test"
    default: return "unsigned"
    }
}

private func describe(_ status: openk4a_firmware_status_t) {
    // A device that has not started an update since power-on reports every
    // step as "in progress" (the status word is zero); say so plainly.
    let idle = [status.depth, status.rgb, status.audio, status.depth_config].allSatisfy {
        $0.overall == OPENK4A_FIRMWARE_OPERATION_INPROGRESS && $0.version_check == OPENK4A_FIRMWARE_OPERATION_INPROGRESS &&
        $0.flash_write == OPENK4A_FIRMWARE_OPERATION_INPROGRESS
    }
    if idle {
        print("  update status: idle (no update started since power-on)")
        return
    }
    func line(_ name: String, _ c: openk4a_firmware_component_status_t) {
        let step = [("version check", c.version_check), ("authentication", c.authentication_check), ("transfer", c.image_transfer),
                    ("erase", c.flash_erase), ("write", c.flash_write)]
            .map { "\($0.0) \(String(cString: openk4a_firmware_operation_name($0.1)))" }.joined(separator: ", ")
        print("  \(name): \(String(cString: openk4a_firmware_operation_name(c.overall))) (\(step))")
    }
    line("depth", status.depth)
    line("rgb", status.rgb)
    line("audio", status.audio)
    line("depth config", status.depth_config)
}

private func loadPackage(_ path: String) -> ([UInt8], openk4a_firmware_package_t) {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    let bytes = [UInt8](data)
    var package = openk4a_firmware_package_t()
    _ = openk4a_firmware_parse_package(bytes, bytes.count, &package)
    return (bytes, package)
}

private func printDeviceVersions(_ device: k4a_device_t) -> k4a_hardware_version_t? {
    var v = k4a_hardware_version_t()
    guard k4a_device_get_version(device, &v) == K4A_RESULT_SUCCEEDED else { return nil }
    print("  device: rgb \(version(v.rgb)), depth \(version(v.depth)), audio \(version(v.audio)), depth config \(v.depth_sensor.major).\(v.depth_sensor.minor)")
    return v
}

func runFirmwareCommand(_ args: [String]) {
    guard let sub = args.first else { usage() }
    switch sub {
    case "info":
        guard args.count > 1 else { usage() }
        let (bytes, package) = loadPackage(args[1])
        print("\(args[1]): \(bytes.count) bytes")
        describe(package)

    case "status":
        let device = openDevice()
        print("serial \(deviceSerial(device))")
        _ = printDeviceVersions(device)
        var status = openk4a_firmware_status_t()
        if openk4a_firmware_status(device, &status) { describe(status) } else { print("  update status: not readable") }
        k4a_device_close(device)

    case "update":
        guard args.count > 1 else { usage() }
        guard args.contains("--yes") else {
            fail("firmware update rewrites the device; add --yes to confirm (and keep it plugged in until it finishes)")
        }
        let (bytes, package) = loadPackage(args[1])
        describe(package)
        guard package.package_valid else { fail("refusing to send an invalid package") }
        let device = openDevice()
        print("serial \(deviceSerial(device))")
        let before = printDeviceVersions(device)
        print("writing \(bytes.count) bytes; this takes a few minutes, do not unplug the camera")
        guard openk4a_firmware_download(device, bytes, bytes.count) else { fail("the device refused the firmware") }
        var status = openk4a_firmware_status_t()
        let finished = openk4a_firmware_wait_update(device, &status, 0)
        print("update \(finished ? "finished" : "did not finish"):")
        describe(status)
        print("resetting the device")
        _ = openk4a_firmware_reset(device)
        k4a_device_close(device)
        // The device re-enumerates; wait for it and read the versions back.
        var reopened: k4a_device_t? = nil
        for _ in 0..<40 {
            Thread.sleep(forTimeInterval: 1)
            var handle: k4a_device_t? = nil
            if k4a_device_open(0, &handle) == K4A_RESULT_SUCCEEDED { reopened = handle; break }
        }
        guard let after = reopened else { fail("the device did not come back after the reset; unplug and replug it") }
        let versions = printDeviceVersions(after)
        k4a_device_close(after)
        let ok = finished &&
            [status.depth, status.rgb, status.audio, status.depth_config].allSatisfy { component in
                withUnsafePointer(to: component) { openk4a_firmware_component_result($0) == OPENK4A_FIRMWARE_OPERATION_SUCCEEDED }
            }
        if let versions, ok {
            let same = versions.rgb == package.rgb && versions.depth == package.depth && versions.audio == package.audio
            print(same ? "device is now on the package's versions" : "versions after the update do not all match the package")
        } else {
            _ = before
            fail("the update did not succeed on every component")
        }

    default:
        usage()
    }
}

private func deviceSerial(_ device: k4a_device_t) -> String {
    var size = 0
    _ = k4a_device_get_serialnum(device, nil, &size)
    var serial = [CChar](repeating: 0, count: max(size, 1) + 1)
    _ = k4a_device_get_serialnum(device, &serial, &size)
    return String(cString: serial)
}

extension k4a_version_t: @retroactive Equatable {
    public static func == (a: k4a_version_t, b: k4a_version_t) -> Bool {
        a.major == b.major && a.minor == b.minor && a.iteration == b.iteration
    }
}
