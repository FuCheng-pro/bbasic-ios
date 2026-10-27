//
//  BBSettings.swift
//  BB9688
//
//  三个「系统设置」的唯一来源：运行监控 / 运行日志 / 速度。
//
//  为什么不用 `@AppStorage` 了：
//    设置页在 240×320 的 LCD 里，用摇杆改值；改完要让 `RootView` 重新决定
//    「要不要采样」「要不要写日志」，还要同步一个静态量 `BBVM.speedScale`。
//    这些副作用散在三个 `@AppStorage` 的 onChange 里，谁先谁后全凭视图更新顺序，
//    而 `@AppStorage` 本身又不保证「写盘」和「属性变更」的时序。
//  集中成一个单例：值变了由它自己负责写盘、同步 VM、往日志写一条事件。
//
//  ⚠️ 唯一的订阅者约定：`RootView` 观察它并调 `syncPerf()`，
//  采样层的起停**不在这里**做 —— 那需要 engine 和运行态，属于视图层的知识。
//

import Foundation
import SwiftUI

final class BBSettings: ObservableObject {

    static let shared = BBSettings()

    /// 速度档位。1× = 200 万条/秒（`BBConst.baseStepsPerSecond`，已按手感实测校准）。
    /// 刻度不等距：实测认可的区间在 0.75×~1×，那一段给得密。
    static let speedLevels: [Double] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    /// 运行中在机头显示监控条
    @Published var showPerf: Bool = false {
        didSet { if oldValue != showPerf { store.set(showPerf, forKey: Keys.perf) } }
    }

    /// 每秒一行写 CSV（`PerfLog`）
    @Published var logEnabled: Bool = false {
        didSet { if oldValue != logEnabled { store.set(logEnabled, forKey: Keys.log) } }
    }

    /// 背景音乐。
    ///
    /// 真正的播放器状态存在 `BGMPlayer` 那边（它要在「没有 UI 的路径」也知道该不该响），
    /// 这里只是给设置页一个**可观察的镜像**：`@Published` 变了 SwiftUI 才会重画那一行，
    /// 直接读 `BGMPlayer.isEnabled` 的话按了开关界面不会变。
    @Published var bgm: Bool = BGMPlayer.shared.isEnabled {
        didSet {
            guard oldValue != bgm else { return }
            BGMPlayer.shared.isEnabled = bgm
        }
    }

    /// 虚拟机速度倍率
    @Published var speed: Double = BBConst.speedDefault {
        didSet {
            guard oldValue != speed else { return }
            store.set(speed, forKey: Keys.speed)
            // VM 线程每个节流片重读一次这个静态量，所以改完立刻生效，不用重进游戏
            BBVM.speedScale = speed
            // 日志里留一条：否则下一份 CSV 的 stepPerSec 突然减半，
            // 事后分不清是程序行为变了还是有人调了档。
            PerfLog.shared.event("速度 → \(Self.label(speed))（目标 \(wanSteps) 万条/秒）")
        }
    }

    // MARK: - 派生值

    /// `0.75×`（不是 `0.750000×`）
    static func label(_ v: Double) -> String {
        if abs(v - v.rounded()) < 0.001 { return "\(Int(v.rounded()))×" }
        return String(format: "%.2f×", v).replacingOccurrences(of: "0×", with: "×")
    }

    var speedLabel: String { Self.label(speed) }

    /// 折算成绝对速率（万条/秒）—— 这个数字才是可复现的结论
    /// 任意倍率都要能算（面板里每一档都要显示），所以做成静态函数
    static func wanSteps(for v: Double) -> Int {
        Int((BBConst.baseStepsPerSecond * v / 10_000).rounded())
    }

    var wanSteps: Int { Self.wanSteps(for: speed) }

    // MARK: - 操作

    /// 下一档 / 上一档。空档位（存了非法值）时回到 1×。
    func cycleSpeed(_ direction: Int = 1) {
        let levels = Self.speedLevels
        let current = levels.firstIndex { abs($0 - speed) < 0.001 } ?? 3
        speed = levels[(current + direction + levels.count) % levels.count]
    }

    // MARK: - 落地

    private enum Keys {
        static let perf = "bb.perfHUD"
        static let log = "bb.perfLog"
        /// 键名带 `bps`：基准从 50 万改成 200 万时换过一次，旧的 `4.0` 会变成 800 万
        static let speed = BBConst.speedKey
    }

    private let store = UserDefaults.standard

    private init() {
        // init 里给存储属性赋值不会触发 didSet，所以下面不会写盘、不会写日志事件
        showPerf = store.bool(forKey: Keys.perf)
        logEnabled = store.bool(forKey: Keys.log)

        let raw = store.double(forKey: Keys.speed)
        // 校验：必须是合法档位。旧版本可能留下 4.0（按旧基准是 200 万，
        // 按新基准是 400 万×2），落在档位之外就回 1×。
        if Self.speedLevels.contains(where: { abs($0 - raw) < 0.001 }) {
            speed = raw
        } else {
            speed = BBConst.speedDefault
        }

        // 让 VM 一启动就用对的速率（原先由 `RootView.onAppear` 里的
        // `BBVM.loadSpeedFromDefaults()` 负责，那条路现在没了）
        BBVM.speedScale = speed
    }
}
