//
//  PerfHub.swift
//  BB9688
//
//  运行监控的**聚合层**：把「每帧耗时」和「每秒一次的系统采样」揉成一份读数。
//
//  设计上刻意是 1Hz：
//    24fps 那条路已经被证明不能进 SwiftUI（2026-10-26 的崩溃就是每帧 diff 打乱了
//    ARC 配平）。监控自己要是每秒发 24 次值，等于把刚拆掉的雷重新埋回去。
//    所以 HUD 的值**每秒只变一次**，画面那条路仍然只走 `CALayer.contents`。
//
//  未打开监控时 `isRunning == false`，`noteFrame` 直接返回 ——
//  监控本身不能成为新的发热源。
//
//  采样有两个「需求方」：屏幕上的监控条（`.hud`）和落盘日志（`.log`）。
//  用 Set 计数而不是布尔，是因为两者可以独立开关：
//    只记日志、监控条收起来时，仍然每秒采样一次并写文件 ——
//    否则「不开监控就记不到数」会逼着人一边玩一边盯屏幕。
//

import Combine
import Foundation

final class PerfHub: ObservableObject {

    /// 一份读数（每秒刷新一次）
    struct Reading {
        var fps: Double = 0
        /// 虚拟机每秒执行的字节码条数
        var stepsPerSecond: Double = 0
        /// 开机以来执行过的总条数（日志里用来对齐「哪一段跑得最多」）
        var totalSteps: UInt64 = 0
        var cpuProcess: Double = 0
        var cpuMain: Double = -1
        var cpuMachine: Double = -1
        var machineRunning = false
        var threadCount = 0
        var footprintMB: Double = 0
        var thermal = "正常"
        var thermalRaw = 0
        var lowPower = false
        /// 一帧的总 CPU 时间（拷贝 + 缩放编码），毫秒
        var frameMS: Double = 0
        var copyMS: Double = 0
        var encodeMS: Double = 0
        /// 实际重绘的帧占「帧泵尝试」的比例。低 = 画面静止，引擎在跳过
        var paintedRatio: Double = 0

        var stepsText: String {
            if stepsPerSecond >= 1_000_000 {
                return String(format: "%.1fM", stepsPerSecond / 1_000_000)
            }
            if stepsPerSecond >= 1_000 {
                return String(format: "%.0fK", stepsPerSecond / 1_000)
            }
            return String(format: "%.0f", stepsPerSecond)
        }
    }

    static let shared = PerfHub()

    /// 谁会用到采样。两个需求方可以同时存在，各自开关互不影响。
    enum Demand: String {
        /// 屏幕上的监控条
        case hud
        /// 落盘日志
        case log
    }

    @Published private(set) var reading = Reading()
    private(set) var isRunning = false

    private var timer: Timer?
    private var stepProvider: (() -> UInt64)?
    private var demands: Set<String> = []

    private var windowStart = Date()
    private var lastSteps: UInt64 = 0
    private var frames = 0
    private var skipped = 0
    private var cpuMSAcc = 0.0
    private var copyMSAcc = 0.0
    private var encodeMSAcc = 0.0

    /// 只在「跳档」时写一次事件，不然日志里每秒一行「过热」会淹掉真正的时间点
    private var lastThermalRaw = -1
    private var lastLowPower = false

    private init() {}

    // MARK: 生命周期

    /// 声明/撤销一个需求。两个都撤销才真正停表。
    ///
    /// 每次调用都刷新 `stepProvider`：引擎换了一台机器（重新进游戏），
    /// 读数要立刻跟着换，不能还盯着上一局的计数器。
    func demand(_ d: Demand, on: Bool, stepProvider: @escaping () -> UInt64) {
        self.stepProvider = stepProvider
        if on {
            demands.insert(d.rawValue)
        } else {
            demands.remove(d.rawValue)
        }
        sync()
    }

    private func sync() {
        if demands.isEmpty {
            timer?.invalidate()
            timer = nil
            isRunning = false
            stepProvider = nil
            lastThermalRaw = -1
            return
        }
        guard !isRunning else { return }

        isRunning = true
        windowStart = Date()
        lastSteps = stepProvider?() ?? 0
        // 清掉上一局的读数：不然刚起表的那一次 `tick`（dt≈0，走「沿用上一轮」
        // 分支）会把上局最后一次的帧率当成这一局的第一条样本写进日志。
        reading = Reading()
        resetCounters()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // 先立刻出一次：CPU/内存/热状态不等窗口，马上就有数，
        // 免得刚点开监控是一片空白，让人以为没生效。
        tick()
    }

    /// 彻底停表（退出运行态时调用）。需求本身还在的话下次 demand 会重新起表。
    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        stepProvider = nil
    }

    // MARK: 打点（由引擎在主线程调）

    /// 真正画了一帧。`copyMs` = 取画布+比对，`encodeMs` = 缩放 + 建 CGImage
    func noteFrame(copyMs: Double, encodeMs: Double) {
        guard isRunning else { return }
        frames += 1
        copyMSAcc += copyMs
        encodeMSAcc += encodeMs
        cpuMSAcc += copyMs + encodeMs
    }

    /// 帧泵跑了但画面没变，引擎直接跳过（这恰恰是省电的部分）
    func noteSkippedFrame() {
        guard isRunning else { return }
        skipped += 1
    }

    // MARK: 采样

    private func tick() {
        let now = Date()
        let dt = now.timeIntervalSince(windowStart)
        let sample = BBPerfSampler.shared.sample()

        var next = Reading()
        next.cpuProcess = sample.cpuProcess
        next.cpuMain = sample.cpuMain
        next.cpuMachine = sample.cpuMachine
        next.machineRunning = sample.machineRunning
        next.threadCount = sample.threadCount
        next.footprintMB = sample.footprintMB
        next.thermal = sample.thermal
        next.thermalRaw = sample.thermalRaw
        next.lowPower = sample.lowPower
        next.totalSteps = stepProvider?() ?? 0

        // 窗口太短时算速率会飙出天文数字（刚 start 的那一次 dt≈0），
        // 只更新系统指标，速率沿用上一次的值。
        var windowOK = false
        if dt >= 0.25 {
            windowOK = true
            let steps = next.totalSteps
            next.fps = Double(frames) / dt
            next.stepsPerSecond = steps >= lastSteps ? Double(steps - lastSteps) / dt : 0
            if frames > 0 {
                next.frameMS = cpuMSAcc / Double(frames)
                next.copyMS = copyMSAcc / Double(frames)
                next.encodeMS = encodeMSAcc / Double(frames)
            }
            let attempts = frames + skipped
            next.paintedRatio = attempts > 0 ? Double(frames) / Double(attempts) : 0

            windowStart = now
            lastSteps = steps
            resetCounters()
        } else {
            // 保留上一轮速率，避免读数在 0 和真实值之间跳
            next.fps = reading.fps
            next.stepsPerSecond = reading.stepsPerSecond
            next.frameMS = reading.frameMS
            next.copyMS = reading.copyMS
            next.encodeMS = reading.encodeMS
            next.paintedRatio = reading.paintedRatio
        }

        reading = next

        // 落盘。`isActive` 为假时 `record` 立刻返回，所以这里不用额外判断
        // 「日志有没有开」—— 一个 if 换 1Hz 的调用，值。
        // 只写「窗口成立」的那一次：起表瞬间 dt≈0 的样本没有速率意义，
        // 写进去只会让第一行出现一个假的 0 帧。
        if windowOK {
            PerfLog.shared.record(next)
        }

        // 只在状态**跳档**时写事件：热状态和低电量模式都是慢变量，
        // 每秒重复写一条只会把真正的时间点淹掉。
        if lastThermalRaw >= 0, next.thermalRaw != lastThermalRaw {
            PerfLog.shared.event("温度 → \(next.thermal)")
        }
        lastThermalRaw = next.thermalRaw
        if next.lowPower != lastLowPower {
            PerfLog.shared.event(next.lowPower ? "低电量模式开" : "低电量模式关")
            lastLowPower = next.lowPower
        }
    }

    private func resetCounters() {
        frames = 0
        skipped = 0
        cpuMSAcc = 0
        copyMSAcc = 0
        encodeMSAcc = 0
    }
}
