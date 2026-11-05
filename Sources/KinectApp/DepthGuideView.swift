import SwiftUI
import KinectKit

/// The words for the depth data, in one place: the guide window, the menu
/// tooltips and the preview captions all read from here.
enum DepthCopy {
    static func help(for stream: SyphonOutput.Stream) -> String {
        switch stream {
        case .color: return "The colour camera."
        case .depth: return "Distance in millimetres, 16-bit, split over two 8-bit channels: red is the high byte, green the low, blue a preview. 0 means no reading."
        case .ir: return "Infrared brightness, packed the same way as depth. Bright is close or reflective; it is not a distance."
        case .depthInColor: return "Depth resampled into the colour camera's view, so it lines up with the colour image pixel for pixel."
        case .colorInDepth: return "Colour resampled into the depth camera's view, so it lines up with the depth image."
        case .depthPreview: return "Depth as colours: warm is near, cool is far, black is no reading. For looking at, not measuring."
        case .xyTable: return "The direction each depth pixel looks, for building point clouds from the depth stream."
        }
    }

    static func rangeText(_ mode: DepthMode) -> String? {
        guard let range = mode.rangeMetres else { return nil }
        return String(format: "%g to %g m", range.lowerBound, range.upperBound)
    }
}

/// Why the depth looks the way it does, for someone who has never used a
/// depth camera: what is measured, which mode to pick, why pixels go black,
/// and what each image and number means.
struct DepthGuideView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                section("What the camera measures") {
                    Text("The Kinect shines infrared light at the scene and times how long it takes to come back, pixel by pixel. The result is a depth image: one distance per pixel, from the camera to whatever that pixel sees.")
                    Text("A value of 0 means no reading for that pixel, not zero distance. Distances are millimetres in the raw data and over OSC, and metres in everything TouchDesigner gets.")
                }

                section("Reading the colours") {
                    ramp
                    Text("The colorized preview maps distance onto this ramp. The colour range in the menu sets the distance at the far end; it changes the picture, never the data.")
                }

                section("Picking a depth mode") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow {
                            Text("Mode").bold()
                            Text("Reliable range").bold()
                            Text("Rate").bold()
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(DepthMode.allCases.filter { $0 != .off }) { mode in
                            GridRow(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.label).fontWeight(mode == model.configuration.depthMode ? .semibold : .regular)
                                    Text(mode.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(DepthCopy.rangeText(mode) ?? "no depth")
                                Text("\(mode.maximumFrameRate.rawValue) fps")
                            }
                        }
                    }
                    Text("Narrow is a 75° by 65° view, wide is 120° by 120°. Binned means the sensor averages 2x2 blocks: fewer pixels, less noise, longer reach. Outside the reliable range the camera still returns numbers, with more holes and more noise.")
                }

                section("Why pixels go black") {
                    bullets([
                        "Too close or too far for the mode.",
                        "Sunlight or other infrared washing out the camera's own light; a sunny window behind the subject is the classic case.",
                        "Dark, matte or absorbent surfaces, such as black cloth, that return too little light.",
                        "Glass, mirrors, water and shiny metal, which send the light elsewhere.",
                        "Edges of objects, where one pixel sees two distances at once, and the far corners of a wide view where the light is dim.",
                        "Things thinner than a pixel: cables, hair.",
                    ])
                    Text("The camera also drops a pixel when it is not confident in it. This is the same rule Microsoft's software applies, so the holes here are the holes you would see on Windows.")
                }

                section("The images") {
                    definitions([
                        ("Depth", "Distance per pixel. Metres as a 32-bit float in TouchDesigner; millimetres as 16-bit over Syphon, split into red (high byte) and green (low byte) because Syphon carries 8-bit colour."),
                        ("Depth (colorized)", "The ramp above, for looking at. Black is no reading."),
                        ("IR", "How much of the camera's own infrared light came back: a brightness, not a distance. Bright means close or reflective. It looks dark at first; raise the levels."),
                        ("Point cloud", "Every depth pixel as a 3D point in metres. x is right, y is down, z is forward, as seen from the depth camera. A pixel with no depth has z = 0."),
                        ("Depth (color aligned)", "Depth resampled into the colour camera's view. The two cameras sit a few centimetres apart; this makes the images line up pixel for pixel, for keying and for texturing point clouds."),
                        ("Color (depth aligned)", "The colour image resampled into the depth camera's view, the other way round."),
                        ("XY table", "The direction each depth pixel looks, so a point is (x × depth, y × depth, depth). Only needed to build point clouds yourself from a Syphon depth stream."),
                        ("Player index", "Which tracked person covers each pixel, 0 for nobody."),
                    ])
                }

                section("How accurate it is") {
                    Text("Against Microsoft's own software on the same frames, this decoder is within a millimetre on average and under a millimetre RMS. The camera itself has random noise of about 1 to 2 mm at 1 m, growing with distance and toward the corners, and systematic error of a few millimetres that grows with range. It drifts slightly while it warms up over the first half hour, which the calibration compensates. For measurement, let it warm up and average a few frames.")
                }
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private var ramp: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 0) {
                Rectangle().fill(.black).frame(width: 36)
                LinearGradient(colors: [.red, .yellow, .green, .cyan, .blue], startPoint: .leading, endPoint: .trailing)
            }
            .frame(height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            HStack {
                Text("no reading").frame(width: 72, alignment: .leading)
                Text("near")
                Spacer()
                Text(String(format: "%.1f m and beyond", model.output.previewRangeMillimetres / 1000))
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3).fontWeight(.semibold)
            content()
        }
    }

    private func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(item)
                }
            }
        }
    }

    private func definitions(_ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.0) { term, meaning in
                VStack(alignment: .leading, spacing: 1) {
                    Text(term).fontWeight(.semibold)
                    Text(meaning).foregroundStyle(.secondary)
                }
            }
        }
    }
}
