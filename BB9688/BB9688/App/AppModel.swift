//
//  AppModel.swift
//  BB9688
//
//  整机状态机：关机 / 开机 / 程序列表 / 运行中。
//  界面只读这里，按键只调这里的方法。
//

import Foundation
import SwiftUI

final class AppModel: ObservableObject {

    enum Mode: Equatable {
        case off
        case boot
        case launcher
        case running
        case about
        /// 设置页（列表末行「设置」进去）。240×320 里的矢量界面，摇杆操作。
        case settings
    }

    /// 设置页里的一行。顺序就是屏幕上的顺序。
    ///
    /// 放在 `AppModel` 而不是视图里：它是**状态机的一部分** —— 摇杆上下要按这个
    /// 顺序换行、中键要按这个顺序决定切哪个开关，视图只负责画出来。
    enum SettingRow: Int, CaseIterable {
        case perf      // 运行监控
        case log       // 运行日志
        case bgm       // 背景音乐
        case speed     // 速度
        case logFile   // 日志文件（跳到分享面板）
        case power     // 关机

        var title: String {
            switch self {
            case .perf:    return "运行监控"
            case .log:     return "运行日志"
            case .bgm:     return "背景音乐"
            case .speed:   return "速度"
            case .logFile: return "日志文件"
            case .power:   return "关机"
            }
        }

        var detail: String {
            switch self {
            case .perf:    return "机头显示帧率 / CPU，进游戏后生效"
            case .log:     return "每秒一行写 CSV，进游戏后开始记"
            case .bgm:     return "按画面自动换曲，不需要选曲目"
            case .speed:   return "虚拟机执行速率"
            case .logFile: return "查看 · 分享 · 清空"
            case .power:   return "关机后推摇杆或点屏幕可再开"
            }
        }
    }

    @Published private(set) var mode: Mode = .off
    @Published var selectedIndex = 0
    /// 设置页里选中的行
    @Published var settingsIndex = 0
    /// 设置页里选「日志文件」时要弹的分享面板。
    /// 这个 sheet 只能用触摸操作（系统 ShareLink），所以它是**唯一**一处
    /// 离开拟物界面的地方 —— 摇杆按不出来分享列表，这是 iOS 的限制，不是偷懒。
    @Published var showLogSheet = false
    /// 金手指面板。和上面那个 sheet 一样只在运行态开得出。
    @Published var showCheatSheet = false
    @Published private(set) var lastEvent: String = ""
    /// 启动失败的原因（列表底部显示）。nil = 没有错误，显示普通操作提示。
    @Published private(set) var launchError: String?

    /// 正在运行的程序名。设置面板的「返回」要写清楚返回到哪 ——
    /// 一行「返回程序列表」不如「返回列表 · 大富翁」能让人放心按下。
    @Published private(set) var currentTitle: String?

    let engine = MachineEngine()

    /// 金手指（只在运行「大富翁」时解锁）。面板和设置面板都读这一份。
    var cheat: BBCheat { engine.cheat }

    private var bootWork: DispatchWorkItem?

    /// 列表里的一行：磁盘上扫描出来的程序 + 本机信息。
    /// 不再是写死的三个 —— `Programs/` 里有什么就列什么，见 `ProgramStore.discover()`。
    @Published private(set) var rows: [BBProgram] = []
    /// 列表底部那行的可用空间，跟着 `refreshPrograms()` 一起更新
    @Published private(set) var freeSpace = "剩余 —"

    /// 可运行的程序数量（`rows` 末尾两行是「本机信息」「设置」，不算）
    var programCount: Int { max(0, rows.count - 2) }

    init() {
        ProgramStore.seedBundledPrograms()
        refreshPrograms()

        // 程序自己结束（跑完 / 出错 / 内部退出）时回列表，并把原因写在列表底部。
        // 以前这里什么都不做：界面停在「运行中」，屏幕上是一帧静止的黑画，
        // 用户按任何键都没有反应 —— 这就是「打不开游戏」的另一半。
        engine.onExit = { [weak self] reason in
            guard let self, self.mode == .running else { return }
            // 日志里记下「退出原因」：它是把「为什么卡住」和「卡在第几秒」
            // 对上的唯一线索 —— 光看 CPU 曲线猜不出是程序自己跑了还是崩了。
            PerfLog.shared.event("程序退出：\(reason)")
            self.mode = .launcher
            self.currentTitle = nil
            self.launchError = "程序已退出：\(reason)"
            self.refreshPrograms()
        }

        // 进 App 就是**开机状态**：过一遍开机动画直接停在程序列表。
        // 打开就该是一台能用的机器 —— 不该先看到一块黑屏，再去找开机键。
        boot()
    }

    /// 重新扫盘。外部往 App 的「文件」里拖了新程序目录后，
    /// 回到前台（`scenePhase == .active`）或重新进列表时调一次就能看到。
    func refreshPrograms() {
        // ★ 只有真的变了才写 @Published。
        //   这个方法是从 `LauncherScreen.onAppear` 里调的，也就是 SwiftUI 正在更新视图的
        //   过程中；而 `@Published` 的 setter **无条件**发通知（值相同也发）。
        //   以前这里每次都给 `freeSpace` 赋一次同样的字符串，等于在视图更新里反复
        //   触发 objectWillChange —— iOS 26 的新 ViewGraph 对这种重入很敏感。
        let space = ProgramStore.freeSpaceText
        if space != freeSpace { freeSpace = space }

        var list = ProgramStore.discover()
        list.append(BBProgram(id: "about", title: "本机信息", detail: "机型 / 屏幕 / 虚拟机", bin: ""))
        // 设置放**最后一行**：程序列表的顺序是用户自己的东西，不该被系统项挤开。
        // 可发现性靠列表底部的操作提示（「末行是设置」）来补。
        list.append(BBProgram(id: "settings", title: "设置", detail: "监控 / 日志 / 速度 / 关机", bin: ""))
        guard list != rows else { return }
        rows = list
        if selectedIndex >= rows.count { selectedIndex = max(0, rows.count - 1) }
    }

    // 注意：这里**不能**把 engine.objectWillChange 转发给 AppModel。
    // 虚拟机运行时 engine 每帧（24fps）都会发一次变更，转发上来就是整台机器重建，
    // DeviceView 里的 DragGesture 会被反复拆掉重装 —— 手势 onEnded 丢失，
    // 摇杆方向卡住、连发定时器停不下来，表现就是「没按键它自己走」。
    // 画面刷新交给 FramebufferView 自己订阅 engine。

    var selectedProgram: BBProgram? {
        guard rows.indices.contains(selectedIndex) else { return nil }
        return rows[selectedIndex]
    }

    // MARK: - 电源

    func togglePower() {
        if mode == .off {
            boot()
        } else {
            shutdown()
        }
    }

    func boot() {
        bootWork?.cancel()
        mode = .boot
        // 开机时重扫一次：这期间用户可能刚往「文件」里拖过程序目录
        refreshPrograms()
        note("开机 · 载入 BBVM")

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .boot else { return }
            self.mode = .launcher
            self.note("进入 BB 程序列表")
        }
        bootWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    func shutdown() {
        bootWork?.cancel()
        engine.stop()
        currentTitle = nil
        mode = .off
        note("关机")
    }

    // MARK: - 按键

    func move(_ delta: Int) {
        guard mode == .launcher, !rows.isEmpty else { return }
        launchError = nil
        selectedIndex = (selectedIndex + delta + rows.count) % rows.count
    }

    func confirm() {
        switch mode {
        case .launcher:
            guard let program = selectedProgram else { return }
            if program.id == "about" {
                mode = .about
                note("打开本机信息")
            } else if program.id == "settings" {
                settingsIndex = 0
                mode = .settings
                note("打开设置")
            } else if let error = engine.start(program) {
                // 起不来就**留在列表里说话**，不要切成「运行中」黑屏。
                launchError = "打不开 \(program.title)：\(error)"
                note("打不开 \(program.title)")
                PerfLog.shared.event("打不开 \(program.title)：\(error)")
                // 顺便重扫一次：文件可能是刚拷进来的，上一帧的 rows 还是旧的
                refreshPrograms()
            } else {
                launchError = nil
                currentTitle = program.title
                mode = .running
                note("运行 \(program.title)")
                // 只记程序名和 bin：文件名之外的路径会带用户目录名，没必要写进日志
                PerfLog.shared.event("启动 \(program.title)（\(program.bin)）")
            }
        case .off:
            boot()
        case .settings:
            settingsActivate()
        default:
            break
        }
    }

    func back() {
        switch mode {
        case .about, .settings:
            mode = .launcher
            note("返回列表")
        case .off:
            break
        default:
            // 运行中的「返回」由 DeviceView 直接送 ESC 给程序，
            // 不在这里杀虚拟机 —— 否则程序自己的「返回上一级」永远用不上。
            break
        }
    }

    // MARK: - 设置页

    /// 摇杆上下：换行，首尾相接。
    func settingsMove(_ delta: Int) {
        guard mode == .settings else { return }
        let n = SettingRow.allCases.count
        guard n > 0 else { return }
        settingsIndex = (settingsIndex + delta + n) % n
    }

    /// 中键 / 右键：是开关就翻，是动作就做。
    func settingsActivate() {
        guard mode == .settings, let row = SettingRow(rawValue: settingsIndex) else { return }
        let settings = BBSettings.shared
        switch row {
        case .perf:
            settings.showPerf.toggle()
        case .log:
            settings.logEnabled.toggle()
        case .bgm:
            // 走 `BBSettings.bgm` 而不是直接翻 `BGMPlayer.isEnabled`：
            // 前者是 @Published，界面才会跟着刷新；后者只管发声。
            settings.bgm.toggle()
        case .speed:
            // 中键循环下一档。没有做「左右调值」：这一版摇杆左右在设置页
            // 故意不接动作 —— 斜推时的判向偶尔会落到左右，会莫名其妙改速度。
            settings.cycleSpeed(1)
        case .logFile:
            showLogSheet = true
        case .power:
            shutdown()
        }
    }

    /// 回主菜单（程序列表）：停掉虚拟机，退出当前程序。
    /// 这是「返回主页」那个独立入口干的事，不要和左键的 ESC 混在一起。
    func home() {
        guard mode == .running else { return }
        PerfLog.shared.event("返回列表（手动结束程序）")
        engine.stop()
        currentTitle = nil
        mode = .launcher
        note("已返回程序列表")
    }

    /// 运行中把按键转发给虚拟机
    func sendKey(_ code: UInt32) {
        guard mode == .running else { return }
        engine.sendKey(code)
    }

    func tap(x: Int, y: Int) {
        guard mode == .running else { return }
        engine.tap(x: x, y: y)
    }

    /// 松手时清掉残留的方向键
    func flushInput() {
        engine.dropPendingDirections()
    }

    /// 让界面上的提示条说一句话（按键手感提示）
    func hint(_ text: String) {
        note(text)
    }

    private func note(_ text: String) {
        lastEvent = text
    }
}
