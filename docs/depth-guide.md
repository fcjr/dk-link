# Understanding the depth data

## What the camera measures

The camera shines infrared light at the scene and times how long it takes to
come back, pixel by pixel. The result is a **depth image**: one distance per
pixel, from the camera to whatever that pixel is looking at. A value of **0
means "no reading"** for that pixel, not "zero distance".

Distances are **millimetres** in the raw data and in OSC, and **metres** in
everything TouchDesigner gets (float images and CHOP channels).

## Picking a depth mode

| Mode | Pixels | Field of view | Reliable range | Rate | Use it for |
|---|---|---|---|---|---|
| NFOV unbinned | 640 x 576 | 75° x 65° | 0.5 to 3.9 m | 30 fps | the default: most detail, a room-sized scene |
| NFOV 2x2 binned | 320 x 288 | 75° x 65° | 0.5 to 5.5 m | 30 fps | longer reach, less noise, a quarter of the pixels |
| WFOV 2x2 binned | 512 x 512 | 120° x 120° | 0.25 to 2.9 m | 30 fps | wide, close scenes: installations, tables, near interaction |
| WFOV unbinned | 1024 x 1024 | 120° x 120° | 0.25 to 2.2 m | 15 fps | wide and detailed, at half the frame rate |
| Passive IR | 1024 x 1024 | | | 30 fps | an infrared picture with no depth at all |

NFOV is "narrow field of view", WFOV "wide". "Binned" means the sensor
averages 2x2 blocks: fewer pixels, less noise, longer reach. Outside the
reliable range the camera still returns numbers, with more holes and more
noise.

## Why pixels go black

A black (0) pixel is one the camera could not measure. The usual causes:

- **Too close or too far** for the mode (see the table).
- **Sunlight or other infrared** washing out the camera's own light; a sunny
  window behind the subject is the classic case.
- **Dark, matte or absorbent surfaces** (black cloth, some plastics) return
  too little light.
- **Glass, mirrors, water and shiny metal** send the light elsewhere.
- **Edges of objects**, where one pixel sees two distances at once, and the
  far corners of the image where the illuminator is dim.
- **Thin things** (cables, hair) thinner than a pixel.

The camera also rejects a pixel when it isn't confident in it; this is the
same rule Microsoft's software uses, so the holes you see are the holes you
would see on Windows.

## The images, and what the numbers mean

- **Depth**: distance in metres (TouchDesigner, 32-bit float) or millimetres
  (Syphon and the `k4a` API, 16-bit). 0 = no reading.
- **Depth (colorized)**: a false-colour preview, near is warm, far is cool,
  black is no reading. The **preview range** slider sets the distance that
  maps to the far end of the colours; it changes the picture, never the data.
- **Over Syphon**, which only carries 8-bit colour, a 16-bit depth value is
  split across two channels: red is the high byte, green the low byte, blue
  an 8-bit preview. The TouchDesigner component and the GLSL in
  `touchdesigner/` put it back together. The native TouchDesigner operators
  don't need this: they get real floats.
- **IR**: how much of the camera's own infrared light came back, a brightness,
  not a distance. Bright means close or reflective. It looks dark at first;
  raise the levels.
- **Point cloud**: every depth pixel turned into a 3D point, x y z in metres.
  x is right, y is down, z is forward (away from the camera), as seen from
  the depth camera. A pixel with no depth has z = 0.
- **Depth aligned to colour / colour aligned to depth**: the two cameras sit a
  few centimetres apart and see slightly different views. These images
  resample one camera's picture into the other's geometry so they line up
  pixel for pixel, for keying and texturing point clouds.
- **XY table**: the direction each depth pixel looks, so a point is
  `(x_table * depth, y_table * depth, depth)`. Only needed when building
  point clouds yourself from a Syphon depth stream.
- **Player index**: which tracked person covers each pixel (0 = nobody).

## How accurate is it

Compared with Microsoft's own software on the same frames, this decoder is
within a millimetre on average and 0.5 to 0.7 mm RMS. The camera itself has
random noise of about 1 to 2 mm at 1 m, growing with distance and toward the
image corners, and systematic error of a few millimetres that grows with
range. It drifts slightly as it warms up over the first half hour, which the
calibration compensates. For measurement work, let it warm up and average a
few frames.

## Coordinates, in one place

- Depth camera frame: origin at the depth sensor, x right, y down, z forward,
  metres (TouchDesigner, point clouds, skeletons) or millimetres (OSC).
- Colour camera frame: the same, but at the colour sensor, a few centimetres
  away. "Aligned" images convert between the two.
- Image pixels: (0,0) top left.
