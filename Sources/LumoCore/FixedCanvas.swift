import Foundation
import simd

/// A stage owns its pixels and optional editable abstract geometry, never a recursive recipe.
public struct FixedCanvas: Codable, Equatable, Sendable {
    public var round: Int
    public var reference: SourceReference
    public var geometry: AbstractScene?
    public var colorSeed: UInt64
    public var shapeSeed: UInt64
}

extension ShapeParameters {
    public static var continuation: ShapeParameters {
        var p=ShapeParameters()
        p.density=0.5; p.scale=0.5; p.variation=0.5; p.curvature=0.5
        p.stretch=0.5; p.direction=0; p.clustering=0.5; p.coherence=0.5
        p.organic=0.5; p.erosion=0.5
        return p
    }
}

public enum EffectCommitter {
    /// Render the whole scene; crop overlays and export dimensions do not enter the stage.
    public static func prepare(recipe: GenerationRecipe, scene: AbstractScene, renderer: MetalRenderer, longEdge: Int = 4096) throws -> GenerationRecipe {
        guard recipe.lineExtraction.enabled || recipe.method != .deconstruction || !scene.fragments.isEmpty else {throw LumoError.message("请先导入参考图片再固定效果。")}
        let dimensions=ExportSettings.dimensions(aspect:scene.aspect,longEdge:longEdge)
        let image=try renderer.image(scene:scene,width:dimensions.width,height:dimensions.height)
        let pixels=try ReferencePixels.png(image)
        guard pixels.count<=32*1024*1024 else {throw LumoError.message("固定画布超过 32 MB，请降低细节后重试。当前画面未改变。")}
        let round=(recipe.fixedCanvas?.round ?? 0)+1
        var reference=try ReferenceAnalyzer.analyze(data:pixels,name:"固定效果 \(round)",forColor:true)
        reference.renderImage=pixels
        reference.features=(try? ReferenceAnalyzer.analyze(data:pixels,name:reference.name,forColor:false))?.features
        var next=recipe
        next.fixedCanvas=FixedCanvas(round:round,reference:reference,geometry:recipe.method == .abstract && !recipe.lineExtraction.enabled ? scene : nil,colorSeed:recipe.colorSeed,shapeSeed:recipe.shapeSeed)
        // All visible source layers are already baked into the captured input.
        var inputs=GenerationRecipe()
        inputs.colorSource=reference
        next.colorSource=reference; next.colorLayers=inputs.colorLayers
        next.shapeSource=reference
        next.version=4
        next.lineExtraction=LineExtractionParameters()
        if recipe.lineExtraction.enabled {next.method = .deconstruction}
        if next.method == .deconstruction {
            next.deconstruction.expandedTransforms=true
            next.deconstruction.breakup=0
            next.shapeSeed &+= 0xD1B54A32D192ED03
        } else {
            next.color=ColorParameters(); next.shape = .continuation
        }
        return next
    }
}

public enum FixedSceneGenerator {
    public static func generate(_ recipe: GenerationRecipe, fixed: FixedCanvas) -> AbstractScene {
        guard var scene=fixed.geometry else {preconditionFailure("Fixed abstract generation requires geometry")}
        if scene.aspect != recipe.canvasAspect {
            let factor=Float(recipe.canvasAspect/scene.aspect)
            for i in scene.shapes.indices {
                scene.shapes[i].center.x *= factor
                scene.shapes[i].contour=scene.shapes[i].contour.map {SIMD2($0.x*factor,$0.y)}
            }
            scene.aspect=recipe.canvasAspect
        }
        scene.mode=recipe.mode; scene.shapeDisplay=recipe.shapeDisplay; scene.appearance=recipe.appearance
        if recipe.mode == .shape {scene.background = .white}
        let p=recipe.shape
        let structureChanged=p != .continuation || recipe.shapeSeed != fixed.shapeSeed
        let colorChanged=recipe.color != ColorParameters() || recipe.colorSeed != fixed.colorSeed
        // Preserve exact geometry and RGB values at the start of every round.
        if !structureChanged && !colorChanged {return scene}
        if colorChanged {
            let palette=SceneGenerator.palette(for:recipe)
            let dominance=abs(recipe.color.dominance-0.5)*2
            func recolor(_ color:RGBColor,id:Int) -> RGBColor {
                var result=SceneGenerator.adjust(color,parameters:recipe.color)
                var random=SeededRandom(seed:recipe.colorSeed &+ UInt64(id+1) &* 0x9E3779B97F4A7C15)
                if recipe.colorSeed != fixed.colorSeed {
                    let sample=random.unit(); var sum=0.0
                    for entry in palette {sum+=entry.weight; if sample<=sum {result=entry.color; break}}
                } else if dominance>0 {
                    let slot=palette.count>1 ? 1+Int(random.next()%UInt64(palette.count-1)) : 0
                    let target=recipe.color.dominance>0.5 ? palette[0].color : palette[slot].color
                    result=RGBColor(result.r+(target.r-result.r)*dominance,result.g+(target.g-result.g)*dominance,result.b+(target.b-result.b)*dominance)
                }
                return result
            }
            scene.background=recolor(scene.background,id:-1)
            for i in scene.shapes.indices {scene.shapes[i].color=recolor(scene.shapes[i].color,id:scene.shapes[i].id)}
        }
        if recipe.mode == .shape {scene.background = .white}
        guard structureChanged else {return scene}
        let visible=scene.shapes.filter {$0.opacity>0}.map(\.id).sorted()
        let ranks=Dictionary(uniqueKeysWithValues:visible.enumerated().map {($0.element,$0.offset)})
        for i in scene.shapes.indices {
            let base=scene.shapes[i]
            var random=SeededRandom(seed:fixed.shapeSeed &+ UInt64(base.id+1) &* 0x9E3779B97F4A7C15)
            let sample=random.unit(), rotationSample=random.unit(), phase=random.unit()*2*Double.pi
            let sides=3+Int(random.next()%5)
            let angle=p.direction*Double.pi/180+(rotationSample-0.5)*(p.coherence-0.5)*2*Double.pi
            let scale=exp((p.scale-0.5)*3+(p.variation-0.5)*(sample-0.5)*3)
            let stretch=exp((p.stretch-0.5)*2)
            let focal=SIMD2<Float>(Float(scene.aspect/2),0.5)
            var center=base.center+(focal-base.center)*Float((p.clustering-0.5)*1.5)
            if recipe.shapeSeed != fixed.shapeSeed {
                var other=SeededRandom(seed:recipe.shapeSeed &+ UInt64(base.id+1) &* 0x9E3779B97F4A7C15)
                center += SIMD2(Float((other.unit()-random.unit())*scene.aspect*0.6),Float((other.unit()-random.unit())*0.6))
            }
            let meanRadius=base.contour.reduce(0.0) {$0+Double(simd_length($1-base.center))}/Double(max(1,base.contour.count))
            scene.shapes[i].center=center
            scene.shapes[i].contour=base.contour.map {point in
                let local=point-base.center
                let theta=atan2(Double(local.y),Double(local.x)), radius=Double(simd_length(local))
                var adjusted=radius
                let curve=(p.curvature-0.5)*2
                if curve>0 {adjusted=radius+(meanRadius-radius)*curve}
                else if curve<0 {
                    let sector=2*Double.pi/Double(sides), offset=(theta+phase+4*Double.pi).truncatingRemainder(dividingBy:sector)-sector/2
                    adjusted *= 1+(-curve)*(cos(sector/2)/cos(offset)-1)
                }
                let lobes=0.48*sin(theta*2+phase)+0.30*cos(theta*3-phase*1.7)+0.18*sin(theta*5+phase*2.1)
                let erosion=0.13*sin(theta*13+phase*3)+0.075*cos(theta*23-phase)+0.04*sin(theta*37+phase*2)
                adjusted *= exp(lobes*(p.organic-0.5)*2.3+erosion*(p.erosion-0.5)*2)
                let x=cos(theta)*adjusted*scale*sqrt(stretch), y=sin(theta)*adjusted*scale/sqrt(stretch)
                return center+SIMD2(Float(x*cos(angle)-y*sin(angle)),Float(x*sin(angle)+y*cos(angle)))
            }
            if p.density<0.5,let rank=ranks[base.id] {
                let opacity=max(0,min(1,p.density*2*Double(visible.count)-Double(rank)))
                scene.shapes[i].opacity *= Float(opacity*opacity*(3-2*opacity))
            }
        }
        if p.density>0.5 {
            let originals=scene.shapes.filter {$0.opacity>0}
            let progress=(p.density-0.5)*2
            let amount=Float(progress*progress*(3-2*progress))
            let firstID=(scene.shapes.map(\.id).max() ?? -1)+1
            for (i,base) in originals.prefix(max(0,768-scene.shapes.count)).enumerated() {
                var copy=base, random=SeededRandom(seed:recipe.shapeSeed &+ UInt64(base.id+1) &* 0xA0761D6478BD642F)
                copy.id=firstID+i; copy.opacity *= amount
                copy.center += SIMD2(Float((random.unit()-0.5)*scene.aspect*0.25),Float((random.unit()-0.5)*0.25))
                copy.contour=base.contour.map {copy.center+($0-base.center)*0.55}
                scene.shapes.append(copy)
            }
        }
        return scene
    }
}
