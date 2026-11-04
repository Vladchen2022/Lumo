import Foundation

public struct LayerDeconstruction: Codable, Equatable, Sendable {
    public var parameters: DeconstructionParameters
    public var lockedShapeSeed: UInt64?
    public var lockedColorSeed: UInt64?
    public init(parameters: DeconstructionParameters) {self.parameters = parameters}
    public var isLocked: Bool {lockedShapeSeed != nil}
}

public struct FragmentAdjustment: Codable, Equatable, Sendable {
    /// Translation relative to the canvas width and height.
    public var offset = SIMD2<Float>(repeating:0)
    public var hidden = false
    public var pinned: ImageFragment?
    public var pinnedAspect: Double?
    public init() {}
}

public struct FragmentArrangement: Codable, Equatable, Sendable {
    /// Back to front; slots remain stable when reordering, including their seeds.
    public var layerOrder = [0,1,2]
    public var layers: [Int:LayerDeconstruction] = [:]
    public var fragments: [Int:FragmentAdjustment] = [:]
    public init() {}

    public mutating func clearFragments(in layer: Int) {
        fragments = fragments.filter {$0.key/80 != layer}
    }
}

extension DeconstructionParameters {
    var isValid: Bool {
        [granularity,breakup,rotation,sizeVariation,overlap,grouping,softness,spacing].allSatisfy {$0.isFinite && (0...1).contains($0)}
    }
}

extension FragmentArrangement {
    var isValid: Bool {
        layerOrder.count == 3 && Set(layerOrder) == Set(0..<3)
        && layers.allSatisfy {(0..<3).contains($0.key) && $0.value.parameters.isValid && ($0.value.lockedShapeSeed == nil) == ($0.value.lockedColorSeed == nil)}
        && fragments.count <= 240 && fragments.allSatisfy {id, edit in
            guard (0..<240).contains(id), [edit.offset.x,edit.offset.y].allSatisfy({$0.isFinite && abs($0)<=4}) else {return false}
            guard let pin=edit.pinned else {return edit.pinnedAspect == nil}
            guard let aspect=edit.pinnedAspect, (0.25...4).contains(aspect), pin.id==id, pin.layer==id/80,
                  (3...256).contains(pin.contour.count), pin.contour.count == pin.textureCoordinates.count else {return false}
            return (pin.contour+[pin.center]).allSatisfy {$0.x.isFinite && $0.y.isFinite && abs($0.x)<256 && abs($0.y)<256}
                && (pin.textureCoordinates+[pin.sourceCenter]).allSatisfy {(-0.00001...1.00001).contains($0.x) && (-0.00001...1.00001).contains($0.y)}
                && (pin.triangles.map {t in t.count<=3*(pin.contour.count-2) && t.count%3==0 && t.allSatisfy {pin.contour.indices.contains($0)}} ?? true)
        }
    }
}

extension AbstractScene {
    public func fragment(at point: SIMD2<Float>) -> ImageFragment? {
        for layer in (layerOrder ?? Array(layers.indices)).reversed() {
            guard layers.indices.contains(layer), layers[layer].enabled, layers[layer].opacity > 0, layers[layer].blockOpacity > 0 else {continue}
            for fragment in fragments.reversed() where fragment.layer == layer {
                if fragment.contains(point) {return fragment}
            }
        }
        return nil
    }
}

extension ImageFragment {
    func contains(_ p: SIMD2<Float>) -> Bool {
        var inside=false
        for i in contour.indices {
            let a=contour[i], b=contour[(i+1)%contour.count]
            if (a.y>p.y) != (b.y>p.y), p.x < a.x+(p.y-a.y)*(b.x-a.x)/(b.y-a.y) {inside.toggle()}
        }
        return inside
    }
}
