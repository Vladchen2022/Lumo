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
    @Published var alert: StudioAlert?
    @Published var status = "拖动滑块，探索同一张构成的变化"
    @Published var importingColor = false
    @Published var importingLayers: Set<Int> = []
    @Published var selectedColorLayer = 0
    @Published var showColorPicker = false
    @Published var importingShape = false
    @Published var isExporting = false
    @Published private(set) var projectURL: URL?
    let renderer: MetalRenderer?
    private var history = RecipeHistory()
    private var savedProject = LumoProject()
    private var colorRequest = UUID(), shapeRequest = UUID()
    private var layerRequests = [UUID(),UUID(),UUID()]
    private var originalURLs: [UUID:URL] = [:]
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
        let before = recipe; var next = recipe; action(&next)
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
    func undo() { if let next = history.undo(recipe) { recipe = next; scene = SceneGenerator.generate(next); resetExportAspect() } }
    func redo() { if let next = history.redo(recipe) { recipe = next; scene = SceneGenerator.generate(next); resetExportAspect() } }
    func randomize(color: Bool = true, shape: Bool = true) {
        edit { r in if color {r.randomizeColor()}; if shape {r.randomizeShape()} }
        status = "已生成新的构成；锁定的来源保持不变"
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
                    if color {r.setLayer(layer) {$0.source = reference; $0.enabled = true; $0.paletteOverrides = [:]; $0.weightOverrides = [:]}}
                    else {r.shapeSource = reference; if let f = reference.features {r.shape = ShapeParameters(features:f)}}
                }
                if color {if let id = reference.id {originalURLs[id] = url}; selectedColorLayer = layer}
                status = color ? "颜色层 \(layer+1) 已提取；可混合、调透明度或点选色标" : "已提取结构特征，可以继续调整"
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
        colorRequest = UUID(); shapeRequest = UUID(); layerRequests = [UUID(),UUID(),UUID()]; importingLayers = []; importingColor = false; importingShape = false
    }
    func addSnapshot() {
        guard snapshots.count < 100 else {alert=StudioAlert(message:"最多保存 100 个收藏，请先删除不需要的构成。"); return}
        snapshots.insert(SavedSnapshot(name:"构成 \(String(format:"%02d",snapshots.count+1))",recipe:recipe),at:0)
        status = "已收藏当前构成；保存项目后可随时恢复"
    }
    func restore(_ snapshot: SavedSnapshot) {edit {$0=snapshot.recipe}; status="已恢复「\(snapshot.name)」"}
    func deleteSnapshot(_ id: UUID) {snapshots.removeAll {$0.id==id}}
    func resetExportAspect() {
        exportSettings.crop=nil
        let longest = max(exportSettings.width,exportSettings.height)
        if recipe.canvasAspect >= 1 {exportSettings.width=longest; exportSettings.height=max(1,Int(Double(longest)/recipe.canvasAspect))}
        else {exportSettings.height=longest; exportSettings.width=max(1,Int(Double(longest)*recipe.canvasAspect))}
    }
    func prepareCrop(width: Int, height: Int, format: ImageFormat) {
        exportSettings.width=width; exportSettings.height=height; exportSettings.format=format
        exportSettings.crop=CropRegion.centered(outputAspect:Double(width)/Double(height),canvasAspect:recipe.canvasAspect)
        status="拖动框内移动、角点缩放；按 Esc 或点击「退出框选」结束"
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
        var next=original; next.shape.density=1; next.mode = .combined; next.shape.direction=Double(frame)*0.8
        recipe=next; scene=SceneGenerator.generate(next)
    }
    func profileRestore(_ original:GenerationRecipe) {recipe=original; scene=SceneGenerator.generate(original)}
}
