import Foundation

public struct SeededRandom: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    public mutating func unit() -> Double { Double(next() >> 11) / 9007199254740992.0 }
}
public struct SceneShape: Codable, Equatable, Sendable {
    public var id: Int
    public var layer: Int = 0
    public var center: SIMD2<Float>
    public var contour: [SIMD2<Float>]
    public var color: RGBColor
    public var opacity: Float
    public var gradient: Float
}
public struct AbstractScene: Codable, Equatable, Sendable {
    public var aspect: Double
    public var background: RGBColor
    public var shapes: [SceneShape]
    public var mode: DisplayMode
    public var shapeDisplay: ShapeDisplay
    public var appearance: AppearanceParameters
    public var layers: [ColorLayer] = []
    public var method: GenerationMethod = .abstract
    public var fragments: [ImageFragment] = []
}
public enum SceneGenerator {
    public static func palette(for recipe: GenerationRecipe, layer index: Int = 0, adjusted: Bool = true, sixSlots: Bool = false) -> [PaletteEntry] {
        let layer = recipe.layer(index)
        var originals: [PaletteEntry]
        if let imported = layer.source?.palette, !imported.isEmpty {
            // The independent color seed changes placement and proportions without discarding the reference colors.
            originals = imported
        } else {
            let palettes: [[RGBColor]] = [
                [.init(0.94,0.90,0.79), .init(0.86,0.30,0.19), .init(0.96,0.67,0.26), .init(0.15,0.35,0.36), .init(0.37,0.54,0.52), .init(0.16,0.20,0.25)],
                [.init(0.91,0.91,0.88), .init(0.19,0.35,0.64), .init(0.38,0.57,0.80), .init(0.94,0.50,0.41), .init(0.97,0.76,0.63), .init(0.19,0.24,0.34)],
                [.init(0.95,0.87,0.83), .init(0.51,0.30,0.47), .init(0.82,0.43,0.54), .init(0.90,0.66,0.54), .init(0.36,0.46,0.44), .init(0.17,0.21,0.25)],
                [.init(0.89,0.90,0.76), .init(0.46,0.56,0.29), .init(0.22,0.37,0.30), .init(0.89,0.65,0.22), .init(0.76,0.33,0.20), .init(0.15,0.21,0.17)],
                [.init(0.92,0.90,0.94), .init(0.44,0.36,0.72), .init(0.68,0.64,0.84), .init(0.28,0.61,0.65), .init(0.94,0.72,0.27), .init(0.16,0.17,0.30)]
            ]
            var rng = SeededRandom(seed: recipe.colorSeed &+ UInt64(index) &* 0xD1B54A32D192ED03)
            let colors = palettes[Int(rng.next() % UInt64(palettes.count))]
            originals = colors.enumerated().map { PaletteEntry($0.element, $0.offset == 0 ? 0.32 : 0.136) }
        }
        if sixSlots || !layer.paletteOverrides.isEmpty || !layer.weightOverrides.isEmpty {
            while originals.count < 6 {
                let biggest = originals.indices.max {originals[$0].weight < originals[$1].weight}!
                originals[biggest].weight /= 2
                originals.append(originals[biggest])
            }
            originals = Array(originals.prefix(6))
        }
        for (slot,color) in layer.paletteOverrides where originals.indices.contains(slot) {originals[slot].color = color}
        var weights = originals.map(\.weight)
        for (slot,weight) in layer.weightOverrides where weights.indices.contains(slot) {weights[slot] = weight}
        if !weights.isEmpty {
            weights[0] *= pow(5, (recipe.color.dominance - 0.5) * 2)
        }
        let sum = max(weights.reduce(0, +), 0.00001)
        return originals.enumerated().map { PaletteEntry(adjusted ? adjust($0.element.color, parameters: recipe.color) : $0.element.color, weights[$0.offset] / sum) }
    }
    public static func generate(_ recipe: GenerationRecipe) -> AbstractScene {
        if recipe.method == .deconstruction {return DeconstructionGenerator.generate(recipe)}
        if let fixed=recipe.fixedCanvas, fixed.geometry != nil {return FixedSceneGenerator.generate(recipe,fixed:fixed)}
        let palette = palette(for: recipe)
        let p = recipe.shape
        var shapes: [SceneShape] = []
        for layerIndex in 0..<3 {
        let palette = self.palette(for: recipe, layer: layerIndex)
        var random = SeededRandom(seed: recipe.shapeSeed &+ UInt64(layerIndex) &* 0xD1B54A32D192ED03)
        let focal = SIMD2<Double>(0.28 + random.unit() * 0.44, 0.28 + random.unit() * 0.44)
        let count = 3 + p.density * 61
        // Every ID consumes the same number of random values. Changing density never moves an existing shape.
        for id in 0..<64 {
            let ux = random.unit(), uy = random.unit(), sizeSample = random.unit()
            let rotationSample = random.unit(), stretchSample = random.unit()
            let sides = 3 + Int(random.next() % 5)
            let phase = random.unit() * 2 * Double.pi
            let waveA = random.unit(), waveB = random.unit(), waveC = random.unit()
            let rotation = p.direction * .pi / 180 + (rotationSample - 0.5) * .pi * 2 * (1 - p.coherence)
            let radius = (0.035 + p.scale * 0.225) * (1 + (sizeSample - 0.5) * 1.65 * p.variation)
            let elongation = 1 + p.stretch * (0.6 + stretchSample * 2.2)
            let center = SIMD2<Float>(Float((ux * (1 - p.clustering * 0.68) + focal.x * p.clustering * 0.68) * recipe.canvasAspect), Float(uy * (1 - p.clustering * 0.68) + focal.y * p.clustering * 0.68))
            var contour: [SIMD2<Float>] = []
            let segments = p.organic == 0 && p.erosion == 0 ? 48 : 128
            for j in 0..<segments {
                let angle = Double(j) / Double(segments) * 2 * .pi
                let sector = 2 * Double.pi / Double(sides)
                let offset = (angle + phase).truncatingRemainder(dividingBy: sector) - sector / 2
                let polygonRadius = cos(sector / 2) / cos(offset)
                let smoothRadius = 0.83 + 0.15 * sin(angle * 3 + phase) * waveA + 0.10 * cos(angle * 5 + phase * 2) * waveB + 0.07 * sin(angle * 2) * waveC
                // Positive radial harmonics keep contours simple and triangulable. Low-frequency
                // lobes/pinches and high-frequency erosion share stable per-element phases.
                let lobes = 0.48*sin(angle*2+phase) + 0.30*cos(angle*3-phase*1.7) + 0.18*sin(angle*5+phase*2.1)
                let organicRadius = exp(lobes * p.organic * 1.15)
                let erosion = 1 + p.erosion*(0.13*sin(angle*13+phase*3) + 0.075*cos(angle*23-phase) + 0.04*sin(angle*37+phase*2))
                let scaleRhythm = 1 + p.organic*(pow(0.18+sizeSample*0.82,1.8)*1.4-0.65)
                let r = radius * (polygonRadius * (1 - p.curvature) + smoothRadius * p.curvature) * organicRadius * erosion * scaleRhythm
                let localX = cos(angle) * r * sqrt(elongation), localY = sin(angle) * r / sqrt(elongation)
                contour.append(center + SIMD2(Float(localX * cos(rotation) - localY * sin(rotation)), Float(localX * sin(rotation) + localY * cos(rotation))))
            }
            var colorRandom = SeededRandom(seed: recipe.colorSeed &+ UInt64(layerIndex) &* 0xD1B54A32D192ED03 &+ UInt64(id) &* 0x9E3779B97F4A7C15)
            let sample = colorRandom.unit()
            var cumulative = 0.0
            var selected = palette.last!.color
            for entry in palette { cumulative += entry.weight; if sample < cumulative { selected = entry.color; break } }
            // Blend around weighted boundaries so the dominance slider does not abruptly recolor whole shapes.
            var boundary=0.0
            for index in 0..<max(0,palette.count-1) {
                boundary += palette[index].weight
                let band=min(0.035,min(palette[index].weight,palette[index+1].weight)/3)
                if band>0,abs(sample-boundary)<band {
                    let value=(sample-boundary+band)/(band*2), t=value*value*(3-2*value)
                    let a=palette[index].color, b=palette[index+1].color
                    selected=RGBColor(a.r+(b.r-a.r)*t,a.g+(b.g-a.g)*t,a.b+(b.b-a.b)*t)
                    break
                }
            }
            let alpha = min(1, max(0, count - Double(id)))
            let opacity = Float(alpha * alpha * (3 - 2 * alpha))
            shapes.append(SceneShape(id: layerIndex*64+id, layer: layerIndex, center: center, contour: contour, color: selected, opacity: opacity, gradient: Float(0.035 + colorRandom.unit() * 0.055)))
        }
        }
        return AbstractScene(aspect: recipe.canvasAspect, background: recipe.mode == .shape ? .white : palette[0].color, shapes: shapes, mode: recipe.mode, shapeDisplay: recipe.shapeDisplay, appearance: recipe.appearance, layers: (0..<3).map {recipe.layer($0)})
    }
    static func adjust(_ c: RGBColor, parameters p: ColorParameters) -> RGBColor {
        let maxC = max(c.r, c.g, c.b), minC = min(c.r, c.g, c.b), delta = maxC - minC
        var h = 0.0
        if delta > 0 {
            if maxC == c.r { h = ((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6) }
            else if maxC == c.g { h = (c.b - c.r) / delta + 2 }
            else { h = (c.r - c.g) / delta + 4 }
            h /= 6
        }
        h = (h + p.hue / 360 + 2).truncatingRemainder(dividingBy: 1)
        let s = min(1, max(0, (maxC == 0 ? 0 : delta / maxC) * p.saturation * 2))
        let v = min(1, max(0, maxC + (p.brightness - 0.5) * 0.8))
        let chroma = v * s, x = chroma * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1)), m = v - chroma
        let components: (Double, Double, Double)
        switch Int(h * 6) { case 0: components = (chroma,x,0); case 1: components = (x,chroma,0); case 2: components = (0,chroma,x); case 3: components = (0,x,chroma); case 4: components = (x,0,chroma); default: components = (chroma,0,x) }
        func contrast(_ value: Double) -> Double { min(1,max(0,(value + m - 0.5) * pow(3, (p.contrast - 0.5) * 2) + 0.5)) }
        return RGBColor(contrast(components.0), contrast(components.1), contrast(components.2))
    }
}
