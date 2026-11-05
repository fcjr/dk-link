import Foundation
import Metal
import DKCore
import Syphon

// dklink: a command-line face on the core, for diagnostics and fixtures.

func usage() -> Never {
    let text = """
    usage: dklink <command> [options]

      list                         devices attached
      info                         serial, firmware, sync jacks
      calibration [out.json]       the device's calibration document
      capture [options]            stream depth/IR and write frames
         --mode <nfov_unbinned|nfov_2x2binned|wfov_unbinned|wfov_2x2binned|passive_ir>
         --fps <5|15|30>  --frames <n>  --out <dir>  [--raw] [--color <720p|1080p|...>]
      imu [--seconds n]            print IMU samples
      color [--frames n] [--out dir] [--res 720p]   colour frames to BGRA files
      controls                     read every colour control
      firmware info <bin>          what a firmware package carries
      firmware status              the device's update status and versions
      firmware update <bin> --yes  write a package to the device (takes minutes; do not unplug)
    """
    FileHandle.standardError.write((text + "\n").data(using: .utf8)!)
    exit(2)
}

func arg(_ name: String, _ fallback: String? = nil) -> String? {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return fallback
}
func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("dklink: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

func openDevice() -> k4a_device_t {
    var device: k4a_device_t? = nil
    guard k4a_device_open(0, &device) == K4A_RESULT_SUCCEEDED, let d = device else {
        fail("no Azure Kinect could be opened")
    }
    return d
}

func depthMode(_ name: String) -> k4a_depth_mode_t {
    switch name.lowercased() {
    case "nfov_unbinned": return K4A_DEPTH_MODE_NFOV_UNBINNED
    case "nfov_2x2binned": return K4A_DEPTH_MODE_NFOV_2X2BINNED
    case "wfov_unbinned": return K4A_DEPTH_MODE_WFOV_UNBINNED
    case "wfov_2x2binned": return K4A_DEPTH_MODE_WFOV_2X2BINNED
    case "passive_ir": return K4A_DEPTH_MODE_PASSIVE_IR
    case "off": return K4A_DEPTH_MODE_OFF
    default: fail("unknown depth mode \(name)")
    }
}

func colorResolution(_ name: String) -> k4a_color_resolution_t {
    switch name.lowercased() {
    case "off": return K4A_COLOR_RESOLUTION_OFF
    case "720p": return K4A_COLOR_RESOLUTION_720P
    case "1080p": return K4A_COLOR_RESOLUTION_1080P
    case "1440p": return K4A_COLOR_RESOLUTION_1440P
    case "1536p": return K4A_COLOR_RESOLUTION_1536P
    case "2160p": return K4A_COLOR_RESOLUTION_2160P
    case "3072p": return K4A_COLOR_RESOLUTION_3072P
    default: fail("unknown colour resolution \(name)")
    }
}

func fps(_ value: Int) -> k4a_fps_t {
    switch value {
    case 5: return K4A_FRAMES_PER_SECOND_5
    case 15: return K4A_FRAMES_PER_SECOND_15
    default: return K4A_FRAMES_PER_SECOND_30
    }
}

func writePGM(_ path: String, _ image: k4a_image_t) {
    let width = Int(k4a_image_get_width_pixels(image))
    let height = Int(k4a_image_get_height_pixels(image))
    guard let buffer = k4a_image_get_buffer(image) else { return }
    var data = Data("P5\n\(width) \(height)\n65535\n".utf8)
    // PGM is big-endian 16-bit.
    let pixels = buffer.withMemoryRebound(to: UInt16.self, capacity: width * height) { $0 }
    var swapped = [UInt16](repeating: 0, count: width * height)
    for i in 0..<(width * height) { swapped[i] = pixels[i].bigEndian }
    swapped.withUnsafeBytes { data.append(contentsOf: $0) }
    try? data.write(to: URL(fileURLWithPath: path))
}

func writeImage(_ path: String, _ image: k4a_image_t) {
    guard let buffer = k4a_image_get_buffer(image) else { return }
    let data = Data(bytes: buffer, count: k4a_image_get_size(image))
    try? data.write(to: URL(fileURLWithPath: path))
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
if flag("--trace") { k4a_set_debug_message_handler(nil, nil, K4A_LOG_LEVEL_TRACE) }

switch command {
case "list":
    let count = k4a_device_get_installed_count()
    print("\(count) Azure Kinect device(s)")
    for index in 0..<count {
        var device: k4a_device_t? = nil
        if k4a_device_open(index, &device) == K4A_RESULT_SUCCEEDED, let d = device {
            var size = 0
            _ = k4a_device_get_serialnum(d, nil, &size)
            var serial = [CChar](repeating: 0, count: size + 1)
            _ = k4a_device_get_serialnum(d, &serial, &size)
            print("  [\(index)] serial \(String(cString: serial))")
            k4a_device_close(d)
        } else {
            print("  [\(index)] (could not open)")
        }
    }

case "info":
    let device = openDevice()
    var size = 0
    _ = k4a_device_get_serialnum(device, nil, &size)
    var serial = [CChar](repeating: 0, count: size + 1)
    _ = k4a_device_get_serialnum(device, &serial, &size)
    print("serial: \(String(cString: serial))")
    var version = k4a_hardware_version_t()
    if k4a_device_get_version(device, &version) == K4A_RESULT_SUCCEEDED {
        print("rgb firmware:   \(version.rgb.major).\(version.rgb.minor).\(version.rgb.iteration)")
        print("depth firmware: \(version.depth.major).\(version.depth.minor).\(version.depth.iteration)")
        print("audio firmware: \(version.audio.major).\(version.audio.minor).\(version.audio.iteration)")
        print("depth sensor:   \(version.depth_sensor.major).\(version.depth_sensor.minor)")
    }
    var inJack = false, outJack = false
    if k4a_device_get_sync_jack(device, &inJack, &outJack) == K4A_RESULT_SUCCEEDED {
        print("sync in: \(inJack)  sync out: \(outJack)")
    }
    k4a_device_close(device)

case "calibration":
    let device = openDevice()
    var size = 0
    _ = k4a_device_get_raw_calibration(device, nil, &size)
    var raw = [UInt8](repeating: 0, count: size)
    guard k4a_device_get_raw_calibration(device, &raw, &size) == K4A_BUFFER_RESULT_SUCCEEDED else { fail("no calibration") }
    let text = String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    if CommandLine.arguments.count > 2 {
        try? text.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)
        print("wrote \(size) bytes to \(CommandLine.arguments[2])")
    } else {
        print(text)
    }
    k4a_device_close(device)

case "capture":
    let mode = depthMode(arg("--mode", "nfov_unbinned")!)
    let rate = Int(arg("--fps", "30")!) ?? 30
    let frames = Int(arg("--frames", "10")!) ?? 10
    let out = arg("--out", ".")!
    let res = colorResolution(arg("--color", "off")!)
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let device = openDevice()
    var config = K4A_DEVICE_CONFIG_INIT_DISABLE_ALL
    config.depth_mode = mode
    config.camera_fps = fps(rate)
    config.color_resolution = res
    config.color_format = K4A_IMAGE_FORMAT_COLOR_BGRA32
    guard k4a_device_start_cameras(device, &config) == K4A_RESULT_SUCCEEDED else { fail("cameras would not start") }
    if flag("--raw") { openk4a_device_set_keep_raw(device, true) }
    var written = 0
    var dropped = 0
    let start = Date()
    while written < frames {
        var capture: k4a_capture_t? = nil
        let result = k4a_device_get_capture(device, &capture, 2000)
        if result == K4A_WAIT_RESULT_TIMEOUT { dropped += 1; if dropped > 10 { fail("no frames arriving") }; continue }
        guard result == K4A_WAIT_RESULT_SUCCEEDED, let c = capture else { fail("capture failed") }
        if let depth = k4a_capture_get_depth_image(c) {
            writePGM("\(out)/depth_\(written).pgm", depth)
            let ts = k4a_image_get_device_timestamp_usec(depth)
            print("frame \(written): depth \(k4a_image_get_width_pixels(depth))x\(k4a_image_get_height_pixels(depth)) t=\(ts)us temp=\(k4a_capture_get_temperature_c(c))C")
            k4a_image_release(depth)
        }
        if let ir = k4a_capture_get_ir_image(c) {
            writePGM("\(out)/ir_\(written).pgm", ir)
            k4a_image_release(ir)
        }
        if let color = k4a_capture_get_color_image(c) {
            writeImage("\(out)/color_\(written).bgra", color)
            print("   colour \(k4a_image_get_width_pixels(color))x\(k4a_image_get_height_pixels(color)) t=\(k4a_image_get_device_timestamp_usec(color))us")
            k4a_image_release(color)
        }
        if flag("--raw") {
            var size = 0
            if let raw = openk4a_device_last_raw(device, &size) {
                try? Data(bytes: raw, count: size).write(to: URL(fileURLWithPath: "\(out)/raw_\(written).bin"))
            }
        }
        k4a_capture_release(c)
        written += 1
    }
    let seconds = Date().timeIntervalSince(start)
    print(String(format: "%d frames in %.2fs (%.1f fps)", written, seconds, Double(written) / seconds))
    if flag("--raw") {
        var size = 0
        if let block = openk4a_device_calibration_block(device, &size) {
            try? Data(bytes: block, count: size).write(to: URL(fileURLWithPath: "\(out)/calibration_block.bin"))
            print("calibration block: \(size) bytes")
        }
    }
    k4a_device_stop_cameras(device)
    k4a_device_close(device)

case "imu":
    let seconds = Double(arg("--seconds", "2")!) ?? 2
    let device = openDevice()
    var config = K4A_DEVICE_CONFIG_INIT_DISABLE_ALL
    config.depth_mode = K4A_DEPTH_MODE_NFOV_2X2BINNED
    config.camera_fps = K4A_FRAMES_PER_SECOND_30
    guard k4a_device_start_cameras(device, &config) == K4A_RESULT_SUCCEEDED else { fail("cameras would not start") }
    guard k4a_device_start_imu(device) == K4A_RESULT_SUCCEEDED else { fail("imu would not start") }
    let deadline = Date().addingTimeInterval(seconds)
    var count = 0
    while Date() < deadline {
        var sample = k4a_imu_sample_t()
        if k4a_device_get_imu_sample(device, &sample, 100) == K4A_WAIT_RESULT_SUCCEEDED {
            count += 1
            if count % 50 == 1 {
                let a = sample.acc_sample.xyz, g = sample.gyro_sample.xyz
                print(String(format: "acc %+.3f %+.3f %+.3f  gyro %+.4f %+.4f %+.4f  temp %.1f  t=%llu", a.x, a.y, a.z, g.x, g.y, g.z, sample.temperature, sample.acc_timestamp_usec))
            }
        }
    }
    print("\(count) samples in \(seconds)s (\(Double(count) / seconds) Hz)")
    k4a_device_stop_imu(device)
    k4a_device_stop_cameras(device)
    k4a_device_close(device)

case "color":
    let frames = Int(arg("--frames", "5")!) ?? 5
    let out = arg("--out", ".")!
    let res = colorResolution(arg("--res", "720p")!)
    // --format bgra32|nv12|yuy2|mjpg
    let formatName = arg("--format", "bgra32")!.lowercased()
    let format: k4a_image_format_t
    switch formatName {
    case "bgra32": format = K4A_IMAGE_FORMAT_COLOR_BGRA32
    case "nv12": format = K4A_IMAGE_FORMAT_COLOR_NV12
    case "yuy2": format = K4A_IMAGE_FORMAT_COLOR_YUY2
    case "mjpg": format = K4A_IMAGE_FORMAT_COLOR_MJPG
    default: fail("unknown colour format \(formatName)")
    }
    let fileExtension = formatName == "mjpg" ? "jpg" : formatName
    try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
    let device = openDevice()
    var config = K4A_DEVICE_CONFIG_INIT_DISABLE_ALL
    config.color_resolution = res
    config.color_format = format
    config.camera_fps = res == K4A_COLOR_RESOLUTION_3072P ? K4A_FRAMES_PER_SECOND_15 : K4A_FRAMES_PER_SECOND_30
    guard k4a_device_start_cameras(device, &config) == K4A_RESULT_SUCCEEDED else { fail("colour would not start") }
    var written = 0
    var misses = 0
    var lastTimestamp: UInt64 = 0
    var gaps: [Double] = []
    let started = Date()
    while written < frames {
        var capture: k4a_capture_t? = nil
        let result = k4a_device_get_capture(device, &capture, 2000)
        guard result == K4A_WAIT_RESULT_SUCCEEDED, let c = capture else { misses += 1; if misses > 5 { fail("no colour frames") }; continue }
        if let color = k4a_capture_get_color_image(c) {
            writeImage("\(out)/color_\(written).\(fileExtension)", color)
            let ts = k4a_image_get_device_timestamp_usec(color)
            if lastTimestamp != 0 { gaps.append(Double(ts) - Double(lastTimestamp)) }
            lastTimestamp = ts
            print("colour \(k4a_image_get_width_pixels(color))x\(k4a_image_get_height_pixels(color)) \(k4a_image_get_size(color)) bytes t=\(ts)us exposure \(k4a_image_get_exposure_usec(color))us wb \(k4a_image_get_white_balance(color))K iso \(k4a_image_get_iso_speed(color))")
            k4a_image_release(color)
            written += 1
        }
        k4a_capture_release(c)
    }
    let elapsed = Date().timeIntervalSince(started)
    if !gaps.isEmpty {
        print(String(format: "%d frames in %.2fs (%.1f fps), mean frame interval %.1f ms", written, elapsed, Double(written) / elapsed, gaps.reduce(0, +) / Double(gaps.count) / 1000))
    }
    k4a_device_stop_cameras(device)
    k4a_device_close(device)

case "controls":
    let device = openDevice()
    var config = K4A_DEVICE_CONFIG_INIT_DISABLE_ALL
    config.color_resolution = K4A_COLOR_RESOLUTION_720P
    config.color_format = K4A_IMAGE_FORMAT_COLOR_BGRA32
    config.camera_fps = K4A_FRAMES_PER_SECOND_30
    guard k4a_device_start_cameras(device, &config) == K4A_RESULT_SUCCEEDED else { fail("colour would not start") }
    let names: [(k4a_color_control_command_t, String)] = [
        (K4A_COLOR_CONTROL_EXPOSURE_TIME_ABSOLUTE, "exposure"), (K4A_COLOR_CONTROL_BRIGHTNESS, "brightness"),
        (K4A_COLOR_CONTROL_CONTRAST, "contrast"), (K4A_COLOR_CONTROL_SATURATION, "saturation"),
        (K4A_COLOR_CONTROL_SHARPNESS, "sharpness"), (K4A_COLOR_CONTROL_WHITEBALANCE, "whitebalance"),
        (K4A_COLOR_CONTROL_BACKLIGHT_COMPENSATION, "backlight"), (K4A_COLOR_CONTROL_GAIN, "gain"),
        (K4A_COLOR_CONTROL_POWERLINE_FREQUENCY, "powerline"),
    ]
    for (control, name) in names {
        var mode = K4A_COLOR_CONTROL_MODE_MANUAL
        var value: Int32 = 0
        var supportsAuto = false
        var minV: Int32 = 0, maxV: Int32 = 0, step: Int32 = 0, def: Int32 = 0
        var defMode = K4A_COLOR_CONTROL_MODE_MANUAL
        let caps = k4a_device_get_color_control_capabilities(device, control, &supportsAuto, &minV, &maxV, &step, &def, &defMode) == K4A_RESULT_SUCCEEDED
        let cur = k4a_device_get_color_control(device, control, &mode, &value) == K4A_RESULT_SUCCEEDED
        print("\(name): \(cur ? "\(value) (\(mode == K4A_COLOR_CONTROL_MODE_AUTO ? "auto" : "manual"))" : "unreadable")  range \(caps ? "\(minV)..\(maxV) step \(step) default \(def)\(supportsAuto ? " auto" : "")" : "unknown")")
    }
    k4a_device_stop_cameras(device)
    k4a_device_close(device)

case "decode":
    // decode <raw.bin> <out-prefix> [--mode m]: a fresh model, one frame, the planes as PGM.
    guard CommandLine.arguments.count > 3 else { usage() }
    let raw = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    let prefix = CommandLine.arguments[3]
    let mode = depthMode(arg("--mode", "nfov_unbinned")!)
    guard let info = openk4a_mode_of(mode) else { fail("no such mode") }
    let width = Int(info.pointee.width), height = Int(info.pointee.height)
    var source = [CChar](repeating: 0, count: 128)
    // --block <calibration_block.bin> --calibration <calibration.json>: the device's own tables.
    var block: [UInt8] = []
    var calibration = openk4a_calibration_t()
    var haveCalibration = false
    if let blockPath = arg("--block"), let jsonPath = arg("--calibration") {
        block = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: blockPath)))
        let json = try! Data(contentsOf: URL(fileURLWithPath: jsonPath))
        haveCalibration = json.withUnsafeBytes { bytes in
            openk4a_calibration_parse(bytes.bindMemory(to: CChar.self).baseAddress, json.count, &calibration)
        }
        if !haveCalibration { fail("calibration JSON did not parse") }
    }
    let model: OpaquePointer? = block.isEmpty
        ? openk4a_depth_model_open(mode, nil, 0, nil, &source, source.count)
        : block.withUnsafeBufferPointer { openk4a_depth_model_open(mode, $0.baseAddress, $0.count, &calibration, &source, source.count) }
    guard let model else { fail("no depth model for this mode (pass --block and --calibration for modes without builtin tables)") }
    if flag("--radial") { openk4a_depth_model_set_radial_output(model, true) }
    var depth = [UInt16](repeating: 0, count: width * height)
    var ir = [UInt16](repeating: 0, count: width * height)
    let useMetal = flag("--metal")
    let metal = useMetal ? openk4a_metal_decoder_create() : nil
    if useMetal && metal == nil { fail("no Metal decoder") }
    func run() {
        raw.withUnsafeBytes { bytes in
            if let metal {
                _ = openk4a_metal_decode(metal, model, bytes.bindMemory(to: UInt8.self).baseAddress, raw.count, &depth, &ir)
            } else {
                openk4a_depth_decode_full(model, bytes.bindMemory(to: UInt8.self).baseAddress, raw.count, &depth, &ir, nil)
            }
        }
    }
    run()
    let start = Date()
    var times = openk4a_depth_times_t()
    for _ in 0..<10 { run() }
    let seconds = Date().timeIntervalSince(start) / 10
    if !useMetal {
        raw.withUnsafeBytes { bytes in
            openk4a_depth_decode_full(model, bytes.bindMemory(to: UInt8.self).baseAddress, raw.count, &depth, &ir, &times)
        }
        print(String(format: "stages: unpack+project %.1f ms, filter %.1f ms, total %.1f ms", Double(times.projection_nsec) / 1e6, Double(times.filter_nsec) / 1e6, Double(times.total_nsec) / 1e6))
    }
    func pgm(_ path: String, _ pixels: [UInt16]) {
        var data = Data("P5\n\(width) \(height)\n65535\n".utf8)
        var swapped = pixels.map { $0.bigEndian }
        swapped.withUnsafeBytes { data.append(contentsOf: $0) }
        try! data.write(to: URL(fileURLWithPath: path))
    }
    pgm(prefix + ".depth.pgm", depth)
    pgm(prefix + ".ir.pgm", ir)
    let valid = depth.filter { $0 != 0 }.count
    print(String(format: "decoded %dx%d in %.1f ms (%@, mean of 10), %d valid depth pixels, tables: %@", width, height, seconds * 1000, useMetal ? "metal" : "cpu", valid, String(cString: source)))
    openk4a_depth_model_free(model)
    if let metal { openk4a_metal_decoder_destroy(metal) }

case "bench":
    // bench [--mode m] [--color res] [--imu] [--seconds n]: rates and pairing with no file I/O.
    let mode = depthMode(arg("--mode", "nfov_unbinned")!)
    let res = colorResolution(arg("--color", "off")!)
    let seconds = Double(arg("--seconds", "4")!) ?? 4
    let device = openDevice()
    var config = K4A_DEVICE_CONFIG_INIT_DISABLE_ALL
    config.depth_mode = mode
    let maxFps = openk4a_mode_max_fps(openk4a_mode_of(mode))
    config.camera_fps = fps(Int(min(30, maxFps)))
    config.color_resolution = res
    config.color_format = K4A_IMAGE_FORMAT_COLOR_BGRA32
    guard k4a_device_start_cameras(device, &config) == K4A_RESULT_SUCCEEDED else { fail("cameras would not start") }
    var imuCount = 0
    var imuStop = false
    let imuLock = NSLock()
    if flag("--imu") {
        guard k4a_device_start_imu(device) == K4A_RESULT_SUCCEEDED else { fail("imu would not start") }
        Thread.detachNewThread {
            while true {
                imuLock.lock(); let stop = imuStop; imuLock.unlock()
                if stop { break }
                var sample = k4a_imu_sample_t()
                if k4a_device_get_imu_sample(device, &sample, 50) == K4A_WAIT_RESULT_SUCCEEDED { imuLock.lock(); imuCount += 1; imuLock.unlock() }
            }
        }
    }
    let start = Date()
    var captures = 0, withColor = 0, timeouts = 0
    var skews: [Int64] = []
    var lastDepth: Int64 = 0
    var gaps: [Int64] = []
    while Date().timeIntervalSince(start) < seconds {
        var capture: k4a_capture_t? = nil
        let result = k4a_device_get_capture(device, &capture, 1000)
        guard result == K4A_WAIT_RESULT_SUCCEEDED, let c = capture else { timeouts += 1; continue }
        captures += 1
        var depthTs: UInt64 = 0
        if let depth = k4a_capture_get_depth_image(c) ?? k4a_capture_get_ir_image(c) {
            depthTs = k4a_image_get_device_timestamp_usec(depth)
            if lastDepth != 0 { gaps.append(Int64(depthTs) - lastDepth) }
            lastDepth = Int64(depthTs)
            k4a_image_release(depth)
        }
        if let color = k4a_capture_get_color_image(c) {
            withColor += 1
            if depthTs != 0 { skews.append(Int64(k4a_image_get_device_timestamp_usec(color)) - Int64(depthTs)) }
            k4a_image_release(color)
        }
        k4a_capture_release(c)
    }
    let elapsed = Date().timeIntervalSince(start)
    let decoderName = String(cString: openk4a_device_decoder_name(device))
    imuLock.lock(); imuStop = true; let imuTotal = imuCount; imuLock.unlock()
    if flag("--imu") { k4a_device_stop_imu(device) }
    k4a_device_stop_cameras(device)
    k4a_device_close(device)
    let meanGap = gaps.isEmpty ? 0 : Double(gaps.reduce(0, +)) / Double(gaps.count) / 1000
    let maxGap = Double(gaps.max() ?? 0) / 1000
    let dropped = gaps.filter { $0 > 50_000 }.count
    let backwards = gaps.filter { $0 < 0 }.count
    print(String(format: "captures %d in %.2fs = %.1f fps (timeouts %d); depth gap mean %.1f ms max %.1f ms, %d gaps >50ms, %d backwards; decoder %@", captures, elapsed, Double(captures) / elapsed, timeouts, meanGap, maxGap, dropped, backwards, decoderName))
    if withColor > 0 {
        let sorted = skews.sorted()
        print(String(format: "colour on %d/%d captures; colour-depth skew median %.1f ms, min %.1f, max %.1f", withColor, captures, Double(sorted[sorted.count / 2]) / 1000, Double(sorted.first!) / 1000, Double(sorted.last!) / 1000))
    }
    if flag("--imu") { print(String(format: "imu %d samples = %.0f Hz", imuTotal, Double(imuTotal) / elapsed)) }

case "syphon":
    // The Syphon servers visible on this machine right now.
    let directory = SyphonServerDirectory.shared()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
    let servers = directory.servers as? [[String: Any]] ?? []
    print("\(servers.count) Syphon server(s)")
    for server in servers {
        print("  \(server["SyphonServerDescriptionAppNameKey"] ?? "?"): \(server["SyphonServerDescriptionNameKey"] ?? "?")")
    }

case "syphon-grab":
    // syphon-grab <server name substring> <out.bgra>: one frame from a running server, as raw BGRA plus a .txt with its size.
    guard CommandLine.arguments.count > 3 else { usage() }
    let wanted = CommandLine.arguments[2]
    let out = CommandLine.arguments[3]
    let directory = SyphonServerDirectory.shared()
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
    let servers = directory.servers as? [[String: Any]] ?? []
    guard let description = servers.first(where: { (($0["SyphonServerDescriptionNameKey"] as? String) ?? "").contains(wanted) }) else {
        fail("no Syphon server named like \(wanted)")
    }
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fail("no Metal") }
    guard let client = SyphonMetalClient(serverDescription: description, device: device, options: nil, newFrameHandler: nil) else { fail("no client") }
    var frame: MTLTexture? = nil
    for _ in 0..<60 {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        if let f = client.newFrameImage() { frame = f; break }
    }
    guard let texture = frame else { fail("no frame arrived") }
    // The IOSurface-backed texture is private to the GPU; blit to a shared one to read it.
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: texture.pixelFormat, width: texture.width, height: texture.height, mipmapped: false)
    descriptor.storageMode = .shared
    let copy = device.makeTexture(descriptor: descriptor)!
    let commandBuffer = queue.makeCommandBuffer()!
    let blit = commandBuffer.makeBlitCommandEncoder()!
    blit.copy(from: texture, to: copy)
    blit.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    var pixels = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    pixels.withUnsafeMutableBytes { copy.getBytes($0.baseAddress!, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
    try! Data(pixels).write(to: URL(fileURLWithPath: out))
    try! "\(texture.width) \(texture.height)".write(toFile: out + ".txt", atomically: true, encoding: .utf8)
    print("grabbed \(texture.width)x\(texture.height) from \(description["SyphonServerDescriptionNameKey"] ?? "?")")
    client.stop()

case "firmware":
    runFirmwareCommand(Array(CommandLine.arguments.dropFirst(2)))

case "record":
    runRecordCommand()

case "play":
    runPlayCommand()

case "camera-calibration":
    // camera-calibration <calibration.json> <out.bin> [--mode m] [--color res]: the depth camera's
    // k4a_calibration_camera_t as raw bytes (the struct the SDK hands the depth engine).
    guard CommandLine.arguments.count > 3 else { usage() }
    let json = try! Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
    var text = [CChar](repeating: 0, count: json.count + 1)
    json.withUnsafeBytes { bytes in for i in 0..<json.count { text[i] = CChar(bitPattern: bytes[i]) } }
    var calibration = k4a_calibration_t()
    guard k4a_calibration_get_from_raw(&text, text.count, depthMode(arg("--mode", "nfov_unbinned")!), colorResolution(arg("--color", "720p")!), &calibration) == K4A_RESULT_SUCCEEDED else { fail("calibration did not parse") }
    var camera = flag("--color-camera") ? calibration.color_camera_calibration : calibration.depth_camera_calibration
    if flag("--raw") {
        // The document's own camera: sensor resolution, normalised intrinsics, the form the SDK's depth module keeps.
        var parsed = openk4a_calibration_t()
        guard json.withUnsafeBytes({ bytes in openk4a_calibration_parse(bytes.bindMemory(to: CChar.self).baseAddress, json.count, &parsed) }) else { fail("raw calibration did not parse") }
        camera = flag("--color-camera") ? parsed.color : parsed.depth
    }
    let data = Data(bytes: &camera, count: MemoryLayout<k4a_calibration_camera_t>.size)
    try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
    print("wrote \(data.count) bytes: \(camera.resolution_width)x\(camera.resolution_height), \(camera.intrinsics.parameter_count) parameters, metric radius \(camera.metric_radius)")

case "reset":
    // Resets the device (the colour MCU's reset command); it re-enumerates a few seconds later.
    let device = openDevice()
    let ok = openk4a_firmware_reset(device)
    print(ok ? "reset sent; the device re-enumerates in a few seconds" : "reset refused")
    k4a_device_close(device)

default:
    usage()
}
