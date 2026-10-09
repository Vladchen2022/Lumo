import SwiftUI
import AppKit
import LumoCore

@main enum LumoEntry {
    @MainActor static func main() {
        if let index = CommandLine.arguments.firstIndex(of:"--verify-deconstruction"), CommandLine.arguments.count > index+1 {
            do {try DeconstructionVerification.run(projectURL:URL(fileURLWithPath:CommandLine.arguments[index+1])); exit(0)} catch {fputs("Deconstruction verification failed: \(error)\n",stderr); exit(1)}
        }
        if CommandLine.arguments.contains("--verify") {
            do {try Verification.run(); exit(0)} catch {fputs("Verification failed: \(error)\n",stderr); exit(1)}
        }
        NSApplication.shared.setActivationPolicy(.regular)
        LumoApp.main()
    }
}
@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    weak var model:StudioModel?
    private var escapeMonitor: Any?
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApplication.shared.activate(ignoringOtherApps:true)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) {[weak self] event in
            if event.keyCode == 53, NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil, let model = self?.model, model.isCropping, model.alert == nil, !model.showExportSheet, !model.showColorPicker {
                model.finishCrop(); return nil
            }
            return event
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool {true}
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {model?.confirmAbandon() == false ? .terminateCancel : .terminateNow}
    func application(_ application:NSApplication,open urls:[URL]) {if let url=urls.first {model?.openProject(url:url)}}
}
struct LumoApp:App {
    @StateObject private var model=StudioModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var profiled=false
    var body:some Scene {
        Window("Lumo",id:"studio") {
            StudioView(model:model).onAppear {
                delegate.model=model
                if WindowMetrics.enabled && !profiled {profiled=true; Task {await WindowMetrics.run(model:model)}}
            }.onOpenURL {model.openProject(url:$0)}
        }.defaultSize(width:1360,height:900).windowStyle(.hiddenTitleBar)
            .commands {
                CommandGroup(replacing:.newItem) {
                    Button("新建构成") {model.newProject()}.keyboardShortcut("n")
                    Button("打开项目…") {model.openProject()}.keyboardShortcut("o")
                }
                CommandGroup(replacing:.saveItem) {
                    Button("保存项目") {model.saveProject()}.keyboardShortcut("s")
                    Button("项目另存为…") {model.saveProject(asNew:true)}.keyboardShortcut("s",modifiers:[.command,.shift])
                    Divider()
                    Button("导出图片…") {model.showExportSheet=true}.keyboardShortcut("e",modifiers:[.command,.shift]).disabled(!model.canExport)
                }
                CommandGroup(replacing:.undoRedo) {
                    Button("撤销") {model.undo()}.keyboardShortcut("z").disabled(!model.canUndo)
                    Button("重做") {model.redo()}.keyboardShortcut("z",modifiers:[.command,.shift]).disabled(!model.canRedo)
                }
                CommandMenu("构成") {
                    Button("固定当前效果") {model.fixCurrentEffect()}.keyboardShortcut("f",modifiers:[.command,.shift]).disabled(!model.canFix)
                    Button("抽取线条") {model.extractLines()}.keyboardShortcut("l",modifiers:[.command,.shift]).disabled(model.recipe.fixedCanvas == nil || model.isFixing || model.recipe.lineExtraction.enabled)
                    Button("返回构成") {model.returnToComposition()}.disabled(!model.recipe.lineExtraction.enabled)
                    Divider()
                    Button("退出框选") {model.finishCrop()}.disabled(!model.isCropping)
                    Divider()
                    Button("全部随机") {model.randomize()}.keyboardShortcut("r").disabled(model.recipe.lineExtraction.enabled || (model.recipe.colorLocked && model.recipe.shapeLocked))
                    Button("收藏当前构成") {model.addSnapshot()}.keyboardShortcut("d")
                    Divider()
                    ForEach(CompositionPreset.allCases,id:\.self) {preset in Button(preset.title) {model.apply(preset)}}
                }
            }
    }
}
