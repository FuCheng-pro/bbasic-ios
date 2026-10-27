//
//  PerfLog.swift
//  BB9688
//
//  运行日志的**落盘层**：把监控读数每秒写一行到 CSV，存在「文件」App 能看到的目录里。
//
//  为什么要这个：
//    截图只能抓到一个瞬间，而且发热是「随时间变化」的问题 —— 进游戏头 10 秒正常、
//    第 30 秒开始掉帧，这种曲线截图是抓不到的。落盘之后一次游玩就是一条完整曲线，
//    停下来再看，比反复截图准得多。
//
//  放在哪：
//    <Documents>/PerfLog/perf-yyyyMMdd-HHmmss.csv
//    Info.plist 里 UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace 都开着，
//    所以「文件」App → 我的 iPhone → 9688 → PerfLog 里能直接看到，
//    也能长按分享。App 里还给了分享按钮，走系统面板发出去即可。
//
//  格式：
//    第一行是表头，之后每行要么是 kind=s（每秒样本），要么是 kind=e（事件）。
//    严格 CSV：逗号分隔、字段里绝不含逗号（注释里的逗号换成「·」）。
//    既有 apple 的数字格式都能直接打开，也方便我这边脚本算 p95 / 找拐点。
//
//  开销：
//    1Hz + 一次 write(2)，一秒钟不到 100 字节，可以忽略。
//    单份文件超 8MB 自动换新（约 20 小时），最多留 15 份，多了删最旧的。
//

import Combine
import Darwin
import Foundation

final class PerfLog: ObservableObject {

    static let shared = PerfLog()

    /// 面板里列出来的一行
    struct FileInfo: Identifiable {
        let url: URL
        let bytes: Int
        let modified: Date
        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    /// 日志子目录名（Documents 下一层，避免和程序目录混在一起）
    static let folderName = "PerfLog"
    /// 最多保留几份
    static let keepFiles = 15
    /// 单份上限（字节），超了自动换新
    static let maxBytes = 8 * 1024 * 1024

    // MARK: 对外状态

    /// 是否正在记录。关掉之后文件仍然在，只是不再增长。
    @Published private(set) var isActive = false
    @Published private(set) var currentName = ""
    /// 当前文件已经写了多少行（含事件行），面板上显示用
    @Published private(set) var lineCount = 0

    // MARK: 内部

    private let lock = NSLock()
    private var handle: FileHandle?
    private var url: URL?
    private var startedAt = Date()
    private var seconds = 0
    private var bytes = 0

    /// 会话累计，用来在收尾时写一行汇总
    private var sampleCount = 0
    private var fpsSum = 0.0
    private var frameSum = 0.0
    private var maxFrame = 0.0
    private var cpuSum = 0.0
    private var stepsSum = 0.0
    private var hotSeconds = 0

    private init() {}

    // MARK: 目录

    static var directory: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                 in: .userDomainMask).first else { return nil }
        let dir = docs.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: 开关

    /// 打开就继续写当前文件（没有就新建），关掉就收尾并关闭句柄。
    func setActive(_ on: Bool) {
        if on {
            if !isActive { startNew() }
        } else if isActive {
            finish(note: "记录已关闭")
        }
    }

    /// 换一份新文件（用户主动点，或单份超过上限时自动调用）
    func startNew() {
        finish(note: "换新文件")

        guard let dir = Self.directory else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let file = dir.appendingPathComponent("perf-\(stamp.string(from: Date())).csv")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let h = try? FileHandle(forWritingTo: file) else { return }

        lock.lock()
        handle = h
        url = file
        startedAt = Date()
        seconds = 0
        bytes = 0
        sampleCount = 0
        fpsSum = 0; frameSum = 0; maxFrame = 0; cpuSum = 0; stepsSum = 0; hotSeconds = 0
        isActive = true
        currentName = file.lastPathComponent
        lineCount = 0
        lock.unlock()

        write(Self.header, to: h)
        event("会话开始 · v\(Self.appVersion) · \(Self.deviceModel()) · \(ProcessInfo.processInfo.operatingSystemVersionString)"
              + " · 速度 \(String(format: "%.2f", BBVM.speedScale))× 目标 "
              + "\(Int(BBConst.baseStepsPerSecond * BBVM.speedScale / 10_000)) 万条/秒")

        pruneOldFiles(keeping: file)
    }

    /// 收尾：补一行汇总再关文件。`note` 会出现在汇总行里。
    func finish(note: String) {
        lock.lock()
        guard isActive, let h = handle else {
            isActive = false
            handle = nil
            url = nil
            lock.unlock()
            return
        }
        let n = sampleCount
        let avgFPS = n > 0 ? fpsSum / Double(n) : 0
        let avgFrame = n > 0 ? frameSum / Double(n) : 0
        let avgCPU = n > 0 ? cpuSum / Double(n) : 0
        let avgSteps = n > 0 ? stepsSum / Double(n) : 0
        // 用插值拼，不用 String(format:) —— 后者混用 %d 和 Int 在 64 位上是
        // 「能跑但很脆」的写法，汇总行不值得冒这个险。
        let summary = "会话结束（\(note)）· 时长 \(seconds)s · 样本 \(n)"
            + " · 均帧 " + String(format: "%.1f", avgFPS)
            + " · 均一帧 " + String(format: "%.1f", avgFrame) + "ms"
            + " · 峰值 " + String(format: "%.1f", maxFrame) + "ms"
            + " · 均CPU " + String(format: "%.0f", avgCPU) + "%"
            + " · 均指令 " + String(format: "%.0f", avgSteps) + "/s"
            + " · 过热 \(hotSeconds)s"
        let row = line(kind: "e", values: Array(repeating: "", count: 15), note: summary)
        write(row, to: h)
        try? h.close()

        isActive = false
        handle = nil
        url = nil
        currentName = ""
        lock.unlock()
    }

    // MARK: 写入

    /// 每秒一条。由 `PerfHub.tick()` 在主线程调。
    func record(_ r: PerfHub.Reading) {
        let shouldRotate: Bool

        lock.lock()
        guard isActive, let h = handle else {
            lock.unlock()
            return
        }
        seconds += 1
        sampleCount += 1
        fpsSum += r.fps
        frameSum += r.frameMS
        maxFrame = max(maxFrame, r.frameMS)
        cpuSum += r.cpuProcess
        stepsSum += r.stepsPerSecond
        if r.thermalRaw >= 2 { hotSeconds += 1 }

        let values = [
            String(format: "%.1f", r.fps),
            String(format: "%.2f", r.frameMS),
            String(format: "%.2f", r.copyMS),
            String(format: "%.2f", r.encodeMS),
            String(format: "%.0f", r.paintedRatio * 100),
            String(format: "%.0f", r.cpuProcess),
            r.cpuMachine < 0 ? "" : String(format: "%.0f", r.cpuMachine),
            r.cpuMain < 0 ? "" : String(format: "%.0f", r.cpuMain),
            String(r.totalSteps),
            String(format: "%.0f", r.stepsPerSecond),
            String(format: "%.0f", r.footprintMB),
            String(r.threadCount),
            r.thermal,
            r.lowPower ? "1" : "0",
            r.machineRunning ? "1" : "0",
        ]
        let row = line(kind: "s", values: values, note: "")
        let added = write(row, to: h)

        bytes += added
        lineCount += 1
        shouldRotate = bytes > Self.maxBytes && seconds > 5
        let full = bytes
        lock.unlock()

        if shouldRotate {
            startNew()
            event("单份超过 \(full / 1024 / 1024)MB，已自动换新文件")
        }
    }

    /// 事件行：启动、失败、结束、切前后台、温度跳档…都走这里。
    /// 这是日志里最有用的部分 —— 光看数字分不清「第 40 秒掉帧」是因为换了个画面
    /// 还是因为系统开始降频，事件行能把两件事对上时间轴。
    func event(_ note: String) {
        lock.lock()
        guard isActive, let h = handle else {
            lock.unlock()
            return
        }
        let row = line(kind: "e", values: Array(repeating: "", count: 15), note: note)
        bytes += write(row, to: h)
        lineCount += 1
        lock.unlock()
    }

    // MARK: 列表 / 清理

    /// 所有日志，最新在前
    static func files() -> [FileInfo] {
        guard let dir = directory,
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return [] }

        return items
            .filter { $0.pathExtension.lowercased() == "csv" }
            .compactMap { u -> FileInfo? in
                let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return FileInfo(url: u,
                                bytes: v?.fileSize ?? 0,
                                modified: v?.contentModificationDate ?? Date.distantPast)
            }
            .sorted { $0.modified > $1.modified }
    }

    static func deleteAll() {
        shared.finish(note: "清空日志")
        for f in files() {
            try? FileManager.default.removeItem(at: f.url)
        }
    }

    /// 只留最近 `keepFiles` 份（`keeping` 那份一定留）
    private func pruneOldFiles(keeping current: URL) {
        let all = Self.files()
        guard all.count > Self.keepFiles else { return }
        for f in all.dropFirst(Self.keepFiles) where f.url != current {
            try? FileManager.default.removeItem(at: f.url)
        }
    }

    // MARK: 拼行

    /// 表头。加一列都要同时改这里和 `record` 的 values 数组。
    private static let header = "wall,sec,kind,fps,frameMs,copyMs,encMs,paintPct,cpuPct,vmPct,mainPct,steps,stepPerSec,memMB,threads,thermal,lowPower,vmRunning,note"

    /// 19 列固定顺序。事件行的 15 个数值位留空，这样表格里时间轴还是对齐的。
    private func line(kind: String, values: [String], note: String) -> String {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm:ss"
        var cols: [String] = [clock.string(from: Date()), String(seconds), kind]
        cols.append(contentsOf: values)
        cols.append(note.replacingOccurrences(of: ",", with: "·")
                        .replacingOccurrences(of: "\n", with: " "))
        return cols.joined(separator: ",")
    }

    @discardableResult
    private func write(_ text: String, to h: FileHandle) -> Int {
        guard let data = (text + "\n").data(using: .utf8) else { return 0 }
        do {
            try h.write(contentsOf: data)
            return data.count
        } catch {
            return 0
        }
    }

    // MARK: 环境信息

    private static var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v)(\(b))"
    }

    /// `hw.machine` 给的是「iPhone13,2」这种型号串，比 UIDevice.name 有用得多 ——
    /// 同一个「iPhone」在不同机型上 CPU 差好几倍，判断读数是否正常要靠这个。
    private static func deviceModel() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }
}
