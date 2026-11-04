# Kinect for Mac

Native macOS support for the Azure Kinect DK: a menu bar app that streams the
camera's depth, IR and colour to TouchDesigner (and anything else) over
Syphon, plus a `libk4a`-compatible core you can build against.

No kernel extension, no driver, no Homebrew. Plug the Kinect in, open the app.

## What works

| | |
|---|---|
| Depth | NFOV binned/unbinned, WFOV binned/unbinned, passive IR, at the camera's own rates (30 fps NFOV, 15 fps WFOV unbinned) |
| IR | every mode |
| Colour | 720p through 3072p, BGRA / NV12 / YUY2 (MJPG re-encoded), with exposure, white balance, gain, brightness, contrast, saturation, sharpness, backlight and powerline controls |
| IMU | accelerometer and gyro at 1.6 kHz with the device's own temperature model |
| Outputs | Syphon servers: Color, Depth, IR, Depth (color aligned), Color (depth aligned), Depth (colorized), XY Table; body joints over OSC |
| Timestamps | depth/IR on the device clock; colour frames put on that clock (about 5 ms median error) and paired to the nearest depth frame |
| Recording | `k4arecord` record and playback, MKV in the SDK's own track layout (ffmpeg reads it) |
| Transforms | depth to colour, colour to depth and point cloud on Metal (3 to 4 ms at 2160p), CPU engine for the k4a API |
| Devices | paired by serial across the depth and colour functions, hotplug events, multi-camera sync config accepted |
| Firmware | package parsing, status, and the SDK's update sequence (`kinectctl firmware`) |

### What is still open

**Depth accuracy.** The decoder is a port of [OpenK4A](https://github.com/LukeSchoen/OpenK4A),
a clean-room reimplementation of Microsoft's closed depth engine, brought to
parity against Microsoft's own engine run as an oracle (see below). Per-pixel
phase tables, the radial-to-Z map, the temperature and laser-phase models and
the field-of-illumination mask all come from *your* camera's calibration block
(`docs/calibration-block.md`). Against the engine on the same frames: NFOV
unbinned 0.7 mm RMS (bias under 0.1 mm, 99.6% / 98.3% valid-mask agreement),
NFOV binned 0.6 mm, WFOV binned 0.6 mm, WFOV unbinned 0.5 mm, all at full
resolution and flat across range and temperature. Two residual terms (a
laser-temperature curve and a per-mode constant, about 1 mm) are fitted
against the engine on the author's unit rather than read from the camera;
another unit may need its own.

**GPU decode** is in: the depth pass runs as Metal compute kernels (1.4 ms per
NFOV frame on an M4 Max, bit-identical to the CPU pass, which stays as the
fallback and the reference). Set `OPENK4A_DECODER=cpu` to force the CPU pass.

## Install

Build the app bundle and copy it to Applications:

```sh
scripts/bundle.sh                       # ad hoc signed, for this machine
scripts/bundle.sh --sign "Developer ID Application: …" --dmg --notarize <profile>
open "dist/Kinect for Mac.app"
```

`--dmg` writes a drag-to-Applications disk image; `--notarize` submits it with
`notarytool` using a keychain profile made with `xcrun notarytool store-credentials`.
A signed but not yet notarized build opens with right-click, Open, the first
time; a notarized one opens like any other app.

macOS asks for camera access the first time (that is the colour camera; the
depth camera needs no permission). The app lives in the menu bar: pick a depth
mode, colour resolution and frame rate, tick the Syphon outputs you want, and
open the preview window.

## TouchDesigner

The quick way: open the Textport in TouchDesigner and run

```python
exec(open('/path/to/dk-mac/touchdesigner/build_kinect_component.py').read())
```

It builds a `kinect` Base COMP in `/project1` (and saves `kinect.tox` next to
the script) with four outputs: `color`, `depth_mm` (32-bit float
millimetres), `ir`, and `pointcloud` (RGB32F metres in the depth camera's
frame, alpha = valid). The point cloud needs no intrinsics typed in: the app
publishes the camera's unit-ray table as the "Kinect XY Table" stream and the
GLSL multiplies it by depth. The shaders are in `touchdesigner/*.glsl` if you
would rather wire it by hand.

By hand: add a **Syphon Spout In TOP** and pick the server:

- `Kinect Color` is plain BGRA.
- `Kinect Depth`, `Kinect IR` and `Kinect Depth (color aligned)` are 16-bit
  values packed into 8-bit channels, because Syphon carries 8-bit BGRA:
  **R = high byte, G = low byte, B = 8-bit preview** (0 to the "preview range"
  set in the app, 5 m by default), A = 255.
- `Kinect Depth (colorized)` is a false-colour preview.
- `Kinect XY Table` is the depth camera's unit rays, 16-bit each: R,G = x
  (high, low), B,A = y, mapped from -2..2 onto 0..65535. A point is
  `(x * z, y * z, z)`.

To get millimetres back in a GLSL TOP (set its pixel format to 32-bit float):

```glsl
out vec4 fragColor;
void main() {
    vec4 packed = texture(sTD2DInputs[0], vUV.st);
    float mm = packed.r * 255.0 * 256.0 + packed.g * 255.0;   // 0 = no depth
    fragColor = vec4(mm, mm, mm, 1.0);
}
```

Divide by 1000 for metres. `touchdesigner/kinect_pointcloud.glsl` turns that
and the XY table into the point cloud.

## Body tracking

Microsoft's body tracking SDK is Windows/Linux only and closed. The Mac route
is Apple's Vision framework: it finds 2D body joints in the colour image, and
each joint is lifted to 3D by looking up the depth behind it through the
calibration (median of a 5x5 depth neighbourhood). Joints use k4abt-style
names (`pelvis`, `neck`, `shoulder_left`, `elbow_left`, `wrist_left`,
`hip_left`, `knee_left`, `ankle_left`, their right-hand twins, `nose`,
`eye_left/right`, `ear_left/right`). Positions are millimetres in the depth
camera's frame (x right, y down, z forward).

Turn it on in the menu; it sends OSC bundles over UDP (127.0.0.1:7000 by
default) that an **OSC In CHOP/DAT** in TouchDesigner receives:

```
/kinect/bodies                      count
/kinect/body/<i>/<joint>            x y z confidence   (mm; z = 0 when no depth)
/kinect/body/<i>/<joint>/pixel      u v                (colour pixels)
```

It runs at the colour frame rate when the machine keeps up and otherwise
skips frames rather than falling behind. Body index is Vision's detection
order; there is no identity tracking across frames.

## Command line

`kinectctl` is the diagnostic tool, built alongside the app:

```sh
swift build -c release
.build/release/kinectctl list                 # attached devices
.build/release/kinectctl info                 # serial, firmware, sync jacks
.build/release/kinectctl capture --mode nfov_unbinned --frames 30 --out /tmp/cap --raw
.build/release/kinectctl color --res 1080p --out /tmp/color
.build/release/kinectctl imu --seconds 3
.build/release/kinectctl controls
.build/release/kinectctl bench --color 720p --imu  # rates and colour/depth pairing, no file I/O
.build/release/kinectctl decode raw.bin out   # decode a recorded raw frame
.build/release/kinectctl syphon               # Syphon servers on this machine
.build/release/kinectctl syphon-grab Depth out.bgra   # one frame from a server
.build/release/kinectctl record out.mkv --seconds 10 --color 720p   # k4arecord MKV
.build/release/kinectctl play out.mkv            # config, tags, tracks, seeks
.build/release/kinectctl firmware info <bin>     # parse a firmware package
.build/release/kinectctl firmware status         # the device's versions and update state
.build/release/kinectctl firmware update <bin> --yes   # the SDK's update sequence (untested on hardware here)
.build/release/kinectctl reset                   # reset the device (clears a stuck IMU after a crashed session)
```

Measured with the camera at NFOV unbinned: 30 fps with colour and IMU
running in every mode the camera offers (15 fps WFOV unbinned, its own
limit); decode 1.4 ms per frame on Metal, 10 ms on the CPU pass.

## Measuring against Microsoft's engine

`oracle/` runs Microsoft's own Linux depth engine inside a Docker container
(Mesa software OpenGL) on recorded raw frames, as a black-box reference. Its
answers for the fixture frames live under `Tests/KinectCoreTests/Fixtures/oracle/`
and the parity tests hold the open decoder to them. See `oracle/README.md`.

## Building and testing

Requires Xcode 15 or later (the Metal shaders compile at run time, so the
separate Metal toolchain download is not needed).

```sh
swift build
swift test                                    # no camera needed
KINECT_HW_TESTS=1 swift test --filter HardwareTests   # with a camera attached
```

The hardware-free suite covers the raw frame format, the companding table,
the calibration document, the depth decoder against a recorded frame (bit for
bit, at every optimisation level, CPU and Metal), the 16-bit packing and the
XY table on the GPU, and a Syphon publish/receive round trip in-process.

## How it works

```
Sources/CLibusb      libusb 1.0.29, Darwin backend (LGPL 2.1)
Sources/KinectCore   the k4a API in C: OpenK4A's device protocol, frame
                     format, depth decoder, calibration and transforms (MIT),
                     with this project's macOS layer:
                       openk4a_usb.c        libusb transport, async stream reads
                       openk4a_color_avf.m  colour over AVFoundation
                       openk4a_uvc.c        UVC camera controls as USB control
                                            transfers (Apple's driver leaves the
                                            default pipe reachable)
                       openk4a_imu.c        IMU reader on a pthread
                       openk4a_depth_metal.m the depth pass as Metal kernels
                       openk4a_calibration_block.c the device's calibration block
                       openk4a_record.c / openk4a_playback.c / openk4a_matroska.c  k4arecord
                       openk4a_firmware.c   firmware packages and updates
Sources/Syphon       Syphon's Metal server and client (BSD), shader compiled
                     from source at run time
Sources/KinectKit    Swift: device, session, Metal packing and transforms, Syphon output, body tracking, OSC
Sources/KinectApp    the SwiftUI menu bar app
Sources/kinectctl    the command-line tool
touchdesigner/       the component builder and GLSL for TouchDesigner
```

The depth camera and the IMU are vendor-specific USB interfaces that macOS
leaves unclaimed, so libusb drives them from user space. The device restarts
its clock when the colour camera starts, so, like Microsoft's SDK, the core
drops depth frames stamped more than ten periods from zero until the restart
shows up. The colour camera is
UVC and already owned by macOS, so it is read through AVFoundation like any
webcam, and its controls are sent as UVC class requests on the same device.

## Licence

MIT. Third-party notices: `Sources/KinectCore/openk4a/LICENSE.OpenK4A`,
`Sources/CLibusb/LICENSE.libusb`, `Sources/Syphon/LICENSE.Syphon`.
Microsoft's Azure Kinect Sensor SDK headers (MIT) are reproduced under
`Sources/KinectCore/include/k4a`. Microsoft's depth engine is not used and
nothing here is derived from it.
