import SwiftUI
import LumoCore

struct ExportSheet:View {
    @ObservedObject var model:StudioModel
    @Environment(\.dismiss) private var dismiss
    @State private var width:Int
    @State private var height:Int
    @State private var format:ImageFormat
    @State private var useCrop:Bool
    init(model:StudioModel) {
        self.model=model; _width=State(initialValue:model.exportSettings.width); _height=State(initialValue:model.exportSettings.height)
        _format=State(initialValue:model.exportSettings.format); _useCrop=State(initialValue:model.exportSettings.crop != nil)
    }
    private var valid:Bool {(1...4096).contains(width) && (1...4096).contains(height)}
    private var needsSelection:Bool {
        guard useCrop else {return false}
        guard let crop=model.exportSettings.crop else {return true}
        return abs(crop.width*model.recipe.canvasAspect/crop.height-Double(width)/Double(max(1,height)))>0.001
    }
    var body:some View {
        VStack(alignment:.leading,spacing:22) {
            HStack {Text("导出图片").font(.system(size:20,weight:.semibold)); Spacer(); Text("sRGB").font(.system(size:11,design:.monospaced)).foregroundStyle(Theme.secondary)}
            Picker("导出区域",selection:$useCrop) {Text("整张画布").tag(false); Text("框选局部").tag(true)}.pickerStyle(.segmented)
                .onChange(of:useCrop) {_,next in if !next {model.finishCrop(); matchAspect(fromWidth:true)}}
            HStack(spacing:10) {
                ForEach([1024,2048,4096],id:\.self) {value in Button("\(value)") {
                    if useCrop {width=value; height=value}
                    else if model.recipe.canvasAspect>=1 {width=value; height=max(1,Int(Double(value)/model.recipe.canvasAspect))}
                    else {height=value; width=max(1,Int(Double(value)*model.recipe.canvasAspect))}
                }.buttonStyle(.bordered)}
                Spacer(); Text("像素").font(.system(size:11)).foregroundStyle(Theme.secondary)
            }
            HStack(spacing:14) {
                VStack(alignment:.leading,spacing:8) {Text("宽度").font(.system(size:11)); TextField("宽度",value:$width,format:.number.grouping(.never)).textFieldStyle(.roundedBorder).onChange(of:width) {_,_ in if !useCrop {matchAspect(fromWidth:true)}}}
                Text("×").foregroundStyle(Theme.secondary).padding(.top,20)
                VStack(alignment:.leading,spacing:8) {Text("高度").font(.system(size:11)); TextField("高度",value:$height,format:.number.grouping(.never)).textFieldStyle(.roundedBorder).onChange(of:height) {_,_ in if !useCrop {matchAspect(fromWidth:false)}}}
            }
            Text(useCrop ? "选框按输出比例锁定；局部将按目标尺寸重新绘制。" : "整张导出保持画布比例。单边最多 4096 像素。")
                .font(.system(size:11)).foregroundStyle(Theme.secondary).lineSpacing(4)
            Picker("文件格式",selection:$format) {ForEach(ImageFormat.allCases,id:\.self) {Text($0.title).tag($0)}}.pickerStyle(.segmented).frame(width:160)
            Divider()
            HStack {
                Button("取消",role:.cancel) {if model.exportSettings.crop != nil {model.finishCrop()}; dismiss()}.keyboardShortcut(.cancelAction)
                Spacer()
                if useCrop && !needsSelection {Button("重新框选") {model.prepareCrop(width:width,height:height,format:format); dismiss()}.disabled(!valid)}
                Button(needsSelection ? "在画布框选" : "导出…") {
                    if needsSelection {model.prepareCrop(width:width,height:height,format:format); dismiss()}
                    else {
                        var settings=model.exportSettings; settings.width=width; settings.height=height; settings.format=format
                        if !useCrop {settings.crop=nil}
                        dismiss()
                        DispatchQueue.main.async {model.exportImage(settings:settings)}
                    }
                }.buttonStyle(.borderedProminent).foregroundStyle(Theme.background).disabled(!valid || model.isExporting).keyboardShortcut(.defaultAction)
            }
        }.padding(28).frame(width:420).background(Theme.panel).preferredColorScheme(.dark).tint(Theme.accent)
    }
    private func matchAspect(fromWidth:Bool) {
        guard width>0,height>0 else {return}
        if fromWidth {let h=max(1,Int((Double(width)/model.recipe.canvasAspect).rounded())); if height != h {height=h}}
        else {let w=max(1,Int((Double(height)*model.recipe.canvasAspect).rounded())); if width != w {width=w}}
    }
}
