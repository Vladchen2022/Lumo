import Foundation
import Metal
import ImageIO
import LumoCore

enum DeconstructionVerification {
    static func run(projectURL: URL) throws {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/deconstruction-range",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var project = try ProjectStore.open(projectURL)
        project.recipe.method = .deconstruction; project.recipe.deconstruction.expandedTransforms = true; project.recipe.deconstruction.strongTransforms = true
        project.recipe.version = project.recipe.currentVersion
        project.recipe.deconstruction.granularity = 0.7
        project.recipe.deconstruction.breakup = 0.62
        project.recipe.deconstruction.rotation = 0.45
        project.recipe.deconstruction.overlap = 0.68
        project.recipe.deconstruction.softness = 0.08
        let renderer = try MetalRenderer()
        let scene = SceneGenerator.generate(project.recipe)
        guard (0..<3).allSatisfy({project.recipe.layer($0).source != nil}) else {throw LumoError.message("验证项目需要三张参考图。")}
        project.snapshots.insert(SavedSnapshot(name:"图像解构",recipe:project.recipe),at:0)
        let saved = root.appendingPathComponent("trial.lumo")
        try ProjectStore.save(project,to:saved)
        let restored = try ProjectStore.open(saved)
        guard restored.recipe == project.recipe, SceneGenerator.generate(restored.recipe) == scene else {throw LumoError.message("解构项目重建不一致。")}
        var settings = ExportSettings(); settings.width = 1024; settings.height = Int(1024/scene.aspect)
        try renderer.export(scene:scene,settings:settings,to:root.appendingPathComponent("mixed.png"))
        var original = project.recipe; original.deconstruction.breakup = 0
        try renderer.export(scene:SceneGenerator.generate(original),settings:settings,to:root.appendingPathComponent("reassembled.png"))
        settings.width = 1024; settings.height = 768; settings.crop = .centered(outputAspect:4.0/3,canvasAspect:scene.aspect,fraction:0.42)
        try renderer.export(scene:scene,settings:settings,to:root.appendingPathComponent("crop.png"))
        settings.width = 4096; settings.height = Int(4096/scene.aspect); settings.crop = nil; settings.format = .jpeg
        try renderer.export(scene:scene,settings:settings,to:root.appendingPathComponent("full-4096.jpg"))
        for (name,width,height) in [("mixed.png",1024,Int(1024/scene.aspect)),("reassembled.png",1024,Int(1024/scene.aspect)),("crop.png",1024,768),("full-4096.jpg",4096,Int(4096/scene.aspect))] {
            let url = root.appendingPathComponent(name)
            guard let input = CGImageSourceCreateWithURL(url as CFURL,nil), let properties = CGImageSourceCopyPropertiesAtIndex(input,0,nil) as? [CFString:Any],
                  properties[kCGImagePropertyPixelWidth] as? Int == width, properties[kCGImagePropertyPixelHeight] as? Int == height, properties[kCGImagePropertyProfileName] != nil else {throw LumoError.message("解构输出尺寸或色彩配置无效。")}
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:1536,height:Int(1536/scene.aspect),mipmapped:false)
        descriptor.storageMode = .private; descriptor.usage = .renderTarget
        let target = renderer.device.makeTexture(descriptor:descriptor)!
        var samples: [Double] = [], gpu: [Double] = []
        for frame in 0..<130 {
            var recipe = project.recipe; recipe.deconstruction.granularity = 1; recipe.deconstruction.breakup = Double(frame)/130; recipe.deconstruction.rotation = 0.7
            let start = CFAbsoluteTimeGetCurrent()
            let next = SceneGenerator.generate(recipe), command = renderer.queue.makeCommandBuffer()!
            let pass = MTLRenderPassDescriptor(); pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            try renderer.encode(scene:next,viewport:CGRect(x:0,y:0,width:scene.aspect,height:1),pass:pass,command:command)
            command.commit(); command.waitUntilCompleted()
            if let error = command.error {throw error}
            if frame >= 10 {samples.append((CFAbsoluteTimeGetCurrent()-start)*1000); gpu.append((command.gpuEndTime-command.gpuStartTime)*1000)}
        }
        samples.sort(); gpu.sort()
        let report: [String:Any] = ["gpu":renderer.device.name,"frames":samples.count,"layers":3,"fragmentsPerLayer":80,"medianMilliseconds":samples[samples.count/2],"p95Milliseconds":samples[Int(Double(samples.count)*0.95)],"gpuMedianMilliseconds":gpu[gpu.count/2],"exports":["mixed.png","reassembled.png","crop.png","full-4096.jpg"],"workflow":"三图原像素 → 解构调节 → 收藏保存 → 项目内图片恢复 → 整图与局部导出：通过"]
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:root.appendingPathComponent("report.json"),options:.atomic)
        print(String(data:data,encoding:.utf8)!)
        guard samples[Int(Double(samples.count)*0.95)] < 33.33 else {throw LumoError.message("解构离屏性能超过 33.33 ms。")}
    }
}

extension DeconstructionVerification {
    static func strongControls(projectURL:URL) throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("artifacts/strong-controls",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        var project=try ProjectStore.open(projectURL)
        project.recipe.lineExtraction.enabled=false; project.recipe.method = .deconstruction
        project.recipe.deconstruction.expandedTransforms=true; project.recipe.deconstruction.strongTransforms=true
        project.recipe.version=project.recipe.currentVersion
        project.recipe.deconstruction.granularity=0.58; project.recipe.deconstruction.breakup=0.2
        project.recipe.deconstruction.rotation=141.0/360; project.recipe.deconstruction.sizeVariation=0.65
        project.recipe.deconstruction.overlap=0.5; project.recipe.deconstruction.grouping=0.83; project.recipe.deconstruction.softness=0
        let base=project.recipe, renderer=try MetalRenderer()
        let controls:[(String,WritableKeyPath<GenerationRecipe,Double>)]=[("scatter",\.deconstruction.breakup),("size",\.deconstruction.sizeVariation),("overlap",\.deconstruction.overlap)]
        var comparisons:[[String:Any]]=[]
        let tileWidth=320, tileHeight=Int(320/base.canvasAspect)
        let contact=CGContext(data:nil,width:5*tileWidth,height:3*tileHeight,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (row,item) in controls.enumerated() {
            var endpoints:[[UInt8]]=[]
            for (column,value) in [0.0,0.25,0.5,0.75,1.0].enumerated() {
                var recipe=base; recipe[keyPath:item.1]=value
                let scene=SceneGenerator.generate(recipe)
                let image=try renderer.image(scene:scene,width:tileWidth,height:tileHeight)
                contact.draw(image,in:CGRect(x:column*tileWidth,y:(2-row)*tileHeight,width:tileWidth,height:tileHeight))
                if column==0 || column==4 {endpoints.append(Array(image.dataProvider!.data! as Data))}
                var settings=ExportSettings(); settings.width=1024; settings.height=Int(1024/base.canvasAspect)
                try renderer.export(scene:scene,settings:settings,to:root.appendingPathComponent("\(item.0)-\(Int(value*100)).png"))
                guard recipe.colorSeed==base.colorSeed,recipe.shapeSeed==base.shapeSeed else {throw LumoError.message("调节时种子发生变化。")}
            }
            var changed=0
            for i in stride(from:0,to:endpoints[0].count,by:4) {
                if (0..<3).contains(where:{abs(Int(endpoints[0][i+$0])-Int(endpoints[1][i+$0]))>12}) {changed+=1}
            }
            comparisons.append(["control":item.0,"changedPixelFraction":Double(changed)/Double(tileWidth*tileHeight)])
        }
        try ReferencePixels.png(contact.makeImage()!).write(to:root.appendingPathComponent("slider-comparison.png"),options:.atomic)
        project.snapshots.insert(SavedSnapshot(name:"强化调节起点",recipe:base),at:0)
        let path=root.appendingPathComponent("强化调节验证.lumo")
        try ProjectStore.save(project,to:path)
        let restored=try ProjectStore.open(path)
        guard restored.recipe==base,SceneGenerator.generate(restored.recipe)==SceneGenerator.generate(base) else {throw LumoError.message("新范围保存重建不一致。")}
        var settings=ExportSettings(); settings.matchAspect(2.4,longEdge:2048)
        settings.crop = .centered(outputAspect:2.4,canvasAspect:base.canvasAspect,fraction:0.42)
        for format in [ImageFormat.png,.jpeg] {
            settings.format=format
            try renderer.export(scene:SceneGenerator.generate(base),settings:settings,to:root.appendingPathComponent("强化范围-矩形局部.\(format == .png ? "png" : "jpg")"))
        }
        let descriptor=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:1536,height:Int(1536/base.canvasAspect),mipmapped:false)
        descriptor.storageMode = .private; descriptor.usage = .renderTarget
        let target=renderer.device.makeTexture(descriptor:descriptor)!
        var samples:[Double]=[]
        for frame in 0..<130 {
            var recipe=base; recipe.deconstruction.granularity=1
            recipe.deconstruction.breakup=0.2+0.8*Double(frame)/129
            recipe.deconstruction.sizeVariation=1; recipe.deconstruction.overlap=1
            let start=CFAbsoluteTimeGetCurrent(),scene=SceneGenerator.generate(recipe),command=renderer.queue.makeCommandBuffer()!
            let pass=MTLRenderPassDescriptor(); pass.colorAttachments[0].texture=target; pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            try renderer.encode(scene:scene,viewport:CGRect(x:0,y:0,width:scene.aspect,height:1),pass:pass,command:command)
            command.commit(); command.waitUntilCompleted()
            if let error=command.error {throw error}
            if frame>=10 {samples.append((CFAbsoluteTimeGetCurrent()-start)*1000)}
        }
        samples.sort()
        let report:[String:Any]=["gpu":renderer.device.name,"sourceLayers":(0..<3).filter {base.layer($0).source != nil}.count,"frames":samples.count,"medianMilliseconds":samples[samples.count/2],"p95Milliseconds":samples[Int(Double(samples.count)*0.95)],"endpointComparisons":comparisons,"projectRebuildPassed":true,"comparisonRows":["scatter","size","overlap"],"comparisonColumns":[0,25,50,75,100]]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:root.appendingPathComponent("report.json"),options:.atomic)
        print(String(data:data,encoding:.utf8)!)
        guard samples[Int(Double(samples.count)*0.95)]<33.33 else {throw LumoError.message("强化范围离屏性能超过 33.33 ms。")}
    }
}
