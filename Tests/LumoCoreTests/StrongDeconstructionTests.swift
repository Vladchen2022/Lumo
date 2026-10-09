import XCTest
import CoreGraphics
import simd
@testable import LumoCore

final class StrongDeconstructionTests: XCTestCase {
    private func recipe() throws -> GenerationRecipe {
        let c=CGContext(data:nil,width:256,height:256,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<16 {for x in 0..<16 {
            c.setFillColor(CGColor(srgbRed:Double((x*7+y*3)%17)/16,green:Double((x*3+y*11)%17)/16,blue:Double((x*13+y*5)%17)/16,alpha:1))
            c.fill(CGRect(x:x*16,y:y*16,width:16,height:16))
        }}
        var r=GenerationRecipe(); r.method = .deconstruction; r.version=r.currentVersion
        r.colorSource=try ReferenceAnalyzer.analyze(data:ReferencePixels.png(c.makeImage()!),name:"grid",forColor:true)
        r.deconstruction.granularity=0.58; r.deconstruction.breakup=0.2
        r.deconstruction.rotation=0.39; r.deconstruction.grouping=0.83
        r.deconstruction.sizeVariation=0; r.deconstruction.overlap=0.5; r.deconstruction.softness=0
        return r
    }
    private func areas(_ scene:AbstractScene) -> [Int:Double] {
        Dictionary(uniqueKeysWithValues:scene.fragments.map {f in
            let p=f.contour
            let twice=p.indices.reduce(0.0) {sum,i in
                let j=(i+1)%p.count
                return sum+Double(p[i].x)*Double(p[j].y)-Double(p[j].x)*Double(p[i].y)
            }
            return (f.id,abs(twice)/2)
        })
    }
    func testGapHasFullIndependentRangeAtTwentyPercentBreakup() throws {
        var r=try recipe()
        let original=SceneGenerator.generate(r), neutral=areas(original)
        r.deconstruction.overlap=0
        let small=SceneGenerator.generate(r), smallAreas=areas(small)
        r.deconstruction.overlap=1
        let large=SceneGenerator.generate(r), largeAreas=areas(large)
        for id in neutral.keys {
            XCTAssertEqual(sqrt(smallAreas[id]!/neutral[id]!),0.12,accuracy:0.0001)
            XCTAssertEqual(sqrt(largeAreas[id]!/neutral[id]!),4,accuracy:0.0001)
            XCTAssertGreaterThan(largeAreas[id]!/smallAreas[id]!,1000)
        }
        XCTAssertEqual(original.fragments.map(\.center),large.fragments.map(\.center))
        XCTAssertEqual(original.fragments.map(\.textureCoordinates),small.fragments.map(\.textureCoordinates))
        r.deconstruction.overlap=0.5; XCTAssertEqual(original,SceneGenerator.generate(r))
    }
    func testSizeVariationProducesTinyAndDominantPiecesAcrossSeeds() throws {
        var r=try recipe()
        for seed in [UInt64(1),42,100,0xBEEF_31] {
            r.shapeSeed=seed; r.deconstruction.sizeVariation=0
            let original=SceneGenerator.generate(r), neutral=areas(original)
            r.deconstruction.sizeVariation=1
            let varied=SceneGenerator.generate(r)
            let scales=areas(varied).map {sqrt($0.value/neutral[$0.key]!)}
            XCTAssertLessThan(scales.min()!,0.08)
            XCTAssertGreaterThan(scales.max()!,4)
            XCTAssertGreaterThan(scales.max()!/scales.min()!,60)
            XCTAssertGreaterThan(scales.filter {$0<0.2}.count,8)
            XCTAssertGreaterThan(scales.filter {$0>2}.count,5)
            XCTAssertEqual(original.fragments.map(\.center),varied.fragments.map(\.center))
            r.deconstruction.sizeVariation=0; XCTAssertEqual(original,SceneGenerator.generate(r))
        }
    }
    func testScatterRemainsStrongWithGroupsAndPreservesLocalRelationships() throws {
        var r=try recipe(); r.deconstruction.rotation=0
        for grouping in [0.0,0.83,1.0] {
            r.deconstruction.grouping=grouping; r.deconstruction.breakup=0
            let assembled=SceneGenerator.generate(r)
            r.deconstruction.breakup=0.2
            let strong=SceneGenerator.generate(r)
            var legacy=r; legacy.deconstruction.strongTransforms=false
            let old=SceneGenerator.generate(legacy)
            func movement(_ scene:AbstractScene) -> Double {
                zip(scene.fragments,assembled.fragments).reduce(0.0) {$0+Double(simd_length($1.0.center-$1.1.center))}/Double(scene.fragments.count)
            }
            XCTAssertGreaterThan(movement(strong),0.10)
            XCTAssertGreaterThan(movement(strong),movement(old)*2)
            XCTAssertTrue(strong.fragments.allSatisfy {f in f.contour.allSatisfy {$0.x.isFinite && $0.y.isFinite}})
            var previous=assembled
            for amount in [0.25,0.5,0.75,1.0] {
                r.deconstruction.breakup=amount
                let next=SceneGenerator.generate(r)
                let distance=zip(previous.fragments,next.fragments).reduce(0.0) {$0+Double(simd_length($1.0.center-$1.1.center))}/Double(next.fragments.count)
                XCTAssertGreaterThan(distance,0.025,"The last quarter must remain responsive as well as the first")
                previous=next
            }
            r.deconstruction.breakup=0; XCTAssertEqual(assembled,SceneGenerator.generate(r))
        }
        r.deconstruction.grouping=1; r.deconstruction.breakup=1; r.deconstruction.rotation=0.8
        let moved=SceneGenerator.generate(r); r.deconstruction.breakup=0
        let start=SceneGenerator.generate(r)
        func group(_ f:ImageFragment) -> Int {min(2,Int(f.sourceCenter.y*3))*3+min(2,Int(f.sourceCenter.x*3))}
        for i in moved.fragments.indices {for j in moved.fragments.indices where j>i && group(moved.fragments[i])==group(moved.fragments[j]) {
            XCTAssertEqual(simd_length(moved.fragments[i].center-moved.fragments[j].center),simd_length(start.fragments[i].center-start.fragments[j].center),accuracy:0.00001)
        }}
    }
    func testRenderedEndpointsDifferAndZeroRestoresExactPixels() throws {
        var r=try recipe(); let renderer=try MetalRenderer()
        func pixels(_ recipe:GenerationRecipe) throws -> [UInt8] {
            let image=try renderer.image(scene:SceneGenerator.generate(recipe),width:256,height:256)
            return Array(image.dataProvider!.data! as Data)
        }
        var extreme=r; extreme.deconstruction.sizeVariation=1; extreme.deconstruction.overlap=1
        let scene=SceneGenerator.generate(extreme), whole=try pixels(extreme)
        let crop=try renderer.image(scene:scene,width:128,height:64,crop:.init(x:0.25,y:0.375,width:0.5,height:0.25))
        let region=Array(crop.dataProvider!.data! as Data)
        for y in 0..<64 {for x in 0..<128 {for c in 0..<4 {
            XCTAssertEqual(Int(region[(y*128+x)*4+c]),Int(whole[((y+96)*256+x+64)*4+c]),accuracy:2)
        }}}
        for path in [\GenerationRecipe.deconstruction.breakup,\.deconstruction.sizeVariation,\.deconstruction.overlap] {
            r[keyPath:path]=0; let a=try pixels(r)
            r[keyPath:path]=1; let b=try pixels(r)
            var changed=0
            for i in stride(from:0,to:a.count,by:4) {
                if (0..<3).contains(where:{abs(Int(a[i+$0])-Int(b[i+$0]))>12}) {changed+=1}
            }
            XCTAssertGreaterThan(Double(changed)/(256*256),0.4,"Each complete slider sweep must visibly change a substantial part of the image")
            r=try recipe()
        }
        r.deconstruction.breakup=0
        let original=try pixels(r)
        for density in [0.0,0.45,1.0] {
            r.deconstruction.granularity=density; r.deconstruction.sizeVariation=1; r.deconstruction.overlap=0; r.deconstruction.rotation=1
            XCTAssertEqual(original,try pixels(r))
            r.deconstruction.overlap=1; XCTAssertEqual(original,try pixels(r))
        }
    }
    func testLegacyMigrationHistoryFixedRoundAndVersionSixPersistence() throws {
        var r=try recipe(); r.version=3; r.deconstruction.strongTransforms=false
        let before=SceneGenerator.generate(r)
        var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(r)) as! [String:Any]
        var p=json["deconstruction"] as! [String:Any]; p.removeValue(forKey:"strongTransforms"); json["deconstruction"]=p
        let old=try JSONDecoder().decode(GenerationRecipe.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertFalse(old.deconstruction.strongTransforms); XCTAssertEqual(before,SceneGenerator.generate(old))
        var history=RecipeHistory(); history.begin(old)
        for step in 1...20 {
            let previous=r; r.deconstruction.strongTransforms=true; r.deconstruction.overlap=Double(step)/20; r.version=r.currentVersion
            history.record(before:previous,after:r)
        }
        history.end(r)
        XCTAssertEqual(history.undo(r),old); XCTAssertEqual(history.redo(old),r)
        let renderer=try MetalRenderer()
        let fixed=try EffectCommitter.prepare(recipe:r,scene:SceneGenerator.generate(r),renderer:renderer,longEdge:256)
        XCTAssertEqual(fixed.version,6); XCTAssertEqual(fixed.deconstruction.breakup,0)
        var project=LumoProject(); project.recipe=fixed; project.snapshots=[SavedSnapshot(name:"旧范围",recipe:old),SavedSnapshot(name:"强化范围",recipe:r)]
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".lumo")
        defer {try? FileManager.default.removeItem(at:path)}
        try ProjectStore.save(project,to:path)
        let restored=try ProjectStore.open(path)
        XCTAssertEqual(restored.recipe,fixed)
        XCTAssertEqual(restored.snapshots.map(\.recipe),project.snapshots.map(\.recipe))
        XCTAssertEqual(restored.snapshots.map(\.id),project.snapshots.map(\.id))
        XCTAssertEqual(restored.snapshots.map(\.name),project.snapshots.map(\.name))
        project.recipe.lineExtraction.enabled=true; project.recipe.version=project.recipe.currentVersion
        XCTAssertEqual(project.recipe.version,6); XCTAssertNoThrow(try ProjectStore.validate(project))
        var invalid=project; invalid.recipe.version=5; XCTAssertThrowsError(try ProjectStore.validate(invalid))
        invalid=project; invalid.recipe.deconstruction.expandedTransforms=false; XCTAssertThrowsError(try ProjectStore.validate(invalid))
        project.recipe.method = .abstract; project.recipe.lineExtraction.enabled=false; project.recipe.version=project.recipe.currentVersion
        XCTAssertEqual(project.recipe.version,4); XCTAssertNoThrow(try ProjectStore.validate(project))
    }
}
