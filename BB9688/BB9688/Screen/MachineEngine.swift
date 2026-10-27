//
//  MachineEngine.swift
//  BB9688
//
//  把 BBVM 包成可观察对象：后台线程跑指令，主线程 24fps 拉一帧。
//  UI 只跟这里打交道。
//

import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI

// MARK: - 程序清单

struct BBProgram: Identifiable, Hashable {
    /// 稳定标识 = 目录名（`Programs/rich` → `rich`），列表排序和图标都靠它
    let id: String
    let title: String
    let detail: String
    /// 可执行字节码文件名
    let bin: String
    /// 程序目录（沙盒里那份，可写）
    let directory: URL?
    /// 列表图标上的一个字（来自 `info.json` 的 `icon`，或标题首字）
    let glyph: String?

    init(id: String, title: String, detail: String, bin: String,
         directory: URL? = nil, glyph: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.bin = bin
        self.directory = directory
        self.glyph = glyph
    }

    /// 内置程序的显示名（中文/带空格的名字没法靠目录名还原）
    static let builtinTitles: [String: String] = [
        "rich": "大富翁",
        "flappybird": "Flappy Bird",
        "man": "MAN 演示"
    ]

    /// 内置程序的陈列文案（尺寸单独算）。名字不在表里的就是外部程序。
    static let builtinBlurbs: [String: String] = [
        "rich": "学习机自带",
        "flappybird": "BBasic 复刻",
        "man": "图形端口自检"
    ]

    /// 内置程序的固定排序，保证「大富翁」永远在第一行
    static let builtinOrder = ["rich", "flappybird", "man"]
}

// MARK: - 资源落盘 / 程序发现

/// 安装包里的 Programs/ 是只读的，程序会写 .SAV / 临时文件，
/// 所以首次运行时整棵树复制到 Documents 下，之后**只认 Documents**。
///
/// 这样一来列表就不再是写死的三个：用户把任意一个程序目录
/// （`Programs/我的游戏/{xxx.bin, XXX.LIB}`）丢进 App 的「文件」里，
/// 或者直接丢一个 `.bin` 到 `Programs/` 根下，下次进列表就会自己出现。
enum ProgramStore {

    /// 调试/自测用：把根目录指到别处。线上永远是 nil，走 `<Documents>/Programs`。
    static var rootOverride: URL?

    /// 沙盒的 Documents（「文件」App 里那台机器的根目录）
    static var documents: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    /// `<Documents>/Programs`
    static var root: URL? {
        if let rootOverride {
            try? FileManager.default.createDirectory(at: rootOverride, withIntermediateDirectories: true)
            return rootOverride
        }
        guard let docs = documents else { return nil }
        let dir = docs.appendingPathComponent("Programs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 扫描位置，按优先级排列。
    ///
    /// 只认 `Programs/` 是不够的：`UIFileSharingEnabled` 打开后，
    /// 「文件」App 里看到的是 **Documents 根**（显示名「9688」），
    /// 大多数人（包括我们自己）会顺手把 `xxx.bin` / 程序文件夹丢在这一层，
    /// 结果以前列表里什么都不长，看起来就是「放了文件没反应、打不开」。
    /// 现在根目录里含 `.bin` 的文件夹、以及裸 `.bin` 都会被认出来，
    /// 而且直接在原地读写（Documents 内可写，不影响存档）。
    static var searchDirectories: [URL] {
        var dirs: [URL] = []
        if let root { dirs.append(root) }
        if let docs = documents, docs.standardizedFileURL != root?.standardizedFileURL {
            dirs.append(docs)
        }
        return dirs
    }

    /// 把安装包里的 Programs/ 整棵树补进 Documents。
    ///
    /// 以前这里是「`.seeded` 存在就整段跳过」，结果是**只要丢过一次就再也补不回来**：
    /// 用户把 `Documents/Programs/rich` 删掉（或在「文件」里挪走）之后，
    /// marker 还在 → 以后每次启动都不再播种 → 列表里内置程序凭空消失，
    /// 看着就像「读不到目录、打不开游戏」。
    /// 现在改成**每次开机都过一遍「缺什么补什么」**：
    /// 目录在就跳过、文件在就不拷，只有真的缺了才从安装包补一份（幂等、成本可忽略）。
    static func seedBundledPrograms() {
        let fm = FileManager.default
        guard let root, let src = AppResources.programsDirectory else { return }
        let marker = root.appendingPathComponent(".seeded")

        let items = (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix(".") { continue }
            let target = root.appendingPathComponent(name)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                try? fm.createDirectory(at: target, withIntermediateDirectories: true)
                for f in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] {
                    let dst = target.appendingPathComponent(f.lastPathComponent)
                    if !fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: f, to: dst) }
                }
                // 给每个程序目录留一个空的 Music 子目录。
                // 商业游戏的原声不能打进安装包，但用户得有个地方放 ——
                // 在「文件」App 里能直接看到的空目录，比一句文档说明管用。
                // 没有曲目表的程序放了也不会播（见 `BGMPlayer.scores`）。
                let music = target.appendingPathComponent("Music", isDirectory: true)
                if !fm.fileExists(atPath: music.path) {
                    try? fm.createDirectory(at: music, withIntermediateDirectories: true)
                }
            } else if !fm.fileExists(atPath: target.path) {
                try? fm.copyItem(at: item, to: target)
            }
        }
        if !fm.fileExists(atPath: marker.path) { try? Data().write(to: marker) }
    }

    /// 扫一遍所有搜索位置：`Documents/Programs` 优先，然后是 Documents 根。
    /// 目录项 = 程序，根下的裸 `.bin` 也算一个。
    /// 顺序：内置三个按 `builtinOrder`，其余按标题。同名（同一 id）只留先扫到的那个。
    static func discover() -> [BBProgram] {
        let fm = FileManager.default
        var found: [BBProgram] = []
        var usedIds = Set<String>()
        let rootPath = root?.standardizedFileURL.path

        for dir in searchDirectories {
            let items = (try? fm.contentsOfDirectory(at: dir,
                                                     includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            for item in items {
                let name = item.lastPathComponent
                if name.hasPrefix(".") || name.hasSuffix("-HD.LIB") { continue }
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                if isDir {
                    // Documents 根下的 Programs 目录已经在第一轮扫过，别当成一个程序
                    if let rootPath, item.standardizedFileURL.path == rootPath { continue }
                    guard let bin = pickBin(in: item) else { continue }
                    let program = make(folder: name, dir: item, bin: bin)
                    if usedIds.insert(program.id).inserted { found.append(program) }
                } else if name.lowercased().hasSuffix(".bin") || looksLikeBBE(item) {
                    // 裸可执行文件：`Programs/` 根或 Documents 根都行
                    let program = make(folder: name, dir: dir, bin: name, isFile: true)
                    if usedIds.insert(program.id).inserted { found.append(program) }
                }
            }
        }

        return found.sorted { a, b in
            let ia = BBProgram.builtinOrder.firstIndex(of: a.id) ?? Int.max
            let ib = BBProgram.builtinOrder.firstIndex(of: b.id) ?? Int.max
            if ia != ib { return ia < ib }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }

    /// 程序目录：`Documents/Programs/<folder>`，必要时从安装包补一份过来。
    /// 用户自己导入的目录本来就有 bin，不会走到补档分支。
    ///
    /// 注意这里补的是**缺哪个文件补哪个**，不是「没有 bin 才补」：
    /// 只拷了 `rich.bin` 却漏了 `RICH.LIB` 的时候，以前不会补 → 程序跑起来找不到资源，
    /// 表现就是进游戏黑屏/直接退出。
    static func directory(for folder: String) -> URL? {
        let fm = FileManager.default
        guard let root else { return nil }
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let src = AppResources.programsDirectory?.appendingPathComponent(folder, isDirectory: true),
           fm.fileExists(atPath: src.path) {
            for f in (try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)) ?? [] {
                let dst = dir.appendingPathComponent(f.lastPathComponent)
                if !fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: f, to: dst) }
            }
        }
        return dir
    }

    /// 沙盒可用空间（列表底部那行用真的，不再写死「剩余 1.2 MB」）
    static var freeSpaceText: String {
        guard let root,
              let v = try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
              let bytes = v.volumeAvailableCapacity else { return "剩余 —" }
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB]
        return "剩余 " + f.string(fromByteCount: Int64(bytes))
    }

    // MARK: 细节

    /// 一个目录里挑可执行文件：
    /// 1. 优先「目录同名.bin」，否则按名字取第一个 `.bin`；
    /// 2. 目录里一个 `.bin` 都没有时，退而看**文件头是不是 "BBE"** ——
    ///    网上流传的 BB 程序后缀五花八门（`.bbe` / `.dat` / 干脆没有后缀），
    ///    以前只认 `.bin`，这些包丢进去永远不出现，也是「放了文件没反应」的常见来源。
    private static func pickBin(in dir: URL) -> String? {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil))?
            .map(\.lastPathComponent) ?? [])
            .filter { !$0.hasPrefix(".") && !$0.hasSuffix("-HD.LIB") }
            .sorted()
        guard !names.isEmpty else { return nil }

        var bins = names.filter { $0.lowercased().hasSuffix(".bin") }
        if bins.isEmpty {
            bins = names.filter { looksLikeBBE(dir.appendingPathComponent($0)) }
        }
        guard !bins.isEmpty else { return nil }
        let folder = dir.lastPathComponent.lowercased()
        if let same = bins.first(where: { $0.lowercased() == "\(folder).bin" }) { return same }
        return bins[0]
    }

    /// 头三字节是 "BBE" 就当它是 BB 可执行文件
    private static func looksLikeBBE(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 3), head.count == 3 else { return false }
        return head[0] == 0x42 && head[1] == 0x42 && head[2] == 0x45   // "BBE"
    }

    private static func make(folder: String, dir: URL, bin: String, isFile: Bool = false) -> BBProgram {
        // 根目录下裸放的可执行文件：id 取去掉扩展名的名字（`demo.bin` → `demo`、`MARIO.bbe` → `MARIO`）
        let stem = isFile ? (folder as NSString).deletingPathExtension : folder
        let id = stem
        let size = ((try? FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent(bin).path))?[.size] as? Int) ?? 0
        let kb = max(1, (size + 1023) / 1024)

        // 程序目录里放一份 info.json 就能自定义标题/说明/图标：
        //   { "title": "超级玛丽", "detail": "外部程序", "icon": "玛", "bin": "MARIO.bin" }
        var title: String?
        var detail: String?
        var glyph: String?
        var binName = bin
        if let data = try? Data(contentsOf: dir.appendingPathComponent("info.json")),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            title = obj["title"] as? String
            detail = obj["detail"] as? String
            glyph = obj["icon"] as? String
            if let b = obj["bin"] as? String,
               FileManager.default.fileExists(atPath: dir.appendingPathComponent(b).path) {
                binName = b
            }
        }

        let name = (title?.isEmpty == false ? title : nil)
            ?? BBProgram.builtinTitles[id]
            ?? stem
        let blurb = BBProgram.builtinBlurbs[id]
        return BBProgram(id: id,
                         title: name,
                         detail: detail?.isEmpty == false
                            ? detail!
                            : (blurb.map { "\($0) · \(kb) KB" } ?? "外部程序 · \(kb) KB"),
                         bin: binName,
                         directory: dir,
                         glyph: glyph ?? name.first.map(String.init))
    }
}

// MARK: - 帧编码

enum FrameEncoder {
    /// 画布是 0x00RRGGBB，小端存放即 BGRA，直接交给 CGImage。
    ///
    /// 实现挪到了 `FrameScaler.makeImage`：它在拷贝缓冲时用 malloc + CGDataProvider
    /// 释放回调，而不走每帧一次的 `Data(buffer:)`（崩溃日志正好挂在那一步）。
    static func makeImage(from pixels: [UInt32], width: Int, height: Int) -> CGImage? {
        FrameScaler.makeImage(pixels, width: width, height: height)
    }
}

// MARK: - 引擎

final class MachineEngine: ObservableObject {

    /// 最新一帧。
    ///
    /// ★ **故意不加 `@Published`**。
    ///   以前它是 `@Published`，于是 24fps 每帧都触发一次 SwiftUI 的视图 diff。
    ///   2026-10-26 12:19 的崩溃就死在那一轮 diff 里：
    ///   `ViewGraph.beginNextUpdate → doDecrementSlow → _swift_release_dealloc`，
    ///   x0 = 0、故障地址 0xfffffffffffffff0 —— 释放了一个根本不存在的对象。
    ///   屏幕内容本来就不该走 SwiftUI 的视图树：它只是一张位图，
    ///   现在由 `LCDLayerView` 直接把 `layer.contents` 赋上去（见 `frameSink`），
    ///   24fps 这条路上一个 SwiftUI 值都不再产生，也就没有 diff 可崩。
    private(set) var image: CGImage?

    /// 帧输出口。`LCDLayerView` 挂上来之后，每出一帧就在这里赋一次 `layer.contents`。
    /// 只在主线程调用（帧泵挂在主 RunLoop 上）。
    var frameSink: ((CGImage) -> Void)?

    @Published private(set) var isRunning = false
    @Published private(set) var exitMessage: String?
    @Published private(set) var current: BBProgram?

    private var machine: BBVM?
    private var worker: Thread?
    private var pump: Timer?

    /// 「现在在哪个界面」的判定器。喂的是 SHOWPIC 的资源号，
    /// 结果用来给背景音乐自动切曲（见 `BGMPlayer`）。
    /// 生命周期跟着 engine 走，每局开新程序时 `reset()`。
    private let sceneDetector = BBSceneDetector()

    /// 金手指。只有大富翁的地址是已知的，其它程序挂上去也不会解锁（见 `BBCheat.unlocked`）。
    /// 放在 engine 上而不是 `AppModel` 上：它必须和 `machine` 同生共死，
    /// 否则换程序之后还捏着上一个 VM 的内存指针。
    let cheat = BBCheat()

    /// 每次 start / stop 递增。VM 线程结束是**异步**回来的，
    /// 用它判断「这个回调是不是已经翻篇的那一局」——
    /// 否则旧程序的收尾回调会把刚起来的新程序踢回列表。
    private var generation = 0

    /// 虚拟机线程结束时回调（主线程）。程序自己退出时，界面靠它回列表并说明原因；
    /// 不加这个的话界面会停在「运行中」的黑屏上，按什么键都没反应。
    var onExit: ((String) -> Void)?

    private var scratch: [UInt32] = []
    private var scratchW = 0
    private var scratchH = 0

    /// 虚拟机已经执行了多少条字节码。给运行监控算「指令/秒」用。
    /// 只在主线程读；VM 线程一直往前写，但 64 位读在 arm64 上是单条指令，不会撕。
    var vmStepCount: UInt64 { machine?.stepCount ?? 0 }

    /// 上一帧的快照，用来判断画面有没有变化（和 `scratch` 交换着用，不额外拷贝）
    private var lastFrame: [UInt32] = []
    private var lastOutputW = -1
    private var lastOutputH = -1

    /// UI 实际要显示的**像素**尺寸（点尺寸 × displayScale）。
    /// 设好之后每帧直接产出这个尺寸的图，UI 端 1:1 贴上，
    /// 不再让 Core Animation 用默认线性插值再放大一次 —— 那样字必糊。
    private var outputPixels = CGSize.zero

    // MARK: 输出尺寸

    func setOutputPixelSize(_ size: CGSize) {
        let w = max(0, Int(size.width.rounded()))
        let h = max(0, Int(size.height.rounded()))
        guard w != Int(outputPixels.width) || h != Int(outputPixels.height) else { return }
        outputPixels = CGSize(width: w, height: h)
        // ★ 不能在这里同步出图。
        //   这个函数是从 `onAppear` / `onChange` 里调的，也就是 SwiftUI **正在更新视图**
        //   的过程中。以前这里同步 `pumpFrame()`，会在视图更新里改状态；iOS 26 起
        //   新 ViewGraph 对重入非常敏感，内部对象会被打乱，之后 release 就崩。
        //   挪到下一次 RunLoop 再出图，语义不变（下一帧就贴上了）。
        DispatchQueue.main.async { [weak self] in self?.pumpFrame() }
    }

    // MARK: 生命周期

    /// ★ 画布超采样倍率。1 = 原版 240×320，3 = 720×960。
    ///
    /// 用户的原话是「股票界面不清晰」。指着屏幕看就三层问题叠在一起：
    ///   · 字号只有 12pt 的宋体，横画本身就是一个像素宽；
    ///   · 12pt 的 CoreText 抗锯齿把这一像素摊成两个半透明的灰像素；
    ///   · 最后一步放大 **3.675 倍**（240→881 不是整数），一个逻辑像素变成
    ///     3 个或 4 个屏幕像素 —— 同一行里竖笔忽粗忽细，灰边被吹成 3~4 像素的宽带。
    /// 前两条改不了（字库和字号是程序定的），只能从第三条下手：先把画布画大，再等比缩。
    ///
    /// **为什么是 3，而不是 2026-10-23 试过的 4**：
    ///   · 3× 画布 720 宽，到屏幕 881 是 **放大** ×1.224，走
    ///     `FrameScaler.upscaleNearest`（一次表查 + 写，每帧 103 万次写）；
    ///     一个画布像素大多落在 1 个屏幕像素上、偶尔 2 个，笔画粗细基本一致。
    ///   · 4× 画布 960 宽，到屏幕 881 是 **缩小** ×0.918，走 `downscaleArea`：
    ///     每个目标像素要采样 2~5 个源像素、再逐通道整数除法。那才是当年
    ///     「高清版本太卡了」的大头，不是画布本身。
    ///   · 顺带：`BBRenderer` 对 1× 素材的整数最近邻放大要求
    ///     `BBHD.scale % payloadScale == 0`，3 % 1 = 0 满足。
    ///
    /// 代价：填充/贴图面积 9×（文字最明显）、画布 + 帧拷贝缓冲约 5.4MB。
    /// **掉帧就把这个数字改回 1**，别处一行都不用动。
    static let renderScale = 3

    /// 启动程序。**成功返回 nil，失败返回给用户看的原因。**
    ///
    /// 以前这里返回 Void，失败只是把原因塞进 `exitMessage`，而 `AppModel` 不看这个值、
    /// 照样把界面切到「运行中」—— 于是用户看到的是「点了确定，屏幕黑着，什么都没发生」。
    /// 现在必须把失败原因带回去，让列表自己说话。
    @discardableResult
    func start(_ program: BBProgram) -> String? {
        stop()

        // 每次起机都从设置里同步一次速度倍率：用户在设置页改完直接进游戏，
        // 不应该还要「先退出再重进」才生效。
        BBVM.loadSpeedFromDefaults()

        guard let dir = program.directory ?? ProgramStore.directory(for: program.id) else {
            return fail("找不到程序目录 \(program.id)")
        }
        let binURL = dir.appendingPathComponent(program.bin)
        guard let data = try? Data(contentsOf: binURL) else {
            return fail("读不到 \(program.bin)（目录：\(dir.lastPathComponent)）")
        }
        if data.count < 16 {
            return fail("\(program.bin) 只有 \(data.count) 字节，不像完整的 BB 程序")
        }

        // 画布倍率必须在 BBVM 建屏幕**之前**定：屏幕尺寸 = 240·scale × 320·scale。
        BBHD.scale = MachineEngine.renderScale

        // `*-HD.LIB` 是高清覆盖包（现在装的是 3× 重制的骰子精灵图，见
        // Tools/pack_hd_lib.py / clean_dice_art.py）。老安装的 Documents 里可能还留着
        // 4× 时代的旧包 —— payload 倍率对不上 3× 画布，贴出来会错位，必须换掉。
        // 策略：安装包里有同名新版就**整体替换**（Documents 只补缺文件，覆盖不了旧的）；
        // 安装包里没有的（用户手放的孤儿包）才删，行为与旧逻辑一致。
        // RICH.LIB / rich.bin / *.SAV 一概不动。
        do {
            let fm = FileManager.default
            let bundleDir = AppResources.programsDirectory?
                .appendingPathComponent(dir.lastPathComponent, isDirectory: true)
            if let items = try? fm.contentsOfDirectory(at: dir,
                                                       includingPropertiesForKeys: nil) {
                for url in items where url.lastPathComponent.hasSuffix("-HD.LIB") {
                    let bundled = bundleDir?.appendingPathComponent(url.lastPathComponent)
                    if let bundled, fm.fileExists(atPath: bundled.path) {
                        // 内容一致就别删了重拷 —— 每次启动省一次 100KB 级 IO
                        if !fm.contentsEqual(atPath: bundled.path, andPath: url.path) {
                            try? fm.removeItem(at: url)
                            try? fm.copyItem(at: bundled, to: url)
                        }
                    } else {
                        try? fm.removeItem(at: url)
                    }
                }
            }
        }

        // 文字渲染外面套一层探针：黑市那种界面只能靠「屏幕上出现了哪些字」来认。
        // 探针只转发，不改绘制行为。
        let textProbe = BBTextProbe(wrapping: CoreTextRenderer())
        let vm = BBVM(programDirectory: dir, textRenderer: textProbe)
        let codeSize = vm.load(bin: data)
        guard codeSize > 0 else {
            return fail("\(program.bin) 载入后是空的")
        }
        vm.screen.clear()

        // ── 背景音乐：按界面自动切，不需要用户选曲 ──────────────────
        // 资源号是唯一可靠的「当前在哪个界面」信号：BBK 版删掉了音频，
        // 但画面还是原版的画面，棋盘每帧重绘几百笔地块图这件事改不掉。
        // 检测器内部有 0.35s 节流，`feed` 只是累加，不在这里做判断。
        sceneDetector.onChange = { scene in BGMPlayer.shared.setScene(scene) }
        sceneDetector.reset()
        vm.graphics.onPictureDrawn = { [weak self] index, area in
            self?.sceneDetector.feed(libIndex: index, area: area)
        }
        // 画笔操作：游乐场那个「小碗接金币」完全没有贴图，只能靠这个认出来。
        vm.graphics.onPaintOp = { [weak self] _ in
            self?.sceneDetector.feedPaint()
        }
        // 文字：黑市没有任何图能代表它，只能靠商品名（催眠符 / 購地卡…）认。
        textProbe.onChar = { [weak self] bytes in
            self?.sceneDetector.feedText(bytes)
        }
        BGMPlayer.shared.attach(programID: program.id, programDirectory: dir)

        // ── 金手指 ──────────────────────────────────────────────────
        // 骰子点数不进内存，只能挂在 VM 的随机数出口上；现金和股价是内存数组，
        // `BBCheat` 自己用定时器读写（见那个文件顶部）。
        // 钩子里**不能**碰任何 UI 状态：它跑在 VM 线程上（见 2026-10-26 的崩溃记录）。
        cheat.attach(vm)
        vm.randomHook = { [weak self] n, frameBase in
            self?.cheat.diceOverride(n: n, frameBase: frameBase)
        }

        current = program
        exitMessage = nil
        machine = vm
        generation &+= 1
        let gen = generation

        let thread = Thread { [weak self] in
            // 登记这条线程的 mach port —— `task_threads` 只给 port 不给名字，
            // 不登记的话运行监控就没法把「虚拟机线程」和主线程分开，
            // 看到 90% 的 CPU 也不知道是谁烧的。
            BBPerfSampler.shared.registerMachineThread()
            vm.run()
            BBPerfSampler.shared.unregisterMachineThread()
            let reason = vm.exitReason ?? "程序结束"
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.isRunning = false
                self.exitMessage = reason
                self.stopPump()
                // 收尾再拉一帧，把最后一屏留住
                self.pumpFrame()
                self.onExit?(reason)
            }
        }
        thread.stackSize = 8 * 1024 * 1024
        thread.qualityOfService = .userInteractive
        worker = thread
        isRunning = true
        thread.start()
        startPump()
        return nil
    }

    /// 统一的失败出口：既记进 `exitMessage`（运行态收尾时也会用到），
    /// 又返回给调用方 —— 两边都不能漏。
    private func fail(_ message: String) -> String {
        exitMessage = message
        isRunning = false
        return message
    }

    func stop() {
        generation &+= 1
        machine?.stop()
        machine = nil
        worker = nil
        stopPump()
        isRunning = false
        // 金手指跟着这一局一起收：它的地址只对当前这份程序镜像有效
        cheat.detach()
        // 两个缓冲都清掉：下次 start 的第一帧必须重新编码，不能和上一局的残留比对
        clearScratch()
        // 音乐跟着一起收：留着一个「程序已退出但还在放地图曲」的尾巴很奇怪
        sceneDetector.reset()
        BGMPlayer.shared.detach()
    }

    // MARK: 输入

    func sendKey(_ code: UInt32) {
        // 确认键（回车）= 掷骰子 / 确定。配一声骰子撞击。
        //
        // 为什么挂在按键上而不是「识别到骰子动画」：
        // BBK 版的骰子是**程序画出来的**（图形端口画方块和点），
        // LIB 里没有任何骰子图，资源号追踪不到。按键是唯一可靠的时机。
        // 音效自带 90ms 限流，长按不会连发成机关枪。
        if code == 13 {
            BGMPlayer.shared.playEffect("DICE")
        }
        machine?.input.pushKey(code)
    }

    /// 松手时清掉还没被程序消费掉的方向键（长按连发会留下几个）
    func dropPendingDirections() {
        machine?.input.dropPendingDirections()
    }

    func tap(x: Int, y: Int) {
        machine?.input.pushTap(x: x, y: y)
    }

    func hold(_ code: UInt32, _ pressed: Bool) {
        machine?.input.setHeld(code, pressed: pressed)
    }

    func sendText(_ scalar: UInt32) {
        machine?.input.pushText(scalar)
    }

    // MARK: 帧泵

    private func startPump() {
        stopPump()
        let timer = Timer(timeInterval: 1.0 / Double(BBConst.fps), repeats: true) { [weak self] _ in
            self?.pumpFrame()
        }
        RunLoop.main.add(timer, forMode: .common)
        pump = timer
    }

    private func stopPump() {
        pump?.invalidate()
        pump = nil
    }

    private func clearScratch() {
        scratch = []
        lastFrame = []
        scratchW = 0
        scratchH = 0
        lastOutputW = -1
        lastOutputH = -1
    }

    private func pumpFrame() {
        guard let vm = machine else { return }

        // 场景识别要**先于**「画面没变就返回」那一关：棋盘等玩家掷骰子时
        // 会静止好几秒，画面不变，但累计值仍在衰减，判定必须照常跑。
        // 内部有 0.35s 节流，这里按 24fps 调进去只有一次布尔比较。
        sceneDetector.tick()

        // 计时只在主线程做，不引锁、不跨线程 —— 监控自己不能成为开销。
        let tCopyStart = CACurrentMediaTime()

        // 锁内「取画布 + 拷像素」。绝不能先 `let s = vm.screen.surface` 再慢慢读：
        // VM 线程的 IN 16 会整个替换 surface，那个「取指针 + retain」和后台的
        // 「存新值 + release 旧值」交错时会把旧画布多释放一次（见 BBScreen.frameLock）。
        guard let shot = vm.screen.copyFrame(into: &scratch) else { return }
        let copyMS = (CACurrentMediaTime() - tCopyStart) * 1000
        let w = shot.width
        let h = shot.height

        if w != scratchW || h != scratchH {
            scratchW = w
            scratchH = h
            lastFrame = []
            lastOutputW = -1
            lastOutputH = -1
            image = nil
        }

        // 尺寸护栏：`setOutputPixelSize` 可能收到 0（布局还没完成）或异常大的值
        // （分屏 / SlideOver 时尺寸抖动）。一旦进了缩放，后面就是「按一个不该出现的
        // 尺寸去分配缓冲」。这里把不合法的尺寸直接退回画布原尺寸。
        let rawW = Int(outputPixels.width)
        let rawH = Int(outputPixels.height)
        let sizeOK = rawW > 1 && rawH > 1 && rawW <= 4096 && rawH <= 4096
        let outW = sizeOK ? rawW : w
        let outH = sizeOK ? rawH : h

        // ★ 画面没变就什么都不做。
        //   大富翁有一大半时间是静止的（等你掷骰子、看地图、读提示），
        //   但帧泵是 24fps 死循环：以前每帧都要把 307KB 拷一遍、放大到 88 万像素、
        //   再建一张 3.5MB 的 CGImage，屏幕却一个像素都没动。
        //   现在先和上一帧逐字节比（`memcmp`，307KB 大约几十微秒），
        //   一样就直接返回 —— 静止时 CPU/内存带宽基本归零，也顺带省电。
        if image != nil, lastOutputW == outW, lastOutputH == outH,
           lastFrame.count == w * h,
           lastFrame.withUnsafeBufferPointer({ old in
               scratch.withUnsafeBufferPointer { new in
                   guard let a = old.baseAddress, let b = new.baseAddress else { return false }
                   return memcmp(a, b, w * h * MemoryLayout<UInt32>.stride) == 0
               }
           }) {
            PerfHub.shared.noteSkippedFrame()
            return
        }

        let encodeStart = CACurrentMediaTime()
        let needsScale = outW > 1 && outH > 1 && (outW != w || outH != h)

        // 重采样到 LCD 的实际像素尺寸。
        //
        // ★ 这里**没有锐化**，而且缩放也不再走 vImage 的 Lanczos。
        //   原因见 FrameScaler 顶部：Lanczos 的负瓣会在每条 1px 描边两侧顶出错位的
        //   亮/暗虚影（实测 240→881 时每行约 80 个采样被顶出 107/255），
        //   大富翁的字、HUD 金边、骰子边全是 1px 描边 —— 屏幕上就是
        //   "右边那一小节跑到左边""描边旁边多一根线"。
        //   现在放大走最近邻、缩小走面积平均，两个核都非负，物理上不可能振铃。
        //   3×3 拉普拉斯锐化也一起删了：它本身就是振铃算子，之前只是为了补 Lanczos 的软。
        //
        // ★ 要缩放就不要先建一张全尺寸的 CGImage 再扔掉。
        //   `makeImage` 里 `Data(buffer:)` 会把整张画布再拷一遍 ——
        //   HD 下是 960×1280×4 = 4.9MB/帧，纯浪费（24fps 就是 118MB/s 的堆带宽）。
        var next: CGImage? = needsScale
            ? FrameScaler.scaledImage(from: scratch, width: w, height: h,
                                      toWidth: outW, toHeight: outH)
            : nil
        // 缩放失败（或本来就不需要缩放）才退回原尺寸图
        if next == nil {
            next = FrameEncoder.makeImage(from: scratch, width: w, height: h)
        }

        guard let next else { return }
        PerfHub.shared.noteFrame(copyMs: copyMS,
                                 encodeMs: (CACurrentMediaTime() - encodeStart) * 1000)
        image = next
        // 直接交给屏幕图层。这一步是普通属性赋值（主线程），
        // 不产生任何 SwiftUI 视图值，也就没有 ViewGraph 的 diff。
        frameSink?(next)

        // 记住这一帧，供下次比较。用交换而不是拷贝：两份缓冲都是满的，
        // 交换是 O(1)，下一帧的 `copyFrame` 会把它整个覆盖掉。
        if lastFrame.count != w * h { lastFrame = [UInt32](repeating: 0, count: w * h) }
        swap(&scratch, &lastFrame)
        lastOutputW = outW
        lastOutputH = outH
    }
}
