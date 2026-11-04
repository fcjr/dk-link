import XCTest
@testable import KinectCore

/// k4arecord without a camera: write a recording from fixture images, read it
/// back, and walk its EBML tree.
final class RecordTests: XCTestCase {
    static func fixture(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        return try! Data(contentsOf: url)
    }

    static func image(fromPGM name: String, format: k4a_image_format_t) -> k4a_image_t {
        let data = fixture(name)
        var cursor = 0
        func token() -> String {
            while data[cursor] == 0x0A || data[cursor] == 0x20 { cursor += 1 }
            var end = cursor
            while data[end] != 0x0A && data[end] != 0x20 { end += 1 }
            defer { cursor = end }
            return String(decoding: data[cursor..<end], as: UTF8.self)
        }
        _ = token(); let width = Int32(token(), radix: 10)!; let height = Int32(token(), radix: 10)!; _ = token(); cursor += 1
        var handle: k4a_image_t? = nil
        XCTAssertEqual(k4a_image_create(format, width, height, width * 2, &handle), K4A_RESULT_SUCCEEDED)
        let out = k4a_image_get_buffer(handle)!
        data.withUnsafeBytes { bytes in
            for i in 0..<Int(width * height) {
                let high: UInt8 = bytes[cursor + 2 * i]; let low: UInt8 = bytes[cursor + 2 * i + 1]; let value = UInt16(high) << 8 | UInt16(low)
                out[2 * i] = UInt8(value & 0xFF); out[2 * i + 1] = UInt8(value >> 8)
            }
        }
        return handle!
    }

    static func pixels(_ image: k4a_image_t) -> [UInt16] {
        let count = k4a_image_get_size(image) / 2
        return k4a_image_get_buffer(image)!.withMemoryRebound(to: UInt16.self, capacity: count) { Array(UnsafeBufferPointer(start: $0, count: count)) }
    }

    var path: String { NSTemporaryDirectory() + "kinect-record-test-\(getpid()).mkv" }

    /// Writes a recording with `frames` captures 33.3 ms apart from t0, IMU at 1 kHz, a custom track, a tag and an attachment.
    func writeRecording(frames: Int, withColor: Bool = true) -> (depth: [UInt16], ir: [UInt16]) {
        var config = K4A_DEVICE_CONFIG_INIT_DISABLE_ALL
        config.depth_mode = K4A_DEPTH_MODE_NFOV_UNBINNED
        config.color_resolution = withColor ? K4A_COLOR_RESOLUTION_720P : K4A_COLOR_RESOLUTION_OFF
        config.color_format = K4A_IMAGE_FORMAT_COLOR_BGRA32
        config.camera_fps = K4A_FRAMES_PER_SECOND_30
        var recording: k4a_record_t? = nil
        XCTAssertEqual(k4a_record_create(path, nil, config, &recording), K4A_RESULT_SUCCEEDED)
        let rec = recording!
        XCTAssertEqual(k4a_record_add_imu_track(rec), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(k4a_record_add_tag(rec, "TEST_TAG", "hello"), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(k4a_record_add_tag(rec, "bad name", "x"), K4A_RESULT_FAILED)
        let calibration = Self.fixture("calibration.json")
        calibration.withUnsafeBytes { bytes in
            XCTAssertEqual(k4a_record_add_attachment(rec, "calibration.json", bytes.bindMemory(to: UInt8.self).baseAddress, calibration.count), K4A_RESULT_SUCCEEDED)
        }
        var settings = k4a_record_subtitle_settings_t(high_freq_data: false)
        XCTAssertEqual(k4a_record_add_custom_subtitle_track(rec, "NOTES", "S_TEXT/UTF8", nil, 0, &settings), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(k4a_record_write_header(rec), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(k4a_record_add_tag(rec, "LATE", "no"), K4A_RESULT_FAILED, "tags after the header are refused")

        let depth = Self.image(fromPGM: "nfov_unbinned.depth.pgm", format: K4A_IMAGE_FORMAT_DEPTH16)
        let ir = Self.image(fromPGM: "nfov_unbinned.ir.pgm", format: K4A_IMAGE_FORMAT_IR16)
        var color: k4a_image_t? = nil
        if withColor {
            XCTAssertEqual(k4a_image_create(K4A_IMAGE_FORMAT_COLOR_BGRA32, 1280, 720, 1280 * 4, &color), K4A_RESULT_SUCCEEDED)
            let buffer = k4a_image_get_buffer(color)!
            for i in 0..<(1280 * 720) { buffer[i * 4] = UInt8(i % 251); buffer[i * 4 + 1] = UInt8((i / 7) % 253); buffer[i * 4 + 2] = 100; buffer[i * 4 + 3] = 255 }
        }
        let t0: UInt64 = 1_000_000
        for frame in 0..<frames {
            let ts = t0 + UInt64(frame) * 33_333
            k4a_image_set_device_timestamp_usec(depth, ts)
            k4a_image_set_device_timestamp_usec(ir, ts)
            var capture: k4a_capture_t? = nil
            XCTAssertEqual(k4a_capture_create(&capture), K4A_RESULT_SUCCEEDED)
            k4a_capture_set_depth_image(capture, depth)
            k4a_capture_set_ir_image(capture, ir)
            if let color {
                k4a_image_set_device_timestamp_usec(color, ts + 1_500) // the colour exposure sits a little after
                k4a_capture_set_color_image(capture, color)
            }
            XCTAssertEqual(k4a_record_write_capture(rec, capture), K4A_RESULT_SUCCEEDED)
            k4a_capture_release(capture)
            for i in 0..<33 {
                var sample = k4a_imu_sample_t()
                sample.acc_timestamp_usec = ts + UInt64(i) * 1_000
                sample.gyro_timestamp_usec = sample.acc_timestamp_usec + 7
                sample.acc_sample.xyz = .init(x: Float(frame), y: Float(i), z: -9.81)
                sample.gyro_sample.xyz = .init(x: 0.1, y: 0.2, z: 0.3)
                XCTAssertEqual(k4a_record_write_imu_sample(rec, sample), K4A_RESULT_SUCCEEDED)
            }
            var note = Array("frame \(frame)".utf8)
            XCTAssertEqual(k4a_record_write_custom_track_data(rec, "NOTES", ts, &note, note.count), K4A_RESULT_SUCCEEDED)
        }
        XCTAssertEqual(k4a_record_flush(rec), K4A_RESULT_SUCCEEDED)
        k4a_record_close(rec)
        let result = (Self.pixels(depth), Self.pixels(ir))
        k4a_image_release(depth)
        k4a_image_release(ir)
        if let color { k4a_image_release(color) }
        return result
    }

    override func tearDown() { try? FileManager.default.removeItem(atPath: path) }

    func testRoundTrip() throws {
        let (depthPixels, irPixels) = writeRecording(frames: 10)
        var playback: k4a_playback_t? = nil
        XCTAssertEqual(k4a_playback_open(path, &playback), K4A_RESULT_SUCCEEDED)
        let pb = try XCTUnwrap(playback)
        defer { k4a_playback_close(pb) }

        var config = k4a_record_configuration_t()
        XCTAssertEqual(k4a_playback_get_record_configuration(pb, &config), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(config.depth_mode, K4A_DEPTH_MODE_NFOV_UNBINNED)
        XCTAssertEqual(config.color_resolution, K4A_COLOR_RESOLUTION_720P)
        XCTAssertEqual(config.color_format, K4A_IMAGE_FORMAT_COLOR_BGRA32)
        XCTAssertEqual(config.camera_fps, K4A_FRAMES_PER_SECOND_30)
        XCTAssertTrue(config.depth_track_enabled && config.ir_track_enabled && config.color_track_enabled && config.imu_track_enabled)
        XCTAssertEqual(config.wired_sync_mode, K4A_WIRED_SYNC_MODE_STANDALONE)
        XCTAssertEqual(config.start_timestamp_offset_usec, 1_000_000, "the first timestamp written is the start offset")
        XCTAssertEqual(k4a_playback_get_recording_length_usec(pb), 9 * 33_333 + 32 * 1_000, "last IMU sample relative to the start")

        // Tags and tracks.
        var size = 0
        _ = k4a_playback_get_tag(pb, "TEST_TAG", nil, &size)
        var value = [CChar](repeating: 0, count: size)
        XCTAssertEqual(k4a_playback_get_tag(pb, "TEST_TAG", &value, &size), K4A_BUFFER_RESULT_SUCCEEDED)
        XCTAssertEqual(String(cString: value), "hello")
        XCTAssertEqual(k4a_playback_get_tag(pb, "NOPE", &value, &size), K4A_BUFFER_RESULT_FAILED)
        XCTAssertEqual(k4a_playback_get_track_count(pb), 5)
        var names: [String] = []
        for i in 0..<5 {
            var n = 0
            _ = k4a_playback_get_track_name(pb, i, nil, &n)
            var name = [CChar](repeating: 0, count: n)
            XCTAssertEqual(k4a_playback_get_track_name(pb, i, &name, &n), K4A_BUFFER_RESULT_SUCCEEDED)
            names.append(String(cString: name))
        }
        XCTAssertEqual(names, ["COLOR", "DEPTH", "IMU", "IR", "NOTES"], "the SDK lists tracks by name")
        XCTAssertTrue(k4a_playback_track_is_builtin(pb, "DEPTH"))
        XCTAssertFalse(k4a_playback_track_is_builtin(pb, "NOTES"))
        XCTAssertTrue(k4a_playback_check_track_exists(pb, "IMU"))
        XCTAssertFalse(k4a_playback_check_track_exists(pb, "AUDIO"))
        var video = k4a_record_video_settings_t()
        XCTAssertEqual(k4a_playback_track_get_video_settings(pb, "DEPTH", &video), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(video.width, 640); XCTAssertEqual(video.height, 576); XCTAssertEqual(video.frame_rate, 30)
        var codecSize = 0
        _ = k4a_playback_track_get_codec_id(pb, "COLOR", nil, &codecSize)
        var codec = [CChar](repeating: 0, count: codecSize)
        _ = k4a_playback_track_get_codec_id(pb, "COLOR", &codec, &codecSize)
        XCTAssertEqual(String(cString: codec), "V_MS/VFW/FOURCC")
        var contextSize = 0
        XCTAssertEqual(k4a_playback_track_get_codec_context(pb, "DEPTH", nil, &contextSize), K4A_BUFFER_RESULT_TOO_SMALL)
        XCTAssertEqual(contextSize, 40, "a BITMAPINFOHEADER")
        var header = [UInt8](repeating: 0, count: 40)
        _ = k4a_playback_track_get_codec_context(pb, "DEPTH", &header, &contextSize)
        XCTAssertEqual(Array(header[16..<20]), Array("b16g".utf8), "depth is b16g")
        _ = k4a_playback_track_get_codec_context(pb, "COLOR", &header, &contextSize)
        XCTAssertEqual(Array(header[16..<20]), Array("BGRA".utf8))

        // Calibration, from the attachment.
        var calibration = k4a_calibration_t()
        XCTAssertEqual(k4a_playback_get_calibration(pb, &calibration), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(calibration.depth_camera_calibration.resolution_width, 640)
        XCTAssertEqual(calibration.color_camera_calibration.resolution_width, 1280)
        var rawSize = 0
        XCTAssertEqual(k4a_playback_get_raw_calibration(pb, nil, &rawSize), K4A_BUFFER_RESULT_TOO_SMALL)
        XCTAssertEqual(rawSize, Self.fixture("calibration.json").count + 1, "null terminated on the way out")
        var attachmentSize = 0
        XCTAssertEqual(k4a_playback_get_attachment(pb, "calibration.json", nil, &attachmentSize), K4A_BUFFER_RESULT_TOO_SMALL)
        XCTAssertEqual(attachmentSize, Self.fixture("calibration.json").count)

        // Captures, in order, with pixels intact and colour paired.
        var count = 0
        while true {
            var capture: k4a_capture_t? = nil
            let result = k4a_playback_get_next_capture(pb, &capture)
            if result == K4A_STREAM_RESULT_EOF { break }
            XCTAssertEqual(result, K4A_STREAM_RESULT_SUCCEEDED)
            let c = try XCTUnwrap(capture)
            let depth = try XCTUnwrap(k4a_capture_get_depth_image(c))
            let ir = try XCTUnwrap(k4a_capture_get_ir_image(c))
            let color = try XCTUnwrap(k4a_capture_get_color_image(c))
            XCTAssertEqual(k4a_image_get_device_timestamp_usec(depth), 1_000_000 + UInt64(count) * 33_333)
            XCTAssertEqual(k4a_image_get_device_timestamp_usec(color), 1_000_000 + UInt64(count) * 33_333 + 1_500)
            XCTAssertEqual(k4a_image_get_format(depth), K4A_IMAGE_FORMAT_DEPTH16)
            XCTAssertEqual(k4a_image_get_format(ir), K4A_IMAGE_FORMAT_IR16)
            XCTAssertEqual(k4a_image_get_format(color), K4A_IMAGE_FORMAT_COLOR_BGRA32)
            XCTAssertEqual(k4a_image_get_stride_bytes(color), 1280 * 4)
            if count == 0 {
                XCTAssertEqual(Self.pixels(depth), depthPixels)
                XCTAssertEqual(Self.pixels(ir), irPixels)
                let buffer = k4a_image_get_buffer(color)!
                XCTAssertEqual(buffer[4 * 1000], UInt8(1000 % 251))
                XCTAssertEqual(buffer[4 * 1000 + 2], 100)
            }
            k4a_image_release(depth); k4a_image_release(ir); k4a_image_release(color)
            k4a_capture_release(c)
            count += 1
        }
        XCTAssertEqual(count, 10)

        // Previous from the end walks back.
        var capture: k4a_capture_t? = nil
        XCTAssertEqual(k4a_playback_get_previous_capture(pb, &capture), K4A_STREAM_RESULT_SUCCEEDED)
        var depth = try XCTUnwrap(k4a_capture_get_depth_image(capture))
        XCTAssertEqual(k4a_image_get_device_timestamp_usec(depth), 1_000_000 + 9 * 33_333)
        k4a_image_release(depth); k4a_capture_release(capture)

        // IMU samples, all of them, in order, with their own timestamps.
        XCTAssertEqual(k4a_playback_seek_timestamp(pb, 0, K4A_PLAYBACK_SEEK_BEGIN), K4A_RESULT_SUCCEEDED)
        var samples = 0
        var sample = k4a_imu_sample_t()
        var last: UInt64 = 0
        while k4a_playback_get_next_imu_sample(pb, &sample) == K4A_STREAM_RESULT_SUCCEEDED {
            XCTAssertGreaterThan(sample.acc_timestamp_usec, last)
            XCTAssertEqual(sample.gyro_timestamp_usec, sample.acc_timestamp_usec + 7)
            XCTAssertEqual(sample.acc_sample.xyz.z, -9.81)
            XCTAssertTrue(sample.temperature.isNaN, "the SDK reports NaN for recorded IMU temperature")
            last = sample.acc_timestamp_usec
            samples += 1
        }
        XCTAssertEqual(samples, 330)
        XCTAssertEqual(sample.acc_timestamp_usec, 0, "EOF zeroes the sample")

        // Seeks: by begin, device time, end; captures and IMU land at the right place.
        XCTAssertEqual(k4a_playback_seek_timestamp(pb, Int64(5 * 33_333), K4A_PLAYBACK_SEEK_BEGIN), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(k4a_playback_get_next_capture(pb, &capture), K4A_STREAM_RESULT_SUCCEEDED)
        depth = try XCTUnwrap(k4a_capture_get_depth_image(capture))
        XCTAssertEqual(k4a_image_get_device_timestamp_usec(depth), 1_000_000 + 5 * 33_333)
        k4a_image_release(depth); k4a_capture_release(capture)
        XCTAssertEqual(k4a_playback_get_next_imu_sample(pb, &sample), K4A_STREAM_RESULT_SUCCEEDED)
        XCTAssertEqual(sample.acc_timestamp_usec, 1_000_000 + 5 * 33_333, "the first IMU sample at or after the seek")

        // A device-time seek just after frame 7: the colour frame 1.5 ms later is the
        // first block after the seek, and depth frame 8 is more than half a period
        // after it, so (as in the SDK) the first capture carries colour alone.
        XCTAssertEqual(k4a_playback_seek_timestamp(pb, Int64(1_000_000 + 7 * 33_333 + 10), K4A_PLAYBACK_SEEK_DEVICE_TIME), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(k4a_playback_get_next_capture(pb, &capture), K4A_STREAM_RESULT_SUCCEEDED)
        XCTAssertNil(k4a_capture_get_depth_image(capture))
        let lateColor = try XCTUnwrap(k4a_capture_get_color_image(capture))
        XCTAssertEqual(k4a_image_get_device_timestamp_usec(lateColor), 1_000_000 + 7 * 33_333 + 1_500)
        k4a_image_release(lateColor); k4a_capture_release(capture)
        XCTAssertEqual(k4a_playback_get_next_capture(pb, &capture), K4A_STREAM_RESULT_SUCCEEDED)
        depth = try XCTUnwrap(k4a_capture_get_depth_image(capture))
        XCTAssertEqual(k4a_image_get_device_timestamp_usec(depth), 1_000_000 + 8 * 33_333, "then the whole frame 8")
        XCTAssertNotNil(k4a_capture_get_color_image(capture).map { k4a_image_release($0) })
        k4a_image_release(depth); k4a_capture_release(capture)
        XCTAssertEqual(k4a_playback_get_previous_capture(pb, &capture), K4A_STREAM_RESULT_SUCCEEDED)
        depth = try XCTUnwrap(k4a_capture_get_depth_image(capture))
        XCTAssertEqual(k4a_image_get_device_timestamp_usec(depth), 1_000_000 + 7 * 33_333)
        k4a_image_release(depth); k4a_capture_release(capture)

        XCTAssertEqual(k4a_playback_seek_timestamp(pb, 0, K4A_PLAYBACK_SEEK_END), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(k4a_playback_get_next_capture(pb, &capture), K4A_STREAM_RESULT_EOF)
        XCTAssertEqual(k4a_playback_get_previous_capture(pb, &capture), K4A_STREAM_RESULT_SUCCEEDED)
        depth = try XCTUnwrap(k4a_capture_get_depth_image(capture))
        XCTAssertEqual(k4a_image_get_device_timestamp_usec(depth), 1_000_000 + 9 * 33_333)
        k4a_image_release(depth); k4a_capture_release(capture)

        // Custom track blocks, forwards and backwards; builtin tracks refuse.
        XCTAssertEqual(k4a_playback_seek_timestamp(pb, 0, K4A_PLAYBACK_SEEK_BEGIN), K4A_RESULT_SUCCEEDED)
        var block: k4a_playback_data_block_t? = nil
        XCTAssertEqual(k4a_playback_get_next_data_block(pb, "NOTES", &block), K4A_STREAM_RESULT_SUCCEEDED)
        XCTAssertEqual(String(decoding: Data(bytes: k4a_playback_data_block_get_buffer(block), count: k4a_playback_data_block_get_buffer_size(block)), as: UTF8.self), "frame 0")
        XCTAssertEqual(k4a_playback_data_block_get_device_timestamp_usec(block), 1_000_000)
        k4a_playback_data_block_release(block)
        XCTAssertEqual(k4a_playback_get_next_data_block(pb, "NOTES", &block), K4A_STREAM_RESULT_SUCCEEDED)
        XCTAssertEqual(k4a_playback_data_block_get_device_timestamp_usec(block), 1_000_000 + 33_333)
        k4a_playback_data_block_release(block)
        XCTAssertEqual(k4a_playback_get_previous_data_block(pb, "NOTES", &block), K4A_STREAM_RESULT_SUCCEEDED)
        XCTAssertEqual(k4a_playback_data_block_get_device_timestamp_usec(block), 1_000_000)
        k4a_playback_data_block_release(block)
        XCTAssertEqual(k4a_playback_get_next_data_block(pb, "DEPTH", &block), K4A_STREAM_RESULT_FAILED)

        // Colour conversion on the way out.
        XCTAssertEqual(k4a_playback_set_color_conversion(pb, K4A_IMAGE_FORMAT_COLOR_NV12), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(k4a_playback_set_color_conversion(pb, K4A_IMAGE_FORMAT_COLOR_MJPG), K4A_RESULT_FAILED, "no MJPG from a BGRA recording")
        XCTAssertEqual(k4a_playback_seek_timestamp(pb, 0, K4A_PLAYBACK_SEEK_BEGIN), K4A_RESULT_SUCCEEDED)
        XCTAssertEqual(k4a_playback_get_next_capture(pb, &capture), K4A_STREAM_RESULT_SUCCEEDED)
        let nv12 = try XCTUnwrap(k4a_capture_get_color_image(capture))
        XCTAssertEqual(k4a_image_get_format(nv12), K4A_IMAGE_FORMAT_COLOR_NV12)
        XCTAssertEqual(k4a_image_get_size(nv12), 1280 * 720 * 3 / 2)
        k4a_image_release(nv12); k4a_capture_release(capture)
    }

    func testDepthOnlyRecordingAndStructure() throws {
        _ = writeRecording(frames: 3, withColor: false)
        var playback: k4a_playback_t? = nil
        XCTAssertEqual(k4a_playback_open(path, &playback), K4A_RESULT_SUCCEEDED)
        var config = k4a_record_configuration_t()
        XCTAssertEqual(k4a_playback_get_record_configuration(playback, &config), K4A_RESULT_SUCCEEDED)
        XCTAssertFalse(config.color_track_enabled)
        XCTAssertEqual(config.color_resolution, K4A_COLOR_RESOLUTION_OFF)
        XCTAssertEqual(k4a_playback_get_track_count(playback), 4)
        k4a_playback_close(playback)

        // The EBML tree: head, then a Segment holding SeekHead, Info, Tracks, Attachments, Tags, Clusters, Cues.
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let bytes = [UInt8](data)
        func header(_ at: Int) -> (id: UInt32, size: UInt64, headerSize: Int) {
            var h = mkv_header_t()
            bytes.withUnsafeBufferPointer { XCTAssertTrue(mkv_parse_header($0.baseAddress! + at, bytes.count - at, &h)) }
            return (h.id, h.size, h.header_size)
        }
        let head = header(0)
        XCTAssertEqual(head.id, 0x1A45DFA3)
        let segmentAt = head.headerSize + Int(head.size)
        let segment = header(segmentAt)
        XCTAssertEqual(segment.id, 0x18538067)
        XCTAssertEqual(segment.headerSize, 4 + 8, "an 8-byte size, like the SDK")
        XCTAssertEqual(Int(segment.size), bytes.count - segmentAt - segment.headerSize, "the segment size was patched at flush")
        var at = segmentAt + segment.headerSize
        var ids: [UInt32] = []
        var clusters = 0
        while at < bytes.count {
            let h = header(at)
            if h.id == 0x1F43B675 { clusters += 1 } else { ids.append(h.id) }
            at += h.headerSize + Int(h.size)
        }
        XCTAssertEqual(ids, [0x114D9B74, 0xEC, 0x1549A966, 0xEC, 0x1654AE6B, 0x1941A469, 0x1254C367, 0xEC, 0x1C53BB6B],
                       "SeekHead+Void, Info+Void, Tracks, Attachments, Tags+Void, (clusters), Cues")
        XCTAssertGreaterThanOrEqual(clusters, 3, "three frames 33 ms apart are at least three 32 ms clusters")
        XCTAssertTrue(data.range(of: Data("K4A_START_OFFSET_NS".utf8)) != nil)
        XCTAssertTrue(data.range(of: Data("S_K4A/IMU".utf8)) != nil)
        XCTAssertTrue(data.range(of: Data("matroska".utf8)) != nil)
    }

    func testVintsAndVoids() {
        var buf = mkv_buf_t()
        mkv_buf_init(&buf)
        XCTAssertTrue(mkv_put_void(&buf, 2))
        XCTAssertEqual(buf.size, 2)
        XCTAssertTrue(mkv_put_void(&buf, 1024))
        XCTAssertEqual(buf.size, 1026)
        XCTAssertTrue(mkv_put_uint(&buf, 0xE7, 300))
        XCTAssertEqual(mkv_vint_length(126), 1)
        XCTAssertEqual(mkv_vint_length(127), 2, "127 is the reserved all-ones value")
        XCTAssertEqual(mkv_vint_length(16382), 2)
        var out = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(mkv_write_vint(&out, 5, 0), 1)
        XCTAssertEqual(out[0], 0x85)
        XCTAssertEqual(mkv_write_vint(&out, 300, 0), 2)
        XCTAssertEqual(out[0], 0x41); XCTAssertEqual(out[1], 0x2C)
        var n = 0
        XCTAssertEqual(mkv_parse_vint(out, 2, &n, true), 300)
        XCTAssertEqual(n, 2)
        mkv_buf_free(&buf)
    }
}
