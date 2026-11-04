# The oracle

Microsoft's own depth engine (the Linux arm64 `libdepthengine.so.2.0` from
the `libk4a1.4` package) run as a black box inside a Linux container with
Mesa's software OpenGL, on raw frames recorded by `kinectctl capture --raw`
and the device's calibration block. Its output is the ground truth the open
decoder is measured against; nothing from the binary is used in the decoder.

```sh
oracle/run.sh nfov_unbinned Tests/KinectCoreTests/Fixtures/nfov_unbinned.raw oracle/out/nfov_unbinned \
    Tests/KinectCoreTests/Fixtures/depth_camera_calibration.bin
python3 -I oracle/compare.py oracle/out/ours_nfov_unbinned.depth.pgm oracle/out/nfov_unbinned.depth.u16
```

Always pass the depth camera calibration (the SDK hands the engine the raw
camera calibration from the device's JSON; `kinectctl camera-calibration
calibration.json out.bin --raw` makes it). Without it the engine uses the
block's own intrinsics for its Z map and its output differs from the SDK's by
up to 15 mm at range; `ORACLE_OUTPUT=radial` sidesteps the map entirely.

`run.sh` fetches the engine from Microsoft's package server and builds the
image on first use (needs Docker and network). The engine binary is not part
of this repository. Outputs:
`<prefix>.depth.u16`, `<prefix>.ir.u16` (little-endian, width x height) and
`<prefix>.info.txt`. The engine's answers for the four fixture frames are kept
under `Tests/KinectCoreTests/Fixtures/oracle/` for the parity tests.
