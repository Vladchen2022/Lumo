import Foundation

public enum ProjectStore {
    private static let magic = Data("LUMO3BIN".utf8)
    public static let byteLimit = 512*1024*1024
    public static let warningBytes = byteLimit*4/5
    private static let legacyLimit = 128*1024*1024
    private static let manifestLimit = 16*1024*1024

    private static func package(_ project: LumoProject) throws -> (manifest:Data, assets:[String:Data], size:Int) {
        try validate(project)
        // Encoding the project registers each distinct binary image once.
        let archive=ReferenceArchive()
        let encoder=JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.userInfo[.referenceArchive]=archive
        encoder.outputFormatting = [.sortedKeys]
        let manifest=try encoder.encode(PackedManifest(project:project,archive:archive))
        let assets=archive.images
        let size=16+manifest.count+assets.values.reduce(0) {$0+$1.count}
        guard manifest.count<=manifestLimit, size<=byteLimit else {
            throw LumoError.message("项目超过 512 MiB，请另存部分阶段后移除不再需要的记录。")
        }
        return (manifest,assets,size)
    }

    private enum ManifestKey: String, CodingKey {case project, assetLengths}
    private struct PackedManifest: Encodable {
        var project: LumoProject
        var archive: ReferenceArchive
        func encode(to encoder: Encoder) throws {
            var container=encoder.container(keyedBy:ManifestKey.self)
            try container.encode(project,forKey:.project)
            try container.encode(archive.images.mapValues(\.count),forKey:.assetLengths)
        }
    }
    private struct AssetIndex: Decodable {var assetLengths: [String:Int]}
    private struct StoredProject: Decodable {var project: LumoProject}

    public static func storageSize(_ project: LumoProject) throws -> Int {try package(project).size}

    @discardableResult public static func save(_ project: LumoProject, to url: URL) throws -> Int {
        let data=try documentData(project)
        try data.write(to:url,options:.atomic)
        return data.count
    }

    public static func documentData(_ project: LumoProject) throws -> Data {
        let package=try package(project)
        var length=UInt64(package.manifest.count).littleEndian
        var data=Data(capacity:package.size)
        data.append(magic)
        withUnsafeBytes(of:&length) {data.append(contentsOf:$0)}
        data.append(package.manifest)
        for id in package.assets.keys.sorted() {data.append(package.assets[id]!)}
        return data
    }

    public static func open(_ url: URL) throws -> LumoProject {
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size<=byteLimit else {throw LumoError.message("项目超过 512 MiB，无法打开。")}
        let decoder=JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let archive=ReferenceArchive()
        decoder.userInfo[.referenceArchive]=archive
        let project: LumoProject
        do {
            let data=try Data(contentsOf:url,options:.mappedIfSafe)
            guard data.count<=byteLimit else {throw LumoError.message("项目过大。")}
            if data.starts(with:magic) {
                guard data.count>=16 else {throw LumoError.message("项目头不完整。")}
                let length=data.withUnsafeBytes {$0.loadUnaligned(fromByteOffset:8,as:UInt64.self).littleEndian}
                guard length<=manifestLimit, length<=data.count-16 else {throw LumoError.message("项目索引损坏。")}
                var offset=16+Int(length)
                let manifest=data[16..<offset]
                let header=try JSONDecoder().decode(AssetIndex.self,from:manifest)
                for key in header.assetLengths.keys.sorted() {
                    let count=header.assetLengths[key]!
                    guard count>=0, count<=32*1024*1024, count<=data.count-offset else {throw LumoError.message("参考图片数据损坏。")}
                    archive.images[key]=data.subdata(in:offset..<offset+count)
                    offset+=count
                }
                guard offset==data.count else {throw LumoError.message("项目包含无效的尾部数据。")}
                project=try decoder.decode(StoredProject.self,from:manifest).project
            } else {
                guard data.count<=legacyLimit else {throw LumoError.message("旧版项目超过 128 MiB。")}
                if let document=try JSONSerialization.jsonObject(with:data) as? [String:Any], let images=document["referenceImages"] as? [String:String] {
                    for (id,value) in images {
                        guard let image=Data(base64Encoded:value) else {throw LumoError.message("参考图片数据损坏。")}
                        archive.images[id]=image
                    }
                }
                project=try decoder.decode(LumoProject.self,from:data)
            }
        } catch {throw LumoError.message("这个文件不是有效的 Lumo 项目，当前画面未改变。")}
        try validate(project)
        return project
    }
    public static func validate(_ project: LumoProject) throws {
        guard (1...2).contains(project.formatVersion), project.snapshots.count <= 100 else { throw LumoError.message("项目版本不受支持，或收藏数量超过限制。") }
        for recipe in [project.recipe]+project.snapshots.map(\.recipe) {
            let strong = recipe.method == .deconstruction && recipe.deconstruction.strongTransforms
            let supported: Bool
            if recipe.version == 7 || recipe.currentVersion == 7 {
                supported = recipe.version == 7 && recipe.currentVersion == 7
            } else if strong {
                supported = recipe.version == 6 && recipe.deconstruction.expandedTransforms
            } else {
                supported = (1...5).contains(recipe.version)
                    && (recipe.fixedCanvas != nil ? recipe.version >= 4 : recipe.version <= 3)
                    && (recipe.fixedCanvas != nil || recipe.method != .deconstruction || recipe.version == (recipe.deconstruction.expandedTransforms ? 3 : 2))
            }
            guard supported else { throw LumoError.message("这个项目使用了更新的生成器版本。") }
            guard recipe.lineExtraction.isValid, !recipe.lineExtraction.enabled || recipe.fixedCanvas != nil, recipe.lineExtraction == LineExtractionParameters() || recipe.version >= 5 else {throw LumoError.message("项目包含无效的线条提取参数。") }
            let normalized = [recipe.color.saturation,recipe.color.brightness,recipe.color.contrast,recipe.color.dominance,recipe.shape.density,recipe.shape.scale,recipe.shape.variation,recipe.shape.curvature,recipe.shape.stretch,recipe.shape.clustering,recipe.shape.coherence,recipe.shape.organic,recipe.shape.erosion,recipe.appearance.softness,recipe.appearance.lineWidth,recipe.appearance.lineStrength,recipe.deconstruction.granularity,recipe.deconstruction.breakup,recipe.deconstruction.rotation,recipe.deconstruction.sizeVariation,recipe.deconstruction.overlap,recipe.deconstruction.grouping]
            guard (normalized+[recipe.deconstruction.softness]).allSatisfy({ $0.isFinite && (0...1).contains($0) }), recipe.color.hue.isFinite, (-180...180).contains(recipe.color.hue), recipe.shape.direction.isFinite, (-180...180).contains(recipe.shape.direction), recipe.canvasAspect.isFinite, (0.25...4).contains(recipe.canvasAspect) else { throw LumoError.message("项目包含无效的调节参数。") }
            guard recipe.deconstruction.isValid, recipe.arrangement.isValid else {throw LumoError.message("项目包含无效的碎片或图层编辑。")}
            guard recipe.colorLayers.count == 3 else {throw LumoError.message("项目必须包含三个颜色层。")}
            for layer in recipe.colorLayers {
                guard [layer.opacity,layer.blockOpacity].allSatisfy({$0.isFinite && (0...1).contains($0)}),layer.paletteOverrides.count <= 6,layer.weightOverrides.count <= 6,
                      layer.paletteOverrides.allSatisfy({(0..<6).contains($0.key) && [$0.value.r,$0.value.g,$0.value.b].allSatisfy {$0.isFinite && (0...1).contains($0)}}),
                      layer.weightOverrides.allSatisfy({(0..<6).contains($0.key) && $0.value.isFinite && (0.001...1).contains($0.value)}) else {throw LumoError.message("颜色层包含无效的混合或色标参数。")}
            }
            var references=[recipe.colorSource,recipe.shapeSource,recipe.colorLayers[1].source,recipe.colorLayers[2].source].compactMap({$0})
            if let fixed=recipe.fixedCanvas {
                guard (1...1000).contains(fixed.round), fixed.reference.renderImage != nil, recipe.colorSource==fixed.reference else {throw LumoError.message("固定阶段包含无效的输入图片。")}
                references.append(fixed.reference)
                if let geometry=fixed.geometry {
                    guard geometry.method == .abstract, geometry.fragments.isEmpty, geometry.layerOrder == nil, geometry.fragmentSoftness == nil, geometry.lineInput == nil, geometry.lineParameters == nil, geometry.lineMask == nil, geometry.shapes.count<=768, geometry.layers.count==3, geometry.aspect.isFinite, (0.25...4).contains(geometry.aspect),
                          [geometry.background.r,geometry.background.g,geometry.background.b].allSatisfy({$0.isFinite && (0...1).contains($0)}),
                          [geometry.appearance.softness,geometry.appearance.lineWidth,geometry.appearance.lineStrength].allSatisfy({$0.isFinite && (0...1).contains($0)}),
                          Set(geometry.shapes.map(\.id)).count==geometry.shapes.count else {throw LumoError.message("固定阶段的布局数据无效。")}
                    for shape in geometry.shapes {
                        guard (0..<100_000).contains(shape.id), (0..<3).contains(shape.layer), (3...128).contains(shape.contour.count),
                              (shape.contour+[shape.center]).allSatisfy({$0.x.isFinite && $0.y.isFinite}), shape.opacity.isFinite, (0...1).contains(shape.opacity), shape.gradient.isFinite, (0...1).contains(shape.gradient),
                              [shape.color.r,shape.color.g,shape.color.b].allSatisfy({$0.isFinite && (0...1).contains($0)}) else {throw LumoError.message("固定阶段包含无效的形状。")}
                    }
                    for layer in geometry.layers {
                        guard [layer.opacity,layer.blockOpacity].allSatisfy({$0.isFinite && (0...1).contains($0)}) else {throw LumoError.message("固定阶段的图层数据无效。")}
                    }
                    references += geometry.layers.compactMap(\.source)
                }
            }
            for source in references {
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
            let aspect=crop.aspect(canvasAspect:project.recipe.canvasAspect)
            guard aspect.isFinite, aspect>0, Float(crop.width)>0, Float(crop.height)>0 else {throw LumoError.message("项目裁切比例无效。")}
            let fitted=ExportSettings.dimensions(aspect:aspect,longEdge:max(project.export.width,project.export.height))
            guard abs(fitted.width-project.export.width)<=1, abs(fitted.height-project.export.height)<=1 else { throw LumoError.message("项目裁切比例与导出尺寸不一致。") }
        } else {
            guard abs((Double(project.export.width)/Double(project.export.height))/project.recipe.canvasAspect-1) < 0.02 else { throw LumoError.message("整张导出的尺寸比例与画布不一致。") }
        }
    }
}
