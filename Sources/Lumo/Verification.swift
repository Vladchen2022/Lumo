import Foundation
import AppKit
import Metal
import ImageIO
import UniformTypeIdentifiers
import LumoCore

enum Verification {
    struct Report:Codable {var frames:Int; var medianMilliseconds:Double; var p95Milliseconds:Double; var worstMilliseconds:Double; var gpuMedianMilliseconds:Double; var gpu:String; var exports:[String]; var workflow:String}
    static func run() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/verification",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try createFixtures(root)
        let colorURL=root.appendingPathComponent("color-reference.png"), shapeURL=root.appendingPathComponent("shape-reference.png")
        let color=try ReferenceAnalyzer.analyze(url:colorURL,forColor:true)
        let secondURL=root.appendingPathComponent("cool-reference.png"), thirdURL=root.appendingPathComponent("accent-reference.png")
        let second=try ReferenceAnalyzer.analyze(url:secondURL,forColor:true), third=try ReferenceAnalyzer.analyze(url:thirdURL,forColor:true)
        let shape=try ReferenceAnalyzer.analyze(url:shapeURL,forColor:false)
        var project=LumoProject()
        project.recipe.colorSource=color; project.recipe.shapeSource=shape; project.recipe.shape=ShapeParameters(features:shape.features!)
        project.recipe.setLayer(1) {$0.source=second; $0.opacity=0.6; $0.blend = .softLight; $0.blockOpacity=0.75; $0.blockBlend = .overlay}
        let accent=try ReferencePixels.originalColor(url:thirdURL,x:0.785,y:0.195)!
        project.recipe.setLayer(2) {$0.source=third; $0.opacity=0.55; $0.blend = .overlay; $0.blockBlend = .softLight; $0.paletteOverrides[5]=accent; $0.weightOverrides[5]=0.18}
        project.recipe.shape.organic=0.7; project.recipe.shape.erosion=0.65
        project.recipe.color.hue=24; project.recipe.shape.curvature=0.62; project.recipe.colorLocked=true
        let originalColorSeed=project.recipe.colorSeed
        project.recipe.randomizeColor(); project.recipe.randomizeShape()
        guard project.recipe.colorSeed == originalColorSeed else {throw LumoError.message("锁定测试失败")}
        project.snapshots=[SavedSnapshot(name:"参考练习",recipe:project.recipe)]
        let file=root.appendingPathComponent("workflow.lumo")
        try ProjectStore.save(project,to:file)
        let expected=SceneGenerator.generate(project.recipe)
        try FileManager.default.removeItem(at:colorURL); try FileManager.default.removeItem(at:shapeURL); try FileManager.default.removeItem(at:secondURL); try FileManager.default.removeItem(at:thirdURL)
        let restored=try ProjectStore.open(file)
        guard restored.recipe == project.recipe, SceneGenerator.generate(restored.recipe) == expected else {throw LumoError.message("保存恢复测试失败")}
        let renderer=try MetalRenderer()
        var exported:[String]=[]
        for mode in DisplayMode.allCases {
            var r=restored.recipe; r.mode=mode
            var settings=ExportSettings(); settings.width=1024; settings.height=1024
            let name="\(mode.rawValue).png"
            try renderer.export(scene:SceneGenerator.generate(r),settings:settings,to:root.appendingPathComponent(name)); exported.append(name)
        }
        var solid=restored.recipe; solid.mode = .shape; solid.shapeDisplay = .solid
        var small=ExportSettings(); small.width=1024; small.height=1024
        try renderer.export(scene:SceneGenerator.generate(solid),settings:small,to:root.appendingPathComponent("solid.png")); exported.append("solid.png")
        var crop=ExportSettings(); crop.width=2048; crop.height=1536; crop.crop=CropRegion.centered(outputAspect:4.0/3,canvasAspect:1,fraction:0.45)
        try renderer.export(scene:expected,settings:crop,to:root.appendingPathComponent("crop.png")); exported.append("crop.png")
        var large=ExportSettings(); large.width=4096; large.height=4096; large.format = .jpeg
        try renderer.export(scene:expected,settings:large,to:root.appendingPathComponent("full-4096.jpg")); exported.append("full-4096.jpg")
        for name in exported {
            let url=root.appendingPathComponent(name)
            guard let source=CGImageSourceCreateWithURL(url as CFURL,nil), let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],properties[kCGImagePropertyProfileName as String] != nil else {throw LumoError.message("\(name) 缺少色彩配置")}
        }
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:1536,height:1536,mipmapped:false)
        descriptor.usage = .renderTarget; descriptor.storageMode = .private
        let texture=renderer.device.makeTexture(descriptor:descriptor)!
        var samples:[Double]=[], gpuSamples:[Double]=[]
        for frame in 0..<130 {
            var r=project.recipe; r.shape.direction=Double(frame)*1.1; r.shape.curvature=Double(frame%100)/100
            // Exercise the densest combined scene, including every contour and outline.
            r.shape.density=1; r.mode = .combined
            let start=CFAbsoluteTimeGetCurrent()
            let scene=SceneGenerator.generate(r)
            let command=renderer.queue.makeCommandBuffer()!
            let pass=MTLRenderPassDescriptor(); pass.colorAttachments[0].texture=texture; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            try renderer.encode(scene:scene,viewport:CGRect(x:0,y:0,width:1,height:1),pass:pass,command:command)
            command.commit(); command.waitUntilCompleted()
            if let error=command.error {throw error}
            if frame>=10 {samples.append((CFAbsoluteTimeGetCurrent()-start)*1000); gpuSamples.append((command.gpuEndTime-command.gpuStartTime)*1000)}
        }
        samples.sort(); gpuSamples.sort()
        let report=Report(frames:samples.count,medianMilliseconds:samples[samples.count/2],p95Milliseconds:samples[Int(Double(samples.count)*0.95)],worstMilliseconds:samples.last!,gpuMedianMilliseconds:gpuSamples[gpuSamples.count/2],gpu:renderer.device.name,exports:exported,workflow:"导入三张颜色参考与结构参考 → 手动取色 → 有机与侵蚀调节 → 分层混合 → 锁定颜色随机结构 → 收藏 → 保存 → 删除原图 → 重新打开 → 局部与整图导出：通过")
        let encoder=JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:root.appendingPathComponent("report.json"))
        try createFixtures(root)
        print(String(data:try encoder.encode(report),encoding:.utf8)!)
        guard report.p95Milliseconds<33.33 else {throw LumoError.message("性能验收未通过：p95 超过 33.33 ms")}
    }
    private static func createFixtures(_ root:URL) throws {
        func write(_ name:String,draw:(CGContext)->Void) throws {
            let context=CGContext(data:nil,width:640,height:480,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            draw(context)
            let image=context.makeImage()!
            let url=root.appendingPathComponent(name)
            let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
            CGImageDestinationAddImage(destination,image,nil)
            guard CGImageDestinationFinalize(destination) else {throw LumoError.message("无法创建测试参考图")}
        }
        try write("color-reference.png") {c in
            c.setFillColor(CGColor(srgbRed:0.93,green:0.86,blue:0.72,alpha:1)); c.fill(CGRect(x:0,y:0,width:640,height:480))
            c.setFillColor(CGColor(srgbRed:0.88,green:0.27,blue:0.17,alpha:1)); c.fill(CGRect(x:0,y:0,width:180,height:480))
            c.setFillColor(CGColor(srgbRed:0.15,green:0.43,blue:0.44,alpha:1)); c.fill(CGRect(x:260,y:0,width:160,height:330))
            c.setFillColor(CGColor(srgbRed:0.94,green:0.64,blue:0.21,alpha:1)); c.fillEllipse(in:CGRect(x:420,y:160,width:180,height:180))
        }
        try write("cool-reference.png") {c in
            c.setFillColor(CGColor(srgbRed:0.77,green:0.84,blue:0.88,alpha:1)); c.fill(CGRect(x:0,y:0,width:640,height:480))
            c.setFillColor(CGColor(srgbRed:0.13,green:0.24,blue:0.48,alpha:1)); c.fill(CGRect(x:60,y:80,width:300,height:310))
            c.setFillColor(CGColor(srgbRed:0.32,green:0.60,blue:0.64,alpha:1)); c.fillEllipse(in:CGRect(x:250,y:100,width:340,height:190))
            c.setFillColor(CGColor(srgbRed:0.63,green:0.57,blue:0.77,alpha:1)); c.fill(CGRect(x:430,y:300,width:180,height:150))
        }
        try write("accent-reference.png") {c in
            c.setFillColor(CGColor(srgbRed:0.85,green:0.79,blue:0.67,alpha:1)); c.fill(CGRect(x:0,y:0,width:640,height:480))
            c.setFillColor(CGColor(srgbRed:0.35,green:0.20,blue:0.12,alpha:1)); c.fillEllipse(in:CGRect(x:60,y:80,width:400,height:270))
            c.setFillColor(CGColor(srgbRed:0.64,green:0.36,blue:0.19,alpha:1)); c.fill(CGRect(x:300,y:40,width:220,height:240))
            c.setFillColor(CGColor(srgbRed:0.91,green:0.12,blue:0.61,alpha:1)); c.fill(CGRect(x:500,y:380,width:8,height:8))
        }
        try write("shape-reference.png") {c in
            c.setFillColor(CGColor(gray:1,alpha:1)); c.fill(CGRect(x:0,y:0,width:640,height:480))
            c.setFillColor(CGColor(gray:0.08,alpha:1)); c.fillEllipse(in:CGRect(x:50,y:300,width:120,height:120))
            c.fill(CGRect(x:80,y:140,width:60,height:170)); c.fill(CGRect(x:65,y:40,width:25,height:120)); c.fill(CGRect(x:125,y:40,width:25,height:120))
            c.fill(CGRect(x:300,y:40,width:130,height:300)); c.fill(CGRect(x:460,y:40,width:120,height:230))
            c.setFillColor(CGColor(gray:1,alpha:1)); for x in stride(from:320,through:400,by:30) {for y in stride(from:70,through:290,by:40) {c.fill(CGRect(x:x,y:y,width:15,height:22))}}
        }
    }
}
