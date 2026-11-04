import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LumoCore

struct StudioAlert: Identifiable { let id = UUID(); let message: String }

private struct CompositionState: Equatable {
    var recipe: GenerationRecipe
    var snapshots: [SavedSnapshot]
}

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
    @Published private(set) var isProcessingLines = false
    @Published private(set) var projectURL: URL?
    @Published var comparison: SavedSnapshot?
    @Published var editingLayer = false
    @Published var fragmentEditing = false
    @Published var selectedFragment: Int?
    @Published private(set) var isSavingProject = false
    @Published private(set) var isLoadingProject = false
    @Published private(set) var recoveryAvailable = false
    @Published private(set) var storageWarning: String?
    @Published private(set) var temporaryLineInput: SourceReference?
    @Published private(set) var isCapturingLines = false
    @Published private(set) var temporaryLineParameters = LineExtractionParameters()
    let renderer: MetalRenderer?
    private var history = EditHistory<CompositionState>()
    private var lineHistory = EditHistory<LineExtractionParameters>()
    private var cropStartSettings: ExportSettings?
    private let io: ProjectIO
    private var draftTask: Task<Void,Never>?
    private var draftRevision: UInt64 = 0
    private var checkedRecovery = false
    private var documentID = UUID()
    private var composition: CompositionState {CompositionState(recipe:recipe,snapshots:snapshots)}
    var isProjectBusy: Bool {isSavingProject || isLoadingProject}
    var isEditingBlocked: Bool {isFixing || isCapturingLines}
    var isShowingLines: Bool {recipe.lineExtraction.enabled || temporaryLineInput != nil}
    var lineParameters: LineExtractionParameters {temporaryLineInput == nil ? recipe.lineExtraction : temporaryLineParameters}
    var canExtractLines: Bool {!isEditingBlocked && !isShowingLines && !importingColor && !importingShape && renderer != nil && (recipe.method == .abstract || !scene.fragments.isEmpty)}
    private var savedProject = LumoProject()
    private var shapeRequest = UUID()
    private var layerRequests = [UUID(),UUID(),UUID()]
    private var originalURLs: [UUID:URL] = [:]
    private var fixRequest=UUID()
    private var lineRequest=UUID()
    private var lineTask: Task<Void,Never>?
    var canExport: Bool {renderer != nil && !isExporting && !isEditingBlocked && !isProcessingLines}
    var canFix: Bool {renderer != nil && !isEditingBlocked && !isProcessingLines && !isExporting && !importingColor && !importingShape && (isShowingLines || recipe.method != .deconstruction || !scene.fragments.isEmpty)}
    var canUndo: Bool {!isEditingBlocked && (temporaryLineInput != nil ? lineHistory.canUndo : history.canUndo)}
    var canRedo: Bool {!isEditingBlocked && (temporaryLineInput != nil ? lineHistory.canRedo : history.canRedo)}
    var isDirty: Bool { project != savedProject }
    var project: LumoProject {
        var p=LumoProject(); p.recipe=recipe; p.snapshots=snapshots
        p.export=cropStartSettings ?? exportSettings; p.export.crop=nil; p.export.matchAspect(recipe.canvasAspect)
        return p
    }
    var title: String { (projectURL?.deletingPathExtension().lastPathComponent ?? "未命名构成") + (isDirty ? " · 已修改" : "") }
    init(io:ProjectIO = ProjectIO()) {
        self.io=io
        do { renderer = try MetalRenderer() }
        catch { renderer = nil; alert = StudioAlert(message:error.localizedDescription) }
    }
    func edit(_ action: (inout GenerationRecipe) -> Void) {
        guard !isEditingBlocked,temporaryLineInput == nil else {return}
        let before=composition
        var next=before
        action(&next.recipe)
        // Local edits belong to a specific source and partition. Layer ordering
        // and ordinary transforms do not change the identity of that partition.
        for slot in 0..<3 {
            let a=before.recipe, b=next.recipe
            let previous=a.arrangement.layers[slot], updated=b.arrangement.layers[slot]
            let old=previous?.parameters ?? a.deconstruction, new=updated?.parameters ?? b.deconstruction
            if (previous?.lockedShapeSeed ?? a.shapeSeed) != (updated?.lockedShapeSeed ?? b.shapeSeed)
                || old.fragmentCount != new.fragmentCount || old.organicCuts != new.organicCuts
                || a.layer(slot).source?.id != b.layer(slot).source?.id || (a.layer(slot).source == nil) != (b.layer(slot).source == nil) {
                next.recipe.arrangement.clearFragments(in:slot)
                if selectedFragment.map({$0/80}) == slot {selectedFragment=nil}
            }
        }
        next.recipe.version=next.recipe.currentVersion
        commit(next)
    }
    private func commit(_ next: CompositionState) {
        let before=composition
        guard before != next else {return}
        history.record(before:before,after:next)
        applyState(next)
    }
    private func applyState(_ next: CompositionState) {
        let previous=recipe
        recipe=next.recipe; snapshots=next.snapshots
        if previous != recipe {
            if previous.canvasAspect != recipe.canvasAspect {resetExportAspect()}
            refreshScene()
            if let selectedFragment, !scene.fragments.contains(where:{$0.id==selectedFragment}) {self.selectedFragment=nil}
        }
        scheduleDraft()
    }
    private func refreshScene() {
        lineTask?.cancel(); lineRequest=UUID()
        var candidate=SceneGenerator.generate(recipe)
        if let temporaryLineInput {
            candidate=AbstractScene.linePreview(input:temporaryLineInput,aspect:recipe.canvasAspect,parameters:temporaryLineParameters)
        }
        guard candidate.lineInput != nil,let parameters=candidate.lineParameters,let renderer else {
            isProcessingLines=false; scene=candidate; return
        }
        if candidate.lineInput == scene.lineInput,let previous=scene.lineParameters,
           parameters.hasSameMask(as:previous),let mask=scene.lineMask {
            candidate.lineMask=mask; isProcessingLines=false; scene=candidate; return
        }
        let request=lineRequest
        isProcessingLines=true; status="正在抽取线条…"
        lineTask=Task {
            do {
                // Coalesce slider events without blocking interaction or the last valid preview.
                try await Task.sleep(nanoseconds:80_000_000)
                let work=Task.detached(priority:.userInitiated) {try renderer.prepareLines(scene:candidate)}
                let mask=try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
                try Task.checkCancellation()
                guard lineRequest == request else {return}
                candidate.lineMask=mask; scene=candidate; isProcessingLines=false
                status="线条已提取；可继续调节、框选或导出"
            } catch is CancellationError {} catch {
                guard lineRequest == request else {return}
                // Keep the stored composition intact if extraction fails.
                if temporaryLineInput != nil {returnToComposition()} else {edit {$0.lineExtraction.enabled=false}}
                alert=StudioAlert(message:error.localizedDescription); status="提线失败，已返回原构成"
            }
        }
    }
    func extractLines() {Task {await captureLines()}}
    func captureLines(longEdge:Int = 4096) async {
        guard canExtractLines,let renderer else {return}
        let captured=scene, request=UUID()
        fixRequest=request; isCapturingLines=true; status="正在读取当前构成…"
        do {
            let input=try await Task.detached(priority:.userInitiated) {
                let size=ExportSettings.dimensions(aspect:captured.aspect,longEdge:longEdge)
                let pixels=try ReferencePixels.png(renderer.image(scene:captured,width:size.width,height:size.height))
                var input=SourceReference(name:"当前画面",thumbnail:Data())
                input.renderImage=pixels
                return input
            }.value
            guard request==fixRequest else {return}
            isCapturingLines=false
            temporaryLineParameters.enabled=true
            temporaryLineInput=input
            lineHistory=EditHistory()
            resetExportAspect()
            refreshScene()
        } catch {
            guard request==fixRequest else {return}
            isCapturingLines=false; status="提线未开始，构成保持原样"
            alert=StudioAlert(message:error.localizedDescription)
        }
    }
    func extractFixedLines() {
        guard recipe.fixedCanvas != nil,!isShowingLines else {return}
        edit {$0.lineExtraction.enabled=true}
    }
    func returnToComposition() {
        guard !isEditingBlocked else {return}
        if temporaryLineInput != nil {
            temporaryLineInput=nil; lineHistory=EditHistory()
            resetExportAspect(); refreshScene()
        } else {edit {$0.lineExtraction.enabled=false}}
        status="已返回构成；提线参数已保留"
    }
    func editLine(_ action:(inout LineExtractionParameters)->Void) {
        if temporaryLineInput != nil {
            let before=temporaryLineParameters
            var next=before; action(&next)
            guard before != next else {return}
            lineHistory.record(before:before,after:next)
            temporaryLineParameters=next; refreshScene()
        } else {edit {action(&$0.lineExtraction)}}
    }
    func lineBinding<T>(_ path:WritableKeyPath<LineExtractionParameters,T>) -> Binding<T> {
        Binding(get:{self.lineParameters[keyPath:path]},set:{value in self.editLine {$0[keyPath:path]=value}})
    }
    func sliderEditing(_ editing: Bool) {
        if temporaryLineInput != nil {
            if editing {lineHistory.begin(temporaryLineParameters)} else {lineHistory.end(temporaryLineParameters)}
        } else {
            if editing {history.begin(composition)} else {history.end(composition); scheduleDraft()}
        }
        objectWillChange.send()
    }
    func binding<T>(_ keyPath: WritableKeyPath<GenerationRecipe,T>) -> Binding<T> {
        Binding(get:{self.recipe[keyPath:keyPath]},set:{newValue in self.edit {$0[keyPath:keyPath]=newValue}})
    }
    func undo() {
        guard !isEditingBlocked else {return}
        if temporaryLineInput != nil {
            if let next=lineHistory.undo(temporaryLineParameters) {temporaryLineParameters=next; refreshScene()}
        } else if let next=history.undo(composition) {
            applyState(next); resetExportAspect()
            if !isProcessingLines {status="已撤销上一步"}
        }
    }
    func redo() {
        guard !isEditingBlocked else {return}
        if temporaryLineInput != nil {
            if let next=lineHistory.redo(temporaryLineParameters) {temporaryLineParameters=next; refreshScene()}
        } else if let next=history.redo(composition) {
            applyState(next); resetExportAspect()
            if !isProcessingLines {status="已重做上一步"}
        }
    }
    func fixCurrentEffect() {Task {await fixEffect()}}
    func fixEffect(longEdge:Int = 4096) async {
        guard canFix,let renderer else {return}
        guard snapshots.count<100 else {alert=StudioAlert(message:"阶段与收藏已满 100 个，请删除不需要的记录后再固定。"); return}
        let before=recipe, capturedProject=project, request=UUID()
        let lineSettings=temporaryLineInput == nil ? nil : temporaryLineParameters
        let captured=lineSettings == nil ? scene : SceneGenerator.generate(before)
        fixRequest=request; isFixing=true; status="正在固定整张画布…"
        do {
            let candidate=try await Task.detached(priority:.userInitiated) {
                var result=capturedProject
                result.recipe=try EffectCommitter.prepare(recipe:before,scene:captured,renderer:renderer,longEdge:longEdge)
                if let lineSettings {
                    result.recipe.lineExtraction=lineSettings
                    result.recipe.version=result.recipe.currentVersion
                }
                result.snapshots.insert(SavedSnapshot(name:"固定前 · 第\(result.recipe.fixedCanvas!.round)轮",recipe:before),at:0)
                result.export.crop=nil; result.export.matchAspect(result.recipe.canvasAspect)
                _=try ProjectStore.storageSize(result)
                return result
            }.value
            let next=candidate.recipe
            guard request==fixRequest else {return}
            isFixing=false
            temporaryLineInput=nil; lineHistory=EditHistory()
            history.end(composition)
            let round=next.fixedCanvas!.round
            commit(CompositionState(recipe:next,snapshots:candidate.snapshots))
            resetExportAspect(); selectedColorLayer=0; editingLayer=false; selectedFragment=nil
            status=lineSettings != nil ? "已保存第 \(round) 轮提线阶段；可继续调节线稿" : before.lineExtraction.enabled ? "线稿已固定；可再次解构或抽取线条" : (next.method == .deconstruction ? "已固定第 \(round) 轮；拖动打散开始再次解构，⌘Z 可撤销固定" : "已固定第 \(round) 轮；保留布局继续变形，参数 50 为本轮起点")
        } catch {if request==fixRequest {alert=StudioAlert(message:error.localizedDescription); status="固定失败，当前画面未改变"}}
        if request==fixRequest {isFixing=false}
    }
    func randomize(color: Bool = true, shape: Bool = true) {
        guard !isShowingLines else {return}
        edit { r in if color {r.randomizeColor()}; if shape {r.randomizeShape()} }
        status = recipe.method == .deconstruction ? "已重新分块或更换碎片叠放；锁定的来源保持不变" : "已生成新的构成；锁定的来源保持不变"
    }
    var canRandomizeParameters: Bool {
        !isEditingBlocked && !isLoadingProject && (isShowingLines || recipe.method != .deconstruction || !cutLayerLocked)
    }
    func randomizeParameters() {
        guard canRandomizeParameters else {return}
        func unit() -> Double {Double.random(in:0...1)}
        if isShowingLines {
            editLine {p in
                p.preset=LineExtractionPreset.allCases.randomElement() ?? p.preset
                p.opacity=unit()
                p.contrast=Double.random(in:0.5...3)
                p.brightness=Double.random(in:-0.3...0.3)
                p.thickness=Double.random(in:0...3)
                p.edgeStrength=Double.random(in:0...3)
                p.overlayOriginal=Bool.random()
            }
        } else if recipe.method == .deconstruction {
            editCuts {p in
                p.expandedTransforms=true; p.strongTransforms=true
                p.granularity=unit(); p.breakup=unit(); p.rotation=unit()
                p.sizeVariation=unit(); p.overlap=unit(); p.spacing=unit()
                p.grouping=unit(); p.softness=unit(); p.organicCuts=Bool.random()
            }
            status="已随机调节\(editingCutLayer.map {"第 \($0+1) 层"} ?? "全局")解构参数；⌘Z 撤销"
        } else {
            edit {r in
                r.color.hue=Double.random(in:-180...180)
                r.color.saturation=unit(); r.color.brightness=unit(); r.color.contrast=unit(); r.color.dominance=unit()
                r.shape.density=unit(); r.shape.scale=unit(); r.shape.variation=unit(); r.shape.curvature=unit()
                r.shape.organic=unit(); r.shape.erosion=unit(); r.shape.stretch=unit()
                r.shape.direction=Double.random(in:-180...180)
                r.shape.clustering=unit(); r.shape.coherence=unit()
                r.appearance.softness=unit(); r.appearance.lineWidth=unit(); r.appearance.lineStrength=unit()
                if r.mode == .shape {r.shapeDisplay=ShapeDisplay.allCases.randomElement() ?? r.shapeDisplay}
            }
            status="已随机调节构成参数；⌘Z 撤销"
        }
    }
    func restoreIterationStart() {
        guard let fixed=recipe.fixedCanvas else {return}
        edit {r in
            r.lineExtraction.enabled=false
            if r.method == .abstract {
                r.color=ColorParameters(); r.shape = fixed.geometry != nil ? .continuation : (fixed.reference.features.map(ShapeParameters.init(features:)) ?? ShapeParameters())
                r.colorSeed=fixed.colorSeed; r.shapeSeed=fixed.shapeSeed
                if let geometry=fixed.geometry {r.mode=geometry.mode; r.shapeDisplay=geometry.shapeDisplay; r.appearance=geometry.appearance}
            } else {Self.resetFragmentLayout(&r)}
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
        guard !isEditingBlocked,temporaryLineInput == nil else {return}
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
                    r.fixedCanvas=nil; r.lineExtraction=LineExtractionParameters()
                    if color {r.arrangement.clearFragments(in:layer); r.setLayer(layer) {$0.source = reference; $0.enabled = true; $0.paletteOverrides = [:]; $0.weightOverrides = [:]}}
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
        fixRequest=UUID(); isFixing=false; isCapturingLines=false
        lineTask?.cancel(); lineRequest=UUID(); isProcessingLines=false
        temporaryLineInput=nil; lineHistory=EditHistory()
        selectedFragment=nil; fragmentEditing=false; editingLayer=false; comparison=nil
        originalURLs.removeAll()
        shapeRequest = UUID(); layerRequests = [UUID(),UUID(),UUID()]; importingLayers = []; importingColor = false; importingShape = false
    }
    func addSnapshot() {
        guard !isEditingBlocked,temporaryLineInput == nil else {return}
        guard snapshots.count < 100 else {alert=StudioAlert(message:"最多保存 100 个收藏，请先删除不需要的构成。"); return}
        var next=composition
        next.snapshots.insert(SavedSnapshot(name:"构成 \(String(format:"%02d",snapshots.count+1))",recipe:recipe),at:0)
        commit(next)
        status="已收藏当前构成；保存项目后可随时恢复"
    }
    func restore(_ snapshot: SavedSnapshot) {
        guard !isEditingBlocked,temporaryLineInput == nil else {return}
        history.end(composition)
        // Restoring a saved recipe also restores its fragment overrides verbatim.
        commit(CompositionState(recipe:snapshot.recipe,snapshots:snapshots))
        selectedFragment=nil; editingLayer=false
        status="已恢复「\(snapshot.name)」"
    }
    func renameSnapshot(_ id: UUID, name: String) {
        let value=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(80))
        guard !isEditingBlocked,!value.isEmpty,let index=snapshots.firstIndex(where:{$0.id==id}) else {return}
        var next=composition
        next.snapshots[index].name=value
        commit(next)
    }
    func deleteSnapshot(_ id: UUID) {
        guard !isEditingBlocked,temporaryLineInput == nil else {return}
        var next=composition; next.snapshots.removeAll {$0.id==id}
        commit(next)
    }
    func resetExportAspect() {
        if let cropStartSettings {exportSettings=cropStartSettings}
        cropStartSettings=nil
        exportSettings.crop=nil
        isCropping=false
        exportSettings.matchAspect(recipe.canvasAspect)
    }
    func prepareCrop(longEdge: Int, format: ImageFormat) {
        if cropStartSettings == nil {cropStartSettings=exportSettings}
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
        guard let renderer, canExport else {return}
        let snapshot=scene, document=documentID
        let panel = NSSavePanel(); panel.allowedContentTypes=settings.format == .png ? [.png] : [.jpeg]
        panel.nameFieldStringValue="Lumo-\(settings.crop == nil ? "构成" : "局部").\(settings.format == .png ? "png" : "jpg")"
        panel.title=settings.crop == nil ? "导出整张图片" : "导出框选局部"
        let result=panel.runModal()
        if isCropping {finishCrop()}
        guard result == .OK, let url=panel.url else {return}
        isExporting=true; status="正在导出 \(settings.width) × \(settings.height)…"
        Task {
            do {
                try await Task.detached(priority:.userInitiated) {try renderer.export(scene:snapshot,settings:settings,to:url)}.value
                if document==documentID && !isCropping {
                    exportSettings=settings; resetExportAspect(); scheduleDraft()
                }
                status="已导出 \(url.lastPathComponent) · \(settings.width) × \(settings.height)"
            } catch {alert=StudioAlert(message:error.localizedDescription); status="导出失败，画面保持不变"}
            isExporting=false
        }
    }
    func saveProject(asNew: Bool = false) {Task { _=await save(asNew:asNew) }}

    private func save(asNew: Bool = false) async -> Bool {
        guard !isProjectBusy else {return false}
        var target=projectURL
        if target == nil || asNew {
            let panel=NSSavePanel(); panel.allowedContentTypes=[UTType(exportedAs:"studio.lumo.project")]
            panel.nameFieldStringValue=projectURL?.lastPathComponent ?? "未命名构成.lumo"
            panel.title="保存 Lumo 项目"
            guard panel.runModal() == .OK, let url=panel.url else {return false}
            target=url
        }
        guard let target else {return false}
        let captured=project
        isSavingProject=true; status="正在后台保存…"
        defer {isSavingProject=false}
        do {
            let bytes=try await io.save(captured,to:target)
            projectURL=target; savedProject=captured
            updateStorageWarning(bytes)
            status=isDirty ? "已保存；之后的调整仍未保存" : "项目已保存，包含参考和收藏"
            scheduleDraft()
            return true
        } catch {alert=StudioAlert(message:error.localizedDescription); status="项目未保存"; return false}
    }
    func confirmAbandon() async -> Bool {
        guard !isProjectBusy else {status="请等待项目读写完成"; return false}
        guard isDirty else {return true}
        let alert=NSAlert(); alert.messageText="保存当前构成吗？"; alert.informativeText="未保存的调整和收藏会丢失。"
        alert.addButton(withTitle:"保存"); alert.addButton(withTitle:"不保存"); alert.addButton(withTitle:"取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard await save() else {return false}
            // Edits made during a background save are still unsaved.
            return !isDirty
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }
    func openProject() {
        guard !isProjectBusy else {return}
        let panel=NSOpenPanel(); panel.allowedContentTypes=[UTType(exportedAs:"studio.lumo.project"),.json]
        panel.allowsMultipleSelection=false; panel.canChooseDirectories=false; panel.title="打开 Lumo 项目"
        if panel.runModal() == .OK, let url=panel.url {openProject(url:url)}
    }
    func openProject(url: URL) {Task {await loadProject(url:url)}}
    func loadProject(url: URL) async {
        guard !isProjectBusy else {return}
        isLoadingProject=true; status="正在后台打开项目…"
        do {
            let opened=try await io.open(url)
            isLoadingProject=false
            guard await confirmAbandon() else {status="保留当前构成"; return}
            installProject(opened,url:url)
            if let bytes=try? url.resourceValues(forKeys:[.fileSizeKey]).fileSize {updateStorageWarning(bytes)}
            status="已打开 \(url.lastPathComponent)"
        } catch {
            isLoadingProject=false; status="项目未打开"
            alert=StudioAlert(message:error.localizedDescription)
        }
    }
    func newProject() {Task {
        guard await confirmAbandon() else {return}
        installProject(LumoProject(),url:nil); status="新的构成"
    }}

    private func installProject(_ value:LumoProject,url:URL?,recovered:Bool=false) {
        cancelImports(); documentID=UUID(); storageWarning=nil
        cropStartSettings=nil; isCropping=false
        recipe=value.recipe; snapshots=value.snapshots; exportSettings=value.export
        resetExportAspect(); savedProject=recovered ? LumoProject() : project
        projectURL=url; history=EditHistory(); refreshScene(); scheduleDraft()
    }

    func checkDraft() async {
        guard !checkedRecovery else {return}
        recoveryAvailable=await io.hasDraft()
        checkedRecovery=true
        if recoveryAvailable {status="发现上次草稿；处理后继续自动保存"}
        scheduleDraft()
    }
    func recoverDraft() async {
        guard recoveryAvailable,await confirmAbandon() else {return}
        isLoadingProject=true
        defer {isLoadingProject=false}
        do {
            let recovered=try await io.recoverDraft()
            recoveryAvailable=false
            installProject(recovered,url:nil,recovered:true)
            status="已恢复上次草稿；请另存项目"
        } catch {alert=StudioAlert(message:error.localizedDescription)}
    }
    func discardDraft() async {
        guard recoveryAvailable else {return}
        recoveryAvailable=false
        await clearDraft()
        scheduleDraft()
    }
    func clearDraft() async {
        guard checkedRecovery,!recoveryAvailable else {return}
        draftTask?.cancel(); draftRevision &+= 1
        _=try? await io.updateDraft(nil,revision:draftRevision)
    }
    private func scheduleDraft() {
        guard checkedRecovery,!recoveryAvailable,!WindowMetrics.enabled else {return}
        draftTask?.cancel()
        draftRevision &+= 1
        let revision=draftRevision, value=isDirty ? project : nil
        draftTask=Task {
            do {
                if value != nil {try await Task.sleep(for:.seconds(1.5))}
                try Task.checkCancellation()
                let bytes=try await io.updateDraft(value,revision:revision)
                guard revision==draftRevision else {return}
                if let bytes {updateStorageWarning(bytes)}
            } catch is CancellationError {} catch {
                guard revision==draftRevision else {return}
                storageWarning="草稿未更新：\(error.localizedDescription)"
            }
        }
    }
    private func updateStorageWarning(_ bytes:Int) {
        storageWarning=bytes>=ProjectStore.warningBytes ? "项目约 \(bytes/1_048_576) MiB，接近 512 MiB 上限" : nil
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
