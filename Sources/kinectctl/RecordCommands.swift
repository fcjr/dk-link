import Foundation
import KinectCore

// kinectctl record / play: the k4arecord API end to end.

private func recordArg(_ name: String, _ fallback: String? = nil) -> String? {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
    return fallback
}

private func recordDie(_ message: String) -> Never {
    FileHandle.standardError.write(("kinectctl: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

private func depthModeNamed(_ name: String) -> k4a_depth_mode_t {
    switch name.lowercased() {
    case "nfov_unbinned": return K4A_DEPTH_MODE_NFOV_UNBINNED
    case "nfov_2x2binned": return K4A_DEPTH_MODE_NFOV_2X2BINNED
    case "wfov_unbinned": return K4A_DEPTH_MODE_WFOV_UNBINNED
    case "wfov_2x2binned": return K4A_DEPTH_MODE_WFOV_2X2BINNED
    case "passive_ir": return K4A_DEPTH_MODE_PASSIVE_IR
    case "off": return K4A_DEPTH_MODE_OFF
    default: recordDie("unknown depth mode \(name)")
    }
}

private func colorResolutionNamed(_ name: String) -> k4a_color_resolution_t {
    switch name.lowercased() {
    case "off": return K4A_COLOR_RESOLUTION_OFF
    case "720p": return K4A_COLOR_RESOLUTION_720P
    case "1080p": return K4A_COLOR_RESOLUTION_1080P
    case "1440p": return K4A_COLOR_RESOLUTION_1440P
    case "1536p": return K4A_COLOR_RESOLUTION_1536P
    case "2160p": return K4A_COLOR_RESOLUTION_2160P
    case "3072p": return K4A_COLOR_RESOLUTION_3072P
    default: recordDie("unknown colour resolution \(name)")
    }
}

/// record <out.mkv> [--seconds n] [--mode m] [--color res] [--no-imu]
func runRecordCommand() {
    guard CommandLine.arguments.count > 2 else { recordDie("usage: kinectctl record <out.mkv> [--seconds n] [--mode m] [--color res] [--no-imu]") }
    let path = CommandLine.arguments[2]
    let seconds = Double(recordArg("--seconds", "3")!) ?? 3
    var device: k4a_device_t? = nil
    guard k4a_device_open(0, &device) == K4A_RESULT_SUCCEEDED, let dev = device else { recordDie("no Azure Kinect could be opened") }
    var config = K4A_DEVICE_CONFIG_INIT_DISABLE_ALL
    config.depth_mode = depthModeNamed(recordArg("--mode", "nfov_unbinned")!)
    config.color_resolution = colorResolutionNamed(recordArg("--color", "720p")!)
    config.color_format = K4A_IMAGE_FORMAT_COLOR_BGRA32
    config.camera_fps = config.depth_mode == K4A_DEPTH_MODE_WFOV_UNBINNED ? K4A_FRAMES_PER_SECOND_15 : K4A_FRAMES_PER_SECOND_30
    let imu = !CommandLine.arguments.contains("--no-imu")

    var recording: k4a_record_t? = nil
    guard k4a_record_create(path, dev, config, &recording) == K4A_RESULT_SUCCEEDED, let rec = recording else { recordDie("could not create \(path)") }
    if imu { guard k4a_record_add_imu_track(rec) == K4A_RESULT_SUCCEEDED else { recordDie("imu track") } }
    _ = k4a_record_add_tag(rec, "KINECTCTL_HOST", ProcessInfo.processInfo.hostName)
    guard k4a_record_write_header(rec) == K4A_RESULT_SUCCEEDED else { recordDie("could not write the recording header") }
    guard k4a_device_start_cameras(dev, &config) == K4A_RESULT_SUCCEEDED else { recordDie("cameras would not start") }
    if imu { guard k4a_device_start_imu(dev) == K4A_RESULT_SUCCEEDED else { recordDie("imu would not start") } }

    // The clock is timed from the first capture: the core can spend a few
    // seconds at start waiting for the device clock to settle.
    var start: Date? = nil
    var captures = 0, samples = 0, timeouts = 0, writeFailures = 0, imuWriteFailures = 0
    while start == nil || Date().timeIntervalSince(start!) < seconds {
        var capture: k4a_capture_t? = nil
        let got = k4a_device_get_capture(dev, &capture, 100)
        if got == K4A_WAIT_RESULT_SUCCEEDED, let c = capture {
            if start == nil { start = Date() }
            if k4a_record_write_capture(rec, c) == K4A_RESULT_SUCCEEDED { captures += 1 } else { writeFailures += 1 }
            k4a_capture_release(c)
        } else {
            timeouts += 1
            if start == nil && timeouts > 100 { recordDie("no captures arrived") }
        }
        if imu && start != nil {
            var sample = k4a_imu_sample_t()
            var drained = 0
            while drained < 2000 {
                let r = k4a_device_get_imu_sample(dev, &sample, 1)
                if r != K4A_WAIT_RESULT_SUCCEEDED { break }
                drained += 1
                if k4a_record_write_imu_sample(rec, sample) == K4A_RESULT_SUCCEEDED { samples += 1 } else { imuWriteFailures += 1 }
            }
        }
    }
    if timeouts > 0 || writeFailures > 0 || imuWriteFailures > 0 {
        print("capture timeouts \(timeouts), capture write failures \(writeFailures), IMU write failures \(imuWriteFailures)")
    }
    if imu { k4a_device_stop_imu(dev) }
    k4a_device_stop_cameras(dev)
    k4a_record_close(rec)
    k4a_device_close(dev)
    let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
    print("recorded \(captures) captures and \(samples) IMU samples to \(path) (\(size / 1_000_000) MB)")
}

/// play <file.mkv>: configuration, tags, tracks, the first captures, a seek check.
func runPlayCommand() {
    guard CommandLine.arguments.count > 2 else { recordDie("usage: kinectctl play <file.mkv>") }
    let path = CommandLine.arguments[2]
    var playback: k4a_playback_t? = nil
    guard k4a_playback_open(path, &playback) == K4A_RESULT_SUCCEEDED, let pb = playback else { recordDie("could not open \(path)") }

    var config = k4a_record_configuration_t()
    _ = k4a_playback_get_record_configuration(pb, &config)
    print("length \(Double(k4a_playback_get_recording_length_usec(pb)) / 1e6) s; depth mode \(config.depth_mode.rawValue), colour \(config.color_resolution.rawValue) format \(config.color_format.rawValue), fps \(config.camera_fps.rawValue); tracks: colour \(config.color_track_enabled) depth \(config.depth_track_enabled) ir \(config.ir_track_enabled) imu \(config.imu_track_enabled); start offset \(config.start_timestamp_offset_usec) us")
    for name in ["K4A_DEVICE_SERIAL_NUMBER", "K4A_DEPTH_MODE", "K4A_COLOR_MODE", "K4A_START_OFFSET_NS", "K4A_WIRED_SYNC_MODE", "K4A_DEPTH_FIRMWARE_VERSION", "KINECTCTL_HOST"] {
        var size = 0
        _ = k4a_playback_get_tag(pb, name, nil, &size)
        var value = [CChar](repeating: 0, count: max(size, 1))
        if k4a_playback_get_tag(pb, name, &value, &size) == K4A_BUFFER_RESULT_SUCCEEDED { print("  tag \(name) = \(String(cString: value))") }
    }
    let count = k4a_playback_get_track_count(pb)
    for i in 0..<count {
        var size = 0
        _ = k4a_playback_get_track_name(pb, i, nil, &size)
        var name = [CChar](repeating: 0, count: max(size, 1))
        _ = k4a_playback_get_track_name(pb, i, &name, &size)
        let trackName = String(cString: name)
        var codecSize = 0
        _ = k4a_playback_track_get_codec_id(pb, trackName, nil, &codecSize)
        var codec = [CChar](repeating: 0, count: max(codecSize, 1))
        _ = k4a_playback_track_get_codec_id(pb, trackName, &codec, &codecSize)
        var video = k4a_record_video_settings_t()
        let isVideo = k4a_playback_track_get_video_settings(pb, trackName, &video) == K4A_RESULT_SUCCEEDED
        print("  track \(trackName): \(String(cString: codec))\(isVideo ? " \(video.width)x\(video.height) @ \(video.frame_rate) fps" : "")\(k4a_playback_track_is_builtin(pb, trackName) ? "" : " (custom)")")
    }
    var calibration = k4a_calibration_t()
    if k4a_playback_get_calibration(pb, &calibration) == K4A_RESULT_SUCCEEDED {
        print("  calibration: depth \(calibration.depth_camera_calibration.resolution_width)x\(calibration.depth_camera_calibration.resolution_height), colour \(calibration.color_camera_calibration.resolution_width)x\(calibration.color_camera_calibration.resolution_height)")
    }
    var shown = 0
    var total = 0
    var firstTs: UInt64 = 0, lastTs: UInt64 = 0
    while true {
        var capture: k4a_capture_t? = nil
        let result = k4a_playback_get_next_capture(pb, &capture)
        if result != K4A_STREAM_RESULT_SUCCEEDED { break }
        guard let c = capture else { break }
        total += 1
        var parts: [String] = []
        var ts: UInt64 = 0
        if let depth = k4a_capture_get_depth_image(c) { ts = k4a_image_get_device_timestamp_usec(depth); parts.append("depth \(k4a_image_get_width_pixels(depth))x\(k4a_image_get_height_pixels(depth))"); k4a_image_release(depth) }
        if let ir = k4a_capture_get_ir_image(c) { if ts == 0 { ts = k4a_image_get_device_timestamp_usec(ir) }; parts.append("ir"); k4a_image_release(ir) }
        if let color = k4a_capture_get_color_image(c) { parts.append("colour \(k4a_image_get_width_pixels(color))x\(k4a_image_get_height_pixels(color)) t=\(k4a_image_get_device_timestamp_usec(color))"); if ts == 0 { ts = k4a_image_get_device_timestamp_usec(color) }; k4a_image_release(color) }
        if firstTs == 0 { firstTs = ts }
        lastTs = ts
        if shown < 5 { print("  capture \(total): t=\(ts) us: \(parts.joined(separator: ", "))"); shown += 1 }
        k4a_capture_release(c)
    }
    print("  \(total) captures, device time \(firstTs)..\(lastTs) us")
    var imuCount = 0
    var sample = k4a_imu_sample_t()
    _ = k4a_playback_seek_timestamp(pb, 0, K4A_PLAYBACK_SEEK_BEGIN)
    while k4a_playback_get_next_imu_sample(pb, &sample) == K4A_STREAM_RESULT_SUCCEEDED { imuCount += 1 }
    print("  \(imuCount) IMU samples")
    // Seek to the middle and read one capture; then from the end backwards.
    let length = Int64(k4a_playback_get_recording_length_usec(pb))
    if k4a_playback_seek_timestamp(pb, length / 2, K4A_PLAYBACK_SEEK_BEGIN) == K4A_RESULT_SUCCEEDED {
        var capture: k4a_capture_t? = nil
        if k4a_playback_get_next_capture(pb, &capture) == K4A_STREAM_RESULT_SUCCEEDED, let c = capture {
            if let depth = k4a_capture_get_depth_image(c) ?? k4a_capture_get_color_image(c) {
                print("  seek to \(length / 2) us: next capture at device time \(k4a_image_get_device_timestamp_usec(depth)) us")
                k4a_image_release(depth)
            }
            k4a_capture_release(c)
        }
    }
    if k4a_playback_seek_timestamp(pb, 0, K4A_PLAYBACK_SEEK_END) == K4A_RESULT_SUCCEEDED {
        var capture: k4a_capture_t? = nil
        if k4a_playback_get_previous_capture(pb, &capture) == K4A_STREAM_RESULT_SUCCEEDED, let c = capture {
            if let depth = k4a_capture_get_depth_image(c) ?? k4a_capture_get_color_image(c) {
                print("  seek to end, previous capture at device time \(k4a_image_get_device_timestamp_usec(depth)) us")
                k4a_image_release(depth)
            }
            k4a_capture_release(c)
        }
    }
    k4a_playback_close(pb)
}
