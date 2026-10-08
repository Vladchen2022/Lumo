import Foundation
import ImageIO
import simd

public struct ImageFragment: Equatable, Sendable {
    public var id: Int
    public var layer: Int
    public var center: SIMD2<Float>
    public var sourceCenter: SIMD2<Float>
    public var contour: [SIMD2<Float>]
    public var textureCoordinates: [SIMD2<Float>]
}
extension SourceReference {
    public var deconstructionImage: Data {renderImage ?? samplingImage ?? thumbnail}
    public var imageAspect: Double {
        guard let source = CGImageSourceCreateWithData(deconstructionImage as CFData,nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {return 1}
        return Double(width)/Double(height)
    }
}

private struct FragmentCell: Sendable {
    var center: SIMD2<Double>
    var contour: [SIMD2<Double>]
}
private final class PartitionCache: @unchecked Sendable {
    struct Key: Equatable {var seed: UInt64; var count: Int; var aspect: Double}
    private let lock = NSLock()
    private var entries: [(Key,[FragmentCell])] = []
    func cells(seed: UInt64, count: Int, aspect: Double) -> [FragmentCell] {
        let key = Key(seed:seed,count:count,aspect:aspect)
        lock.lock()
        if let found = entries.first(where:{$0.0 == key}) {lock.unlock(); return found.1}
        lock.unlock()
        let result = DeconstructionGenerator.partition(seed:seed,count:count,aspect:aspect)
        lock.lock(); entries.insert((key,result),at:0)
        if entries.count > 12 {entries.removeLast()}
        lock.unlock(); return result
    }
}

public enum DeconstructionGenerator {
    private static let cache = PartitionCache()
    public static func generate(_ recipe: GenerationRecipe) -> AbstractScene {
        let layers = (0..<3).map {recipe.layer($0)}
        let p = recipe.deconstruction
        var fragments: [ImageFragment] = []
        for index in layers.indices {
            guard let source = layers[index].source else {continue}
            let sourceAspect = source.imageAspect
            let seed = recipe.shapeSeed &+ UInt64(index) &* 0xD1B54A32D192ED03
            let cells = cache.cells(seed:seed,count:p.fragmentCount,aspect:sourceAspect)
            // Fit the complete source without stretching or dropping its edges.
            let height = min(1,recipe.canvasAspect/sourceAspect), width = height*sourceAspect
            let origin = SIMD2<Double>((recipe.canvasAspect-width)/2,(1-height)/2)
            var ordered: [(UInt64,ImageFragment)] = []
            for (id,cell) in cells.enumerated() {
                let originalCenter = origin + cell.center*height
                let uvCenter = SIMD2(cell.center.x/sourceAspect,cell.center.y)
                let gx = min(2,Int(uvCenter.x*3)), gy = min(2,Int(uvCenter.y*3))
                var groupRandom = SeededRandom(seed:seed &+ UInt64(gy*3+gx) &* 0xA0761D6478BD642F)
                let groupOffset = SIMD2((groupRandom.unit()-0.5)*recipe.canvasAspect,(groupRandom.unit()-0.5))*0.75
                let groupAngle = (groupRandom.unit()-0.5)*2*Double.pi
                var random = SeededRandom(seed:seed &+ UInt64(id+1) &* 0x9E3779B97F4A7C15)
                let target = SIMD2(random.unit()*recipe.canvasAspect,random.unit())
                let independentAngle = (random.unit()-0.5)*2*Double.pi*p.rotation*p.breakup
                let coherentAngle = groupAngle*p.rotation*p.breakup
                let pivot = origin+SIMD2((Double(gx)+0.5)/3*width,(Double(gy)+0.5)/3*height)
                let relative = originalCenter-pivot
                let rotated = SIMD2(relative.x*cos(coherentAngle)-relative.y*sin(coherentAngle),relative.x*sin(coherentAngle)+relative.y*cos(coherentAngle))
                let coherentCenter = pivot+rotated+groupOffset*p.breakup
                let independentCenter = originalCenter+(target-originalCenter)*p.breakup
                let center = independentCenter*(1-p.grouping)+coherentCenter*p.grouping
                let angle = independentAngle*(1-p.grouping)+coherentAngle*p.grouping
                let size = max(0.25,1+p.breakup*((p.overlap-0.5)*0.9+(random.unit()-0.5)*p.sizeVariation*1.1))
                let c = cos(angle), s = sin(angle)
                let contour = cell.contour.map {point -> SIMD2<Float> in
                    let local = (point-cell.center)*height*size
                    return SIMD2(Float(center.x+local.x*c-local.y*s),Float(center.y+local.x*s+local.y*c))
                }
                let coordinates = cell.contour.map {SIMD2<Float>(Float($0.x/sourceAspect),Float($0.y))}
                let fragment = ImageFragment(id:index*80+id,layer:index,center:SIMD2(Float(center.x),Float(center.y)),sourceCenter:SIMD2(Float(uvCenter.x),Float(uvCenter.y)),contour:contour,textureCoordinates:coordinates)
                var order = SeededRandom(seed:recipe.colorSeed &+ UInt64(index*80+id) &* 0xE7037ED1A0B428DB)
                ordered.append((order.next(),fragment))
            }
            fragments += ordered.sorted {$0.0 < $1.0}.map(\.1)
        }
        var appearance = recipe.appearance
        // Exact reassembly has no feathering seams, regardless of the retained edge setting.
        appearance.softness = p.softness*p.breakup
        return AbstractScene(aspect:recipe.canvasAspect,background:RGBColor(0.94,0.93,0.90),shapes:[],mode:.color,shapeDisplay:.solid,appearance:appearance,layers:layers,method:.deconstruction,fragments:fragments)
    }

    /// A complete Voronoi partition: all source pixels belong to a convex fragment.
    /// Adding a site only subdivides nearby cells; existing site IDs and transforms stay fixed.
    fileprivate static func partition(seed: UInt64, count: Int, aspect: Double) -> [FragmentCell] {
        var random = SeededRandom(seed:seed)
        let sites = (0..<count).map {_ in SIMD2(random.unit()*aspect,random.unit())}
        return sites.indices.map {i in
            var polygon = [SIMD2<Double>(0,0),SIMD2(aspect,0),SIMD2(aspect,1),SIMD2(0,1)]
            for j in sites.indices where j != i {
                let normal = sites[j]-sites[i], midpoint = (sites[j]+sites[i])/2
                guard !polygon.isEmpty else {break}
                var clipped: [SIMD2<Double>] = []
                for k in polygon.indices {
                    let a = polygon[k], b = polygon[(k+1)%polygon.count]
                    let da = simd_dot(a-midpoint,normal), db = simd_dot(b-midpoint,normal)
                    if da <= 1e-12 {clipped.append(a)}
                    if (da <= 0) != (db <= 0) {clipped.append(a+(b-a)*(da/(da-db)))}
                }
                polygon = clipped
            }
            // The site always lies inside its cell and is stable when neighboring cells split.
            return FragmentCell(center:sites[i],contour:polygon)
        }
    }
}
