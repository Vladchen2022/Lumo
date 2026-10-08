import SwiftUI
import LumoCore

struct ColorSourcesView: View {
    @ObservedObject var model: StudioModel
    private var index: Int {model.selectedColorLayer}
    private var layer: ColorLayer {model.recipe.layer(index)}
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("颜色来源 · 三层").font(.system(size:11,weight:.semibold))
                Spacer()
                Button {model.edit {$0.colorLocked.toggle()}} label: {Image(systemName:model.recipe.colorLocked ? "lock.fill" : "lock.open").foregroundStyle(model.recipe.colorLocked ? Theme.accent : Theme.secondary)}
                    .buttonStyle(.plain).help("锁定全部配色；换结构时保持颜色层").accessibilityLabel("锁定颜色")
            }
            VStack(spacing:3) {
                ForEach(0..<3,id:\.self) {i in
                    let item = model.recipe.layer(i)
                    HStack(spacing:6) {
                        Button {model.selectedColorLayer = i} label: {
                            HStack(spacing:6) {
                                Text("\(i+1)").font(.system(size:10,weight:.semibold,design:.monospaced)).frame(width:18,height:22).background(i == index ? Theme.accent.opacity(0.22) : Theme.inset,in:RoundedRectangle(cornerRadius:4))
                                Text(item.source?.name ?? (i == 0 ? "随机配色" : "添加参考图片")).font(.system(size:10)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength:0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).foregroundStyle(i == index ? Theme.accent : Theme.secondary).accessibilityLabel("选择颜色层 \(i+1)")
                        Button {model.edit {$0.setLayer(i) {$0.enabled.toggle()}}} label: {Image(systemName:item.enabled ? "eye" : "eye.slash").font(.system(size:10))}
                            .buttonStyle(.plain).foregroundStyle(Theme.secondary).disabled(i > 0 && item.source == nil).accessibilityLabel("显示颜色层 \(i+1)")
                    }.padding(.vertical,3)
                }
            }
            Button {model.importImage(color:true,layer:index)} label: {
                ZStack {
                    RoundedRectangle(cornerRadius:7).fill(Theme.inset)
                    if let source = layer.source, let image = NSImage(data:source.thumbnail) {Image(nsImage:image).resizable().scaledToFit().padding(4)}
                    else {VStack(spacing:6) {Image(systemName:"photo.badge.plus").font(.system(size:20)); Text("导入颜色层 \(index+1)").font(.system(size:10))}.foregroundStyle(Theme.accent)}
                    if model.importingLayers.contains(index) {Theme.background.opacity(0.7); ProgressView().controlSize(.small)}
                }.frame(height:84).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("导入颜色参考 \(index+1)")
            HStack {
                Text("\(index+1) / 3 · 后面的层覆盖前面的层").font(.system(size:9)).foregroundStyle(Theme.secondary)
                Spacer(minLength:0)
                if layer.source != nil {Button {model.clearSource(color:true,layer:index)} label: {Image(systemName:"xmark.circle")}.buttonStyle(.plain).font(.system(size:10)).help("清除当前颜色层")}
            }
            Button {model.showColorPicker = true} label: {
                HStack(spacing:3) {ForEach(Array(SceneGenerator.palette(for:model.recipe,layer:index,sixSlots:true).enumerated()),id:\.offset) {entry in Rectangle().fill(entry.element.color.swiftUI).frame(maxWidth:.infinity).frame(height:20)}}.clipShape(RoundedRectangle(cornerRadius:3))
            }.buttonStyle(.plain).disabled(layer.source == nil).accessibilityLabel("点选颜色层 \(index+1) 的色标").help("打开参考图，替换六个色标并调节占比")
            if layer.source != nil {
                Button("从参考图点选色标…") {model.showColorPicker = true}.buttonStyle(.borderless).font(.system(size:10))
            }
            Picker("层间混合",selection:model.layerBinding(index,\.blend)) {ForEach(ColorBlendMode.allCases,id:\.self) {Text($0.title).tag($0)}}.font(.system(size:10)).controlSize(.small)
            layerSlider("整层透明度",\.opacity)
            DisclosureGroup("色块内部混合") {
                VStack(spacing:10) {
                    Picker("色块方式",selection:model.layerBinding(index,\.blockBlend)) {ForEach(ColorBlendMode.allCases,id:\.self) {Text($0.title).tag($0)}}.controlSize(.small)
                    layerSlider("色块透明度",\.blockOpacity)
                }.padding(.top,10)
            }.font(.system(size:10)).foregroundStyle(Theme.secondary)
            HStack(spacing:6) {
                Button("导入三张…") {model.importImage(color:true,multiple:true)}.buttonStyle(.bordered)
                Button("换颜色") {model.randomize(shape:false)}.buttonStyle(.bordered).disabled(model.recipe.colorLocked)
            }.font(.system(size:10)).controlSize(.small)
        }
    }
    private func layerSlider(_ name: String, _ path: WritableKeyPath<ColorLayer,Double>) -> some View {
        VStack(spacing:4) {
            HStack {Text(name); Spacer(); Text("\(Int(layer[keyPath:path]*100))%").monospacedDigit()}.font(.system(size:10)).foregroundStyle(Theme.secondary)
            Slider(value:model.layerBinding(index,path),onEditingChanged:model.sliderEditing).controlSize(.small).accessibilityLabel("颜色层 \(index+1) \(name)")
        }
    }
}

struct ReferenceColorPicker: View {
    @ObservedObject var model: StudioModel
    let layer: Int
    @Environment(\.dismiss) private var dismiss
    @State private var pixels: ReferencePixels?
    @State private var loading = true
    @State private var slot = 0
    @State private var zoom = 1.0
    @State private var message = "点击图片，为选中色标取色"
    @State private var request = UUID()
    private var source: SourceReference? {model.recipe.layer(layer).source}
    private var palette: [PaletteEntry] {SceneGenerator.palette(for:model.recipe,layer:layer,adjusted:false,sixSlots:true)}
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("参考图取色 · 颜色层 \(layer+1)").font(.system(size:18,weight:.semibold)); Spacer(); Button("完成") {dismiss()}.keyboardShortcut(.cancelAction)}
            Text("先选下面的色标，再点击参考图。替换颜色后可提高权重，让小面积点缀色参与构成。").font(.system(size:11)).foregroundStyle(Theme.secondary)
            HStack(spacing:8) {
                ForEach(0..<6,id:\.self) {i in
                    Button {slot = i; message = "点击图片，替换色标 \(i+1)"} label: {
                        VStack(spacing:5) {
                            RoundedRectangle(cornerRadius:5).fill(palette[i].color.swiftUI).frame(height:34).overlay(RoundedRectangle(cornerRadius:5).stroke(i == slot ? Theme.accent : .clear,lineWidth:3))
                            Text("\(i+1) · \(Int(palette[i].weight*100))%").font(.system(size:10,design:.monospaced)).foregroundStyle(i == slot ? Theme.accent : Theme.secondary)
                        }
                    }.buttonStyle(.plain).accessibilityLabel("色标 \(i+1)")
                }
            }
            HStack {
                Text(source.flatMap {model.originalURL(for:$0)} != nil ? "原图像素取色 · sRGB" : "项目内取色预览 · sRGB").font(.system(size:10)).foregroundStyle(Theme.secondary)
                Spacer()
                Button("−") {zoom = max(1,zoom/1.5)}
                Text("\(Int(zoom*100))%").font(.system(size:10,design:.monospaced)).frame(width:44)
                Button("+") {zoom = min(8,zoom*1.5)}
            }.controlSize(.small)
            GeometryReader {proxy in
                if let pixels {
                    let fit = min(proxy.size.width/Double(pixels.width),proxy.size.height/Double(pixels.height))
                    let width = Double(pixels.width)*fit*zoom, height = Double(pixels.height)*fit*zoom
                    ScrollView([.horizontal,.vertical]) {
                        Image(decorative:pixels.image,scale:1).resizable().interpolation(.none).frame(width:width,height:height)
                            .contentShape(Rectangle()).onTapGesture(coordinateSpace:.local) {point in pick(x:point.x/width,y:point.y/height)}
                            .frame(minWidth:proxy.size.width,minHeight:proxy.size.height)
                    }.background(Theme.background)
                } else if loading {ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)}
                else {Text(message).font(.system(size:11)).frame(maxWidth:.infinity,maxHeight:.infinity)}
            }.frame(height:380).clipShape(RoundedRectangle(cornerRadius:6))
            HStack(spacing:14) {
                Text("色标 \(slot+1) 权重").font(.system(size:11))
                Slider(value:Binding(get:{model.recipe.layer(layer).weightOverrides[slot] ?? palette[slot].weight},set:{value in model.edit {$0.setLayer(layer) {$0.weightOverrides[slot] = value}}}),in:0.005...1,onEditingChanged:model.sliderEditing).accessibilityLabel("选中色标权重")
                Button("恢复自动色标") {model.edit {$0.setLayer(layer) {$0.paletteOverrides = [:]; $0.weightOverrides = [:]}}}.controlSize(.small)
            }
            Text(message).font(.system(size:11)).foregroundStyle(Theme.secondary)
        }.padding(24).frame(width:720).background(Theme.panel).preferredColorScheme(.dark).tint(Theme.accent)
        .task(id:source) {
            pixels = nil; loading = true; request = UUID()
            guard let source else {loading = false; message = "颜色来源已清除，请关闭取色窗口重新导入"; return}
            do {
                let result = try await Task.detached {try ReferencePixels(data:source.samplingImage ?? source.thumbnail)}.value
                guard !Task.isCancelled, self.source == source else {return}
                pixels = result; loading = false
            } catch {if !Task.isCancelled {message = error.localizedDescription; loading = false}}
        }
        .onDisappear {request = UUID()}
    }
    private func pick(x: Double, y: Double) {
        guard let source, let pixels, (0...1).contains(x), (0...1).contains(y) else {return}
        let target = slot, token = UUID(); request = token
        if let url = model.originalURL(for:source) {
            Task {
                do {
                    let color = try await Task.detached {try ReferencePixels.originalColor(url:url,x:x,y:y)}.value
                    guard request == token, self.source == source else {return}
                    if let color {model.pickColor(color,slot:target,layer:layer); message = "已从原图替换色标 \(target+1)"} else {message = "这里是透明像素，请选择有颜色的位置"}
                } catch {message = "原图无法读取，请重新导入；项目内配色保持不变"}
            }
        } else if let color = pixels.color(x:x,y:y) {model.pickColor(color,slot:target,layer:layer); message = "已从项目内预览替换色标 \(target+1)"}
        else {message = "这里是透明像素，请选择有颜色的位置"}
    }
}
