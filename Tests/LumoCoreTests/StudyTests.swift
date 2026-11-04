import XCTest
import CoreGraphics
@testable import LumoCore

final class StudyTests: XCTestCase {
    private func fixture(width:Int=120,height:Int=80,paint:(CGContext)->Void) -> CGImage {
        let ctx=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        paint(ctx)
        return ctx.makeImage()!
    }
    private func rgb(_ gray:Double) -> CGColor {CGColor(srgbRed:gray,green:gray,blue:gray,alpha:1)}
    private func recipe(for image:CGImage) throws -> GenerationRecipe {
        let data=try ReferencePixels.png(image)
        var ref=SourceReference(name:"试验",thumbnail:data)
        ref.renderImage=data
        var recipe=GenerationRecipe()
        recipe.method = .deconstruction
        recipe.canvasAspect=Double(image.width)/Double(image.height)
        recipe.colorSource=ref
        recipe.deconstruction.breakup=0
        recipe.version=recipe.currentVersion
        return recipe
    }
    private func scratchURL(_ ext:String) -> URL {
        FileManager.default.temporaryDirectory.appending(path:UUID().uuidString+"."+ext)
    }
    private func channels(_ image:CGImage) throws -> Set<UInt8> {
        let rgba=try ReferencePixels(image:image).rgbaBytes
        return Set(stride(from:0,to:rgba.count,by:4).flatMap {rgba[$0..<$0+3]})
    }

    func testThreeValuesThresholdsChangeVisiblePixelsWithoutChangingTheSource() throws {
        let strips=fixture {c in
            for (i,gray) in [0.17,0.52,0.88].enumerated() {
                c.setFillColor(rgb(gray)); c.fill(CGRect(x:i*40,y:0,width:40,height:80))
            }
        }
        let renderer=try MetalRenderer()
        var recipe=try recipe(for:strips), study=StudySettings()
        let original=SceneGenerator.generate(recipe)
        study.values=ThreeValues()
        recipe.study=study
        func image() throws -> CGImage {try renderer.image(scene:SceneGenerator.generate(recipe),width:120,height:80)}
        let bands=try channels(image())
        XCTAssertEqual(bands.count,3)
        XCTAssertTrue(bands.contains(0) && bands.contains(255) && bands.contains {abs(Int($0)-128)<=1})
        recipe.study?.values?.low=0.6
        XCTAssertEqual(try channels(image()),Set([0,255]))
        recipe.study=nil
        XCTAssertEqual(SceneGenerator.generate(recipe),original)
    }

    func testTonalRecolorPreservesRenderedLuminanceAndChangesHue() throws {
        let renderer=try MetalRenderer()
        var recipe=GenerationRecipe()
        func pixels() throws -> [UInt8] {
            let image=try renderer.image(scene:SceneGenerator.generate(recipe),width:96,height:96)
            return try ReferencePixels(image:image).rgbaBytes
        }
        let before=try pixels()
        var settings=StudySettings(); settings.tone = .split; recipe.study=settings
        let after=try pixels()
        func luminance(_ p:[UInt8],_ i:Int)->Double {
            RGBColor(Double(p[i])/255,Double(p[i+1])/255,Double(p[i+2])/255).luminance
        }
        var worst=0.0, changed=0
        for i in stride(from:0,to:before.count,by:4) {
            worst=max(worst,abs(luminance(before,i)-luminance(after,i)))
            if before[i] != after[i] || before[i+1] != after[i+1] || before[i+2] != after[i+2] {changed+=1}
        }
        XCTAssertGreaterThan(changed,96*96/2)
        XCTAssertLessThan(worst,0.008)
    }

    func testTextureIsSeededAndCropsMatchTheFullCanvasCoordinates() throws {
        let renderer=try MetalRenderer()
        var r=GenerationRecipe()
        var study=StudySettings(), texture=TextureStudy()
        texture.kind = .mineral
        study.texture=texture; r.study=study
        let scene=SceneGenerator.generate(r)
        let whole=try renderer.image(scene:scene,width:128,height:128)
        let crop=try renderer.image(scene:scene,width:64,height:32,crop:CropRegion(x:0.25,y:0.25,width:0.5,height:0.25))
        let a=try ReferencePixels(image:whole).rgbaBytes, b=try ReferencePixels(image:crop).rgbaBytes
        var differences=0
        for y in 0..<32 {for x in 0..<64 {for ch in 0..<4 {
            if abs(Int(a[((y+32)*128+x+32)*4+ch])-Int(b[(y*64+x)*4+ch]))>2 {differences+=1}
        }}}
        XCTAssertLessThan(differences,5)
        var next=r; next.shapeSeed &+= 1
        XCTAssertNotEqual(SceneGenerator.generate(next).studySeed,scene.studySeed)
        XCTAssertEqual(SceneGenerator.generate(r),scene)
    }

    func testGuidesIncreaseTheFocalDensityAndClearTheCenterOfWhitespace() throws {
        var r=GenerationRecipe()
        let baseline=SceneGenerator.generate(r)
        var guides=CompositionGuides(); guides.strength=1
        let primary=CropRegion(x:0.08,y:0.08,width:0.3,height:0.3)
        guides.regions[.primary]=primary
        guides.regions[.empty]=CropRegion(x:0.65,y:0.65,width:0.30,height:0.30)
        var study=StudySettings(); study.guides=guides; r.study=study
        let scene=SceneGenerator.generate(r)
        func count(_ scene:AbstractScene) -> Int {
            scene.shapes.filter {$0.layer==0 && $0.opacity>0 && primary.contains(x:Double($0.center.x),y:Double($0.center.y))}.count
        }
        XCTAssertGreaterThan(count(scene),count(baseline)+6)
        let renderer=try MetalRenderer()
        let image=try renderer.image(scene:scene,width:120,height:120)
        let color=try XCTUnwrap(ReferencePixels(image:image).color(x:0.8,y:0.8))
        XCTAssertEqual(color.r,scene.background.r,accuracy:0.01)
        XCTAssertEqual(color.g,scene.background.g,accuracy:0.01)
        XCTAssertEqual(color.b,scene.background.b,accuracy:0.01)
    }

    func testEdgeZonesChangeRenderingWithoutMovingContoursAndSurviveFixing() throws {
        let renderer=try MetalRenderer()
        var r=GenerationRecipe()
        let original=SceneGenerator.generate(r)
        var study=StudySettings()
        study.edges=[EdgeZone(region:CropRegion(x:0,y:0,width:1,height:1),style:.lost)]
        study.tone = .cool
        r.study=study; r.version=r.currentVersion
        let scene=SceneGenerator.generate(r)
        XCTAssertEqual(scene.shapes.map(\.contour),original.shapes.map(\.contour))
        var toneOnly=r; toneOnly.study?.edges=[]
        let a=try renderer.image(scene:SceneGenerator.generate(toneOnly),width:128,height:128)
        let b=try renderer.image(scene:scene,width:128,height:128)
        let pa=try ReferencePixels(image:a).rgbaBytes, pb=try ReferencePixels(image:b).rgbaBytes
        XCTAssertGreaterThan(zip(pa,pb).filter {abs(Int($0)-Int($1))>12}.count,250)
        let fixed=try EffectCommitter.prepare(recipe:r,scene:scene,renderer:renderer,longEdge:128)
        XCTAssertEqual(SceneGenerator.generate(fixed),scene)
        var project=LumoProject(); project.recipe=fixed
        XCTAssertNoThrow(try ProjectStore.validate(project))
    }

    func testVisibleAreaUsesCompositedColorsAndExcludesTransparency() throws {
        var plan=AreaPalette()
        plan.main=RGBColor(1,0,0); plan.support=RGBColor(0,0,1); plan.accent=RGBColor(0,1,0)
        let image=fixture(width:120,height:40) {ctx in
            ctx.setFillColor(CGColor(srgbRed:1,green:0,blue:0,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:60,height:40))
            ctx.setFillColor(CGColor(srgbRed:0,green:0,blue:1,alpha:1)); ctx.fill(CGRect(x:60,y:0,width:30,height:40))
        }
        let shares=try StudyAnalysis.visibleShares(image:image,palette:plan)
        XCTAssertEqual(shares[0],2.0/3,accuracy:0.001)
        XCTAssertEqual(shares[1],1.0/3,accuracy:0.001)
        XCTAssertEqual(shares[2],0)
        var r=GenerationRecipe()
        let contours=SceneGenerator.generate(r).shapes.map(\.contour)
        var settings=StudySettings(); settings.palette=plan; r.study=settings
        let planned=SceneGenerator.generate(r)
        XCTAssertEqual(planned.background,plan.main)
        XCTAssertEqual(planned.shapes.map(\.contour),contours)
    }

    func testCropCandidatesAreDistinctBoundedAndMatchRequestedAspect() throws {
        let image=fixture {ctx in
            ctx.setFillColor(rgb(0.95)); ctx.fill(CGRect(x:0,y:0,width:120,height:80))
            ctx.setFillColor(rgb(0.12))
            for i in 0..<8 {ctx.fill(CGRect(x:55+i*5,y:12+i*4,width:7,height:12))}
        }
        let options=try StudyAnalysis.crops(image:image,canvasAspect:1.5,outputAspect:0.75)
        XCTAssertEqual(options.map(\.kind),CropStudyKind.allCases)
        for (i,a) in options.enumerated() {
            XCTAssertTrue(a.region.isStudyRegion)
            XCTAssertEqual(a.region.aspect(canvasAspect:1.5),0.75,accuracy:0.00001)
            for b in options.prefix(i) {XCTAssertNotEqual(a.region,b.region)}
        }
    }

    func testMaskImportFitsWithoutStretchAndProjectContainsAllMaskPixels() throws {
        let url=scratchURL("png"), saved=scratchURL("lumo")
        defer {try? FileManager.default.removeItem(at:url); try? FileManager.default.removeItem(at:saved)}
        let artwork=fixture(width:120,height:60) {ctx in
            ctx.setFillColor(rgb(1)); ctx.fill(CGRect(x:30,y:0,width:60,height:60))
        }
        try ReferencePixels.png(artwork).write(to:url)
        var r=GenerationRecipe(), study=StudySettings()
        study.silhouette=try StudyImage.silhouette(url)
        r.study=study; r.version=r.currentVersion
        try FileManager.default.removeItem(at:url)
        var project=LumoProject(); project.recipe=r
        try ProjectStore.save(project,to:saved)
        let restored=try ProjectStore.open(saved)
        XCTAssertEqual(restored.recipe,r)
        let renderer=try MetalRenderer()
        func render(_ recipe:GenerationRecipe,opaque:Bool=false) throws -> [UInt8] {
            let scene=SceneGenerator.generate(recipe)
            return try ReferencePixels(image:renderer.image(scene:scene,width:120,height:120,opaqueStudyMask:opaque)).rgbaBytes
        }
        func alpha(_ bytes:[UInt8],_ x:Int,_ y:Int) -> UInt8 {bytes[(y*120+x)*4+3]}
        let output=try render(restored.recipe)
        XCTAssertEqual(alpha(output,60,60),255)
        XCTAssertEqual(alpha(output,60,10),0)
        XCTAssertEqual(alpha(output,10,60),0)
        r.study?.silhouette?.inverted=true
        let inverse=try render(r)
        XCTAssertEqual(alpha(inverse,60,60),0)
        XCTAssertEqual(alpha(inverse,10,60),255)
        XCTAssertEqual(alpha(inverse,10,10),0)
        XCTAssertEqual(alpha(try render(r,opaque:true),60,60),255)
    }

    func testSixVariantsKeepOtherParametersAndRandomSeeds() throws {
        let base=GenerationRecipe()
        for axis in VariantAxis.allCases {
            let values=axis.values(around:base)
            XCTAssertEqual(Set(values).count,6)
            for value in values {
                let changed=axis.applying(value,to:base)
                XCTAssertEqual(axis.value(in:changed),value,accuracy:0.000001)
                XCTAssertEqual(axis.applying(axis.value(in:base),to:changed),base)
            }
        }
    }
}
