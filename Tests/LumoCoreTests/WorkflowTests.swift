import XCTest
import CoreGraphics
import ImageIO
import simd
@testable import LumoCore

final class WorkflowTests: XCTestCase {
    private func source(_ color: CGColor? = nil) throws -> SourceReference {
        let context=CGContext(data:nil,width:128,height:128,bitsPerComponent:8,bytesPerRow:0,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        if let color {context.setFillColor(color); context.fill(CGRect(x:0,y:0,width:128,height:128))}
        else {
            for y in 0..<16 {for x in 0..<16 {
                context.setFillColor(CGColor(srgbRed:Double(x)/15,green:Double(y)/15,blue:Double((x+y)%5)/4,alpha:1))
                context.fill(CGRect(x:x*8,y:y*8,width:8,height:8))
            }}
        }
        let data=try ReferencePixels.png(context.makeImage()!)
        return try ReferenceAnalyzer.analyze(data:data,name:"参考",forColor:true)
    }
    private func deconstruction() throws -> GenerationRecipe {
        var recipe=GenerationRecipe()
        recipe.method = .deconstruction; recipe.colorSource=try source()
        recipe.version=recipe.currentVersion
        return recipe
    }

    func testOrganicCutsSharePixelsWhenReassembledAndChangeVisibleContours() throws {
        let renderer=try MetalRenderer()
        var recipe=try deconstruction()
        recipe.deconstruction.breakup=0
        recipe.deconstruction.granularity=1
        for seed in [UInt64(2),42,181,0xBEEF_31] {
            recipe.shapeSeed=seed
            for aspect in [0.5,1,2] {
                recipe.canvasAspect=aspect
                recipe.deconstruction.organicCuts=false
                let straight=SceneGenerator.generate(recipe)
                recipe.deconstruction.organicCuts=true
                let cracked=SceneGenerator.generate(recipe)
                XCTAssertTrue(cracked.fragments.allSatisfy {$0.triangles?.isEmpty == false})
                XCTAssertNotEqual(cracked.fragments.map(\.contour),straight.fragments.map(\.contour))
                let size=ExportSettings.dimensions(aspect:aspect,longEdge:256)
                let a=try renderer.image(scene:straight,width:size.width,height:size.height)
                let b=try renderer.image(scene:cracked,width:size.width,height:size.height)
                let x=Array(a.dataProvider!.data! as Data), y=Array(b.dataProvider!.data! as Data)
                let difference=zip(x,y).filter {abs(Int($0)-Int($1))>2}.count
                XCTAssertLessThanOrEqual(difference,4,"Source must remain whole; aspect \\(aspect), seed \\(seed)")
            }
        }
    }

    func testSpacingMovesCentersWithoutScalingAndPinsSurviveGlobalTransforms() throws {
        var recipe=try deconstruction()
        let original=SceneGenerator.generate(recipe)
        recipe.deconstruction.spacing=1
        let spaced=SceneGenerator.generate(recipe)
        XCTAssertNotEqual(original.fragments.map(\.center),spaced.fragments.map(\.center))
        for (a,b) in zip(original.fragments,spaced.fragments) {
            XCTAssertEqual(a.textureCoordinates,b.textureCoordinates)
            for (p,q) in zip(a.contour,b.contour) {
                XCTAssertLessThan(simd_length((p-a.center)-(q-b.center)),0.000002)
            }
        }

        let anchor=try XCTUnwrap(spaced.fragments.first)
        var pinned=FragmentAdjustment(); pinned.pinned=anchor; pinned.pinnedAspect=recipe.canvasAspect
        recipe.arrangement.fragments[anchor.id]=pinned
        let moved=try XCTUnwrap(spaced.fragments.dropFirst().first)
        let offset=SIMD2<Float>(0.08,-0.05)
        recipe.arrangement.fragments[moved.id,default:FragmentAdjustment()].offset=offset
        let hidden=try XCTUnwrap(spaced.fragments.dropFirst(2).first)
        recipe.arrangement.fragments[hidden.id,default:FragmentAdjustment()].hidden=true
        let edited=SceneGenerator.generate(recipe)
        XCTAssertEqual(edited.fragments.first {$0.id==moved.id}?.center,moved.center+offset)
        XCTAssertFalse(edited.fragments.contains {$0.id==hidden.id})
        recipe.deconstruction.rotation=1; recipe.deconstruction.overlap=0.21
        let adjusted=SceneGenerator.generate(recipe)
        XCTAssertEqual(adjusted.fragments.first {$0.id==anchor.id},anchor)
        XCTAssertNotEqual(adjusted.fragments.first {$0.id==moved.id},edited.fragments.first {$0.id==moved.id})
        recipe.version=recipe.currentVersion
        var project=LumoProject(); project.recipe=recipe
        let url=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString+".lumo")
        defer {try? FileManager.default.removeItem(at:url)}
        try ProjectStore.save(project,to:url)
        XCTAssertEqual(SceneGenerator.generate(try ProjectStore.open(url).recipe),adjusted)
    }

    func testLayerSettingsAndOrderAreIndependentOfPartition() throws {
        var recipe=try deconstruction()
        let red=try source(CGColor(srgbRed:1,green:0,blue:0,alpha:1))
        let blue=try source(CGColor(srgbRed:0,green:0,blue:1,alpha:1))
        recipe.setLayer(0) {$0.source=red}
        recipe.setLayer(1) {$0.source=blue; $0.opacity=1; $0.blend = .normal}
        recipe.deconstruction.breakup=0
        let original=SceneGenerator.generate(recipe)
        let renderer=try MetalRenderer()
        func rgb(_ scene: AbstractScene) throws -> [UInt8] {
            let image=try renderer.image(scene:scene,width:64,height:64)
            return Array((image.dataProvider!.data! as Data).prefix(3))
        }
        XCTAssertEqual(try rgb(original),[255,0,0])
        recipe.arrangement.layerOrder=[1,0,2]
        let reversed=SceneGenerator.generate(recipe)
        XCTAssertEqual(reversed.fragments,original.fragments)
        XCTAssertEqual(try rgb(reversed),[0,0,255])
        XCTAssertEqual(reversed.fragment(at:SIMD2<Float>(0.5,0.5))?.layer,0)

        var layer=LayerDeconstruction(parameters:recipe.deconstruction)
        layer.lockedShapeSeed=recipe.shapeSeed; layer.lockedColorSeed=recipe.colorSeed
        recipe.arrangement.layers[0]=layer
        recipe.deconstruction.breakup=0.83; recipe.shapeSeed &+= 1; recipe.colorSeed &+= 1
        let changed=SceneGenerator.generate(recipe)
        XCTAssertEqual(changed.fragments.filter {$0.layer==0},original.fragments.filter {$0.layer==0})
        XCTAssertNotEqual(changed.fragments.filter {$0.layer==1},original.fragments.filter {$0.layer==1})
    }

    func testBinaryArchiveRejectsTruncatedAndOversizedEntries() throws {
        var project=LumoProject(); project.recipe=try deconstruction()
        let data=try ProjectStore.documentData(project)
        XCTAssertTrue(data.starts(with:Data("LUMO3BIN".utf8)))
        XCTAssertEqual(data.count,try ProjectStore.storageSize(project))
        let url=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString+".lumo")
        defer {try? FileManager.default.removeItem(at:url)}
        try data.write(to:url)
        XCTAssertEqual(try ProjectStore.open(url),project)
        try Data(data.dropLast()).write(to:url)
        XCTAssertThrowsError(try ProjectStore.open(url))
        var broken=data
        broken.replaceSubrange(8..<16,with:[UInt8](repeating:255,count:8))
        try broken.write(to:url)
        XCTAssertThrowsError(try ProjectStore.open(url))
    }

    func testTransparentLineExportUsesMaskInFullAndCroppedPNG() throws {
        let renderer=try MetalRenderer()
        let ref=try source()
        var parameters=LineExtractionParameters(); parameters.enabled=true; parameters.overlayOriginal=true
        var scene=AbstractScene.linePreview(input:ref,aspect:1,parameters:parameters)
        scene.lineMask=try renderer.prepareLines(scene:scene)
        let opaque=try renderer.image(scene:scene,width:128,height:128)
        let transparent=try renderer.image(scene:scene,width:128,height:128,transparentLines:true)
        let a=Array(opaque.dataProvider!.data! as Data), b=Array(transparent.dataProvider!.data! as Data)
        let alpha=stride(from:3,to:b.count,by:4).map {b[$0]}
        XCTAssertTrue(stride(from:3,to:a.count,by:4).allSatisfy {a[$0]==255})
        XCTAssertTrue(alpha.contains(0)); XCTAssertTrue(alpha.contains {$0>0 && $0<255})
        XCTAssertTrue(stride(from:0,to:b.count,by:4).allSatisfy {b[$0]==0 && b[$0+1]==0 && b[$0+2]==0})
        var settings=ExportSettings(); settings.transparentLines=true
        settings.crop=CropRegion(x:0.25,y:0.25,width:0.5,height:0.25); settings.width=64; settings.height=32
        let url=FileManager.default.temporaryDirectory.appending(path:UUID().uuidString+".png")
        defer {try? FileManager.default.removeItem(at:url)}
        try renderer.export(scene:scene,settings:settings,to:url)
        let decoded=try ReferencePixels(data:Data(contentsOf:url))
        XCTAssertEqual(decoded.width,64); XCTAssertEqual(decoded.height,32)
        let rgba=decoded.rgbaBytes
        for y in 0..<32 {for x in 0..<64 {
            XCTAssertEqual(rgba[(y*64+x)*4+3],alpha[(y+32)*128+x+32],accuracy:1)
        }}
    }
}
