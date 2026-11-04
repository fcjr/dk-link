import SwiftUI
import MetalKit
import KinectKit

/// A Metal view that draws the latest texture of one stream, letterboxed.
struct TexturePreview: NSViewRepresentable {
    let frames: PreviewFrames?
    let stream: SyphonOutput.Stream
    let device: MTLDevice?

    func makeCoordinator() -> Renderer { Renderer(device: device) }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: device)
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 30
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1)
        view.framebufferOnly = false
        context.coordinator.frames = frames
        context.coordinator.stream = stream
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.frames = frames
        context.coordinator.stream = stream
    }

    final class Renderer: NSObject, MTKViewDelegate {
        var frames: PreviewFrames?
        var stream: SyphonOutput.Stream = .color
        private let queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?

        init(device: MTLDevice?) {
            queue = device?.makeCommandQueue()
            super.init()
            guard let device else { return }
            let source = """
            #include <metal_stdlib>
            using namespace metal;
            struct V { float4 position [[position]]; float2 uv; };
            vertex V blit_vertex(uint id [[vertex_id]], constant float4 &fit [[buffer(0)]]) {
                float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
                float2 uvs[4] = { float2(0, 1), float2(1, 1), float2(0, 0), float2(1, 0) };
                V out;
                out.position = float4(corners[id] * fit.xy, 0, 1);
                out.uv = uvs[id];
                return out;
            }
            fragment float4 blit_fragment(V in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
                constexpr sampler s(filter::linear);
                return tex.sample(s, in.uv);
            }
            """
            guard let library = try? device.makeLibrary(source: source, options: nil) else { return }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "blit_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "blit_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let queue, let pipeline, let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let commandBuffer = queue.makeCommandBuffer() else { return }
            if let texture = frames?.texture(for: stream), let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                // Letterbox: scale the quad so the texture keeps its aspect.
                let viewAspect = Float(view.drawableSize.width / max(view.drawableSize.height, 1))
                let textureAspect = Float(texture.width) / Float(max(texture.height, 1))
                var fit = SIMD4<Float>(1, 1, 0, 0)
                if textureAspect > viewAspect { fit.y = viewAspect / textureAspect } else { fit.x = textureAspect / viewAspect }
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBytes(&fit, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                encoder.endEncoding()
            } else if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                encoder.endEncoding()
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}

struct PreviewWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var left: SyphonOutput.Stream = .color
    @State private var right: SyphonOutput.Stream = .depthPreview

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $left) { streamOptions }.frame(width: 200)
                Spacer()
                Text(model.state.label).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $right) { streamOptions }.frame(width: 200)
            }
            HStack(spacing: 8) {
                pane(left)
                pane(right)
            }
            HStack(spacing: 16) {
                Text(String(format: "%.1f fps", model.statistics.capturesPerSecond))
                Text(String(format: "%.1f ms/frame", model.processingMilliseconds))
                Text(String(format: "%.1f °C", model.statistics.sensorTemperatureCelsius))
                if let imu = model.lastIMU {
                    Text(String(format: "acc %.2f %.2f %.2f", imu.acceleration.x, imu.acceleration.y, imu.acceleration.z))
                }
                Spacer()
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(minWidth: 900, minHeight: 420)
    }

    private func pane(_ stream: SyphonOutput.Stream) -> some View {
        ZStack(alignment: .bottomLeading) {
            TexturePreview(frames: model.previewFrames, stream: stream, device: model.metalDevice)
            if stream == .color, model.output.bodyTracking, !model.bodies.isEmpty {
                BodyOverlay(bodies: model.bodies, imageSize: model.configuration.colorResolution.size)
            }
            if let note = note(for: stream) {
                Text(note)
                    .font(.caption)
                    .padding(6)
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
    }

    /// Why a pane may be dark, when it is by design rather than a fault.
    private func note(for stream: SyphonOutput.Stream) -> String? {
        let mode = model.configuration.depthMode
        switch stream {
        case .color where model.configuration.colorResolution == .off:
            return "Colour is off in the menu"
        case .depth, .depthPreview, .depthInColor:
            if mode == .off { return "Depth is off in the menu" }
            if mode == .passiveIR { return "Passive IR has no depth; pick another depth mode" }
            if stream == .depth { return "16-bit packed form (R high, G low, B preview), dark by design" }
        case .ir where mode == .off:
            return "Depth is off in the menu"
        default:
            break
        }
        return model.state.isRunning ? nil : "Not streaming"
    }

    private var streamOptions: some View {
        ForEach([SyphonOutput.Stream.color, .depthPreview, .depth, .ir], id: \.self) { stream in
            Text(stream == .depth ? "Depth (packed 16-bit)" : stream.rawValue).tag(stream)
        }
    }
}


/// Joints, bones and boxes over the colour pane, in the same letterboxed
/// placement the Metal view uses for the image.
struct BodyOverlay: View {
    let bodies: [Body]
    let imageSize: (width: Int, height: Int)

    static let bones: [(String, String)] = [
        ("nose", "neck"), ("neck", "shoulder_left"), ("neck", "shoulder_right"),
        ("shoulder_left", "elbow_left"), ("elbow_left", "wrist_left"),
        ("shoulder_right", "elbow_right"), ("elbow_right", "wrist_right"),
        ("neck", "pelvis"), ("pelvis", "hip_left"), ("pelvis", "hip_right"),
        ("hip_left", "knee_left"), ("knee_left", "ankle_left"),
        ("hip_right", "knee_right"), ("knee_right", "ankle_right"),
        ("nose", "eye_left"), ("nose", "eye_right"), ("eye_left", "ear_left"), ("eye_right", "ear_right"),
    ]
    static let palette: [Color] = [.green, .orange, .cyan, .pink, .yellow, .purple]

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard imageSize.width > 0, imageSize.height > 0 else { return }
                let viewAspect = size.width / max(size.height, 1)
                let imageAspect = CGFloat(imageSize.width) / CGFloat(imageSize.height)
                var drawn = size
                if imageAspect > viewAspect { drawn.height = size.width / imageAspect } else { drawn.width = size.height * imageAspect }
                let origin = CGPoint(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2)
                let scale = drawn.width / CGFloat(imageSize.width)
                func place(_ p: SIMD2<Float>) -> CGPoint {
                    CGPoint(x: origin.x + CGFloat(p.x) * scale, y: origin.y + CGFloat(p.y) * scale)
                }
                for body in bodies {
                    let color = BodyOverlay.palette[body.index % BodyOverlay.palette.count]
                    if let box = body.boundingBox {
                        let rect = CGRect(x: origin.x + CGFloat(box.x) * scale, y: origin.y + CGFloat(box.y) * scale,
                                          width: CGFloat(box.z) * scale, height: CGFloat(box.w) * scale)
                        context.stroke(Path(rect), with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1.5, dash: body.source == "rect" ? [6, 4] : []))
                    }
                    if let box = body.boundingBox {
                        context.draw(Text("#\(body.index)").font(.caption).bold().foregroundColor(color),
                                     at: CGPoint(x: origin.x + CGFloat(box.x) * scale + 4, y: origin.y + CGFloat(box.y) * scale - 10), anchor: .leading)
                    } else if let head = body.joints.first(where: { $0.name == "nose" || $0.name == "neck" }) {
                        let p = place(head.colorPixel)
                        context.draw(Text("#\(body.index)").font(.caption).bold().foregroundColor(color), at: CGPoint(x: p.x, y: p.y - 18), anchor: .center)
                    }
                    let joints = Dictionary(uniqueKeysWithValues: body.joints.map { ($0.name, $0) })
                    for (a, b) in BodyOverlay.bones {
                        guard let ja = joints[a], let jb = joints[b] else { continue }
                        var path = Path()
                        path.move(to: place(ja.colorPixel))
                        path.addLine(to: place(jb.colorPixel))
                        context.stroke(path, with: .color(color), lineWidth: 2.5)
                    }
                    for joint in body.joints {
                        let p = place(joint.colorPixel)
                        let r: CGFloat = joint.name == "center" ? 7 : 4
                        context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(color))
                        if let z = joint.position?.z, joint.name == "pelvis" || joint.name == "center" || joint.name == "nose" {
                            context.draw(Text(String(format: "%.2f m", z / 1000)).font(.caption2).foregroundColor(.white), at: CGPoint(x: p.x + 8, y: p.y - 8), anchor: .leading)
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}