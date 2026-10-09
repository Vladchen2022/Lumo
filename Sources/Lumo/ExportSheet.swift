import SwiftUI
import LumoCore

struct ExportSheet:View {
    @ObservedObject var model:StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var longEdge:Int
    @State private var format:ImageFormat
    @State private var useCrop:Bool
    init(model:StudioModel) {
        self.model=model; _longEdge=State(initialValue:max(model.exportSettings.width,model.exportSettings.height))
        _format=State(initialValue:model.exportSettings.format); _useCrop=State(initialValue:model.isCropping)
    }
    private var valid:Bool {(1...4096).contains(longEdge)}
    private var needsSelection:Bool {useCrop && model.exportSettings.crop == nil}
    private var aspect:Double {useCrop ? (model.exportSettings.crop?.aspect(canvasAspect:model.recipe.canvasAspect) ?? model.recipe.canvasAspect) : model.recipe.canvasAspect}
    private var dimensions:(width:Int,height:Int) {ExportSettings.dimensions(aspect:aspect,longEdge:longEdge)}
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack {Text("导出图片").font(.system(size:20,weight:.semibold)); Spacer(); Text("sRGB").font(.system(size:11,design:.monospaced)).foregroundStyle(Theme.secondary)}
            Picker("导出区域",selection:$useCrop) {Text("整张画布").tag(false); Text("框选局部").tag(true)}.pickerStyle(.segmented)
                .onChange(of:useCrop) {_,next in if !next {model.finishCrop()}}
            HStack(spacing:10) {
                ForEach([1024,2048,4096],id:\.self) {value in Button("\(value)") {longEdge=value}.buttonStyle(.bordered)}
                Spacer(); Text("长边 · 像素").font(.system(size:11)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing:14) {
                VStack(alignment:.leading,spacing:8) {
                    Text("自定义长边（1–4096）").font(.system(size:11))
                    TextField("长边像素",value:$longEdge,format:.number.grouping(.never)).textFieldStyle(.roundedBorder).accessibilityIdentifier("exportLongEdge")
                }.frame(width:165)
                Spacer()
                VStack(alignment:.trailing,spacing:8) {
                    Text(needsSelection ? "框选后计算宽高" : "实际导出尺寸").font(.system(size:11)).foregroundStyle(Theme.secondary)
                    Text(needsSelection ? "—" : "\(dimensions.width) × \(dimensions.height)").font(.system(size:16,weight:.medium,design:.monospaced))
                }
            }
            Text(useCrop ? "自由矩形选区，导出保持选区比例。可拖动任意边、角或框内调整，像素宽高按比例取整。" : "整张导出保持画布比例。单边最多 4096 像素。")
                .font(.system(size:11)).foregroundStyle(Theme.secondary).lineSpacing(4)
            Picker("文件格式",selection:$format) {ForEach(ImageFormat.allCases,id:\.self) {Text($0.title).tag($0)}}.pickerStyle(.segmented).frame(width:160)
            Divider()
            HStack {
                Button("取消",role:.cancel) {if model.isCropping {model.finishCrop()}; dismiss()}.keyboardShortcut(.cancelAction)
                Spacer()
                if useCrop && !needsSelection {
                    Button("调整选区") {
                        model.exportSettings.format=format; model.exportSettings.matchAspect(aspect,longEdge:longEdge)
                        dismiss()
                    }.disabled(!valid)
                }
                Button(needsSelection ? "在画布框选" : "导出…") {
                    if needsSelection {model.prepareCrop(longEdge:longEdge,format:format); dismiss()}
                    else {
                        var settings=model.exportSettings; settings.matchAspect(aspect,longEdge:longEdge); settings.format=format
                        if !useCrop {settings.crop=nil}
                        dismiss()
                        DispatchQueue.main.async {model.exportImage(settings:settings)}
                    }
                }.buttonStyle(.borderedProminent).foregroundStyle(Theme.background).disabled(!valid || !model.canExport).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width:420).background(Theme.panel).preferredColorScheme(.dark).tint(Theme.accent)
    }
}
