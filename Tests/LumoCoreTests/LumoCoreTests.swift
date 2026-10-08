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
        recipe.removeValue(forKey:"method"); recipe.removeValue(forKey:"deconstruction")
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
    func testDeconstructionPartitionsEntireImageAndSlidersReturn() throws {
        let root = try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        let url = root.appendingPathComponent("source.png")
        try fixture(url,width:240,height:160) {c in c.setFillColor(CGColor(srgbRed:0.2,green:0.5,blue:0.8,alpha:1)); c.fill(CGRect(x:0,y:0,width:240,height:160))}
        var r = GenerationRecipe(); r.colorSource = try ReferenceAnalyzer.analyze(url:url,forColor:true)
        let abstract = SceneGenerator.generate(r)
        r.method = .deconstruction; r.version = 3
        let original = SceneGenerator.generate(r)
        XCTAssertEqual(original,SceneGenerator.generate(r)); XCTAssertTrue(original.shapes.isEmpty)
        for amount in [0.0,0.4,1.0] {
            r.deconstruction.granularity = amount
            let scene = SceneGenerator.generate(r)
            XCTAssertEqual(scene.fragments.count,r.deconstruction.fragmentCount)
            let area = scene.fragments.reduce(0.0) {total,fragment in
                let p = fragment.textureCoordinates
                let twice = p.indices.reduce(0.0) {sum,i in let j = (i+1)%p.count; return sum+Double(p[i].x*p[j].y-p[j].x*p[i].y)}
                return total+abs(twice)/2
            }
            XCTAssertEqual(area,1,accuracy:0.00001)
        }
        r.deconstruction = DeconstructionParameters(); r.deconstruction.breakup = 0.5001
        let next = SceneGenerator.generate(r)
        XCTAssertEqual(original.fragments.map(\.textureCoordinates),next.fragments.map(\.textureCoordinates))
        for (a,b) in zip(original.fragments,next.fragments) {for (p,q) in zip(a.contour,b.contour) {XCTAssertLessThan(hypot(p.x-q.x,p.y-q.y),0.001)}}
        r.deconstruction.breakup = 0.5; XCTAssertEqual(original,SceneGenerator.generate(r))
        var order = r; order.colorSeed &+= 1
        XCTAssertEqual(Dictionary(uniqueKeysWithValues:original.fragments.map {($0.id,$0.contour)}),Dictionary(uniqueKeysWithValues:SceneGenerator.generate(order).fragments.map {($0.id,$0.contour)}))
        XCTAssertNotEqual(original.fragments.map(\.id),SceneGenerator.generate(order).fragments.map(\.id))
        var grouped = r; grouped.deconstruction.grouping = 1; grouped.deconstruction.sizeVariation = 0; grouped.deconstruction.overlap = 0.5
        grouped.deconstruction.rotation = 0.8; grouped.deconstruction.breakup = 0.8
        let together = SceneGenerator.generate(grouped)
        grouped.deconstruction.breakup = 0
        let assembled = SceneGenerator.generate(grouped)
        func group(_ f: ImageFragment) -> Int {min(2,Int(f.sourceCenter.y*3))*3+min(2,Int(f.sourceCenter.x*3))}
        for i in together.fragments.indices {for j in together.fragments.indices where j>i && group(together.fragments[i]) == group(together.fragments[j]) {
            let a = together.fragments[i].center-together.fragments[j].center, b = assembled.fragments[i].center-assembled.fragments[j].center
            XCTAssertEqual(hypot(a.x,a.y),hypot(b.x,b.y),accuracy:0.00001,"Group rotation must preserve local distances")
        }}
        r.deconstruction.softness = 0.9
        r.method = .abstract; r.version = 1; XCTAssertEqual(abstract,SceneGenerator.generate(r))
    }
    func testGPUDeconstructionZeroBreakupReconstructsPixelsWithoutSeams() throws {
        let root = try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        let url = root.appendingPathComponent("pattern.png")
        try fixture(url,width:256,height:192) {c in
            c.setFillColor(CGColor(srgbRed:0.12,green:0.33,blue:0.74,alpha:1)); c.fill(CGRect(x:0,y:0,width:256,height:192))
            c.setFillColor(CGColor(srgbRed:0.86,green:0.23,blue:0.11,alpha:1)); c.fill(CGRect(x:0,y:96,width:128,height:96))
            c.setFillColor(CGColor(srgbRed:0.2,green:0.72,blue:0.3,alpha:1)); c.fill(CGRect(x:128,y:0,width:128,height:96))
            c.setFillColor(CGColor(srgbRed:1,green:0,blue:1,alpha:1)); c.fill(CGRect(x:201,y:51,width:1,height:1))
        }
        var r = GenerationRecipe(); r.colorSource = try ReferenceAnalyzer.analyze(url:url,forColor:true)
        r.method = .deconstruction; r.version = 3; r.canvasAspect = 4.0/3
        r.color.hue = 135; r.setLayer(0) {$0.paletteOverrides[0] = .init(0,0,0)}
        r.deconstruction.breakup = 0; r.deconstruction.softness = 1
        let renderer = try MetalRenderer()
        let expected = try ReferencePixels(data:r.colorSource!.deconstructionImage).rgbaBytes
        for expanded in [false,true] {for density in [0.0,0.45,1.0] {
            r.deconstruction.expandedTransforms=expanded; r.version=expanded ? 3 : 2
            r.deconstruction.rotation=1; r.deconstruction.sizeVariation=1
            r.deconstruction.granularity = density
            let image = try renderer.image(scene:SceneGenerator.generate(r),width:256,height:192)
            let actual = Array(image.dataProvider!.data! as Data)
            var differences = 0
            for i in stride(from:0,to:actual.count,by:4) {for (a,b) in [(i,i+2),(i+1,i+1),(i+2,i),(i+3,i+3)] {if abs(Int(actual[a])-Int(expected[b])) > 2 {differences += 1}}}
            XCTAssertLessThan(differences,20,"Every source pixel, including the one-pixel accent, must reassemble without holes or flips")
        }}
    }
    func testDeconstructionThreeLayersOfflinePersistenceAndCrop() throws {
        let root = try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        var project = LumoProject(); project.recipe.method = .deconstruction; project.recipe.version = 3
        project.recipe.deconstruction.softness = 1; project.recipe.deconstruction.granularity = 1
        for layer in 0..<3 {
            let url = root.appendingPathComponent("layer\(layer).png")
            try fixture(url,width:200,height:200) {c in
                c.setFillColor(CGColor(srgbRed:Double(layer+1)*0.25,green:0.4,blue:0.7,alpha:0.6)); c.fill(CGRect(x:0,y:0,width:200,height:200))
                c.setFillColor(CGColor(srgbRed:0.8,green:0.2,blue:Double(layer)*0.3,alpha:1)); c.fillEllipse(in:CGRect(x:25,y:20,width:130,height:130))
            }
            let reference = try ReferenceAnalyzer.analyze(url:url,forColor:true)
            project.recipe.setLayer(layer) {$0.source = reference; $0.blend = layer == 0 ? .normal : .softLight; $0.blockBlend = .overlay; $0.blockOpacity = 0.75}
            try FileManager.default.removeItem(at:url)
        }
        project.snapshots = [SavedSnapshot(name:"解构收藏",recipe:project.recipe)]
        let path = root.appendingPathComponent("deconstruction.lumo"); try ProjectStore.save(project,to:path)
        let restored = try ProjectStore.open(path)
        XCTAssertEqual(restored.recipe,project.recipe); XCTAssertEqual(restored.snapshots[0].recipe,project.recipe)
        let renderer = try MetalRenderer(), scene = SceneGenerator.generate(restored.recipe)
        XCTAssertEqual(scene.fragments.count,3*project.recipe.deconstruction.fragmentCount)
        let full = try renderer.image(scene:scene,width:512,height:512), crop = try renderer.image(scene:scene,width:256,height:256,crop:.init(x:0.25,y:0.25,width:0.5,height:0.5))
        let a = Array(full.dataProvider!.data! as Data), b = Array(crop.dataProvider!.data! as Data)
        var differences = 0
        for y in 0..<256 {for x in 0..<256 {for channel in 0..<4 {if abs(Int(a[((y+128)*512+x+128)*4+channel])-Int(b[(y*256+x)*4+channel]))>2 {differences += 1}}}}
        XCTAssertLessThan(differences,100)
        var invalid = project; invalid.recipe.deconstruction.rotation = .nan
        XCTAssertThrowsError(try ProjectStore.validate(invalid))
        invalid = project; invalid.recipe.version = 1; XCTAssertThrowsError(try ProjectStore.validate(invalid))
        var oldReference = restored.recipe; oldReference.setLayer(0) {$0.source!.renderImage = nil}
        XCTAssertEqual(oldReference.colorSource!.deconstructionImage,oldReference.colorSource!.samplingImage)
    }
    func testGPUDeconstructionTransparencyUsesLinearCompositing() throws {
        let root = try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        let url = root.appendingPathComponent("alpha.png")
        try fixture(url,width:64,height:64) {c in c.setFillColor(CGColor(srgbRed:0.8,green:0.2,blue:0.4,alpha:0.5)); c.fill(CGRect(x:0,y:0,width:32,height:64))}
        var r = GenerationRecipe(); r.method = .deconstruction; r.version = 3; r.deconstruction.breakup = 0
        r.colorSource = try ReferenceAnalyzer.analyze(url:url,forColor:true)
        let scene = SceneGenerator.generate(r), renderer = try MetalRenderer()
        let image = try renderer.image(scene:scene,width:64,height:64), bytes = Array(image.dataProvider!.data! as Data)
        let left = (32*64+16)*4, right = (32*64+48)*4
        for (offset,value) in [(2,scene.background.r),(1,scene.background.g),(0,scene.background.b)] {XCTAssertEqual(Double(bytes[right+offset])/255,value,accuracy:0.005)}
        let base = scene.background.linear, source = RGBColor(0.8,0.2,0.4).linear
        for (offset,channel) in [(2,0),(1,1),(0,2)] {
            let linear = Double((base[channel]+source[channel])/2)
            let expected = linear <= 0.0031308 ? linear*12.92 : 1.055*pow(linear,1/2.4)-0.055
            XCTAssertEqual(Double(bytes[left+offset])/255,expected,accuracy:0.015)
        }
    }
    func testExpandedFragmentRangesAndLegacyRecipes() throws {
        let root=try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("range.png")
        try fixture(url,width:200,height:200) {c in c.setFillColor(CGColor(srgbRed:0.8,green:0.3,blue:0.1,alpha:1)); c.fill(CGRect(x:0,y:0,width:200,height:200))}
        var r=GenerationRecipe(); r.method = .deconstruction; r.version=3
        r.colorSource=try ReferenceAnalyzer.analyze(url:url,forColor:true)
        r.deconstruction.granularity=1; r.deconstruction.breakup=0.39
        r.deconstruction.grouping=0; r.deconstruction.rotation=0; r.deconstruction.sizeVariation=0; r.deconstruction.overlap=1
        let original=SceneGenerator.generate(r)
        func headings(_ scene:AbstractScene) -> [Int:Double] {
            Dictionary(uniqueKeysWithValues:scene.fragments.map {f in
                let v=f.contour[1]-f.contour[0]; return (f.id,atan2(Double(v.y),Double(v.x)))
            })
        }
        var previous=headings(original), turns=[Int:Double]()
        for step in 1...40 {
            r.deconstruction.rotation=Double(step)/40
            let angles=headings(SceneGenerator.generate(r))
            for (id,angle) in angles {
                let difference=angle-previous[id]!
                turns[id,default:0]+=atan2(sin(difference),cos(difference))
            }
            previous=angles
        }
        XCTAssertGreaterThan(turns.values.map {abs($0)*180 / .pi}.max()!,330,"Rotation must allow almost a complete turn at only 39% breakup")
        XCTAssertLessThanOrEqual(turns.values.map {abs($0)}.max()!,2 * .pi+0.0001)
        r.deconstruction.rotation=0; XCTAssertEqual(SceneGenerator.generate(r),original)
        r.deconstruction.grouping=0.42
        let baseline=SceneGenerator.generate(r)
        func area(_ points:[SIMD2<Float>]) -> Double {
            abs(points.indices.reduce(0.0) {sum,i in let j=(i+1)%points.count; return sum+Double(points[i].x)*Double(points[j].y)-Double(points[j].x)*Double(points[i].y)})/2
        }
        let originalAreas=Dictionary(uniqueKeysWithValues:baseline.fragments.map {($0.id,area($0.contour))})
        r.deconstruction.sizeVariation=1
        let wide=SceneGenerator.generate(r)
        let scales=wide.fragments.map {sqrt(area($0.contour)/originalAreas[$0.id]!)}
        XCTAssertLessThan(scales.min()!,0.18); XCTAssertGreaterThan(scales.max()!,2.7)
        XCTAssertGreaterThan(scales.max()!/scales.min()!,15,"Small and large pieces must have substantially different scales")
        r.deconstruction.sizeVariation=0; XCTAssertEqual(SceneGenerator.generate(r),baseline)
        r.deconstruction.sizeVariation=1; r.deconstruction.breakup=0
        let reassembled=SceneGenerator.generate(r)
        r.deconstruction.rotation=1; r.deconstruction.sizeVariation=0; r.deconstruction.overlap=0
        XCTAssertEqual(reassembled,SceneGenerator.generate(r),"Zero breakup must restore source geometry regardless of rotation or scale")

        var old=r; old.version=2; old.deconstruction.expandedTransforms=false; old.deconstruction.breakup=0.39
        var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(old)) as! [String:Any]
        var parameters=json["deconstruction"] as! [String:Any]; parameters.removeValue(forKey:"expandedTransforms"); json["deconstruction"]=parameters
        let restored=try JSONDecoder().decode(GenerationRecipe.self,from:JSONSerialization.data(withJSONObject:json))
        XCTAssertFalse(restored.deconstruction.expandedTransforms)
        XCTAssertEqual(SceneGenerator.generate(old),SceneGenerator.generate(restored),"0.3 recipes must keep their existing geometry")
        var project=LumoProject(); project.recipe=restored
        XCTAssertNoThrow(try ProjectStore.validate(project))
        project.recipe=r; project.recipe.deconstruction.expandedTransforms=true; project.recipe.version=3
        let saved=root.appendingPathComponent("expanded.lumo"); try ProjectStore.save(project,to:saved)
        XCTAssertEqual(try ProjectStore.open(saved).recipe,project.recipe)
    }
    func testFreeRectangleDrawingEdgesMovementAndOutputDimensions() throws {
        let crop=CropRegion.selecting(from:CGPoint(x:0.1,y:0.2),to:CGPoint(x:0.8,y:0.45))
        XCTAssertEqual(crop.width,0.7,accuracy:0.000001); XCTAssertEqual(crop.height,0.25,accuracy:0.000001)
        XCTAssertEqual(crop,CropRegion.selecting(from:CGPoint(x:0.8,y:0.45),to:CGPoint(x:0.1,y:0.2)))
        let right=crop.resized(.right,to:CGPoint(x:0.9,y:0.95))
        XCTAssertEqual(right.height,crop.height); XCTAssertEqual(right.y,crop.y); XCTAssertEqual(right.width,0.8,accuracy:0.000001)
        let top=crop.resized(.top,to:CGPoint(x:0.95,y:0.05))
        XCTAssertEqual(top.width,crop.width); XCTAssertEqual(top.x,crop.x); XCTAssertEqual(top.height,0.4,accuracy:0.000001)
        for handle in CropHandle.allCases {
            let resized=crop.resized(handle,to:CGPoint(x:-2,y:3))
            XCTAssertGreaterThan(resized.width,0); XCTAssertGreaterThan(resized.height,0)
            XCTAssertGreaterThanOrEqual(resized.x,0); XCTAssertGreaterThanOrEqual(resized.y,0)
            XCTAssertLessThanOrEqual(resized.x+resized.width,1.000001); XCTAssertLessThanOrEqual(resized.y+resized.height,1.000001)
        }
        let moved=crop.moved(by:CGSize(width:3,height:-3))
        XCTAssertEqual(moved.width,crop.width); XCTAssertEqual(moved.height,crop.height)
        XCTAssertEqual(moved.x+crop.width,1,accuracy:0.000001); XCTAssertEqual(moved.y,0)
        var invalid=LumoProject(); invalid.export.crop=CropRegion(x:0,y:0,width:1,height:1e-309)
        XCTAssertThrowsError(try ProjectStore.validate(invalid))
        for canvas in [0.75,1,16.0/9] {for shape in [crop,top,CropRegion(x:0.25,y:0.05,width:0.09,height:0.8)] {for edge in [1024,2048,4096,1733] {
            var p=LumoProject(); p.recipe.canvasAspect=canvas; p.export.crop=shape
            let aspect=shape.aspect(canvasAspect:canvas); p.export.matchAspect(aspect,longEdge:edge)
            XCTAssertEqual(max(p.export.width,p.export.height),edge)
            XCTAssertEqual(Double(p.export.width)/Double(p.export.height),aspect,accuracy:aspect/Double(min(p.export.width,p.export.height)))
            XCTAssertNoThrow(try ProjectStore.validate(p))
        }}}
    }
    func testGPUFreeRectangularCropMatchesSceneAndBothExportFormats() throws {
        let renderer=try MetalRenderer(); var recipe=GenerationRecipe(); recipe.canvasAspect=4.0/3
        let scene=SceneGenerator.generate(recipe), full=try renderer.image(scene:scene,width:640,height:480)
        let crop=CropRegion(x:0.125,y:0.25,width:0.5,height:0.25)
        let local=try renderer.image(scene:scene,width:320,height:120,crop:crop)
        let a=Array(full.dataProvider!.data! as Data), b=Array(local.dataProvider!.data! as Data)
        var differences=0
        for y in 0..<120 {for x in 0..<320 {for channel in 0..<4 {
            if abs(Int(a[((y+120)*640+x+80)*4+channel])-Int(b[(y*320+x)*4+channel]))>2 {differences+=1}
        }}}
        XCTAssertLessThan(differences,100,"A freely chosen rectangle must retain the same content and proportions")
        let root=try temporaryDirectory(); defer {try? FileManager.default.removeItem(at:root)}
        for format in ImageFormat.allCases {
            var settings=ExportSettings(); settings.crop=crop; settings.matchAspect(crop.aspect(canvasAspect:scene.aspect),longEdge:1024); settings.format=format
            let url=root.appendingPathComponent("free.\(format.rawValue)"); try renderer.export(scene:scene,settings:settings,to:url)
            let source=CGImageSourceCreateWithURL(url as CFURL,nil)!, props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as! [CFString:Any]
            XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int,1024); XCTAssertEqual(props[kCGImagePropertyPixelHeight] as? Int,384)
            XCTAssertNotNil(props[kCGImagePropertyProfileName])
        }
    }
    private func temporaryDirectory() throws -> URL {let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true); return url}
    private func fixture(_ url:URL,width:Int,height:Int,draw:(CGContext)->Void) throws {
        let c=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(c)
        let dest=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(dest,c.makeImage()!,nil); XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
