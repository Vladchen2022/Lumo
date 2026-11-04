import Foundation
import CoreGraphics
import simd

public struct ThreeValues: Codable, Equatable, Sendable {
    /// Thresholds use the sRGB-encoded equivalent of relative luminance.
    public var low = 0.35
    public var high = 0.70
    public init() {}
    var isValid: Bool {(0.02...0.97).contains(low) && (0.04...0.99).contains(high) && high-low>=0.019999}
}

public enum GuideRole: String, Codable, CaseIterable, Sendable {
    case primary, secondary, empty
    public var title: String {
        switch self {case .primary: "主焦点"; case .secondary: "次焦点"; case .empty: "留白"}
    }
}

public struct CompositionGuides: Codable, Equatable, Sendable {
    public var regions: [GuideRole:CropRegion] = [:]
    public var strength = 0.7
    public init() {}
}

public struct AreaPalette: Codable, Equatable, Sendable {
    public var main = RGBColor(0.86,0.81,0.70)
    public var support = RGBColor(0.20,0.42,0.45)
    public var accent = RGBColor(0.83,0.30,0.18)
    public var supportShare = 0.30
    public var accentShare = 0.10
    public init() {}
    public var colors: [RGBColor] {[main,support,accent]}
    public var weights: [Double] {[1-supportShare-accentShare,supportShare,accentShare]}
}

public enum ToneStudy: Int, Codable, CaseIterable, Sendable {
    case warm = 1, cool, split
    public var title: String {
        switch self {case .warm: "暖褐"; case .cool: "冷青"; case .split: "冷暗暖亮"}
    }
}

public enum TextureKind: Int, Codable, CaseIterable, Sendable {
    case patina = 1, mineral
    public var title: String {self == .patina ? "斑驳扩散" : "矿脉条带"}
}

public struct TextureStudy: Codable, Equatable, Sendable {
    public var kind = TextureKind.patina
    public var amount = 0.55
    public var scale = 0.5
    public var direction = 25.0
    public init() {}
}

public enum StudyEdge: String, Codable, CaseIterable, Sendable {
    case sharp, soft, lost
    public var title: String {
        switch self {case .sharp: "锐利"; case .soft: "柔化"; case .lost: "融边"}
    }
}

public struct EdgeZone: Codable, Equatable, Sendable {
    public var region: CropRegion
    public var style: StudyEdge
    public init(region:CropRegion,style:StudyEdge) {self.region=region; self.style=style}
}

public struct SilhouetteStudy: Codable, Equatable, Sendable {
    public var source: SourceReference
    public var aspect: Double
    public var inverted = false
    public init(source:SourceReference,aspect:Double) {self.source=source; self.aspect=aspect}
}

public struct StudySettings: Codable, Equatable, Sendable {
    public var values: ThreeValues?
    public var guides: CompositionGuides?
    public var palette: AreaPalette?
    public var tone: ToneStudy?
    public var texture: TextureStudy?
    public var edges: [EdgeZone] = []
    public var silhouette: SilhouetteStudy?
    public init() {}

    var requiresPass: Bool {values != nil || tone != nil || texture != nil || silhouette != nil || guides?.regions[.empty] != nil}
    var isValid: Bool {
        guard values?.isValid != false, edges.count<=12, edges.allSatisfy({$0.region.isStudyRegion}) else {return false}
        if let guides, !(0...1).contains(guides.strength) || !guides.regions.values.allSatisfy(\.isStudyRegion) {return false}
        if let palette, !palette.colors.allSatisfy({[ $0.r,$0.g,$0.b ].allSatisfy {(0...1).contains($0)}})
            || !(0...0.8).contains(palette.supportShare) || !(0...0.5).contains(palette.accentShare)
            || palette.supportShare+palette.accentShare>0.98 {return false}
        if let texture, !(0...1).contains(texture.amount) || !(0...1).contains(texture.scale) || !(-180...180).contains(texture.direction) {return false}
        if let silhouette, !(1.0/2048...2048).contains(silhouette.aspect)
            || silhouette.source.renderImage == nil || silhouette.source.renderImage!.isEmpty {return false}
        return true
    }
}

extension CropRegion {
    var isStudyRegion: Bool {
        [x,y,width,height].allSatisfy(\.isFinite) && x>=0 && y>=0 && width>=0.015 && height>=0.015
            && x+width<=1.000001 && y+height<=1.000001
    }
    func contains(x:Double,y:Double) -> Bool {x>=self.x && x<=self.x+width && y>=self.y && y<=self.y+height}
}

public enum VariantAxis: String, CaseIterable, Sendable {
    case density, scale, direction, hue, brightness, breakup, spacing
    public var title: String {
        switch self {
        case .density: "密度"; case .scale: "块面尺度"; case .direction: "方向"
        case .hue: "色相"; case .brightness: "明度"; case .breakup: "打散"; case .spacing: "碎片间距"
        }
    }
    public var range: ClosedRange<Double> {self == .hue || self == .direction ? -180...180 : 0...1}
    public func value(in r:GenerationRecipe) -> Double {
        switch self {
        case .density: r.shape.density; case .scale: r.shape.scale; case .direction: r.shape.direction
        case .hue: r.color.hue; case .brightness: r.color.brightness; case .breakup: r.deconstruction.breakup
        case .spacing: r.deconstruction.spacing
        }
    }
    public func values(around recipe:GenerationRecipe) -> [Double] {
        let span=(range.upperBound-range.lowerBound)*0.65
        let start=min(range.upperBound-span,max(range.lowerBound,value(in:recipe)-span/2))
        return (0..<6).map {start+Double($0)*span/5}
    }
    public func applying(_ value:Double,to recipe:GenerationRecipe) -> GenerationRecipe {
        var r=recipe
        let v=min(range.upperBound,max(range.lowerBound,value))
        switch self {
        case .density: r.shape.density=v; case .scale: r.shape.scale=v; case .direction: r.shape.direction=v
        case .hue: r.color.hue=v; case .brightness: r.color.brightness=v
        case .breakup: r.deconstruction.breakup=v; case .spacing: r.deconstruction.spacing=v
        }
        r.version=r.currentVersion
        return r
    }
    public func label(_ value:Double) -> String {
        self == .hue || self == .direction ? "\(Int(value.rounded()))°" : "\(Int((value*100).rounded()))%"
    }
}

enum StudyComposition {
    static func applying(to base:AbstractScene,recipe:GenerationRecipe) -> AbstractScene {
        guard var settings=recipe.study,settings != StudySettings(),base.lineInput == nil else {return base}
        var scene=base
        if scene.method != .abstract {
            settings.guides=nil; settings.palette=nil; settings.edges=[]
        }
        if scene.mode == .shape {settings.palette=nil}
        if let plan=settings.palette {scene.background=plan.main}
        let guides=settings.guides
        let primary=guides?.regions[.primary], secondary=guides?.regions[.secondary]
        let strength=guides?.strength ?? 0
        let adjustShapes=settings.palette != nil || (strength>0 && (primary != nil || secondary != nil))
        for index in scene.shapes.indices where adjustShapes && scene.shapes[index].opacity > 0 {
            var shape=scene.shapes[index]
            var rng=SeededRandom(seed:recipe.shapeSeed &+ UInt64(shape.id) &* 0xB49D5C261FA39AF1)
            let destination=rng.unit(), x=rng.unit(), y=rng.unit()
            let target=destination < 0.62*strength ? primary : destination < 0.87*strength ? secondary : nil
            if let target {
                let center=SIMD2(Float((target.x+target.width*(0.16+0.68*x))*scene.aspect),Float(target.y+target.height*(0.16+0.68*y)))
                let delta=center-shape.center
                shape.center=center; shape.contour=shape.contour.map {$0+delta}
            }
            if let plan=settings.palette {
                var colorRNG=SeededRandom(seed:recipe.colorSeed &+ UInt64(shape.id) &* 0xAC636831F42F47C1)
                let sample=colorRNG.unit()
                let weights=plan.weights
                shape.color = sample < weights[0] ? plan.main : sample < 1-plan.accentShare ? plan.support : plan.accent
            }
            if let primary,primary.contains(x:Double(shape.center.x)/scene.aspect,y:Double(shape.center.y)),scene.mode != .shape {
                let targetColor=scene.background.luminance > 0.32 ? RGBColor.ink : .white
                let t=0.33*strength
                let c=shape.color
                shape.color=RGBColor(c.r*(1-t)+targetColor.r*t,c.g*(1-t)+targetColor.g*t,c.b*(1-t)+targetColor.b*t)
            }
            scene.shapes[index]=shape
        }
        scene.study=settings
        scene.studySeed=UInt32(truncatingIfNeeded:recipe.shapeSeed)
        return scene
    }

    static func edge(at point:SIMD2<Float>,in scene:AbstractScene) -> StudyEdge? {
        scene.study?.edges.last {zone in zone.region.contains(x:Double(point.x)/scene.aspect,y:Double(point.y))}?.style
    }
}
