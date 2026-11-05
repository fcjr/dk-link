# Kinect Azure TOP and CHOP for TouchDesigner on macOS

Native custom operators that give TouchDesigner on a Mac the **Kinect Azure
TOP** and **Kinect Azure CHOP** it has on Windows: the camera's images as
TOPs and body joints as CHOP channels, with the Windows operators' parameter
names, image menu and channel naming, so a patch moves between the two by
swapping the node. No Syphon, no OSC, nothing to wire: drop the folder in and
the nodes are in the OP Create dialog.

Built on the Kinect for Mac library (`libKinectTD.dylib`), which embeds the
whole stack: the k4a-compatible core, the Metal depth decoder, the
transformation engine and Vision body tracking.

## Install

1. Build: `touchdesigner/plugin/build.sh --install` (needs the library built
   first: `swift build -c release --product KinectTD`; or `--stub` for a
   synthetic test library without a camera).
2. That copies the `Kinect Azure` folder to
   `~/Library/Application Support/Derivative/TouchDesigner099/Plugins/`.
   To install by hand, drag the folder there (or into a `Plugins` folder next
   to your `.toe`). Keep the two bundles together: the CHOP links the
   library inside the TOP's bundle, so they share one camera session.
3. Start TouchDesigner. The first time a plugin loads it asks for permission
   and records it in `Plugins/Plugins.json`; a rebuilt plugin asks again.
4. Press Tab, Custom family: **Kinect Azure** (TOP) and **Kinect Azure** (CHOP).

## Kinect Azure TOP

Page *Kinect Azure*:

| parameter | name | notes |
|---|---|---|
| Active | `Active` | starts/stops the camera |
| Sensor | `Sensor` | device index in serial order (Windows takes a serial string) |
| Camera FPS | `Fps` | `fps5`, `fps15`, `fps30` |
| Color Resolution | `Colorres` | `1280x720` … `4096x3072`, plus `off` |
| Depth Mode | `Depthmode` | `narrowunbinned`, `widebinned`, `narrowbinned`, `wideunbinned`, `passiveir`, plus `off` |
| Image | `Image` | see below |
| Body Tracking | `Bodytracking` | runs the Vision tracker; needed by the CHOP |
| Mirror Image | `Mirrorimage` | flips horizontally |

Image menu (the Windows order) and what comes out:

| entry | output |
|---|---|
| Color | BGRA 8-bit, colour resolution |
| Color aligned to Depth | BGRA 8-bit, depth resolution |
| Depth | 32-bit float, metres, depth resolution (0 = no depth) |
| Depth aligned to Color | 32-bit float, metres, colour resolution |
| IR | 32-bit float 0..1, depth resolution (Windows: 16-bit integer) |
| IR aligned to Color | not available on macOS (node warns) |
| Player Index | 8-bit, 0 or the body id, depth resolution, from the person boxes |
| Player Index aligned to Color | not available on macOS (node warns) |
| Point Cloud | RGBA 32-bit float, xyz metres in the depth camera's frame, alpha = valid |
| Point Cloud aligned to Color | RGBA 32-bit float, xyz metres in the colour camera's frame |

Every Kinect Azure node in the process shares **one** camera session: put the
configuration (depth mode, resolution, FPS, body tracking) on one node and use
the others only for their Image; if two active TOPs ask for different
configurations the last one cooked wins. The TOP only uploads when a new frame
has arrived, so TouchDesigner's cook rate does not have to match the camera.

Info CHOP: `image_frame`, `depth_timestamp`, `captures_per_second`,
`decode_ms`, `sensor_temperature`, `bodytracking_ms`, `bodytracking_bodies`,
`devices`. Info DAT: status, serial, image, library.

Not on macOS: Hardware Type (Orbbec), Sensor Orientation, Sync Image to Body
Tracking, the Color and Timing pages (set colour controls from the Kinect for
Mac app or `kinectctl`; wired sync is accepted by the camera but there is no
parameter yet).

## Kinect Azure CHOP

One sample per cook, not time-sliced. Page *Kinect Azure*: `Active`, `Top`
(kept for Windows patches; unused, the session is shared), `Maxplayers`,
`Worldspace`, `Colorspace`, `Confidence`, `Flipimagev`, `Flipskelu`.

Channels, per player `p1` … `pN`:

```
p1/tracked                 1 when a body is tracked
p1/id                      the body's stable id
p1/<joint>:tx ty tz        metres, depth camera frame (x right, y down, z forward)
p1/<joint>:u  v            colour-image UV, 0..1, v up unless Mirror Image V Positions
p1/<joint>:confidence      0..1 (Windows reports 0..3 levels)
```

Joints are the 32 k4abt names in k4abt order (`pelvis`, `spine_navel`,
`spine_chest`, `neck`, `clavicle_left`, `shoulder_left`, `elbow_left`,
`wrist_left`, `hand_left`, `handtip_left`, `thumb_left`, the right side,
`hip_left`, `knee_left`, `ankle_left`, `foot_left`, the right side, `head`,
`nose`, `eye_left`, `ear_left`, `eye_right`, `ear_right`). Vision provides 19 of
them; the rest are zero with confidence 0. Not on macOS: bone rotations, bone
lengths, depth-image positions, IMU channels.

## Testing without the GUI

`test/td_test.py` runs inside TouchDesigner: it creates both nodes, cycles the
Image menu, saves each image, dumps the CHOP channels and node errors to
`$KINECT_TD_TEST_OUT/report.json`, and quits. A project that runs it on start
is built from text with the app's own `toeexpand`/`toecollapse` (an Execute
DAT with `onStart`); launch it with
`/Applications/TouchDesigner.app/Contents/MacOS/TouchDesigner test.toe`.
Build with `--stub` to exercise the pipeline with synthetic images and a fake
body, no camera needed.
