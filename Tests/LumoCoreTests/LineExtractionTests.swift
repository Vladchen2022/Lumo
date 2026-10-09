import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LumoCore

final class LineExtractionTests: XCTestCase {
    private func pattern() throws -> Data {
        let c=CGContext(data:nil,width:256,height:192,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray:1,alpha:1)); c.fill(CGRect(x:0,y:0,width:256,height:192))
        c.setFillColor(CGColor(gray:0,alpha:1)); c.fill(CGRect(x:32,y:28,width:64,height:80))
        c.fillEllipse(in:CGRect(x:142,y:84,width:80,height:80))
        return try ReferencePixels.png(c.makeImage()!)
    }
    private func fixed(_ renderer: MetalRenderer) throws -> GenerationRecipe {
        var recipe=GenerationRecipe(); recipe.method = .deconstruction; recipe.version=3; recipe.deconstruction.strongTransforms=false; recipe.canvasAspect=4.0/3
        recipe.colorSource=try ReferenceAnalyzer.analyze(data:pattern(),name:"pattern",forColor:true)
        recipe.deconstruction.breakup=0
        return try EffectCommitter.prepare(recipe:recipe,scene:SceneGenerator.generate(recipe),renderer:renderer,longEdge:256)
    }
    private func alpha(_ data: Data) throws -> [UInt8] {
        let bytes=try ReferencePixels(data:data).rgbaBytes
        return stride(from:3,to:bytes.count,by:4).map {bytes[$0]}
    }
    func testThinEnginePresetsThicknessAndDeterministicRoundTrip() throws {
        let processor=LineExtractionProcessor(), input=try pattern()
        var p=LineExtractionParameters()
        let original=try processor.mask(input:input,parameters:p), thin=try alpha(original)
        XCTAssertGreaterThan(thin.filter {$0>0}.count,300)
        XCTAssertEqual(Set(thin),Set([0,176]))
        // Edges follow source boundaries, not the filled interior.
        XCTAssertEqual(thin[120*256+64],0)
        XCTAssertTrue((25...35).contains {thin[120*256+$0]>0})
        p.thickness=3
        let wide=try alpha(processor.mask(input:input,parameters:p))
        XCTAssertGreaterThan(wide.filter {$0>0}.count,thin.filter {$0>0}.count*2)
        p.thickness=0; XCTAssertEqual(try processor.mask(input:input,parameters:p),original)
        p.opacity=0.25; p.overlayOriginal=true
        XCTAssertEqual(try processor.mask(input:input,parameters:p),original)
        p.preset = .illustration
        XCTAssertEqual(Set(try alpha(processor.mask(input:input,parameters:p))),Set([0,210]))
    }
    func testPlainTinyInvalidInputAndParameterValidation() throws {
        let processor=LineExtractionProcessor()
        for size in [1,2,64] {
            let c=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(CGColor(gray:0.5,alpha:1)); c.fill(CGRect(x:0,y:0,width:size,height:size))
            let result=try alpha(processor.mask(input:ReferencePixels.png(c.makeImage()!),parameters:LineExtractionParameters()))
            XCTAssertTrue(result.allSatisfy {$0==0})
        }
        XCTAssertThrowsError(try processor.mask(input:Data("bad".utf8),parameters:LineExtractionParameters()))
        var bad=LineExtractionParameters(); bad.contrast = .nan
        XCTAssertThrowsError(try processor.mask(input:pattern(),parameters:bad))
    }
    func testFixedInputIsIndependentOfSubsequentCompositionAndReturnsExactly() throws {
        let renderer=try MetalRenderer()
        var recipe=try fixed(renderer); recipe.deconstruction.breakup=0.8
        let original=SceneGenerator.generate(recipe), before=recipe
        recipe.lineExtraction.enabled=true; recipe.version=5
        let scene=SceneGenerator.generate(recipe)
        XCTAssertEqual(scene.lineInput?.renderImage,recipe.fixedCanvas!.reference.renderImage)
        XCTAssertTrue(scene.fragments.isEmpty)
        recipe.deconstruction.breakup=0.2
        XCTAssertEqual(SceneGenerator.generate(recipe),scene,"Extraction must consume the committed whole canvas, not changed fragments")
        recipe=before; XCTAssertEqual(SceneGenerator.generate(recipe),original)
        // Abstract geometry remains available after extracting from an abstract stage.
        let abstract=GenerationRecipe(), geometry=SceneGenerator.generate(GenerationRecipe())
        var frozen=try EffectCommitter.prepare(recipe:abstract,scene:geometry,renderer:renderer,longEdge:256)
        frozen.lineExtraction.enabled=true; frozen.version=5
        XCTAssertNotNil(SceneGenerator.generate(frozen).lineInput)
        frozen.lineExtraction.enabled=false
        XCTAssertEqual(SceneGenerator.generate(frozen),geometry)
    }
    func testFullAndFreeRectangularCropShareMaskAndBothExportFormats() throws {
        let renderer=try MetalRenderer(); var recipe=try fixed(renderer)
        recipe.lineExtraction.enabled=true; recipe.version=5
        var scene=SceneGenerator.generate(recipe); scene.lineMask=try renderer.prepareLines(scene:scene)
        let full=try renderer.image(scene:scene,width:512,height:384)
        let crop=CropRegion(x:0.125,y:0.25,width:0.5,height:0.25)
        let local=try renderer.image(scene:scene,width:256,height:96,crop:crop)
        let a=Array(full.dataProvider!.data! as Data), b=Array(local.dataProvider!.data! as Data)
        var differences=0
        for y in 0..<96 {for x in 0..<256 {for channel in 0..<4 {
            if abs(Int(a[((y+96)*512+x+64)*4+channel])-Int(b[(y*256+x)*4+channel]))>1 {differences+=1}
        }}}
        XCTAssertEqual(differences,0,"Crop boundaries must not create new edges, move details or change line thickness")
        XCTAssertTrue(stride(from:3,to:a.count,by:4).allSatisfy {a[$0]==255})
        // The mask is not vertically flipped or expanded into filled source shapes.
        let mask=try alpha(scene.lineMask!)
        let canonical=try renderer.image(scene:scene,width:256,height:192)
        let c=Array(canonical.dataProvider!.data! as Data)
        for i in mask.indices {XCTAssertEqual(c[i*4]<250,mask[i]>0)}
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); defer {try? FileManager.default.removeItem(at:root)}
        for format in ImageFormat.allCases {for region in [nil,crop] as [CropRegion?] {
            var settings=ExportSettings(); settings.crop=region; settings.format=format
            settings.matchAspect(region?.aspect(canvasAspect:scene.aspect) ?? scene.aspect,longEdge:1024)
            let url=root.appendingPathComponent("lines-\(region == nil ? "full" : "crop").\(format.rawValue)")
            try renderer.export(scene:scene,settings:settings,to:url)
            let source=CGImageSourceCreateWithURL(url as CFURL,nil)!, props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as! [CFString:Any]
            XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int,settings.width)
            XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int,settings.height)
            XCTAssertNotNil(props[kCGImagePropertyProfileName])
        }}
    }
    func testLineStageProjectPersistenceAndOlderVersionDefaults() throws {
        let renderer=try MetalRenderer(); var recipe=try fixed(renderer)
        recipe.lineExtraction.enabled=true; recipe.lineExtraction.preset = .illustration; recipe.lineExtraction.thickness=2.1; recipe.version=5
        var project=LumoProject(); project.recipe=recipe; project.export.matchAspect(recipe.canvasAspect)
        project.snapshots=[SavedSnapshot(name:"线稿",recipe:recipe)]
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".lumo"); defer {try? FileManager.default.removeItem(at:url)}
        try ProjectStore.save(project,to:url); let opened=try ProjectStore.open(url)
        XCTAssertEqual(opened.recipe,recipe); XCTAssertEqual(opened.snapshots[0].recipe,recipe)
        XCTAssertEqual(try renderer.prepareLines(scene:SceneGenerator.generate(opened.recipe)),try renderer.prepareLines(scene:SceneGenerator.generate(recipe)))
        var bad=project; bad.recipe.fixedCanvas=nil; XCTAssertThrowsError(try ProjectStore.validate(bad))
        bad=project; bad.recipe.version=4; XCTAssertThrowsError(try ProjectStore.validate(bad))
        bad=project; bad.recipe.lineExtraction.brightness=0.4; XCTAssertThrowsError(try ProjectStore.validate(bad))
        var old=try JSONSerialization.jsonObject(with:JSONEncoder().encode(GenerationRecipe())) as! [String:Any]
        old.removeValue(forKey:"lineExtraction")
        let restored=try JSONDecoder().decode(GenerationRecipe.self,from:JSONSerialization.data(withJSONObject:old))
        XCTAssertEqual(restored.lineExtraction,LineExtractionParameters())
    }
    func testFixingExtractedLinesKeepsVisiblePixelsAndAllowsRecutting() throws {
        let renderer=try MetalRenderer(); var recipe=try fixed(renderer)
        recipe.lineExtraction.enabled=true; recipe.version=5
        let scene=SceneGenerator.generate(recipe), expected=try renderer.image(scene:scene,width:256,height:192)
        var next=try EffectCommitter.prepare(recipe:recipe,scene:scene,renderer:renderer,longEdge:256)
        XCTAssertFalse(next.lineExtraction.enabled); XCTAssertEqual(next.method,.deconstruction)
        XCTAssertNil(next.fixedCanvas!.geometry); XCTAssertEqual(next.fixedCanvas!.round,2)
        let actual=try renderer.image(scene:SceneGenerator.generate(next),width:256,height:192)
        let a=Array(expected.dataProvider!.data! as Data), b=Array(actual.dataProvider!.data! as Data)
        XCTAssertEqual(a,b,"Fixing line art must bake the visible line result, not the underlying colored scene")
        next.deconstruction.breakup=0.6
        XCTAssertNotEqual(try renderer.image(scene:SceneGenerator.generate(next),width:256,height:192).dataProvider!.data! as Data,actual.dataProvider!.data! as Data)
        next.lineExtraction.enabled=true; next.version=5
        XCTAssertNoThrow(try renderer.prepareLines(scene:SceneGenerator.generate(next)))
    }
}
