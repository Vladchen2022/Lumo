import Foundation

/// A continuous, piecewise-affine horizontal warp. Boundary vertices stay fixed.
/// Cutting each edge at the lattice boundaries makes both owners of the edge
/// agree exactly, even when they visit the edge in opposite directions.
struct CrackWarp {
    private static let columns = 4
    private static let rows = 13
    private var offsets: [Double]
    let aspect: Double

    init(seed: UInt64, aspect: Double) {
        self.aspect=aspect
        var rng=SeededRandom(seed:seed ^ 0x8B8B0D075141A9BD)
        offsets=(0...Self.rows).flatMap {y in
            (0...Self.columns).map {x in
                (x==0 || x==Self.columns || y==0 || y==Self.rows) ? 0 : (rng.unit()-0.5)*0.092
            }
        }
    }

    func point(_ p: SIMD2<Double>) -> SIMD2<Double> {
        let x=min(Double(Self.columns),max(0,p.x/aspect*Double(Self.columns)))
        let y=min(Double(Self.rows),max(0,p.y*Double(Self.rows)))
        let i=min(Self.columns-1,Int(x)), j=min(Self.rows-1,Int(y))
        let u=x-Double(i), v=y-Double(j)
        let index=j*(Self.columns+1)+i
        let a=offsets[index], b=offsets[index+1], c=offsets[index+Self.columns+1], d=offsets[index+Self.columns+2]
        let displacement = u>=v ? a*(1-u)+b*(u-v)+d*v : a*(1-v)+c*(v-u)+d*u
        return SIMD2(p.x+displacement*aspect,p.y)
    }

    func contour(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
        points.indices.flatMap {i -> [SIMD2<Double>] in
            let a=points[i], b=points[(i+1)%points.count]
            let x=Double(Self.columns)/aspect, y=Double(Self.rows)
            var parameters=[0.0]
            func split(_ lo: Double,_ hi: Double) {
                guard abs(hi-lo)>1e-10 else {return}
                let first=Int(ceil(min(lo,hi))), last=Int(floor(max(lo,hi)))
                guard first<=last else {return}
                for k in first...last {
                    let t=(Double(k)-lo)/(hi-lo)
                    if t>1e-8 && t<1-1e-8 {parameters.append(t)}
                }
            }
            split(a.x*x,b.x*x); split(a.y*y,b.y*y)
            split(a.x*x-a.y*y,b.x*x-b.y*y)
            parameters.sort()
            var result:[SIMD2<Double>]=[], last = -1.0
            for t in parameters where t-last>1e-8 {result.append(point(a+(b-a)*t)); last=t}
            return result
        }
    }

    /// Ear clipping is needed for concave edges; triangle indices are cached with the cut.
    static func triangles(_ contour: [SIMD2<Double>]) -> [Int] {
        func cross(_ a:SIMD2<Double>,_ b:SIMD2<Double>,_ c:SIMD2<Double>) -> Double {
            let x=b-a, y=c-a
            return x.x*y.y-x.y*y.x
        }
        var rest=Array(contour.indices), result:[Int]=[]
        while rest.count>3 {
            var clipped=false
            for i in rest.indices {
                let a=rest[(i+rest.count-1)%rest.count], b=rest[i], c=rest[(i+1)%rest.count]
                let p=contour[a], q=contour[b], r=contour[c], area=cross(p,q,r)
                if abs(area)<1e-13 {rest.remove(at:i); clipped=true; break}
                if area<0 {continue}
                let blocked=rest.contains {j in
                    guard j != a && j != b && j != c else {return false}
                    let s=contour[j]
                    return cross(p,q,s)>=0 && cross(q,r,s)>=0 && cross(r,p,s)>=0
                }
                if !blocked {result += [a,b,c]; rest.remove(at:i); clipped=true; break}
            }
            guard clipped else {return []}
        }
        return result+rest
    }
}
