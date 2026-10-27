//
//  BGMPlayer.swift
//  BB9688
//
//  背景音乐：按「当前界面」自动换曲，用户不需要选曲目。
//
//  ── 为什么要自己配一套曲目表 ──────────────────────────────────
//  BBK 版的大富翁在移植时把音乐整条删掉了（RICH.LIB 里没有音频数据，
//  rich.bin 的 9 万条指令里也没有任何音频端口调用）。所以「哪个画面配哪首」
//  这个信息在原厂代码里不存在，只能根据 DOS 原版（1993）的曲目语义重建：
//
//      RICHT        标题「好运当头」              → 标题画面
//      RICHP        片头「重返大富翁城」           → 开机
//      RICHA–RICHH  地图音乐 01–08                → 棋盘，一首接一首轮换
//      RICHO/Z/N    赌场 / 黑市 / 游乐场           → 预留（还没采样到资源号）
//      RICHY        倒闭音效                      → 预留
//
//  ── 音乐文件从哪来 ───────────────────────────────────────────
//  商业游戏的原声不能打进安装包。所以约定：
//
//      <程序目录>/Music/*.m4a        例：Documents/Programs/rich/Music/RICHT.m4a
//
//  放进去就会被自动发现，按文件名（不分大小写）对号入座。
//  目录不存在或一首都没找到 → 全程静音，不报错、不影响游戏。
//

import Foundation

#if canImport(AVFoundation)
import AVFoundation

final class BGMPlayer: NSObject, AVAudioPlayerDelegate {

    static let shared = BGMPlayer()

    /// 曲目表：程序 id → 场景 → 文件名（不含扩展名）
    ///
    /// 一个场景给多首的时候按顺序轮换，一首播完接下一首，
    /// 这样地图阶段不会 2 分钟一直重复同一段。
    ///
    /// 对应关系不是猜的：来自官方原声带（Steam / LINE MUSIC 上架的
    /// 《大富翁2遊戲原聲帶》，作曲杜迺迪）与 Fandom 的 BGM 一览表，
    /// 并用**时长逐秒核对**过：
    ///     重返大富翁城 0:20 = RICHP(0:20)   好运当头 0:26 = RICHT(0:26)
    ///     繁华都市 1:57 = RICHA(1:57)       美丽的错误 2:06 = RICHB(2:06)
    ///     包君满意 1:36 = RICHD(1:37)       环游旅行 1:50 = RICHF(1:51)
    ///     万事如意 1:31 = RICHG(1:31)
    /// 七首全中，误差 ≤1 秒（转码舍入）。
    ///
    /// 地图八首的顺序照原版：01=A 02=B 03=C 04=D 05=F 06=G 07=H **08=E**。
    /// 注意最后一个是 E 不是 E,F,G,H 顺着排 —— 原版把 E 排在第八位。
    private static let scores: [String: [BBScene: [String]]] = [
        "rich": [
            .title:  ["RICHT"],                      // 好运当头
            .casino: ["RICHO"],                      // 赌场
            .park:   ["RICHN"],                      // 游乐场（777 格，接金币小游戏）
            .market: ["RICHZ"],                      // 黑市（买卡片）
            .settle: ["RICHM"],                      // 每月结算（银行利息 + 排行）
            .bankrupt: ["RICHS"],                    // 周转不灵 / 倒闭
            .board:  ["RICHA", "RICHB", "RICHC", "RICHD",
                      "RICHF", "RICHG", "RICHH", "RICHE"],
        ]
    ]

    /// 淡入淡出时长。0.8s 足够盖掉切歌的突兀，又不会让人觉得"反应慢"。
    private let fade: TimeInterval = 0.8
    /// 目标音量。游戏音效比音乐重要，别盖过按键反馈。
    private let level: Float = 0.55

    private var player: AVAudioPlayer?
    private var folder: URL?
    private var scene: BBScene = .boot
    private var cursor = 0

    private override init() { super.init() }

    // MARK: - 开关

    private static let enabledKey = "bb.bgm"

    /// 默认开。用户关掉后不再自动起播。
    var isEnabled: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: Self.enabledKey) == nil { return true }
            return d.bool(forKey: Self.enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            guard newValue else { stop(); return }
            // 重新打开时要**把当前场景再放一遍**。
            // 不能直接 `apply(scene)`：那个函数用「新场景 == 旧场景」去重，
            // 而这里场景根本没变，会被它当成无事发生，结果开了开关还是静音。
            let current = scene
            scene = .boot
            apply(current)
        }
    }

    /// 目录里有没有可用的音乐。设置页可以据此显示「未导入」。
    var hasMusic: Bool { folder != nil }

    // MARK: - 挂接 / 卸载

    /// 起机时调用：找到这个程序的音乐目录，准备好播放器。
    func attach(programID: String, programDirectory: URL?) {
        DispatchQueue.main.async {
            self.scene = .boot
            self.cursor = 0
            self.trackList = Self.scores[programID] ?? [:]
            self.folder = Self.locate(programID: programID, programDirectory: programDirectory)
            self.configureSession()
        }
    }

    /// 关机 / 退出程序时调用。
    func detach() {
        DispatchQueue.main.async {
            self.scene = .boot
            self.trackList = [:]
            self.folder = nil
            self.stop()
        }
    }

    // MARK: - 场景切换（渲染泵 / VM 线程调用）

    func setScene(_ new: BBScene) {
        DispatchQueue.main.async { self.apply(new) }
    }

    private var trackList: [BBScene: [String]] = [:]

    private func apply(_ new: BBScene) {
        guard isEnabled, new != scene else { return }
        scene = new
        guard let names = trackList[new], !names.isEmpty else {
            // boot 或没有配曲的场景：静音，但不打断正在放的（棋盘上的对话框
            // 也走 board 场景，所以这里基本只会是 boot）
            if new == .boot { stop() }
            return
        }
        play(names[cursor % names.count], loops: names.count == 1 ? -1 : 0)
    }

    // MARK: - 播放

    private func play(_ name: String, loops: Int) {
        guard let url = url(for: name) else { return }
        guard let next = try? AVAudioPlayer(contentsOf: url) else { return }

        next.numberOfLoops = loops
        next.delegate = self
        next.volume = 0
        guard next.play() else { return }
        next.setVolume(level, fadeDuration: fade)

        // 旧的先淡出再停。`old` 是局部捕获的，一定是上一首，
        // 不存在「延迟回调把新歌停掉」的风险，所以不需要额外判断。
        let old = player
        player = next
        old?.setVolume(0, fadeDuration: fade)
        DispatchQueue.main.asyncAfter(deadline: .now() + fade + 0.1) {
            old?.stop()
        }
    }

    func stop() {
        player?.setVolume(0, fadeDuration: 0.25)
        let dying = player
        player = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dying?.stop() }
    }

    // MARK: - 单曲播完 → 轮换下一首

    /// AVAudioPlayer 的这个回调**不在主线程**，而 `play()` 里要建新播放器、
    /// 改 `player` / `cursor` —— 统一丢回主线程做，免得和 `apply()` 抢。
    func audioPlayerDidFinishPlaying(_ finished: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            guard self.isEnabled, self.player === finished else { return }
            guard let names = self.trackList[self.scene], names.count > 1 else { return }
            self.cursor = (self.cursor + 1) % names.count
            self.play(names[self.cursor], loops: 0)
        }
    }

    // MARK: - 短音效

    private var effectPlayer: AVAudioPlayer?
    private var effectURL: URL?
    private var lastEffectAt: TimeInterval = 0

    /// 播一个短音效，**不打断背景音乐**。
    ///
    /// 必须用独立播放器：一个 AVAudioPlayer 实例只能放一条音轨，
    /// 拿 BGM 那个去播音效会把音乐掐掉。
    /// 每次新建实例 —— 音效只有 0.22 秒，建对象的开销远低于可感知阈值。
    func playEffect(_ name: String) {
        guard isEnabled else { return }
        DispatchQueue.main.async {
            let now = Date().timeIntervalSince1970
            // 连按限流：90ms 内不重复，否则长按确认键会变成机关枪
            guard now - self.lastEffectAt > 0.09 else { return }
            guard let url = self.url(for: name) ?? self.effectURL else { return }
            self.effectURL = url
            self.lastEffectAt = now
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
            // 音效比音乐响一点：它要"跳出来"，但不能盖住整段 BGM
            p.volume = 0.85
            p.play()
            self.effectPlayer = p
        }
    }

    // MARK: - 文件查找

    /// 认这些容器。iOS 上 AVAudioPlayer 对 m4a/aac/mp3/wav/caf 都能直接开，ogg 不行，
    /// 留着只是为了让 `containsAudio` 别把一个放了 ogg 的目录当成「有音乐」。
    private static let audioExtensions: Set<String> = ["m4a", "mp3", "wav", "aac", "caf"]

    private func url(for name: String) -> URL? {
        guard let folder else { return nil }
        let want = name.lowercased()
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil)) ?? []
        for f in files where Self.audioExtensions.contains(f.pathExtension.lowercased()) {
            if f.deletingPathExtension().lastPathComponent.lowercased() == want { return f }
        }
        return nil
    }

    /// 音乐目录，按优先级找：
    ///
    ///   1. `<程序目录>/Music/`        —— 用户自己放进去的（Documents，可写、可随时换）
    ///   2. `<bundle>/Music/<id>/`     —— 随 App 一起装进来的内置曲库
    ///
    /// 两处都要求「目录里真的有音频文件」才算命中。原因：`seedBundledPrograms`
    /// 会给每个程序目录建一个空的 `Music/`（让用户在「文件」App 里有个落脚点），
    /// 只判目录是否存在的话会拿到那个空目录，结果就是「明明内置了音乐却全程静音」。
    private static func locate(programID: String, programDirectory: URL?) -> URL? {
        if let programDirectory {
            let music = programDirectory.appendingPathComponent("Music", isDirectory: true)
            if containsAudio(music) { return music }
        }
        for base in bundleBases {
            let music = base.appendingPathComponent("Music", isDirectory: true)
                .appendingPathComponent(programID, isDirectory: true)
            if containsAudio(music) { return music }
        }
        return nil
    }

    /// bundle 里资源可能落在两个位置，和 `AppResources.programsDirectory` 同一个道理：
    /// Xcode 走文件夹引用 → `<bundle>/Music`；SwiftPM 的 `.copy("Resources/Music")`
    /// 保留相对路径 → `<bundle>/Resources/Music`。
    private static var bundleBases: [URL] {
        var bases: [URL] = []
        let bundle = AppResources.bundle
        for base in [bundle.resourceURL, bundle.bundleURL].compactMap({ $0 }) {
            bases.append(base)
            bases.append(base.appendingPathComponent("Resources", isDirectory: true))
        }
        return bases
    }

    private static func containsAudio(_ dir: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return false }
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.contains { audioExtensions.contains($0.pathExtension.lowercased()) }
    }

    private func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // .ambient：跟随静音键、不打断用户正在听的歌、不抢焦点。
        // 模拟器是"背景里的游戏机"，没有理由抢走别人的音乐。
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        #endif
    }
}

#endif
