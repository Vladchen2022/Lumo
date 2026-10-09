import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumoCore

struct StudioAlert: Identifiable { let id = UUID(); let message: String }

@MainActor final class StudioModel: ObservableObject {
    @Published private(set) var recipe = GenerationRecipe()
    @Published private(set) var scene = SceneGenerator.generate(GenerationRecipe())
    @Published private(set) var snapshots: [SavedSnapshot] = []
    @Published var exportSettings = ExportSettings()
    @Published var showExportSheet = false
    @Published var isCropping = false
    @Published var alert: StudioAlert?
    @Published var status = "拖动滑块，探索同一张构成的变化"
    @Published var importingColor = false
    @Published var importingLayers: Set<Int> = []
    @Published var selectedColorLayer = 0
    @Published var showColorPicker = false
    @Published var importingShape = false
    @Published var isExporting = false
    @Published private(set) var isFixing = false
    @Published private(set) var projectURL: URL?
    let renderer: MetalRenderer?
    private var history = RecipeHistory()
    private var savedProject = LumoProject()
    private var colorRequest = UUID(), shapeRequest = UUID()
    private var layerRequests = [UUID(),UUID(),UUID()]
    private var originalURLs: [UUID:URL] = [:]
    private var fixRequest=UUID()
    var canFix: Bool {renderer != nil && !isFixing && !isExporting && !importingColor && !importingShape && (recipe.method != .deconstruction || !scene.fragments.isEmpty)}
    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var isDirty: Bool { project != savedProject }
    var project: LumoProject {
        var p = LumoProject(); p.recipe = recipe; p.snapshots = snapshots; p.export = exportSettings; return p
    }
    var title: String { (projectURL?.deletingPathExtension().lastPathComponent ?? "未命名构成") + (isDirty ? " · 已修改" : "") }
    init() {
        do { renderer = try MetalRenderer() }
        catch { renderer = nil; alert = StudioAlert(message:error.localizedDescription) }
    }
    func edit(_ action: (inout GenerationRecipe) -> Void) {
        guard !isFixing else {return}
        let before = recipe; var next = recipe; action(&next)
        next.version = next.fixedCanvas != nil ? 4 : (next.method == .deconstruction ? (next.deconstruction.expandedTransforms ? 3 : 2) : 1)
        guard next != before else { return }
        recipe = next; history.record(before:before,after:next); scene = SceneGenerator.generate(next)
        if before.canvasAspect != next.canvasAspect { resetExportAspect() }
    }
    func sliderEditing(_ editing: Bool) {
        if editing { history.begin(recipe) } else { history.end(recipe); objectWillChange.send() }
    }
    func binding<T>(_ keyPath: WritableKeyPath<GenerationRecipe,T>) -> Binding<T> {
        Binding(get:{self.recipe[keyPath:keyPath]},set:{newValue in self.edit {$0[keyPath:keyPath]=newValue}})
    }
    func expandedBinding(_ keyPath: WritableKeyPath<GenerationRecipe,Double>) -> Binding<Double> {
        Binding(get:{self.recipe[keyPath:keyPath]},set:{value in
            self.edit {$0[keyPath:keyPath]=value; $0.deconstruction.expandedTransforms=true}
        })
    }
    func undo() {guard !isFixing else {return}; if let next = history.undo(recipe) { recipe = next; scene = SceneGenerator.generate(next); resetExportAspect() } }
    func redo() {guard !isFixing else {return}; if let next = history.redo(recipe) { recipe = next; scene = SceneGenerator.generate(next); resetExportAspect() } }
    func fixCurrentEffect() {
        guard canFix,let renderer else {return}
        guard snapshots.count<100 else {alert=StudioAlert(message:"阶段与收藏已满 100 个，请删除不需要的记录后再固定。"); return}
        let before=recipe, captured=scene, capturedProject=project, request=UUID()
        fixRequest=request; isFixing=true; status="正在固定整张画布…"
        Task {
            do {
                let candidate=try await Task.detached(priority:.userInitiated) {
                    var result=capturedProject
                    result.recipe=try EffectCommitter.prepare(recipe:before,scene:captured,renderer:renderer)
                    result.snapshots.insert(SavedSnapshot(name:"固定前 · 第\(result.recipe.fixedCanvas!.round)轮",recipe:before),at:0)
                    result.export.crop=nil; result.export.matchAspect(result.recipe.canvasAspect)
                    _=try ProjectStore.documentData(result)
                    return result
                }.value
                let next=candidate.recipe
                guard request==fixRequest,recipe==before else {return}
                isFixing=false
                let round=next.fixedCanvas!.round
                snapshots=candidate.snapshots
                edit {$0=next}; resetExportAspect(); selectedColorLayer=0
                status=next.method == .deconstruction ? "已固定第 \(round) 轮；拖动打散开始再次解构，⌘Z 可撤销固定" : "已固定第 \(round) 轮；保留布局继续变形，参数 50 为本轮起点"
            } catch {if request==fixRequest {alert=StudioAlert(message:error.localizedDescription); status="固定失败，当前画面未改变"}}
            if request==fixRequest {isFixing=false}
        }
    }
    func randomize(color: Bool = true, shape: Bool = true) {
        edit { r in if color {r.randomizeColor()}; if shape {r.randomizeShape()} }
        status = recipe.method == .deconstruction ? "已重新分块或更换碎片叠放；锁定的来源保持不变" : "已生成新的构成；锁定的来源保持不变"
    }
    func restoreIterationStart() {
        guard let fixed=recipe.fixedCanvas else {return}
        edit {r in
            if r.method == .abstract {
                r.color=ColorParameters(); r.shape = fixed.geometry != nil ? .continuation : (fixed.reference.features.map(ShapeParameters.init(features:)) ?? ShapeParameters())
                r.colorSeed=fixed.colorSeed; r.shapeSeed=fixed.shapeSeed
                if let geometry=fixed.geometry {r.mode=geometry.mode; r.shapeDisplay=geometry.shapeDisplay; r.appearance=geometry.appearance}
            } else {r.deconstruction.breakup=0}
        }
        status="已恢复本轮固定画面；阶段输入保持不变"
    }
    func apply(_ preset: CompositionPreset) { edit {$0.apply(preset)}; status = "已应用「\(preset.title)」，可以继续调节" }
    func layerBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<ColorLayer,T>) -> Binding<T> {
        Binding(get:{self.recipe.layer(index)[keyPath:keyPath]},set:{value in self.edit {$0.setLayer(index) {$0[keyPath:keyPath] = value}}})
    }
    func importImage(color: Bool, layer: Int = 0, multiple: Bool = false) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.png,.jpeg,.heic,.tiff]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = multiple
        panel.title = color ? (multiple ? "选择最多三张颜色参考（按文件名顺序叠放）" : "选择颜色层 \(layer+1) 的参考") : "选择形状参考"
        if panel.runModal() == .OK {
            if multiple {
                guard panel.urls.count <= 3 else {alert = StudioAlert(message:"一次最多导入三张参考图，请重新选择。"); return}
                for (index,url) in panel.urls.sorted(by:{$0.lastPathComponent < $1.lastPathComponent}).enumerated() {importImage(url:url,color:true,layer:index)}
            } else if let url = panel.url {importImage(url:url,color:color,layer:layer)}
        }
    }
    func importImage(url: URL, color: Bool, layer: Int = 0) {
        let request = UUID()
        if color {layerRequests[layer] = request; importingLayers.insert(layer); importingColor = true} else {shapeRequest = request; importingShape = true}
        Task {
            do {
                let reference = try await Task.detached(priority:.userInitiated) {
                    let access = url.startAccessingSecurityScopedResource(); defer {if access {url.stopAccessingSecurityScopedResource()}}
                    return try ReferenceAnalyzer.analyze(url:url,forColor:color)
                }.value
                guard request == (color ? layerRequests[layer] : shapeRequest) else {return}
                edit {r in
                    r.fixedCanvas=nil
                    if color {r.setLayer(layer) {$0.source = reference; $0.enabled = true; $0.paletteOverrides = [:]; $0.weightOverrides = [:]}}
                    else {r.shapeSource = reference; if let f = reference.features {r.shape = ShapeParameters(features:f)}}
                }
                if color {if let id = reference.id {originalURLs[id] = url}; selectedColorLayer = layer}
                status = color ? (recipe.method == .deconstruction ? "图片层 \(layer+1) 已导入；可调节分块、打散和混合" : "颜色层 \(layer+1) 已提取；可混合、调透明度或点选色标") : "已提取结构特征，可以继续调整"
            } catch {
                guard request == (color ? layerRequests[layer] : shapeRequest) else {return}
                alert = StudioAlert(message:error.localizedDescription)
            }
            if color, request == layerRequests[layer] {importingLayers.remove(layer); importingColor = !importingLayers.isEmpty}
            if !color, request == shapeRequest {importingShape = false}
        }
    }
    func clearSource(color: Bool, layer: Int = 0) {
        if color {layerRequests[layer] = UUID(); importingLayers.remove(layer); importingColor = !importingLayers.isEmpty} else {shapeRequest = UUID(); importingShape = false}
        edit {r in if color {r.setLayer(layer) {$0.source = nil; $0.paletteOverrides = [:]; $0.weightOverrides = [:]}} else {r.shapeSource = nil; r.shape = ShapeParameters()}}
    }
    func originalURL(for source: SourceReference) -> URL? {source.id.flatMap {originalURLs[$0]}.flatMap {FileManager.default.fileExists(atPath:$0.path) ? $0 : nil}}
    func pickColor(_ color: LumoCore.RGBColor, slot: Int, layer: Int) {
        edit {$0.setLayer(layer) {$0.paletteOverrides[slot] = color}}
        status = "已替换颜色层 \(layer+1) 的色标 \(slot+1)；可调占比强化点缀色"
    }
    private func cancelImports() {
        fixRequest=UUID(); isFixing=false
        colorRequest = UUID(); shapeRequest = UUID(); layerRequests = [UUID(),UUID(),UUID()]; importingLayers = []; importingColor = false; importingShape = false
    }
    func addSnapshot() {
        guard !isFixing else {return}
        guard snapshots.count < 100 else {alert=StudioAlert(message:"最多保存 100 个收藏，请先删除不需要的构成。"); return}
        snapshots.insert(SavedSnapshot(name:"构成 \(String(format:"%02d",snapshots.count+1))",recipe:recipe),at:0)
        status = "已收藏当前构成；保存项目后可随时恢复"
    }
    func restore(_ snapshot: SavedSnapshot) {edit {$0=snapshot.recipe}; status="已恢复「\(snapshot.name)」"}
    func deleteSnapshot(_ id: UUID) {guard !isFixing else {return}; snapshots.removeAll {$0.id==id}}
    func resetExportAspect() {
        exportSettings.crop=nil
        isCropping=false
        exportSettings.matchAspect(recipe.canvasAspect)
    }
    func prepareCrop(longEdge: Int, format: ImageFormat) {
        exportSettings.format=format
        exportSettings.crop=nil
        isCropping=true
        exportSettings.matchAspect(recipe.canvasAspect,longEdge:longEdge)
        status="自由矩形：拖动画布建立选区，框内移动，边或角调整；Esc 退出"
    }
    func updateCrop(_ crop: CropRegion) {
        exportSettings.crop=crop
        exportSettings.matchAspect(crop.aspect(canvasAspect:recipe.canvasAspect))
    }
    func finishCrop() {resetExportAspect(); status="已退出框选，画面保持不变"}
    func exportImage(settings: ExportSettings) {
        guard let renderer, !isExporting else {return}
        let snapshot = scene
        let panel = NSSavePanel(); panel.allowedContentTypes=settings.format == .png ? [.png] : [.jpeg]
        panel.nameFieldStringValue="Lumo-\(settings.crop == nil ? "构成" : "局部").\(settings.format == .png ? "png" : "jpg")"
        panel.title=settings.crop == nil ? "导出整张图片" : "导出框选局部"
        guard panel.runModal() == .OK, let url=panel.url else {return}
        exportSettings=settings; isExporting=true; status="正在导出 \(settings.width) × \(settings.height)…"
        Task {
            do {
                try await Task.detached(priority:.userInitiated) {try renderer.export(scene:snapshot,settings:settings,to:url)}.value
                if settings.crop != nil {resetExportAspect()}
                status="已导出 \(url.lastPathComponent) · \(settings.width) × \(settings.height)"
            } catch {alert=StudioAlert(message:error.localizedDescription); status="导出失败，画面保持不变"}
            isExporting=false
        }
    }
    @discardableResult func saveProject(asNew: Bool = false) -> Bool {
        var target=projectURL
        if target == nil || asNew {
            let panel=NSSavePanel(); panel.allowedContentTypes=[UTType(exportedAs:"studio.lumo.project")]; panel.nameFieldStringValue=(projectURL?.lastPathComponent ?? "未命名构成.lumo")
            panel.title="保存 Lumo 项目"
            guard panel.runModal() == .OK, let url=panel.url else {return false}; target=url
        }
        do {try ProjectStore.save(project,to:target!); projectURL=target; savedProject=project; status="项目已保存，包含参考和收藏"; return true}
        catch {alert=StudioAlert(message:error.localizedDescription); return false}
    }
    func confirmAbandon() -> Bool {
        guard isDirty else {return true}
        let alert=NSAlert(); alert.messageText="保存当前构成吗？"; alert.informativeText="未保存的调整和收藏会丢失。"; alert.addButton(withTitle:"保存"); alert.addButton(withTitle:"不保存"); alert.addButton(withTitle:"取消")
        switch alert.runModal() {case .alertFirstButtonReturn: return saveProject(); case .alertSecondButtonReturn: return true; default:return false}
    }
    func openProject() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[UTType(exportedAs:"studio.lumo.project"),.json]; panel.allowsMultipleSelection=false; panel.canChooseDirectories=false; panel.title="打开 Lumo 项目"
        if panel.runModal() == .OK, let url=panel.url {openProject(url:url)}
    }
    func openProject(url: URL) {
        do {
            let project=try ProjectStore.open(url)
            guard confirmAbandon() else {return}
            cancelImports()
            recipe=project.recipe; snapshots=project.snapshots; exportSettings=project.export; resetExportAspect(); savedProject=self.project; projectURL=url; history=RecipeHistory(); scene=SceneGenerator.generate(recipe)
            status="已打开 \(url.lastPathComponent)"
        } catch {alert=StudioAlert(message:error.localizedDescription)}
    }
    func newProject() {
        guard confirmAbandon() else {return}
        cancelImports()
        let p=LumoProject(); recipe=p.recipe; snapshots=[]; exportSettings=p.export; savedProject=p; projectURL=nil; history=RecipeHistory(); scene=SceneGenerator.generate(recipe); status="新的构成"
    }
    func profileFrame(original:GenerationRecipe,frame:Int) {
        var next=original
        if original.method == .deconstruction {
            next.deconstruction.granularity=1
            next.deconstruction.breakup=0.25+Double(frame)/180*0.65
            next.deconstruction.rotation=0.7
        } else {next.shape.density=1; next.mode = .combined; next.shape.direction=Double(frame)*0.8}
        recipe=next; scene=SceneGenerator.generate(next)
    }
    func profileRestore(_ original:GenerationRecipe) {recipe=original; scene=SceneGenerator.generate(original)}
}
