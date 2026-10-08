import Foundation
import LumoCore

// Explicit verification mode only; normal launches collect no metrics and schedule no animation.
final class WindowMetrics:@unchecked Sendable {
    static let shared=WindowMetrics()
    static let enabled=CommandLine.arguments.contains("--profile-window")
    private let lock=NSLock()
    private var timestamps:[Double]=[]
    private var active=false
    private var total=0
    func start() {lock.lock(); timestamps=[]; active=true; lock.unlock()}
    func presented(_ time:Double) {lock.lock(); total+=1; if active && time>0 {timestamps.append(time)}; lock.unlock()}
    func stop() -> [Double] {lock.lock(); active=false; let result=timestamps.sorted(); lock.unlock(); return result}
    var count:Int {lock.lock(); defer {lock.unlock()}; return total}
    @MainActor static func run(model:StudioModel) async {
        guard enabled else {return}
        if let index=CommandLine.arguments.firstIndex(of:"--profile-project"),CommandLine.arguments.count>index+1 {model.openProject(url:URL(fileURLWithPath:CommandLine.arguments[index+1]))}
        try? await Task.sleep(nanoseconds:1_500_000_000)
        let original=model.recipe
        shared.start()
        let start=ProcessInfo.processInfo.systemUptime
        for frame in 0..<180 {
            model.profileFrame(original:original,frame:frame)
            let delay=start+Double(frame+1)/60-ProcessInfo.processInfo.systemUptime
            if delay>0 {try? await Task.sleep(nanoseconds:UInt64(delay*1_000_000_000))}
        }
        try? await Task.sleep(nanoseconds:200_000_000)
        let times=shared.stop()
        model.profileRestore(original)
        try? await Task.sleep(nanoseconds:500_000_000)
        let idleStart=shared.count
        try? await Task.sleep(nanoseconds:1_000_000_000)
        let idleDraws=shared.count-idleStart
        let intervals=zip(times.dropFirst(),times).map {($0-$1)*1000}.filter {$0>0.1}.sorted()
        let average=times.count>1 ? Double(times.count-1)/(times.last!-times.first!) : 0
        let report:[String:Any]=["presentedFrames":times.count,"averageFPS":average,"medianFrameIntervalMilliseconds":intervals.isEmpty ? 0 : intervals[intervals.count/2],"p95FrameIntervalMilliseconds":intervals.isEmpty ? 0 : intervals[Int(Double(intervals.count)*0.95)],"idleDrawsInOneSecond":idleDraws,"previewMaximumPixels":1536,"passed":average>=30 && idleDraws==0]
        if let index=CommandLine.arguments.firstIndex(of:"--profile-window"),CommandLine.arguments.count>index+1 {
            let url=URL(fileURLWithPath:CommandLine.arguments[index+1])
            do {try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic)} catch {print(error)}
        }
        print(report)
    }
}
