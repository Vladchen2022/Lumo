import Foundation

public enum DisplayMode: String, Codable, CaseIterable, Sendable {
    case color, shape, combined
    public var title: String { switch self { case .color: "颜色"; case .shape: "形状"; case .combined: "组合" } }
}
public enum ShapeDisplay: String, Codable, CaseIterable, Sendable {
    case outline, solid
    public var title: String { self == .outline ? "线条" : "块面" }
}
public struct RGBColor: Codable, Equatable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    public static let white = RGBColor(1, 1, 1)
    public static let ink = RGBColor(0.12, 0.12, 0.12)
    public var linear: SIMD3<Float> {
        func convert(_ x: Double) -> Float { Float(x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)) }
        return SIMD3(convert(r), convert(g), convert(b))
    }
    public var luminance: Double { let v = linear; return Double(v.x * 0.2126 + v.y * 0.7152 + v.z * 0.0722) }
}
public struct PaletteEntry: Codable, Equatable, Sendable {
    public var color: RGBColor
    public var weight: Double
    public init(_ color: RGBColor, _ weight: Double) { self.color = color; self.weight = weight }
}
public struct ShapeFeatures: Codable, Equatable, Sendable {
    public var direction: Double
    public var coherence: Double
    public var roughness: Double
    public var density: Double
    public var scale: Double
    public init(direction: Double, coherence: Double, roughness: Double, density: Double, scale: Double) {
        self.direction = direction; self.coherence = coherence; self.roughness = roughness; self.density = density; self.scale = scale
    }
}
public struct SourceReference: Codable, Equatable, Sendable {
    public var id: UUID?
    public var name: String
    public var thumbnail: Data
    public var palette: [PaletteEntry]?
    public var features: ShapeFeatures?
    public var samplingImage: Data?
    public init(name: String, thumbnail: Data, palette: [PaletteEntry]? = nil, features: ShapeFeatures? = nil) {
        self.id = UUID(); self.name = name; self.thumbnail = thumbnail; self.palette = palette; self.features = features
    }
    private enum CodingKeys: String, CodingKey {case id, name, thumbnail, palette, features, samplingImage, thumbnailRef, samplingImageRef}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self,forKey:.id)
        name = try c.decode(String.self,forKey:.name)
        palette = try c.decodeIfPresent([PaletteEntry].self,forKey:.palette)
        features = try c.decodeIfPresent(ShapeFeatures.self,forKey:.features)
        func asset(_ inline: CodingKeys, _ ref: CodingKeys) throws -> Data? {
            if let id = try c.decodeIfPresent(String.self,forKey:ref) {
                guard let archive = decoder.userInfo[.referenceArchive] as? ReferenceArchive, let data = archive.images[id] else {throw LumoError.message("项目缺少参考图片数据。")}
                return data
            }
            return try c.decodeIfPresent(Data.self,forKey:inline)
        }
        guard let thumbnail = try asset(.thumbnail,.thumbnailRef) else {throw LumoError.message("项目缺少参考缩略图。")}
        self.thumbnail = thumbnail; samplingImage = try asset(.samplingImage,.samplingImageRef)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(id,forKey:.id)
        try c.encode(name,forKey:.name); try c.encodeIfPresent(palette,forKey:.palette); try c.encodeIfPresent(features,forKey:.features)
        if let archive = encoder.userInfo[.referenceArchive] as? ReferenceArchive {
            try c.encode(archive.insert(thumbnail),forKey:.thumbnailRef)
            if let samplingImage {try c.encode(archive.insert(samplingImage),forKey:.samplingImageRef)}
        } else {
            try c.encode(thumbnail,forKey:.thumbnail); try c.encodeIfPresent(samplingImage,forKey:.samplingImage)
        }
    }
}
extension CodingUserInfoKey {static let referenceArchive = CodingUserInfoKey(rawValue:"lumo.referenceImages")!}
final class ReferenceArchive {
    var images: [String: Data] = [:]
    private var ids: [Data: String] = [:]
    func insert(_ data: Data) -> String {
        if let id = ids[data] {return id}
        let id = String(images.count); images[id] = data; ids[data] = id; return id
    }
}
public enum ColorBlendMode: Int, Codable, CaseIterable, Sendable {
    case normal, multiply, screen, overlay, softLight
    public var title: String { switch self {case .normal: "正常"; case .multiply: "正片叠底"; case .screen: "滤色"; case .overlay: "叠加"; case .softLight: "柔光"} }
}
public struct ColorLayer: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var source: SourceReference?
    public var opacity = 0.65
    public var blend = ColorBlendMode.softLight
    public var blockBlend = ColorBlendMode.normal
    public var blockOpacity = 1.0
    public var enabled = true
    /// Replacing a slot keeps the palette count at six; its area can be edited separately.
    public var paletteOverrides: [Int: RGBColor] = [:]
    public var weightOverrides: [Int: Double] = [:]
    public init() {}
}
public struct ColorParameters: Codable, Equatable, Sendable {
    public var hue = 0.0
    public var saturation = 0.5
    public var brightness = 0.5
    public var contrast = 0.5
    public var dominance = 0.5
    public init() {}
}
public struct ShapeParameters: Codable, Equatable, Sendable {
    public var density = 0.42
    public var scale = 0.58
    public var variation = 0.55
    public var curvature = 0.35
    public var stretch = 0.22
    public var direction = 0.0
    public var clustering = 0.32
    public var coherence = 0.28
    public var organic = 0.0
    public var erosion = 0.0
    public init() {}
    public init(features: ShapeFeatures) {
        self.init()
        density = features.density
        scale = features.scale
        curvature = 1 - features.roughness
        direction = features.direction
        coherence = features.coherence
        stretch = 0.15 + features.coherence * 0.55
    }
    private enum CodingKeys: String, CodingKey {case density, scale, variation, curvature, stretch, direction, clustering, coherence, organic, erosion}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        density = try c.decode(Double.self,forKey:.density); scale = try c.decode(Double.self,forKey:.scale)
        variation = try c.decode(Double.self,forKey:.variation); curvature = try c.decode(Double.self,forKey:.curvature)
        stretch = try c.decode(Double.self,forKey:.stretch); direction = try c.decode(Double.self,forKey:.direction)
        clustering = try c.decode(Double.self,forKey:.clustering); coherence = try c.decode(Double.self,forKey:.coherence)
        organic = try c.decodeIfPresent(Double.self,forKey:.organic) ?? 0
        erosion = try c.decodeIfPresent(Double.self,forKey:.erosion) ?? 0
    }
}
public struct AppearanceParameters: Codable, Equatable, Sendable {
    public var softness = 0.10
    public var lineWidth = 0.28
    public var lineStrength = 0.60
    public init() {}
}
public enum CompositionPreset: String, CaseIterable, Sendable {
    case geometric, organic, sparse, weathered
    public var title: String { switch self { case .geometric: "几何块面"; case .organic: "有机流动"; case .sparse: "疏松线条"; case .weathered: "侵蚀斑驳" } }
}
public struct GenerationRecipe: Codable, Equatable, Sendable {
    public var version = 1
    public var colorSeed: UInt64 = 0xCAFE_42
    public var shapeSeed: UInt64 = 0xBEEF_31
    public var mode = DisplayMode.combined
    public var shapeDisplay = ShapeDisplay.outline
    public var color = ColorParameters()
    public var shape = ShapeParameters()
    public var appearance = AppearanceParameters()
    public var colorSource: SourceReference?
    public var colorLayers: [ColorLayer] = Self.defaultLayers
    public var shapeSource: SourceReference?
    public var colorLocked = false
    public var shapeLocked = false
    public var canvasAspect = 1.0
    public init() {}
    private static var defaultLayers: [ColorLayer] {
        (1...3).map {index in var layer = ColorLayer(); layer.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!; if index == 1 {layer.opacity = 1; layer.blend = .normal}; return layer}
    }
    public func layer(_ index: Int) -> ColorLayer {
        var layer = colorLayers[index]
        if index == 0 {layer.source = colorSource}
        return layer
    }
    public mutating func setLayer(_ index: Int, _ update: (inout ColorLayer) -> Void) {
        var value = layer(index); update(&value)
        colorLayers[index] = value
        if index == 0 {colorSource = value.source; colorLayers[0].source = nil}
    }
    private enum CodingKeys: String, CodingKey {case version, colorSeed, shapeSeed, mode, shapeDisplay, color, shape, appearance, colorSource, colorLayers, shapeSource, colorLocked, shapeLocked, canvasAspect}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self,forKey:.version)
        colorSeed = try c.decode(UInt64.self,forKey:.colorSeed); shapeSeed = try c.decode(UInt64.self,forKey:.shapeSeed)
        mode = try c.decode(DisplayMode.self,forKey:.mode); shapeDisplay = try c.decode(ShapeDisplay.self,forKey:.shapeDisplay)
        color = try c.decode(ColorParameters.self,forKey:.color); shape = try c.decode(ShapeParameters.self,forKey:.shape)
        appearance = try c.decode(AppearanceParameters.self,forKey:.appearance)
        colorSource = try c.decodeIfPresent(SourceReference.self,forKey:.colorSource)
        colorLayers = try c.decodeIfPresent([ColorLayer].self,forKey:.colorLayers) ?? Self.defaultLayers
        shapeSource = try c.decodeIfPresent(SourceReference.self,forKey:.shapeSource)
        colorLocked = try c.decode(Bool.self,forKey:.colorLocked); shapeLocked = try c.decode(Bool.self,forKey:.shapeLocked)
        canvasAspect = try c.decode(Double.self,forKey:.canvasAspect)
    }
    public mutating func apply(_ preset: CompositionPreset) {
        shape = ShapeParameters(); appearance = AppearanceParameters()
        switch preset {
        case .geometric: shape.curvature = 0.05; shape.density = 0.32; mode = .color
        case .organic: shape.curvature = 0.92; shape.organic = 0.78; shape.variation = 0.72; shape.clustering = 0.48; appearance.softness = 0.18; mode = .color
        case .sparse: shape.density = 0.16; shape.scale = 0.46; shape.stretch = 0.56; shape.curvature = 0.62; mode = .shape; shapeDisplay = .outline; appearance.lineWidth = 0.18
        case .weathered: shape.curvature = 0.8; shape.organic = 0.68; shape.erosion = 0.82; shape.variation = 0.9; shape.density = 0.68; appearance.softness = 0.08; mode = .color
        }
    }
    public mutating func randomizeColor() { guard !colorLocked else { return }; colorSeed = UInt64.random(in: 0...UInt64.max) }
    public mutating func randomizeShape() { guard !shapeLocked else { return }; shapeSeed = UInt64.random(in: 0...UInt64.max) }
}
public struct CropRegion: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
    public func viewport(aspect: Double) -> CGRect { CGRect(x: x * aspect, y: y, width: width * aspect, height: height) }
    public static func centered(outputAspect: Double, canvasAspect: Double, fraction: Double = 0.72) -> CropRegion {
        let ratio = outputAspect / canvasAspect
        let width = min(fraction, fraction * ratio), height = width / ratio
        return CropRegion(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }
}
public enum ImageFormat: String, Codable, CaseIterable, Sendable { case png, jpeg; public var title: String { self == .png ? "PNG" : "JPEG" } }
public struct ExportSettings: Codable, Equatable, Sendable {
    public var width = 2048, height = 2048
    public var format = ImageFormat.png
    public var crop: CropRegion?
    public init() {}
}
public struct SavedSnapshot: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name: String
    public var date = Date()
    public var recipe: GenerationRecipe
    public init(name: String, recipe: GenerationRecipe) { self.name = name; self.recipe = recipe }
}
public struct LumoProject: Codable, Equatable, Sendable {
    public var formatVersion = 2
    public var recipe = GenerationRecipe()
    public var snapshots: [SavedSnapshot] = []
    public var export = ExportSettings()
    public init() {}
}

public struct RecipeHistory {
    private var undoStates: [GenerationRecipe] = []
    private var redoStates: [GenerationRecipe] = []
    private var transaction: GenerationRecipe?
    public init() {}
    public var canUndo: Bool { !undoStates.isEmpty }
    public var canRedo: Bool { !redoStates.isEmpty }
    public mutating func begin(_ current: GenerationRecipe) { if transaction == nil { transaction = current } }
    public mutating func record(before: GenerationRecipe, after: GenerationRecipe) {
        guard transaction == nil, before != after else { return }
        append(before)
    }
    private mutating func append(_ recipe: GenerationRecipe) { undoStates.append(recipe); if undoStates.count > 100 { undoStates.removeFirst() }; redoStates.removeAll() }
    public mutating func end(_ current: GenerationRecipe) { if let before = transaction, before != current { append(before) }; transaction = nil }
    public mutating func undo(_ current: GenerationRecipe) -> GenerationRecipe? {
        end(current); guard let result = undoStates.popLast() else { return nil }; redoStates.append(current); return result
    }
    public mutating func redo(_ current: GenerationRecipe) -> GenerationRecipe? {
        guard let result = redoStates.popLast() else { return nil }; undoStates.append(current); return result
    }
}

public enum LumoError: LocalizedError {
    case message(String)
    public var errorDescription: String? { switch self { case .message(let text): text } }
}
