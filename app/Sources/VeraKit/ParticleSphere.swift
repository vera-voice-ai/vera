import MetalKit
import SwiftUI

/// Vera's particle sphere — from Vera Sphere Lab (`~/Projects/sphere/Sphere/MetalParticleSphereView.swift`): thousands
/// of particles on a golden-angle sphere, folded by a slow vector field, over a translucent pink-cyan membrane that
/// follows the same field. Of the lab's modes only «speaking» is brought: while Vera speaks the sphere turns pink and
/// its folds kick on every peak of her real voice (`voiceEnergy`, 0…1); otherwise it rests.
///
/// Drawn with Metal on the Mac and the phone. An off-screen snapshot (ImageRenderer cannot draw Metal) gets the same
/// particles on a Canvas: set `ParticleSphere.offscreen` before rendering one.
public struct ParticleSphere: View {
    nonisolated(unsafe) public static var offscreen = false

    let speaking: Bool
    let voiceEnergy: Double
    let particles: Int
    let glow: Double
    let dotScale: Double
    let warp: Double

    /// `particles`: about 20 000 for a big stage, a few thousand for a small tile. `dotScale`: the dots' size (1 — the
    /// lab's; a small sphere with fewer, bigger dots reads better). `warp`: how much the field folds the sphere (1 — the lab's).
    public init(speaking: Bool = false, voiceEnergy: Double = 0, particles: Int = 6_000, glow: Double = 1, dotScale: Double = 1,
                warp: Double = 1) {
        self.speaking = speaking; self.voiceEnergy = voiceEnergy; self.particles = particles; self.glow = glow
        self.dotScale = dotScale; self.warp = warp
    }

    public var body: some View {
        if Self.offscreen {
            SphereCanvas(speaking: speaking, voiceEnergy: voiceEnergy, particles: min(particles, 4_000), glow: glow, dotScale: dotScale, warp: warp)
        } else {
            SphereMetal(speaking: speaking, voiceEnergy: voiceEnergy, particles: particles, glow: glow, dotScale: dotScale, warp: warp)
        }
    }
}

// MARK: - The field (the lab's math, unchanged)

struct SphereParticle { var position: SIMD2<Float>; var size: Float; var alpha: Float; var glow: Float; var depth: Float }
struct SphereMembraneVertex { var position: SIMD4<Float>; var color: SIMD4<Float> }

/// The sphere's motion and look, frame by frame, for any renderer. Positions are in normalized device coordinates.
final class SphereField {
    var particleCount = 6_000
    var glow = 1.0
    var dotScale = 1.0
    var warp = 1.0
    private let rotation = 0.15
    private let deformation = 0.82
    private let deformationSpeed = 1.0
    var speaking = false
    var voiceEnergy = 0.0
    /// The lab's tints: rest (violet-pink) and speaking (pink).
    nonisolated static let restTint = SIMD3<Float>(0.88, 0.36, 0.92), speakingTint = SIMD3<Float>(1.0, 0.34, 0.70)
    private(set) var tint = restTint
    private(set) var particles: [SphereParticle] = []
    private(set) var membrane: [SphereMembraneVertex] = []
    static let latitudeSegments = 64, longitudeSegments = 128

    private var speakingWeight = 0.0, speechResponseEnvelope = 0.0, previousVoiceEnergy = 0.0, currentSpeechPeak = 0.0
    private var speechPeakImpulse = 0.0, lastSpeechPeakTime = -1.0, speechQuietDuration = 0.0
    private var directionChangeArmed = false, deformationDirection = 1.0
    private let started = CACurrentMediaTime()
    private var previousFrameTime: CFTimeInterval?
    private var deformationClock = 0.0

    static let membraneIndices: [UInt32] = {
        var out: [UInt32] = []
        out.reserveCapacity(latitudeSegments * longitudeSegments * 6)
        for row in 0..<latitudeSegments {
            for column in 0..<longitudeSegments {
                let next = (column + 1) % longitudeSegments
                let a = UInt32(row * longitudeSegments + column), b = UInt32((row + 1) * longitudeSegments + column)
                let c = UInt32(row * longitudeSegments + next), d = UInt32((row + 1) * longitudeSegments + next)
                out.append(contentsOf: [a, b, c, c, b, d])
            }
        }
        return out
    }()

    /// Advance to now and rebuild the particles and the membrane for a drawable of `size` pixels.
    func step(size: CGSize, membrane withMembrane: Bool = true) {
        let now = CACurrentMediaTime()
        let elapsed = now - started
        let deltaTime = min(0.1, max(0, now - (previousFrameTime ?? now)))
        previousFrameTime = now
        // The lab's «speaking» mode, unchanged: tint, and folds that kick on the voice's peaks.
        speakingWeight += ((speaking ? 1.0 : 0.0) - speakingWeight) * (1 - exp(-deltaTime / 0.025))
        tint += ((speaking ? Self.speakingTint : Self.restTint) - tint) * Float(1 - exp(-deltaTime / 0.32))
        if speakingWeight > 0.1 {
            if voiceEnergy < 0.12 {
                speechQuietDuration += deltaTime
                if speechQuietDuration >= 1.20 { directionChangeArmed = true }
            } else { speechQuietDuration = 0 }
            if voiceEnergy >= previousVoiceEnergy {
                currentSpeechPeak = max(currentSpeechPeak, voiceEnergy)
            } else if currentSpeechPeak >= 0.42, currentSpeechPeak - voiceEnergy >= 0.035, elapsed - lastSpeechPeakTime >= 0.14 {
                lastSpeechPeakTime = elapsed
                if directionChangeArmed { deformationDirection = Double.random(in: 0..<1) < 0.5 ? -1 : 1; directionChangeArmed = false }
                speechPeakImpulse = max(speechPeakImpulse, currentSpeechPeak)
                currentSpeechPeak = voiceEnergy
            }
        } else {
            currentSpeechPeak = 0; speechPeakImpulse = 0; speechQuietDuration = 0; directionChangeArmed = false
        }
        previousVoiceEnergy = voiceEnergy
        speechPeakImpulse *= exp(-deltaTime / 0.32)
        let envelopeTarget = speaking ? min(1, max(0, (voiceEnergy - 0.06) * 2.4)) : 0
        let envelopeTime = envelopeTarget > speechResponseEnvelope ? 0.025 : 0.11
        speechResponseEnvelope += (envelopeTarget - speechResponseEnvelope) * (1 - exp(-deltaTime / envelopeTime))
        let speechResponse = max(speechResponseEnvelope, min(1, speechPeakImpulse / 0.60))
        let speechMul = 1 + speakingWeight * (0.16 + speechResponse * 39.0)
        deformationClock += deltaTime * 0.36 * deformationSpeed * min(40, speechMul) * deformationDirection
        let time = deformationClock
        let golden = Double.pi * (3 - sqrt(5.0))
        let speedDrift = min(0.25, max(0, min(rotation - 0.05, 1.8 - rotation)))
        let phase = 1.4 * (rotation * elapsed + speedDrift * integratedNoise(elapsed, rate: 0.012, seed: 21.7))
            + 0.20 * noise(elapsed * 0.03, seed: 32.4)
        let turn = 0.30 * sin(phase)
        let amount = 0.90 * warp * min(1, max(0, deformation * (1 + 0.05 * noise(time * 0.08, seed: 44.1))))
        let radius = min(size.width, size.height) * 0.43
        let pulse = 1 + 0.008 * sin(elapsed * 1.45)
        let n = max(1, particleCount)
        let k1 = SIMD3<Double>(0.267, 0.535, 0.802), k2 = SIMD3<Double>(-0.802, 0.267, 0.535)
        let k3 = SIMD3<Double>(0.535, -0.802, 0.267), k4 = SIMD3<Double>(0.408, 0.816, -0.408)
        let k5 = SIMD3<Double>(-0.267, 0.617, 0.739)
        let drift = [noise(time * 0.25, seed: 1.3), noise(time * 0.22, seed: 4.9), noise(time * 0.28, seed: 8.2),
                     noise(time * 0.19, seed: 12.7), noise(time * 0.17, seed: 16.4)]
        let strengths = [0.65 * (1 + 0.12 * noise(time * 0.11, seed: 20.1)), 0.52 * (1 + 0.12 * noise(time * 0.09, seed: 24.7)),
                         0.40 * (1 + 0.12 * noise(time * 0.13, seed: 28.3)), 0.24 * (1 + 0.12 * noise(time * 0.08, seed: 31.9)),
                         0.15 * (1 + 0.45 * noise(time * 0.17, seed: 18.6))]
        if withMembrane {
            buildMembrane(size: size, radius: radius * 0.88, pulse: pulse, amount: amount, turn: turn, time: time,
                          axes: [k1, k2, k3, k4, k5], drift: drift, strengths: strengths)
        }
        // Sprite sizes were tuned for the lab's 580-point stage (~1080 px); a small sphere keeps them in proportion.
        let spriteScale = Float(max(0.45, min(1, min(size.width, size.height) / 1080)))
        particles.removeAll(keepingCapacity: true)
        if particles.capacity < n { particles.reserveCapacity(n) }
        for i in 0..<n {
            let seed = unitNoise(Double(i) * 19.19 + 2.7)
            let lat = min(0.998, max(-0.998, 1 - 2 * ((Double(i) + 0.5) / Double(n)) + (seed - 0.5) * 0.018))
            let lon = Double(i) * golden + (seed - 0.5) * 0.035
            let ring = sqrt(max(0, 1 - lat * lat))
            let base = SIMD3(cos(lon) * ring, lat, sin(lon) * ring)
            let f1 = 5.4 * dot(base, k1) + time * 0.075 + drift[0] * 0.62
            let f2 = 6.1 * dot(base, k2) - time * 0.062 + drift[1] * 0.58
            let f3 = 4.7 * dot(base, k3) + time * 0.051 + drift[2] * 0.64
            let f4 = 7.3 * dot(base, k4) - time * 0.043 + drift[3] * 0.52
            let f5 = 8.2 * dot(base, k5) + time * 0.037 + drift[4] * 0.70
            let field = k1 * (5.4 * cos(f1) * strengths[0]) + k2 * (6.1 * cos(f2) * strengths[1]) + k3 * (4.7 * cos(f3) * strengths[2])
                + k4 * (7.3 * cos(f4) * strengths[3]) + k5 * (8.2 * cos(f5) * strengths[4])
            let tangent = field - base * dot(field, base)
            let deformed = normalize(base + tangent * (amount * 0.085) + cross(base, tangent) * (amount * 0.15))
            let radial = 1 + amount * 0.05 * (sin(f1 + drift[2]) * cos(f2 + drift[3]) + 0.36 * sin(f3 - f4 + drift[0]) + 0.12 * sin(f5 + drift[1]))
            let rx = deformed.x * cos(turn) - deformed.z * sin(turn), rz = deformed.x * sin(turn) + deformed.z * cos(turn)
            let perspective = 0.93 + 0.10 * rz
            let px = (rx * radius * pulse * radial * perspective) / max(1, Double(size.width) * 0.5)
            let py = (-deformed.y * radius * pulse * radial * perspective) / max(1, Double(size.height) * 0.5)
            let depth = (rz + 1) * 0.5
            let concentration = min(1, max(0, (abs(sin(f1) * cos(f2)) + abs(sin(f3 - f4)) * 0.36 - 0.18) / 0.62))
            let frontDensity = depth > 0.5 ? concentration : concentration * 0.1
            let diameter = (depth > 0.5 ? 1.32 : 0.88) * (0.82 + depth * 0.42) * (1 + frontDensity * 0.38)
            let alpha = min(0.82, ((depth > 0.5 ? 0.78 : 0.22) * (0.72 + depth * 0.28) + frontDensity * 0.88) * glow)
            let sprite = max(1, Float((diameter * 0.72 + frontDensity * 3.5) * dotScale) * spriteScale)
            particles.append(SphereParticle(position: SIMD2(Float(px), Float(py)), size: sprite, alpha: Float(alpha),
                                            glow: Float(frontDensity), depth: Float(depth)))
        }
    }

    private func buildMembrane(size: CGSize, radius: Double, pulse: Double, amount: Double, turn: Double, time: Double,
                               axes: [SIMD3<Double>], drift: [Double], strengths: [Double]) {
        let lat = Self.latitudeSegments, lon = Self.longitudeSegments
        membrane.removeAll(keepingCapacity: true)
        if membrane.capacity < (lat + 1) * lon { membrane.reserveCapacity((lat + 1) * lon) }
        let pink = SIMD3<Float>(0.96, 0.20, 0.72), cyan = SIMD3<Float>(0.12, 0.62, 0.86)
        for row in 0...lat {
            let latitude = cos(Double.pi * Double(row) / Double(lat))
            let ring = sqrt(max(0, 1 - latitude * latitude))
            for column in 0..<lon {
                let longitude = 2 * Double.pi * Double(column) / Double(lon)
                let base = SIMD3(cos(longitude) * ring, latitude, sin(longitude) * ring)
                let f1 = 5.4 * dot(base, axes[0]) + time * 0.075 + drift[0] * 0.62
                let f2 = 6.1 * dot(base, axes[1]) - time * 0.062 + drift[1] * 0.58
                let f3 = 4.7 * dot(base, axes[2]) + time * 0.051 + drift[2] * 0.64
                let f4 = 7.3 * dot(base, axes[3]) - time * 0.043 + drift[3] * 0.52
                let f5 = 8.2 * dot(base, axes[4]) + time * 0.037 + drift[4] * 0.70
                let field = axes[0] * (5.4 * cos(f1) * strengths[0]) + axes[1] * (6.1 * cos(f2) * strengths[1])
                    + axes[2] * (4.7 * cos(f3) * strengths[2]) + axes[3] * (7.3 * cos(f4) * strengths[3])
                    + axes[4] * (8.2 * cos(f5) * strengths[4])
                let tangent = field - base * dot(field, base)
                let deformed = normalize(base + tangent * (amount * 0.085) + cross(base, tangent) * (amount * 0.15))
                let radial = 1 + amount * 0.05 * (sin(f1 + drift[2]) * cos(f2 + drift[3]) + 0.36 * sin(f3 - f4 + drift[0]) + 0.12 * sin(f5 + drift[1]))
                let x = deformed.x * cos(turn) - deformed.z * sin(turn), z = deformed.x * sin(turn) + deformed.z * cos(turn)
                let perspective = 0.93 + 0.10 * z
                let px = (x * radius * pulse * radial * perspective) / max(1, Double(size.width) * 0.5)
                let py = (-deformed.y * radius * pulse * radial * perspective) / max(1, Double(size.height) * 0.5)
                let concentration = min(1, max(0, (abs(sin(f1) * cos(f2)) + abs(sin(f3 - f4)) * 0.36 - 0.18) / 0.62))
                let ridge = concentration * concentration * (3 - 2 * concentration)
                let rim = pow(max(0, 1 - abs(z)), 4)
                let wave = Float(0.5 + 0.5 * sin(f1 - f4 + f5 * 0.35))
                let baseColor = pink * (1 - wave) + cyan * wave
                let highlight = Float(min(0.42, ridge * 0.16 + rim * 0.38))
                let color = baseColor * (1 - highlight) + SIMD3<Float>(1, 0.78, 0.94) * highlight
                let alpha = Float(min(0.42, (0.055 + ridge * 0.10 + rim * 0.18) * glow))
                membrane.append(SphereMembraneVertex(position: SIMD4(Float(px), Float(py), Float(z), 1),
                                                     color: SIMD4(color.x * alpha, color.y * alpha, color.z * alpha, alpha)))
            }
        }
        // Smooth only sharp local kinks, keeping the broad flowing folds.
        let source = membrane
        for row in 1..<lat {
            for column in 0..<lon {
                let index = row * lon + column
                let left = row * lon + (column + lon - 1) % lon, right = row * lon + (column + 1) % lon
                let above = (row - 1) * lon + column, below = (row + 1) * lon + column
                let neighbor = (source[left].position + source[right].position + source[above].position + source[below].position) * 0.25
                let bend = source[index].position - neighbor
                let bendPixels = sqrt(bend.x * bend.x + bend.y * bend.y + bend.z * bend.z) * Float(min(size.width, size.height) * 0.5)
                let correction = min(0.58, max(0, (bendPixels - 0.30) * 0.42))
                if correction > 0 {
                    membrane[index].position = source[index].position * (1 - correction) + neighbor * correction
                    let nc = (source[left].color + source[right].color + source[above].color + source[below].color) * 0.25
                    membrane[index].color = source[index].color * (1 - correction) + nc * correction
                }
            }
        }
    }

    private func unitNoise(_ x: Double) -> Double { let v = sin(x * 12.9898 + 78.233) * 43758.5453; return v - floor(v) }
    private func valueNoise(_ x: Double, _ seed: Double) -> Double { unitNoise(x * 37.719 + seed * 13.13) * 2 - 1 }
    private func noise(_ t: Double, seed: Double) -> Double {
        let s = floor(t), f = t - s, blend = f * f * (3 - 2 * f), a = valueNoise(s, seed), b = valueNoise(s + 1, seed)
        return a + (b - a) * blend
    }
    private func integratedNoise(_ elapsed: Double, rate: Double, seed: Double) -> Double {
        let position = max(0, elapsed) * rate, steps = Int(floor(position)), f = position - Double(steps)
        var sum = 0.0
        if steps > 0 { for step in 0..<steps { sum += (valueNoise(Double(step), seed) + valueNoise(Double(step + 1), seed)) * 0.5 } }
        let a = valueNoise(Double(steps), seed), b = valueNoise(Double(steps + 1), seed)
        return (sum + a * f + (b - a) * (pow(f, 3) - 0.5 * pow(f, 4))) / rate
    }
    private func dot(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { a.x * b.x + a.y * b.y + a.z * b.z }
    private func cross(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
    }
    private func normalize(_ v: SIMD3<Double>) -> SIMD3<Double> { v / max(sqrt(dot(v, v)), 0.0001) }
}

// MARK: - Canvas (off-screen snapshots)

struct SphereCanvas: View {
    let speaking: Bool
    let voiceEnergy: Double
    let particles: Int
    let glow: Double
    var dotScale = 1.0
    var warp = 1.0

    var body: some View {
        Canvas { g, size in
            let field = SphereField()
            field.speaking = speaking; field.voiceEnergy = voiceEnergy; field.particleCount = particles; field.glow = glow
            field.dotScale = dotScale; field.warp = warp
            field.step(size: size, membrane: false)
            let t = speaking ? SphereField.speakingTint : SphereField.restTint, tint = Color(red: Double(t.x), green: Double(t.y), blue: Double(t.z))
            for p in field.particles.sorted(by: { $0.depth < $1.depth }) {
                let x = (CGFloat(p.position.x) + 1) * size.width / 2, y = (1 - CGFloat(p.position.y)) * size.height / 2
                let d = CGFloat(max(1, p.size * 0.6))
                g.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)), with: .color(tint.opacity(Double(p.alpha) * 0.8)))
            }
        }
    }
}

// MARK: - Metal (on screen)

private let sphereShaders = """
#include <metal_stdlib>
using namespace metal;
struct Particle { float2 position; float size; float alpha; float glow; float depth; };
struct Out { float4 position [[position]]; float2 uv; float alpha; float glow; float depth; float size; };
struct Membrane { float4 position; float4 color; };
struct MembraneOut { float4 position [[position]]; float4 color; float depth; };
vertex MembraneOut membraneVertex(uint vertexID [[vertex_id]], const device Membrane *vertices [[buffer(0)]]) {
    Membrane v = vertices[vertexID];
    MembraneOut o; o.position = float4(v.position.xy, 0.5 - v.position.z * 0.5, 1); o.color = v.color; o.depth = v.position.z; return o;
}
fragment float4 membraneFragment(MembraneOut in [[stage_in]]) {
    float front = smoothstep(-0.72, 0.22, in.depth);
    return in.color * mix(0.18, 1.0, front);
}
vertex Out particleVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]],
                          const device Particle *particles [[buffer(0)]], constant float2 &viewport [[buffer(1)]]) {
    const float2 corners[6] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(-1,1), float2(1,-1), float2(1,1) };
    Particle p = particles[instanceID]; float2 uv = corners[vertexID];
    float2 ndc = p.position + uv * p.size / viewport;
    Out o; o.position = float4(ndc, 0, 1); o.uv = uv; o.alpha = p.alpha; o.glow = p.glow; o.depth = p.depth; o.size = p.size; return o;
}
// `crisp` (big dots): a solid disc with a 1.5-pixel edge and no halo; otherwise the lab's soft dot.
fragment float4 particleFragment(Out in [[stage_in]], constant float3 &baseTint [[buffer(0)]], constant float &crisp [[buffer(1)]]) {
    float r2 = dot(in.uv, in.uv); if (r2 > 1.0) discard_fragment();
    float r = sqrt(r2);
    float soft = 1.0 - smoothstep(0.18, 0.58, r);
    float edge = clamp(1.5 / max(in.size, 1.0), 0.02, 0.5);
    float sharp = 1.0 - smoothstep(0.7 - edge, 0.7, r);
    float core = mix(soft, sharp, crisp);
    float halo = exp(-r2 * 5.0) * in.glow * (1.0 - crisp);
    float3 color = mix(baseTint, float3(1.0, 0.88, 1.0), core * mix(0.48, 0.25, crisp));
    float a = core * in.alpha * mix(0.76, 0.95, crisp) + halo * 0.04;
    return float4(color * a, a);
}
"""

@MainActor
final class SphereRenderer: NSObject, MTKViewDelegate {
    let field = SphereField()
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var membranePipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var particleBuffer: MTLBuffer?, membraneBuffer: MTLBuffer?, indexBuffer: MTLBuffer?

    func configure(_ view: MTKView) {
        guard let device = view.device else { return }
        queue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: sphereShaders, options: nil)
            func blend(_ d: MTLRenderPipelineDescriptor, additive: Bool) {
                let c = d.colorAttachments[0]!
                c.pixelFormat = view.colorPixelFormat; c.isBlendingEnabled = true
                c.rgbBlendOperation = .add; c.alphaBlendOperation = .add
                c.sourceRGBBlendFactor = .one; c.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
                c.sourceAlphaBlendFactor = .one; c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            let p = MTLRenderPipelineDescriptor()
            p.vertexFunction = library.makeFunction(name: "particleVertex"); p.fragmentFunction = library.makeFunction(name: "particleFragment")
            blend(p, additive: true); p.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: p)
            let m = MTLRenderPipelineDescriptor()
            m.vertexFunction = library.makeFunction(name: "membraneVertex"); m.fragmentFunction = library.makeFunction(name: "membraneFragment")
            blend(m, additive: false); m.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            membranePipeline = try device.makeRenderPipelineState(descriptor: m)
            let depth = MTLDepthStencilDescriptor(); depth.depthCompareFunction = .lessEqual; depth.isDepthWriteEnabled = true
            depthState = device.makeDepthStencilState(descriptor: depth)
            let idx = SphereField.membraneIndices
            indexBuffer = idx.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        } catch {
            NSLog("Vera sphere: Metal pipeline failed: %@", String(describing: error))
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let device = view.device, let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let pipeline, let membranePipeline, let depthState, let queue, let indexBuffer else { return }
        pass.depthAttachment?.loadAction = .clear; pass.depthAttachment?.clearDepth = 1
        field.step(size: view.drawableSize)
        let particles = field.particles, membrane = field.membrane
        let pBytes = particles.count * MemoryLayout<SphereParticle>.stride
        let mBytes = membrane.count * MemoryLayout<SphereMembraneVertex>.stride
        guard pBytes > 0, mBytes > 0 else { return }
        if (particleBuffer?.length ?? 0) < pBytes { particleBuffer = device.makeBuffer(length: pBytes, options: .storageModeShared) }
        if (membraneBuffer?.length ?? 0) < mBytes { membraneBuffer = device.makeBuffer(length: mBytes, options: .storageModeShared) }
        guard let particleBuffer, let membraneBuffer else { return }
        particles.withUnsafeBytes { memcpy(particleBuffer.contents(), $0.baseAddress!, pBytes) }
        membrane.withUnsafeBytes { memcpy(membraneBuffer.contents(), $0.baseAddress!, mBytes) }
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(membranePipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setVertexBuffer(membraneBuffer, offset: 0, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: SphereField.membraneIndices.count, indexType: .uint32,
                                      indexBuffer: indexBuffer, indexBufferOffset: 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(particleBuffer, offset: 0, index: 0)
        var viewport = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
        encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
        var tint = field.tint
        encoder.setFragmentBytes(&tint, length: MemoryLayout<SIMD3<Float>>.stride, index: 0)
        var crisp: Float = field.dotScale > 1 ? 1 : 0
        encoder.setFragmentBytes(&crisp, length: MemoryLayout<Float>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particles.count)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}

@MainActor
private func makeSphereView(_ renderer: SphereRenderer) -> MTKView {
    let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    view.colorPixelFormat = .bgra8Unorm
    view.depthStencilPixelFormat = .depth32Float
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    view.preferredFramesPerSecond = 30
    view.framebufferOnly = true
    view.delegate = renderer
    #if os(macOS)
    view.wantsLayer = true
    view.layer?.isOpaque = false
    #else
    view.isOpaque = false
    view.backgroundColor = .clear
    #endif
    renderer.configure(view)
    return view
}

#if os(macOS)
struct SphereMetal: NSViewRepresentable {
    let speaking: Bool
    let voiceEnergy: Double
    let particles: Int
    let glow: Double
    let dotScale: Double
    let warp: Double
    func makeCoordinator() -> SphereRenderer { SphereRenderer() }
    func makeNSView(context: Context) -> MTKView { makeSphereView(context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) {
        let f = context.coordinator.field
        f.speaking = speaking; f.voiceEnergy = voiceEnergy; f.particleCount = particles; f.glow = glow; f.dotScale = dotScale; f.warp = warp
    }
}
#else
struct SphereMetal: UIViewRepresentable {
    let speaking: Bool
    let voiceEnergy: Double
    let particles: Int
    let glow: Double
    let dotScale: Double
    let warp: Double
    func makeCoordinator() -> SphereRenderer { SphereRenderer() }
    func makeUIView(context: Context) -> MTKView { makeSphereView(context.coordinator) }
    func updateUIView(_ view: MTKView, context: Context) {
        let f = context.coordinator.field
        f.speaking = speaking; f.voiceEnergy = voiceEnergy; f.particleCount = particles; f.glow = glow; f.dotScale = dotScale; f.warp = warp
    }
}
#endif
