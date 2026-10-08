import Foundation

public enum ProjectStore {
    public static func save(_ project: LumoProject, to url: URL) throws {
        try validate(project)
        let archive = ReferenceArchive()
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970; encoder.userInfo[.referenceArchive] = archive
        var document = try JSONSerialization.jsonObject(with:encoder.encode(project)) as! [String:Any]
        document["formatVersion"] = 2
        document["referenceImages"] = archive.images.mapValues {$0.base64EncodedString()}
        let data = try JSONSerialization.data(withJSONObject:document,options:[.prettyPrinted,.sortedKeys])
        guard data.count <= 128*1024*1024 else {throw LumoError.message("项目超过 128 MB，请减少使用不同参考图的收藏后再保存。")}
        try data.write(to:url,options:.atomic)
    }
    public static func open(_ url: URL) throws -> LumoProject {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 128*1024*1024 else { throw LumoError.message("项目超过 128 MB，无法打开。") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let project: LumoProject
        do {
            let data = try Data(contentsOf:url), archive = ReferenceArchive()
            if let document = try JSONSerialization.jsonObject(with:data) as? [String:Any], let images = document["referenceImages"] as? [String:String] {
                for (id,value) in images {guard let image = Data(base64Encoded:value) else {throw LumoError.message("参考图片数据损坏。")}; archive.images[id] = image}
            }
            decoder.userInfo[.referenceArchive] = archive
            project = try decoder.decode(LumoProject.self,from:data)
        }
        catch { throw LumoError.message("这个文件不是有效的 Lumo 项目，当前画面未改变。") }
        try validate(project); return project
    }
    public static func validate(_ project: LumoProject) throws {
        guard (1...2).contains(project.formatVersion), project.snapshots.count <= 100 else { throw LumoError.message("项目版本不受支持，或收藏数量超过限制。") }
        for recipe in [project.recipe]+project.snapshots.map(\.recipe) {
            guard (1...2).contains(recipe.version), recipe.method != .deconstruction || recipe.version == 2 else { throw LumoError.message("这个项目使用了更新的生成器版本。") }
            let normalized = [recipe.color.saturation,recipe.color.brightness,recipe.color.contrast,recipe.color.dominance,recipe.shape.density,recipe.shape.scale,recipe.shape.variation,recipe.shape.curvature,recipe.shape.stretch,recipe.shape.clustering,recipe.shape.coherence,recipe.shape.organic,recipe.shape.erosion,recipe.appearance.softness,recipe.appearance.lineWidth,recipe.appearance.lineStrength,recipe.deconstruction.granularity,recipe.deconstruction.breakup,recipe.deconstruction.rotation,recipe.deconstruction.sizeVariation,recipe.deconstruction.overlap,recipe.deconstruction.grouping]
            guard (normalized+[recipe.deconstruction.softness]).allSatisfy({ $0.isFinite && (0...1).contains($0) }), recipe.color.hue.isFinite, (-180...180).contains(recipe.color.hue), recipe.shape.direction.isFinite, (-180...180).contains(recipe.shape.direction), recipe.canvasAspect.isFinite, (0.25...4).contains(recipe.canvasAspect) else { throw LumoError.message("项目包含无效的调节参数。") }
            guard recipe.colorLayers.count == 3 else {throw LumoError.message("项目必须包含三个颜色层。")}
            for layer in recipe.colorLayers {
                guard [layer.opacity,layer.blockOpacity].allSatisfy({$0.isFinite && (0...1).contains($0)}),layer.paletteOverrides.count <= 6,layer.weightOverrides.count <= 6,
                      layer.paletteOverrides.allSatisfy({(0..<6).contains($0.key) && [$0.value.r,$0.value.g,$0.value.b].allSatisfy {$0.isFinite && (0...1).contains($0)}}),
                      layer.weightOverrides.allSatisfy({(0..<6).contains($0.key) && $0.value.isFinite && (0.001...1).contains($0.value)}) else {throw LumoError.message("颜色层包含无效的混合或色标参数。")}
            }
            for source in [recipe.colorSource,recipe.shapeSource,recipe.colorLayers[1].source,recipe.colorLayers[2].source].compactMap({$0}) {
                guard source.thumbnail.count <= 2*1024*1024 else { throw LumoError.message("项目参考缩略图过大。") }
                guard (source.samplingImage?.count ?? 0) <= 16*1024*1024 else {throw LumoError.message("项目取色预览过大。")}
                guard (source.renderImage?.count ?? 0) <= 32*1024*1024 else {throw LumoError.message("项目解构图片过大。")}
                if let palette = source.palette {
                    guard (1...12).contains(palette.count), palette.allSatisfy({ [$0.color.r,$0.color.g,$0.color.b].allSatisfy { $0.isFinite && (0...1).contains($0) } && $0.weight.isFinite && $0.weight >= 0 }), palette.reduce(0,{$0+$1.weight}) > 0 else { throw LumoError.message("项目配色数据无效。") }
                }
                if let f = source.features {
                    guard [f.coherence,f.roughness,f.density,f.scale].allSatisfy({$0.isFinite && (0...1).contains($0)}), f.direction.isFinite, (-180...180).contains(f.direction) else { throw LumoError.message("项目结构特征无效。") }
                }
            }
        }
        guard (1...4096).contains(project.export.width), (1...4096).contains(project.export.height) else { throw LumoError.message("项目导出尺寸无效。") }
        if let crop = project.export.crop {
            guard [crop.x,crop.y,crop.width,crop.height].allSatisfy(\.isFinite), crop.x >= 0, crop.y >= 0, crop.width > 0, crop.height > 0, crop.x+crop.width <= 1.000001, crop.y+crop.height <= 1.000001 else { throw LumoError.message("项目裁切区域无效。") }
            guard abs((crop.width*project.recipe.canvasAspect/crop.height)/(Double(project.export.width)/Double(project.export.height))-1) < 0.002 else { throw LumoError.message("项目裁切比例与导出尺寸不一致。") }
        } else {
            guard abs((Double(project.export.width)/Double(project.export.height))/project.recipe.canvasAspect-1) < 0.02 else { throw LumoError.message("整张导出的尺寸比例与画布不一致。") }
        }
    }
}
