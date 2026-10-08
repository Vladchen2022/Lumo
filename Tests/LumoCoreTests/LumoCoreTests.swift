import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import LumoCore

final class LumoCoreTests:XCTestCase {
    func testDeterminismAndIndependentControls() {
        let recipe=GenerationRecipe(), original=SceneGenerator.generate(GenerationRecipe())
        XCTAssertEqual(original,SceneGenerator.generate(recipe))
        var recolored=recipe; recolored.color.hue=91; recolored.color.brightness=0.7
        let colors=SceneGenerator.generate(recolored)
        XCTAssertEqual(original.shapes.map(\.contour),colors.shapes.map(\.contour)); XCTAssertNotEqual(original.shapes.map(\.color),colors.shapes.map(\.color))
        var reshaped=recipe; reshaped.shape.curvature=0.9; reshaped.shape.direction=45
        XCTAssertNotEqual(original.shapes.map(\.contour),SceneGenerator.generate(reshaped).shapes.map(\.contour))
        XCTAssertEqual(SceneGenerator.palette(for:recipe),SceneGenerator.palette(for:reshaped))
        XCTAssertEqual(original.shapes.map(\.color),SceneGenerator.generate(reshaped).shapes.map(\.color))
    }
    func testDensityKeepsIDsAndHasContinuousFade() {
        var a=GenerationRecipe(); a.shape.density=0.2
        var b=a; b.shape.density=0.9
        XCTAssertEqual(SceneGenerator.generate(a).shapes.map(\.contour),SceneGenerator.generate(b).shapes.map(\.contour))
        a.shape.density=0.207; b=a; b.shape.density+=0.0001
        let alphas=SceneGenerator.generate(a).shapes.map(\.opacity), next=SceneGenerator.generate(b).shapes.map(\.opacity)
        XCTAssertTrue(zip(alphas,next).allSatisfy {abs($0-$1)<0.02})
        XCTAssertTrue(alphas.contains {$0>0 && $0<1})
    }
    func testModesAndSliderRoundTripKeepGeometry() {
        var r=GenerationRecipe(); let original=SceneGenerator.generate(r)
        for mode in DisplayMode.allCases {r.mode=mode; XCTAssertEqual(original.shapes.map(\.contour),SceneGenerator.generate(r).shapes.map(\.contour))}
        r.mode = .combined; r.shape.stretch=0.9; r.shape.stretch=GenerationRecipe().shape.stretch
        XCTAssertEqual(original,SceneGenerator.generate(r))
    }
    func testDominanceChangesContinuously() {
        var a=GenerationRecipe(), b=a
        for step in 0..<100 {
            a.color.dominance=Double(step)/100; b=a; b.color.dominance+=0.0001
            let old=SceneGenerator.generate(a).shapes.map(\.color), new=SceneGenerator.generate(b).shapes.map(\.color)
            for (x,y) in zip(old,new) {XCTAssertLessThan(abs(x.r-y.r)+abs(x.g-y.g)+abs(x.b-y.b),0.04)}
        }
    }
    func testLocksAndHistoryTransaction() {
        var r=GenerationRecipe(); r.colorLocked=true; r.shapeLocked=true; let original=r
        r.randomizeColor(); r.randomizeShape(); XCTAssertEqual(r,original)
        var history=RecipeHistory(); history.begin(r)
        for n in 1...20 {let before=r; r.color.hue=Double(n); history.record(before:before,after:r)}
        history.end(r); XCTAssertEqual(history.undo(r),original); XCTAssertFalse(history.canUndo)
        XCTAssertEqual(history.redo(original),r)
        history.begin(r); history.end(r); XCTAssertEqual(history.undo(r),original)
    }
    func testPaletteExtractionTransparencyAndWeights() throws {
        let root=try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("palette.png")
        try fixture(url,width:100,height:100) {c in
            c.setFillColor(CGColor(srgbRed:1,green:0,blue:0,alpha:1)); c.fill(CGRect(x:0,y:0,width:75,height:100))
            c.setFillColor(CGColor(srgbRed:0,green:0,blue:1,alpha:1)); c.fill(CGRect(x:75,y:0,width:25,height:100))
        }
        let source=try ReferenceAnalyzer.analyze(url:url,forColor:true), palette=source.palette!
        XCTAssertEqual(palette.count,2); XCTAssertEqual(palette.reduce(0,{$0+$1.weight}),1,accuracy:0.000001)
        XCTAssertEqual(palette[0].weight,0.75,accuracy:0.02); XCTAssertGreaterThan(palette[0].color.r,0.98); XCTAssertLessThan(palette[0].color.b,0.02)
        XCTAssertNil(source.features)
        let empty=root.appendingPathComponent("transparent.png"); try fixture(empty,width:40,height:40) {_ in}
        XCTAssertThrowsError(try ReferenceAnalyzer.analyze(url:empty,forColor:true))
    }
    func testShapeReferenceContainsOnlyStatisticsAndRejectsPlainImage() throws {
        let root=try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("lines.png")
        try fixture(url,width:300,height:300) {c in
            c.setFillColor(CGColor(gray:1,alpha:1)); c.fill(CGRect(x:0,y:0,width:300,height:300))
            c.setFillColor(CGColor(gray:0,alpha:1)); for x in stride(from:20,through:280,by:40) {c.fill(CGRect(x:x,y:0,width:10,height:300))}
        }
        let source=try ReferenceAnalyzer.analyze(url:url,forColor:false)
        XCTAssertNil(source.palette); XCTAssertGreaterThan(source.features!.coherence,0.9)
        XCTAssertEqual(source.features!.direction,90,accuracy:2)
        let encoded=String(data:try JSONEncoder().encode(source.features!),encoding:.utf8)!
        XCTAssertFalse(encoded.contains("contour")); XCTAssertFalse(encoded.contains("position"))
        let plain=root.appendingPathComponent("plain.png"); try fixture(plain,width:80,height:80) {c in c.setFillColor(CGColor(gray:0.5,alpha:1)); c.fill(CGRect(x:0,y:0,width:80,height:80))}
        XCTAssertThrowsError(try ReferenceAnalyzer.analyze(url:plain,forColor:false))
        XCTAssertEqual(try ReferenceAnalyzer.analyze(url:plain,forColor:true).palette?.count,1)
        let invalid=root.appendingPathComponent("invalid.png"); try Data("invalid".utf8).write(to:invalid)
        XCTAssertThrowsError(try ReferenceAnalyzer.analyze(url:invalid,forColor:true))
    }
    func testProjectsSurviveDeletingSourcesAndRejectInvalidData() throws {
        let root=try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("source.png"); try fixture(url,width:80,height:80) {c in c.setFillColor(CGColor(srgbRed:0.2,green:0.6,blue:0.5,alpha:1)); c.fill(CGRect(x:0,y:0,width:80,height:80))}
        var project=LumoProject(); project.recipe.colorSource=try ReferenceAnalyzer.analyze(url:url,forColor:true)
        project.snapshots=[SavedSnapshot(name:"收藏",recipe:project.recipe)]
        let path=root.appendingPathComponent("test.lumo"); try ProjectStore.save(project,to:path); try FileManager.default.removeItem(at:url)
        let read=try ProjectStore.open(path)
        XCTAssertEqual(read.recipe,project.recipe); XCTAssertEqual(read.snapshots[0].recipe,project.recipe)
        XCTAssertEqual(SceneGenerator.generate(read.recipe),SceneGenerator.generate(project.recipe))
        project.recipe.shape.scale = .nan; XCTAssertThrowsError(try ProjectStore.save(project,to:path))
        project=LumoProject(); project.formatVersion=99; XCTAssertThrowsError(try ProjectStore.validate(project))
        try Data("{}".utf8).write(to:path); XCTAssertThrowsError(try ProjectStore.open(path))
    }
    func testFormatsOrientationAndLargeReferenceDownsampling() throws {
        let root=try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        let context=CGContext(data:nil,width:400,height:200,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.displayP3)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed:0.5,green:0.3,blue:0.2,alpha:1)); context.fill(CGRect(x:0,y:0,width:400,height:200))
        for type in [UTType.jpeg,UTType.heic,UTType.tiff] {
            let url=root.appendingPathComponent("oriented.\(type.preferredFilenameExtension!)")
            let destination=CGImageDestinationCreateWithURL(url as CFURL,type.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(destination,context.makeImage()!,[kCGImagePropertyOrientation:6] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let reference=try ReferenceAnalyzer.analyze(url:url,forColor:true)
            let source=CGImageSourceCreateWithData(reference.thumbnail as CFData,nil)!, thumb=CGImageSourceCreateImageAtIndex(source,0,nil)!
            XCTAssertGreaterThan(thumb.height,thumb.width); XCTAssertLessThanOrEqual(thumb.height,256)
            let color=reference.palette![0].color
            XCTAssertEqual(color.r,0.5,accuracy:0.03); XCTAssertEqual(color.g,0.3,accuracy:0.03); XCTAssertEqual(color.b,0.2,accuracy:0.03)
        }
        let url=root.appendingPathComponent("large.png")
        try fixture(url,width:6000,height:4000) {c in c.setFillColor(CGColor(gray:0.6,alpha:1)); c.fill(CGRect(x:0,y:0,width:6000,height:4000))}
        let reference=try ReferenceAnalyzer.analyze(url:url,forColor:true)
        let source=CGImageSourceCreateWithData(reference.thumbnail as CFData,nil)!, image=CGImageSourceCreateImageAtIndex(source,0,nil)!
        XCTAssertLessThanOrEqual(max(image.width,image.height),256)
    }
    func testCropRatioAndValidation() throws {
        for canvas in [1.0,4.0/3,3.0/4] {for output in [1.0,16.0/9,9.0/16] {
            let crop=CropRegion.centered(outputAspect:output,canvasAspect:canvas)
            XCTAssertEqual(crop.width*canvas/crop.height,output,accuracy:0.000001)
            XCTAssertGreaterThan(crop.width,0); XCTAssertLessThanOrEqual(crop.x+crop.width,1)
        }}
        var p=LumoProject(); p.export.width=800; p.export.height=600; p.export.crop=CropRegion.centered(outputAspect:4.0/3,canvasAspect:1)
        XCTAssertNoThrow(try ProjectStore.validate(p)); p.export.crop!.x=2; XCTAssertThrowsError(try ProjectStore.validate(p))
    }
    func testGPUOutputModesProfilesAndCropConsistency() throws {
        let renderer=try MetalRenderer()
        var r=GenerationRecipe(); r.mode = .shape
        let scene=SceneGenerator.generate(r), full=try renderer.image(scene:scene,width:512,height:512)
        let bytes=Array(full.dataProvider!.data! as Data)
        var isGray=true
        for i in stride(from:0,to:bytes.count,by:4) {
            let b=Int(bytes[i]), g=Int(bytes[i+1]), red=Int(bytes[i+2])
            if abs(b-g)>1 || abs(g-red)>1 {isGray=false; break}
        }
        XCTAssertTrue(isGray)
        let crop=CropRegion(x:0.25,y:0.25,width:0.5,height:0.5), local=try renderer.image(scene:scene,width:256,height:256,crop:crop)
        let partial=Array(local.dataProvider!.data! as Data)
        var differences=0
        for y in 0..<256 {for x in 0..<256 {for channel in 0..<4 {
            let a=Int(bytes[((y+128)*512+x+128)*4+channel]), b=Int(partial[(y*256+x)*4+channel])
            if abs(a-b)>1 {differences+=1}
        }}}
        XCTAssertLessThan(differences,100,"Same pixel density crop must match full scene")
        let root=try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        for format in ImageFormat.allCases {
            var settings=ExportSettings(); settings.width=128; settings.height=128; settings.format=format
            let url=root.appendingPathComponent("image.\(format.rawValue)"); try renderer.export(scene:scene,settings:settings,to:url)
            let source=CGImageSourceCreateWithURL(url as CFURL,nil)!, props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as! [String:Any]
            XCTAssertEqual(props[kCGImagePropertyPixelWidth as String] as? Int,128); XCTAssertNotNil(props[kCGImagePropertyProfileName as String])
        }
        XCTAssertThrowsError(try renderer.image(scene:scene,width:4097,height:200))
    }
    func testLegacyProjectMigrationAndSixSlotEditing() throws {
        var old = LumoProject(); old.recipe.colorSource = SourceReference(name:"旧参考",thumbnail:Data(),palette:[PaletteEntry(.init(0.8,0.2,0.1),0.9),PaletteEntry(.init(0.1,0.2,0.9),0.1)])
        old.recipe.colorSource!.id = nil // 0.1 source records had no identity field.
        var json = try JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any]
        json["formatVersion"] = 1
        var recipe = json["recipe"] as! [String:Any]; recipe.removeValue(forKey:"colorLayers")
        var shape = recipe["shape"] as! [String:Any]; shape.removeValue(forKey:"organic"); shape.removeValue(forKey:"erosion"); recipe["shape"] = shape; json["recipe"] = recipe
        let root = try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        let url = root.appendingPathComponent("legacy.lumo"); try JSONSerialization.data(withJSONObject:json).write(to:url)
        let migrated = try ProjectStore.open(url)
        XCTAssertEqual(migrated.recipe,old.recipe)
        XCTAssertEqual(SceneGenerator.generate(migrated.recipe),SceneGenerator.generate(old.recipe))
        var edited = migrated.recipe
        edited.setLayer(0) {$0.paletteOverrides[5] = .init(0,1,0); $0.weightOverrides[5] = 0.3}
        let palette = SceneGenerator.palette(for:edited)
        XCTAssertEqual(palette.count,6); XCTAssertEqual(palette[5].color.r,0,accuracy:0.000001); XCTAssertEqual(palette[5].color.g,1,accuracy:0.000001); XCTAssertEqual(palette[5].color.b,0,accuracy:0.000001); XCTAssertGreaterThan(palette[5].weight,0.2)
        XCTAssertEqual(SceneGenerator.generate(edited).shapes.map(\.contour),SceneGenerator.generate(old.recipe).shapes.map(\.contour))
    }
    func testThreeLayersPersistenceDeduplicationAndIndependentGeometry() throws {
        let root = try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        var project = LumoProject()
        for layer in 0..<3 {
            let url = root.appendingPathComponent("source\(layer).png")
            try fixture(url,width:300,height:250) {c in c.setFillColor(CGColor(srgbRed:Double(layer)/3,green:0.6,blue:0.5,alpha:1)); c.fill(CGRect(x:0,y:0,width:300,height:250))}
            let reference = try ReferenceAnalyzer.analyze(url:url,forColor:true)
            project.recipe.setLayer(layer) {$0.source = reference; $0.blend = .overlay; $0.blockBlend = .softLight; $0.opacity = 0.6; $0.blockOpacity = 0.7}
            try FileManager.default.removeItem(at:url)
        }
        project.snapshots = (0..<100).map {SavedSnapshot(name:"构成 \($0)",recipe:project.recipe)}
        let url = root.appendingPathComponent("layers.lumo"); try ProjectStore.save(project,to:url)
        let restored = try ProjectStore.open(url)
        XCTAssertEqual(project.recipe,restored.recipe)
        XCTAssertEqual(project.snapshots.map(\.recipe),restored.snapshots.map(\.recipe))
        XCTAssertEqual(project.snapshots.map(\.id),restored.snapshots.map(\.id))
        for (before,after) in zip(project.snapshots,restored.snapshots) {XCTAssertEqual(before.date.timeIntervalSince1970,after.date.timeIntervalSince1970,accuracy:0.00001)}
        let json = try JSONSerialization.jsonObject(with:Data(contentsOf:url)) as! [String:Any]
        XCTAssertLessThanOrEqual((json["referenceImages"] as! [String:String]).count,6)
        let scene = SceneGenerator.generate(project.recipe)
        var changed = project.recipe; changed.setLayer(2) {$0.opacity = 0.3; $0.blockBlend = .multiply}
        XCTAssertEqual(scene.shapes.map(\.contour),SceneGenerator.generate(changed).shapes.map(\.contour))
        changed.colorLocked = true; let before = changed; changed.randomizeColor(); XCTAssertEqual(changed,before)
        changed.setLayer(1) {$0.opacity = .nan}; XCTAssertThrowsError(try ProjectStore.validate({var p = project; p.recipe = changed; return p}()))
    }
    func testOrganicContoursAreStableAndReturnToOriginal() {
        var r = GenerationRecipe(); let original = SceneGenerator.generate(r)
        r.shape.organic = 0.9; r.shape.erosion = 0.8
        let organic = SceneGenerator.generate(r)
        XCTAssertNotEqual(original.shapes.map(\.contour),organic.shapes.map(\.contour))
        XCTAssertEqual(organic,SceneGenerator.generate(r))
        XCTAssertEqual(original.shapes.map(\.color),organic.shapes.map(\.color))
        XCTAssertTrue(organic.shapes.flatMap(\.contour).allSatisfy {$0.x.isFinite && $0.y.isFinite})
        r.shape.density = 0.9; XCTAssertEqual(organic.shapes.map(\.contour),SceneGenerator.generate(r).shapes.map(\.contour))
        r.shape.organic = 0; r.shape.erosion = 0; r.shape.density = GenerationRecipe().shape.density
        XCTAssertEqual(original,SceneGenerator.generate(r))
    }
    func testOriginalPixelPickingRareAccentOrientationAndTransparency() throws {
        let root = try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        let url = root.appendingPathComponent("accent.png")
        try fixture(url,width:1000,height:1000) {c in
            c.setFillColor(CGColor(srgbRed:0.3,green:0.3,blue:0.3,alpha:1)); c.fill(CGRect(x:0,y:0,width:1000,height:1000))
            c.setFillColor(CGColor(srgbRed:1,green:0,blue:0,alpha:1)); c.fill(CGRect(x:900,y:99,width:1,height:1))
            c.clear(CGRect(x:50,y:50,width:20,height:20))
        }
        let accent = try XCTUnwrap(ReferencePixels.originalColor(url:url,x:0.9005,y:0.9005))
        XCTAssertEqual(accent.r,1,accuracy:0.01); XCTAssertEqual(accent.g,0,accuracy:0.01)
        XCTAssertNil(try ReferencePixels.originalColor(url:url,x:0.055,y:0.945))
        let reference = try ReferenceAnalyzer.analyze(url:url,forColor:true)
        let pixels = try ReferencePixels(data:XCTUnwrap(reference.samplingImage))
        XCTAssertEqual(pixels.color(x:0.9005,y:0.9005),accent)
        // Rotate the same pixels 90° clockwise via EXIF, then sample the transformed location.
        let rotated = root.appendingPathComponent("rotated.tiff")
        let src = CGImageSourceCreateWithURL(url as CFURL,nil)!, image = CGImageSourceCreateImageAtIndex(src,0,nil)!
        let dest = CGImageDestinationCreateWithURL(rotated as CFURL,UTType.tiff.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(dest,image,[kCGImagePropertyOrientation:6] as CFDictionary); XCTAssertTrue(CGImageDestinationFinalize(dest))
        XCTAssertEqual(try ReferencePixels.originalColor(url:rotated,x:0.0995,y:0.9005),accent)
    }
    func testGPUFiveBlendModesAndLayerOpacity() throws {
        let renderer = try MetalRenderer()
        var r = GenerationRecipe(); r.mode = .color
        var scene = SceneGenerator.generate(r)
        scene.background = .init(0.3,0.6,0.5)
        scene.shapes = [SceneShape(id:0,center:SIMD2(0.5,0.5),contour:[SIMD2(0.1,0.1),SIMD2(0.9,0.1),SIMD2(0.9,0.9),SIMD2(0.1,0.9)],color:.init(0.8,0.2,0.4),opacity:1,gradient:0)]
        func sample(_ scene: AbstractScene) throws -> [Double] {
            let image = try renderer.image(scene:scene,width:64,height:64), bytes = Array(image.dataProvider!.data! as Data), i = (32*64+32)*4
            return [Double(bytes[i+2])/255,Double(bytes[i+1])/255,Double(bytes[i])/255]
        }
        let expected: [[Double]] = [[0.8,0.2,0.4],[0.24,0.12,0.2],[0.86,0.68,0.7],[0.48,0.36,0.4],[0.4486335,0.456,0.45]]
        for mode in ColorBlendMode.allCases {
            scene.layers[0].blend = mode
            let pixel = try sample(scene)
            for channel in 0..<3 {XCTAssertEqual(pixel[channel],expected[mode.rawValue][channel],accuracy:0.015,"\(mode)")}
        }
        scene.layers[0].blend = .normal; scene.layers[0].opacity = 0
        for (value,base) in zip(try sample(scene),[0.3,0.6,0.5]) {XCTAssertEqual(value,base,accuracy:0.005)}
        scene.layers[0].opacity = 0.5
        let pixel = try sample(scene)
        XCTAssertGreaterThan(pixel[0],0.3); XCTAssertLessThan(pixel[0],0.8)
        // A second block uses its own blend against the first block before the layer is composited.
        scene.layers[0].opacity = 1; scene.layers[0].blockBlend = .multiply
        var second = scene.shapes[0]; second.id = 1; scene.shapes.append(second)
        let multiplied = try sample(scene)
        XCTAssertEqual(multiplied[0],0.64,accuracy:0.015); XCTAssertEqual(multiplied[1],0.04,accuracy:0.015)
    }
    func testShapeModeRendersAdditionalLayerContours() throws {
        let renderer = try MetalRenderer(); var r = GenerationRecipe(); r.mode = .shape; r.shapeDisplay = .solid
        r.setLayer(0) {$0.enabled = false}
        r.setLayer(2) {$0.source = SourceReference(name:"第二组形状",thumbnail:Data()); $0.opacity = 1}
        var scene = SceneGenerator.generate(r)
        scene.shapes = [SceneShape(id:128,layer:2,center:SIMD2(0.5,0.5),contour:[SIMD2(0.1,0.1),SIMD2(0.9,0.1),SIMD2(0.9,0.9),SIMD2(0.1,0.9)],color:.init(1,0,0),opacity:1,gradient:0)]
        let image = try renderer.image(scene:scene,width:64,height:64), bytes = Array(image.dataProvider!.data! as Data), index = (32*64+32)*4
        XCTAssertLessThan(bytes[index],40); XCTAssertEqual(bytes[index],bytes[index+1]); XCTAssertEqual(bytes[index+1],bytes[index+2])
    }
    func testMultiLayerOrganicCropMatchesFullOutput() throws {
        let renderer = try MetalRenderer(); var r = GenerationRecipe(); r.apply(.weathered)
        for layer in 1..<3 {r.setLayer(layer) {$0.source = SourceReference(name:"palette",thumbnail:Data()); $0.blockOpacity = 0.7; $0.blockBlend = .overlay}}
        let scene = SceneGenerator.generate(r), full = try renderer.image(scene:scene,width:512,height:512), crop = try renderer.image(scene:scene,width:256,height:256,crop:.init(x:0.25,y:0.25,width:0.5,height:0.5))
        let a = Array(full.dataProvider!.data! as Data), b = Array(crop.dataProvider!.data! as Data)
        var error = 0
        for y in 0..<256 {for x in 0..<256 {for c in 0..<4 {if abs(Int(a[((y+128)*512+x+128)*4+c])-Int(b[(y*256+x)*4+c]))>2 {error += 1}}}}
        XCTAssertLessThan(error,100)
    }
    private func temporaryDirectory() throws -> URL {let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url}
    private func fixture(_ url:URL,width:Int,height:Int,draw:(CGContext)->Void) throws {
        let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(c)
        let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(dest,c.makeImage()!,nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
