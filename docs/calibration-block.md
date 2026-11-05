# The IR sensor calibration block (NV tag 2)

The depth MCU hands over one file in answer to `DEV_CMD_NV_DATA_GET` with tag 2.
On the camera used here it is 503,728 bytes. This is what the file holds, as
far as the depth decoder needs it. The layout was read from the type
information (DWARF) that ships with the Linux build of Microsoft's depth engine
(`libdepthengine.so.2.0`, arm64, debug info not stripped): struct names, field
names, offsets and sizes only. No code from the engine was read or reproduced;
the decoder that uses these tables is OpenK4A's.

All integers are little-endian. Floats are IEEE single.

## File header, 16 bytes at offset 0 (`CAL_FILE_HEADER_V1`)

| offset | type | field | fixture value |
|---|---|---|---|
| 0 | u16 | file version | 0x0303 |
| 2 | u16 | calibration version | 0x0301 |
| 4 | u16 | header record size | 240 |
| 6 | u8 | reserved | 0 |
| 7 | u8 | file header size | 16 |
| 8 | u32 | file size | 503728 |
| 12 | u32 | reserved | 0 |

## Record header, 24 bytes at the start of every record (`CAL_BLOCK_INFO_V1`)

| offset | type | field |
|---|---|---|
| 0 | u8 | record id (`CAL_BLOCK_ID`) |
| 1 | u8 | record version |
| 2 | u16 | calibration version |
| 4 | u32 | record size, header included |
| 8 | u64 | checksum |
| 16 | u16 | calibration year |
| 18 | u8 | month |
| 19 | u8 | day |
| 20 | u8 | hour |
| 21 | u8 | minute |
| 22 | u8 | second |
| 23 | u8 | pass |

Record ids: 0x41 ADDRVAL_REGLIST, 0x43 DEVICE_CONFIG, 0x44 PIXEL_DEFECT,
0x46 FOI_MASK, 0x47 GEOMETRIC, 0x49 ILLUM_PROFILE, 0x4C LSDACS, 0x50 P0,
0x52 REGISTRATION, 0x53 SPATIAL_TEMP_CORRECTION, 0x54 GLOBAL_TEMP_CORRECTION,
0xD7 GAINCORRECTION, 0xFF HDR.

## Header record, 240 bytes at offset 16 (`CAL_HEADER_BLOCK_V3`, id 0xFF)

After the 24-byte record header: u16 number of records that follow (99),
u16 chip id, u16 sensor rows (1024), u16 sensor cols (1024), 128 bytes config
version string ("6109.11"), 32 bytes serial number, 32 bytes chip unique id,
then u32 control API version, firmware version, calibration version, sequence
version.

The records that follow tile the rest of the file exactly. On the fixture:
1 ADDRVAL_REGLIST, 7 FOI_MASK, 1 GEOMETRIC, 7 ILLUM_PROFILE, 1 LSDACS, 16 P0,
16 SPATIAL_TEMP_CORRECTION, 48 GLOBAL_TEMP_CORRECTION, 1 ID 0x56, 1 GAINCORRECTION.

## P0 record (`CAL_P0BLOCK_V4`, id 0x50, version 4)

After the record header:

| offset | type | field |
|---|---|---|
| 24 | u8 | mode (block numbering, below) |
| 25 | u8 | frequency index, 1..3 |
| 26 | u16 | modulation frequency in 10 kHz (19800 = 198 MHz) |
| 28 | u16 | integration time |
| 30 | u8 | row coefficients per row (1) |
| 31 | u8 | column coefficients per column (3) |
| 32..39 | u8 | analog/digital/subsampling/software binning, rows then cols |
| 40 | u16 | rows |
| 42 | u16 | cols |
| 44 | u16 | row offset on the 1024x1024 sensor |
| 46 | u16 | column offset |
| 48 | f32[] | rows x row-coefficients, then cols x column-coefficients |

The phase offset of a pixel is `rowCoeff[row] + colCoeff[col][last]`, in
radians, taken modulo 2π. On this camera the first two of the three column
coefficients are zero everywhere; what they would mean when set is not known,
so a block that sets them is declined and the compiled-in tables are used.

Block mode numbering seen: 4 = NFOV native 640x576 at offset (192, 180),
5 = WFOV 1024x1024, 7 = WFOV 2x2 hardware-binned 512x512, 1 = NFOV
hardware-binned 320x288, and 0, 2, 9 = 512x512 one- and two-frequency modes
the public SDK does not expose. Frequencies for the depth modes: 198, 189 and
54 MHz; the dealiasing constants compiled in are for those.

Checked against the compiled-in tables (which were measured from a different
camera): the row profiles correlate 1.000 and the full per-pixel P0 agrees to
0.005 turns rms per frequency once a constant is removed, which is about 4 mm.

## Spatial temperature correction record (`CAL_SPATIAL_TEMP_CORR_BLOCK_V0INFO`, id 0x53)

One per mode and frequency; the frequency index is **0-based** here (the P0
record's is 1-based). After the record header:

| offset | type | field |
|---|---|---|
| 24 | u8 | mode |
| 25 | u8 | frequency index, 0..2 |
| 26 | u16 | frequency in 10 kHz |
| 28 | u16 | integration time |
| 30 | u16 | calibration phase |
| 32 | u16 | rows |
| 34 | u16 | cols |
| 36 | u16 | row offset on the sensor |
| 38 | u16 | column offset |
| 40 | f32[2] | SimpleRowModel |
| 48 | f32[5] | SimpleColumnModel |
| 68 | u16 | number of calibrations |
| 72 | f32[4] | RowTemperatureCoeff |
| 88 | f32[10] | ColumnTemperatureCoeff |
| 128 | f32[3] | BaseCalTemperature |
| 144 | i16[cols] | per-column offsets: the P0 column profile, negated, with 65536 = 2π |

How the decoder uses it. Checked against the tables OpenK4A measured out of
the engine (which, it turns out, are these numbers for the mode-4 record of
that camera): the engine's spatial temperature correction of a pixel's phase
is, in the decoder's form,

    theta(row, col, T) = p0(row, col) + 0.01 (T - BaseCalTemperature[0])
                         * ( poly(ColumnTemperatureCoeff[5..9], row / rows)
                           + RowTemperatureCoeff[1]
                           + RowTemperatureCoeff[3] * col / cols )

with T the sensor temperature from the frame footer. The per-row term agrees
with OpenK4A's measured table to 1e-4 rad (the table was read from the
engine's fixed-point copy), the column slope to all digits, and 0.01 with
intercept -BaseCalTemperature/100 is what OpenK4A fitted as 0.00999 and
-0.2786 from eight captures. The other half of each coefficient set is the
same numbers over the second temperature basis: ColumnTemperatureCoeff[0..4]
and RowTemperatureCoeff[0], [2] are the [5..9], [1], [3] values divided by
-100 / BaseCalTemperature[0], so they carry nothing extra. SimpleRowModel and
SimpleColumnModel are not used by this model; what the engine does with them
is not known.

## Global temperature correction record (`CAL_TEMP_CORR_BLOCK_V0_V1INFO`, id 0x54)

One per mode, frequency and capture (tap 1..9); 96 bytes. After the record
header: u8 mode, u8 frequency index (0-based), u8 capture number, u8 laser id
(16: the laser), 4 bytes reserved, then `TEMP_COEFFS`: f32[8] amplitude
coefficients and f32[8] phase coefficients.

How the decoder uses the phase polynomials, settled against Microsoft's engine
run on this camera's own frames (the oracle, `oracle/run.sh`), first at two
laser temperatures 5.6 °C apart and then on a 30-minute warm-up series (below):
with `x = laser temperature / 100` (the frame footer's `laser_temp[0]`),
`phase(x) = Σ c_k x^k` is in **turns**, and the engine takes off, per
frequency, `phase(x) − phase(x_cal)` of the frequency's **first tap** (capture
1, 4, 7), with `x_cal` the spatial record's BaseCalTemperature[0] / 100. That
is a per-frequency phase offset the decoder folds into its rotation table.
It is what makes depth stable with laser temperature: before any of it, this
camera read 2.9 mm short at 25 °C and 3.0 mm long at 31 °C.

Two things the warm-up series showed that the two-temperature fit could not:

- It is the first tap's polynomial, not the mean of the three. The mean left a
  drift of −0.27 mm per degree on NFOV unbinned; the first tap's polynomial
  predicts the measured change to 0.03 mm over 4.4 °C.
- The records are the **laser's, not the mode's**. Decoded with its own
  (mode 7) records, WFOV 2x2 binned drifted −0.35 mm per degree; with the
  native NFOV mode's (block mode 4) it does not. Every mode therefore takes
  the native mode's set; mode 1's set is the same model to 0.03 mm per
  degree, so the two cannot be told apart, and mode 4 is used. The modes'
  own records remain parsed and are the fallback when the native set is
  missing. What the WFOV records are for is not known.

The per-tap differences (about 0.02 turns between the three taps of a
frequency) are the asymmetry the engine builds into its demodulation; the
decoder still uses the recorded camera's demodulation matrices. The amplitude
polynomials are not used; the IR scale below was fitted instead.

## Field-of-illumination mask record (id 0x46)

After the record header: u8 mode, 7 bytes zero, u16 rows, u16 cols, 4 bytes
zero, then rows × (u16 first column, u16 last column), inclusive; a row of
0xFFFF is unlit. There is one per block mode, on that mode's own grid, and
the software-binned NFOV mode (320x288) uses the mode-1 record. Checked
against the engine's output: it never reports depth outside the mask, on any
row, in either NFOV mode (`openk4a_calblock_find_foi`). This was 86% of the
pixels the decoder used to keep that the engine rejects.

## The saturation code

A twelve-bit field of exactly 0x400 (the sign bit with no magnitude) is the
sensor's saturation mark; it unpacks to a negative zero, and any pixel with
one on any tap is invalid in the engine's output (0 of 148,000 pixels the
engine kept had one; 11% of the unbinned and 38% of the binned pixels it
rejected did). The decoder invalidates them on the block path.

## Constants: derived from the block, engine constants, and what is measured

Every number the decoder uses on the block path is one of three kinds.

**Derived from the block.** Besides the per-pixel tables (P0, the
temperature models, the mask, the radial-to-Z map from the geometric
calibration), the phase-to-millimetre constants: the P0 records name the
modulation frequencies (19800, 18900, 5400 x 10 kHz); their greatest common
divisor is f_base = 9 MHz and M = f / f_base = 22, 21, 6. A turn of
frequency k is c / (2 f_k) of range, the engine combines the three with the
weights M_k^2 / sum(M^2), and so

    alpha_k = M_k * c / (2 f_base sum(M^2)),  c_m = M,  c_md = M / sum(M^2)

with c = 299,714,130 m/s, the speed of light in air (c_vacuum / 1.000261).
That value is the engine's own: its Alpha[k] constants, as recorded from the
engine's calibration memory (openk4a_depth_builtin.h: 381.183441, 363.856903,
103.959106), give c = Alpha_k * 2 f_base sum(M^2) / M_k = 299,714,1xx m/s from
each of the three frequencies to 1e-7. It was confirmed against the engine's
*radial* output (ORACLE_OUTPUT=radial, which keeps the radial-to-Z map out of
the comparison): with c = 3e8 ours read +0.958 +/- 0.001 mm/m long on a
10 m scene (NFOV, 33.9 C) and +0.984 (WFOV binned); the prediction for
299,714,130 is +0.954; with it the slope is +0.004 +/- 0.001 mm/m (NFOV) and
+0.029 (WFOV binned), i.e. zero. c in vacuum would read 0.27 mm/m short. See
"Range residual" below. The de-alias table and the T, RScale, ROffset constants are
functions of M alone (T's rows are integer vectors orthogonal to M; the
table enumerates the wrap triples); they are compiled in and the block path
checks that the block's M is the one they are for.

**Engine constants, the same for every camera** (`DepthTransforms::CalibThresholds`
in the engine is filled per mode in code; no block record carries
thresholds): the gates (max confidence, AB floors, AB ratio, radial range,
the JBL weights) and the reflectivity floor, which is 3/8 of the narrow
modes' value in the wide modes. The 3/8 was measured against the engine's
masks: on the fixture frames, factors 0.28, 0.31, 0.33, 0.35, 0.375, 0.40
give mask disagreements of 4201, 3244, 2687, 2223, 2082 and 2509 pixels on
WFOV binned, so 0.375 is the optimum to about +-0.02. The illumination
profile records (id 0x49, `CAL_ILLUM_PROFILE_BLOCK_V2`) carry a per-mode
`ABScale` (12.00 for mode 4, 3.73 for mode 7, 3.76 for mode 5, 28.9 for
mode 1) and `TargetRefl` 0.25; the ratio 3.73 / 12.00 = 0.31 was tested as
the reflectivity factor and is worse than 0.375, so that scale is not how
the engine derives its floor.

**Measured against the engine and still so.** The IR plane's scale per mode
(0.9522 NFOV unbinned, 0.9338 NFOV binned, 0.9382 WFOV binned, 0.9434 WFOV
unbinned; OpenK4A measured 0.9697 on another camera). The 0x49 `ABScale`
does not give it (the ratio between the WFOV modes matches to 0.2%, the
NFOV pair does not), nor do the 0x54 amplitude polynomials; it may be per
camera. It only scales the IR plane.

**The demodulation matrices.** The engine computes its demodulation
pseudo-inverse per frame (`DepthEngineFrameParams::PseudoInverse[3][6]`,
`ComputePseudoInvMatForTempModel`, from the 0x54 global temperature records
and the frame's temperatures). The decoder still uses the matrices OpenK4A
read out of the engine on another camera. Inverting those matrices gives
tap phases of 0.9, 121.7, 241.1 degrees for the first frequency (a mean
offset of about +1.25 degrees and tap asymmetries under 0.8 degrees) and
tap amplitudes within 1.3% of each other. Everything that the block offers
was tried against the engine on this camera's frames:

- ideal 120-degree taps with the mean laser-temperature rotation: bias
  +1.45 mm (NFOV unbinned), +2.35 mm (NFOV binned), i.e. the engine's
  matrices carry a mean phase offset that the ideal ones lack; a uniform
  tap offset of +0.7 degrees zeroes the bias on the 25 C frame and +1.1
  degrees on the 32 C frame, which is the +1.25 degrees of the measured
  matrices to within the temperature dependence;
- the per-tap phase polynomials of the 0x54 records used as tap asymmetries
  (either sign, with or without the amplitude polynomials as tap
  amplitudes): rms 2.4-2.5 mm instead of 1.6, so they are not the
  asymmetry the engine builds in;
- the per-frequency amplitude scale: the engine's masks are best matched
  with the frequencies' amplitudes equal (the AB ratio gate), which the
  measured matrices give to within 7%; the 0x54 amplitude polynomials'
  ratios, their square roots and their inverses are all worse.

So the measured matrices stay. They are within 1 mm of the engine on this
camera at two temperatures, but whether their +1.25 degrees is the other
camera's or the engine's is not known; a second camera settles it.

**What remains against the engine** (fixture frames, after the above):
NFOV unbinned bias -0.9 mm rms 1.7, NFOV binned +0.05 / 1.6, WFOV binned
-1.4 / 3.3, WFOV unbinned -0.9 / 3.2, mask agreement above 97% in every
mode. The remaining bias is additive (the same at 0.2 m and 2 m) and is not
a rounding convention (the engine's integer minus our sub-millimetre value
spreads over -2.5..+4 mm around +0.5, not within +-0.5). The spatial filter
is a 5x5 box: adding a Gaussian over the window (sigma 0.8 to 3) only makes
the agreement worse, so `JBLFGaussianSigma` in the engine's thresholds is
effectively flat. The geometric record's `ZOffset` is 0 on this camera.

## WFOV unbinned (mode 5)

The device sends this mode as nine 1024x1024 planes of one byte per pixel
(160-byte header, planes 1,048,736 bytes apart, 40-byte footer), not the
12-bit packing of the other modes. The bytes are not samples: each is the
companded difference between a pixel and the pixel above it in the same
column, and a plane is unpacked by accumulating down every column from zero
(`unpack8_plane`; the Metal `unpack` kernel runs one thread per column and
plane). A byte's bit 7 is the sign; bits 4 to 6 are a 3-bit exponent *e* and
bits 0 to 3 a 4-bit mantissa *m*, with

    magnitude = m                        when e = 0
    magnitude = (16 + m) << (e - 1)      otherwise

so the codes run 0..15 in steps of 1, 16..31 in steps of 1, 32..62 in steps
of 2, 64..124 in steps of 4, and so on up to 7680. The byte 0x80 (sign with
nothing) is the saturation mark, as 0x400 is in the 12-bit modes; the
accumulated value is kept as a negative zero and the pixel is invalid.

How the law was measured: a WFOV unbinned frame and a WFOV 2x2 binned frame
of the same still scene were captured seconds apart (the mode table's
layouts are in `openk4a_frame.c`; `dklink decode` writes the planes).
The binned frame's 12-bit taps are known to be right, so every candidate law
was scored by the correlation between the unbinned plane, summed 2x2, and
the binned plane, tap by tap. Treating the bytes as samples gave no
correlation under any law; accumulating them down the columns under the
law above gives 0.997, and the de-aliased phases then agree with the binned
frame's and with the engine's. No large fixture was added for this: the
engine's own IR and depth for the fixture frame (Fixtures/oracle) are the
recorded check, and `Tests/DKCoreTests/WfovUnbinnedTests.swift` holds
the law's shape (monotone, sign-symmetric, 0x80 is zero).

The mode decodes on its own 1024x1024 grid with the block's mode-5 P0,
temperature and illumination-mask records, like every other mode. Two more
per-mode constants were measured against the engine and apply to both WFOV
modes (`OPENK4A_ORACLE_*`): the reflectivity floor is 3/8 of the NFOV one,
and the IR scale is 0.9382 (2x2 binned) and 0.9434 (unbinned).

## The filter's averaging

The 5x5 joint bilateral pass averages the three frequencies' phasors as
complex numbers weighted by magnitude, and takes the amplitude of the
averaged phasor, not the average of the amplitudes (coherent averaging; the
engine's formulation). Incoherent averaging let noise-dominated pixels at
long range pass the confidence gate with a random phase: it was the whole
of the WFOV unbinned false-accept problem, and it tightened every other mode
as well (NFOV unbinned rms 2.2 → 1.6 mm). The gate thresholds are unchanged.

Every build decodes to the same bits: the rotation table is built with one
`__sincosf` call per entry, because the optimiser merges a separate `sinf`
and `cosf` into that call and its last-place rounding differs from theirs
for some arguments, which moved single pixels by a millimetre between -O0
and -O2 builds. The Metal pass reads the same table and matches the CPU
pass pixel for pixel in every mode; the test suite checks both.

With all of the above, on the fixture frames against the engine:

| mode | bias (mm) | rms (mm) | precision | recall |
|---|---|---|---|---|
| NFOV unbinned | −0.8 | 1.6 | 99.6% | 98.6% |
| NFOV 2x2 binned | +0.1 | 1.6 | 97.4% | 99.7% |
| WFOV 2x2 binned | −1.3 | 3.3 | 99.7% | 97.9% |
| WFOV unbinned | −0.9 | 3.2 | 99.8% | 98.2% |

Precision is the share of our valid pixels the engine also keeps, recall the
share of the engine's we keep. `oracle/compare.py` prints these from a
`dklink decode` PGM and an `oracle/run.sh` output.

What still differs is a ±5 mm bias that steps with the de-alias table
entry (the same profile in both WFOV modes, a different one in NFOV). It is
not the per-frequency laser phase (folded in from the 0x54 records), not the
alpha scale, and not the three taps' relative phases: the builtin
demodulation matrices are a scaled pseudo-inverse of the taps' phasors, the
fitted tap offsets are under 1.5°, and this block's per-tap 0x54 phase
polynomials differ between taps by under 1°, worth at most 2 mm. The
remaining candidates are the engine's `PseudoInverse` and `PhaseOffsets`
calibration fields, whose values are not in any record the block carries
in a form that has been identified.

## Other records, read but not used

`CAL_GEOMETRIC_BLOCK_V3` (0x47): the depth camera's intrinsics on the 1024x1024
sensor; the same numbers the calibration JSON carries, which is what the
decoder's radialToZ table is built from.

## Warm-up series

`oracle/warmup.sh` records NFOV unbinned and WFOV 2x2 binned frames every two
minutes while the camera streams for half an hour; `oracle/run.sh` gives the
engine's answer for each, `dklink decode --block --calibration` ours, and
`oracle/tempdiff.py` the per-pixel change of (ours − engine) between two
frames of the same scene, which cancels the scene and leaves only what moves
with temperature. On this camera the laser went from 29.5 to 35.1 °C (the
sensor from 29.2 to 36.2 °C) over the series, and the earlier fixture frame
at 25.3 °C is the cold point.

Change of (ours − engine) relative to the first frame of the series, same
pixels, mm (the per-pixel spread about these means is 0.7 mm in WFOV and
1.6 mm in NFOV, the sensors' own noise):

| frame | laser °C | NFOV, mean of taps | NFOV, first tap | WFOV, own records | WFOV, native records |
|---|---|---|---|---|---|
| t00 | 29.5 | 0 | 0 | 0 | 0 |
| t05 | 33.1 | | | −1.06 | −0.00 |
| t08 | 33.9 | −1.02 | −0.11 | | |
| t10 | 34.2 | | | −1.58 | −0.20 |
| t12 | 34.6 | | −0.33 | | |
| t15 | 35.1 | −1.67 | −0.50 | −2.01 | −0.39 |

Both modes keep a residual of about −0.07 mm per degree whose source was not
found (candidates: the engine's fixed-point conversion of the coefficients,
or a basis other than laser °C / 100 for the polynomial); it is 0.4 mm over
the camera's whole operating range. The change maps are uniform: nothing of
what moves with temperature has spatial or range structure, so the spatial
correction and the range constants are right.

What does not move with temperature: each scene has a static per-pixel
pattern of (ours − engine), about ±0.15 % of range in the interior and
−0.6 % at the left edge of the frame on the far wall of the series scene,
3 mm at 2 m. It is the same in every frame of the series at every
temperature, it is not the radial-to-Z map's shape (correlation −0.45), and
it is not range-proportional; it is the one systematic difference left and
is where the per-mode "bias" of about a millimetre comes from, since a
scene samples that pattern differently.

## Illuminator baseline (the static per-pixel pattern)

After the temperature work a static per-pixel difference from the engine
remained: a lateral tilt, about +7 mm across an NFOV frame and +20 mm across
a WFOV binned frame, the same at every temperature, and sampled differently
by each scene (so it showed up as a varying per-frame "bias"). It is the
illuminator offset.

The depth sensor and the laser illuminator are a few millimetres apart, so
the modulated light travels illuminator -> scene -> sensor, and the phase
measures half that round trip, `p = (|P - L| + |P|) / 2` for a scene point `P`
on a pixel's unit ray `u` and the illuminator at `L`. The engine reports the
sensor's own distance `|P| = d`; inverting the round trip,

    d = (p^2 - |L|^2 / 4) / (p - (u . L) / 2).

`L` is in the illumination profile record (`CAL_ILLUM_PROFILE_BLOCK_V2`, id
0x49): `SensorToLSOffsetX/Y/Z` as int16 millimetres (this camera: (-14, 0, 1)
for the NFOV modes, (-22, 0, 0) for the WFOV modes). The decoder precomputes
`(u . L) / 2` per pixel over the calibration's unit rays and `|L|^2 / 4`, and
applies the inversion in `depth_conclude` before the radial-to-Z step. Nothing
is fitted; the offset is read from the block.

Effect against the engine on the fixture frames (bias / rms, mm):

| mode | before | after |
|---|---|---|
| NFOV unbinned | -0.9 / 1.7 | -0.8 / 1.7 |
| NFOV 2x2 binned | +0.05 / 1.6 | +0.8 / 1.9 |
| WFOV 2x2 binned | -1.4 / 3.3 | -1.5 / 1.7 |
| WFOV unbinned | -0.9 / 3.2 | -1.1 / 1.3 |

The WFOV modes, whose wider field makes the lateral term largest, roughly
halve; the NFOV modes were already dominated by other noise. The lateral
tilt is gone (its coefficient drops from ~+7/+11 mm to under 0.1). What
remains is a range-proportional residual of about 1 mm per metre and a
sub-millimetre constant, which is not a per-pixel pattern.

## 0x49 illumination profile record

| offset | type | field |
|---|---|---|
| 24 | u8 | mode |
| 25 | u8 | pixel binning |
| 26 | u8 | laser id |
| 28 | u32 | profile data size |
| 32 | f32 | ABScale |
| 36 | f32 | target reflectivity |
| 40 | i16[3] | sensor-to-light-source offset, mm (x right, y down, z forward) |
| 46 | i16 | target distance |
| 48 | u16 | rows |
| 50 | u16 | cols |
| 52 | u16 | row offset |
| 54 | u16 | column offset |
| 56 | ... | per-pixel profile data (not used) |

## Range residual, and the oracle's intrinsics

Measured on the warm-up series and the fixtures in the engine's radial
output (ORACLE_OUTPUT=radial), so the radial-to-Z map is not involved, and
with our decoder at 0.1 mm resolution (a harness that scales output_scale
and the illuminator-baseline terms by 10) so rounding is not either:

* **Scale.** ours - engine against range is a straight line whose slope is
  the speed of light: +0.96 mm/m with c = 3e8, +0.004 +/- 0.001 mm/m with
  299,714,130 m/s (the engine's Alpha constant, above). Fixed.

* **The engine's Z needs the SDK's camera calibration.** The SDK hands the
  engine the depth camera's raw calibration (`k4a_calibration_camera_t`, the
  1024x1024 sensor form with normalised intrinsics); run without it the
  engine uses the block's own intrinsics for its radial-to-Z map, and the two
  maps differ by up to 15 mm at 5-7 m in a range- and column-structured way
  that looked like a decoder error. Against the engine run as the SDK runs it
  (`dklink camera-calibration calibration.json out.bin --raw`, passed as
  run.sh's fourth argument; the fixture copy is
  `Fixtures/depth_camera_calibration.bin`) our Z is flat across range in
  every mode. The parity fixtures under `Fixtures/oracle/` are now those.
  Per mode on the fixture frames (ours - engine, Z, pixels valid in both):

  | mode | bias | rms | only ours | only engine |
  |---|---|---|---|---|
  | NFOV unbinned (25 C) | -1.69 | 1.83 | 0.2% | 0.7% |
  | NFOV 2x2 binned (31 C) | +0.02 | 0.63 | 1.2% | 0.1% |
  | WFOV 2x2 binned (31 C) | -1.44 | 1.56 | 0.2% | 0.6% |
  | WFOV unbinned (31 C) | -1.04 | 1.17 | 0.2% | 0.6% |

* **What remains: a constant per mode, and a laser-temperature curve.** With
  range and the map out of the way, engine - ours (0.1 mm resolution,
  radial) is spatially uniform to +/-0.2 mm across the image and flat across
  range within every frame, and depends on the laser temperature:

  | laser C | NFOV | WFOV binned |
  |---|---|---|
  | 25.2 | +1.9 | |
  | 27.9 | +0.8 | +1.9 |
  | 29.5 | +0.4 | +1.5 |
  | 30.8 | | +1.8 |
  | 32.8 | +0.3 | +1.5 |
  | 33.9 | +0.5 | +1.7 |
  | 34.6 | +0.7 | +1.9 |
  | 35.1 | +0.9 | +2.1 |

  A quadratic in laser temperature fits each to 0.03 (NFOV) and 0.12 mm (WFOV)
  rms: 0.044 (T - 31.4)^2 and 0.033 (T - 31.2)^2 mm, plus a constant of about
  +0.3 mm (NFOV) and +1.5 mm (WFOV). The curvature is a third of the laser
  correction's own and has the same vertex in both modes, so it belongs to the
  laser model, but no evaluation of the 0x54 records predicts it: the other
  taps' polynomials, their mean, an amplitude-weighted mean, the sensor
  temperature or its mean with the laser's, dropping or doubling the x^6 term,
  all predict monotonic changes (rms 0.45-1.7 mm after a constant), and the
  base temperature only moves the constant. The WFOV-only constant is not in
  any record field either (ZOffset is 0; target_distance is 4650 for every
  mode; the illuminator offsets are applied). A second camera or more
  temperature points with a different engine version would be the way to
  tell a convention from a per-unit term. Reproduce with oracle/warmup.sh
  and the scripts the measurement used (scratch: rangefit/fit.py, fitr.py,
  bins.py, map.py, rules.py, variants.py).

## The fitted residual (`OPENK4A_FITTED_RESIDUAL_*`)

The curve above is the one term in the decoder that is **fitted against the
engine rather than derived**. It is applied on the block path only, as a
radial offset added before the radial-to-Z step, recomputed per frame from
the smoothed laser temperature T:

    residual_mm = C_mode + K (T - T0)^2
    T0 = 31.25 C, K = 0.0462 mm/C^2
    C = +0.168 (NFOV unbinned), -0.125 (NFOV 2x2 binned),
        +1.414 (WFOV 2x2 binned), +1.037 (WFOV unbinned)

Fitted on 2026-11-04 against the engine's radial output on serial
000146321712 (this unit): the 16-point warm-up series (NFOV unbinned and
WFOV binned, laser 29.5 to 35.1 C), two cold frames (27.9 C) and the fixture
frames (25.3 and 30.8 C); 22 frames for the shared T0 and K (rms 0.04 mm;
T0 +/- 0.25 C, K +/- 0.004 mm/C^2; the two families fitted alone give T0
31.25 both, K 0.045 and 0.049), one frame each for the NFOV binned and WFOV
unbinned constants, placed on the shared curve. The binned modes sit about
0.3 to 0.4 mm below their unbinned siblings, so the constant is per mode,
not per family. The constants live in one place in `openk4a_depth_model.c`
with this provenance; another camera may need its own, or none.

Per frame, engine minus ours in the radial output after the fit (mm, the
decoder's own 1 mm output, trimmed mean over the interior; the sensor's
frame-to-frame noise is about 1 mm per pixel):

| frame | laser C | NFOV unbinned | WFOV binned |
|---|---|---|---|
| fixture | 25.3 | -0.07 | |
| cold | 27.9 | +0.05 | -0.01 |
| t00 | 29.5 | +0.07 | 0.00 |
| fixture (WFOV) | 30.8 | | +0.04 |
| t02 | 32.0 | -0.03 | -0.02 |
| t04 | 32.8 | -0.03 | -0.02 |
| t06 | 33.4 | -0.03 | -0.01 |
| t08 | 33.9 | -0.02 | 0.00 |
| t10 | 34.2 | -0.02 | 0.00 |
| t12 | 34.6 | +0.01 | 0.00 |
| t14 | 35.0 | +0.04 | +0.02 |
| t15 | 35.1 | +0.03 | +0.01 |

NFOV 2x2 binned (one frame, 30.8 C): -0.01; WFOV unbinned (one frame,
30.9 C): 0.00. Note for anyone re-measuring with the 0.1 mm harness
(rangefit/h/fine.c): it scales `output_scale` by ten, and this term is
computed in the output's units, so under that trick only a tenth of it is
applied; measure with the decoder's own output instead.

On the fixture frames, ours minus engine in Z (pixels valid in both):
NFOV unbinned bias -0.03 mm rms 0.71 (was -1.69 / 1.83), NFOV binned -0.09 /
0.64 (was +0.02 / 0.63), WFOV binned -0.27 / 0.60 (was -1.44 / 1.56), WFOV
unbinned -0.19 / 0.52 (was -1.04 / 1.17). Mask agreement is unchanged. Metal
and the CPU pass stay bit-identical; the NULL-block (builtin) path is
untouched.
