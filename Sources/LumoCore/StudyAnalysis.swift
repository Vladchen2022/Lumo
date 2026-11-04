import Foundation
import CoreGraphics

public enum CropStudyKind: String, CaseIterable, Sendable {
    case open, dense, diagonal
    public var title:String {
        switch self {case .open: "偏留白"; case .dense: "偏密集"; case .diagonal: "偏对角线"}
    }
}

public struct StudyCrop: Identifiable, Sendable {
    public var kind: CropStudyKind
    public var region: CropRegion
    public var id: CropStudyKind {kind}
}

public enum StudyAnalysis {
    /// Classify composited pixels by their closest role in sRGB. Transparent
    /// pixels are weighted by coverage, and fully transparent pixels are omitted.
    public static func visibleShares(image:CGImage,palette:AreaPalette) throws -> [Double] {
        let data=try ReferencePixels(image:image).rgbaBytes
        let colors=palette.colors.map {SIMD3($0.r,$0.g,$0.b)}
        var counts=[0.0,0,0]
        for i in stride(from:0,to:data.count,by:4) {
            let alpha=Double(data[i+3])
            guard alpha>0 else {continue}
            let pixel=SIMD3(Double(data[i]),Double(data[i+1]),Double(data[i+2]))/alpha
            var best=0, distance=Double.infinity
            for (index,c) in colors.enumerated() {
                let d=c-pixel
                let candidate=0.3*d.x*d.x+0.55*d.y*d.y+0.15*d.z*d.z
                if candidate<distance {distance=candidate; best=index}
            }
            counts[best]+=alpha
        }
        let total=counts.reduce(0,+)
        return total>0 ? counts.map {$0/total} : counts
    }

    public static func crops(image:CGImage,canvasAspect:Double,outputAspect:Double) throws -> [StudyCrop] {
        guard (0.25...4).contains(canvasAspect), (0.25...4).contains(outputAspect) else {return []}
        let pixels=try ReferencePixels(image:image)
        let raw=pixels.rgbaBytes, w=pixels.width, h=pixels.height
        guard w>=4,h>=4 else {return []}
        let luma=(0..<w*h).map {i in
            let k=i*4
            return Float(Int(raw[k])*54+Int(raw[k+1])*183+Int(raw[k+2])*19+Int(255-raw[k+3])*256)/65280
        }
        var energy=[Float](repeating:0,count:w*h), diagonal=energy
        for y in 1..<h-1 {for x in 1..<w-1 {
            let i=y*w+x
            let dx=luma[i+1]-luma[i-1], dy=luma[i+w]-luma[i-w]
            energy[i]=abs(dx)+abs(dy)
            diagonal[i]=2*abs(dx*dy)/max(0.000001,dx*dx+dy*dy)*energy[i]
        }}
        guard energy.reduce(0,+)>Float(w*h)*0.001 else {return []}
        struct Candidate {
            var region:CropRegion
            var quiet:Double
            var energy:Double
            var diagonal:Double
        }
        var candidates:[Candidate]=[]
        for fraction in [0.40,0.55,0.71] {
            let fit=CropRegion.centered(outputAspect:outputAspect,canvasAspect:canvasAspect,fraction:fraction)
            for row in 0...4 {for column in 0...4 {
                let r=CropRegion(x:Double(column)/4*(1-fit.width),y:Double(row)/4*(1-fit.height),width:fit.width,height:fit.height)
                let left=Int(r.x*Double(w)), top=Int(r.y*Double(h))
                let right=min(w,max(left+1,Int((r.x+r.width)*Double(w))))
                let bottom=min(h,max(top+1,Int((r.y+r.height)*Double(h))))
                var e=0.0,d=0.0,quiet=0.0
                for y in top..<bottom {for x in left..<right {
                    let i=y*w+x, a=Double(energy[i])
                    e+=a; d+=Double(diagonal[i]); quiet+=a<0.035 ? 1 : 0
                }}
                let area=Double((right-left)*(bottom-top))
                candidates.append(Candidate(region:r,quiet:quiet/area,energy:e/area,diagonal:d/area))
            }}
        }
        func overlap(_ a:CropRegion,_ b:CropRegion)->Double {
            let w=max(0,min(a.x+a.width,b.x+b.width)-max(a.x,b.x))
            let h=max(0,min(a.y+a.height,b.y+b.height)-max(a.y,b.y))
            return w*h/(a.width*a.height+b.width*b.height-w*h)
        }
        var picks:[StudyCrop]=[]
        for kind in CropStudyKind.allCases {
            func score(_ c:Candidate)->Double {
                switch kind {
                case .open: return c.quiet*0.65+min(1,c.energy/0.025)*0.35
                case .dense: return c.energy
                case .diagonal: return c.diagonal
                }
            }
            if let best=candidates.filter({c in picks.allSatisfy {overlap($0.region,c.region)<0.66}})
                .max(by:{score($0)<score($1)}) {
                picks.append(StudyCrop(kind:kind,region:best.region))
            }
        }
        return picks
    }
}
