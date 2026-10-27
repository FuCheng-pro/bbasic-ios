//
//  PerfHUDView.swift
//  BB9688
//
//  运行监控条。
//
//  位置是算过的，不是随手放的：机身比 iPhone 更高，屏幕上方会剩下约 60pt 的
//  空档（`RootView` 里 `slack * 0.34`），而 LCD 只从机身的 11% 处开始 ——
//  中间那条白色塑料区正好够放一条 60pt 的监控条。
//  放在这儿有两个好处：不挡 LCD 上一个像素，也不压摇杆和左右键。
//  底部是放不下的：那里只剩 116pt，还要留给「程序列表」和按键提示。
//
//  读数每秒刷新一次（`PerfHub`），不是每帧 —— 24fps 那条路不能碰 SwiftUI。
//

import SwiftUI

struct PerfHUDView: View {

    @ObservedObject private var hub = PerfHub.shared

    /// 虚拟机当前执行了多少条指令（引擎提供）
    let stepProvider: () -> UInt64
    var width: CGFloat = 340

    private var r: PerfHub.Reading { hub.reading }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            topRow
            barRow
            bottomRow
            verdictRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .onAppear {
            // 只声明「监控条要看数」，不负责开关计时器 ——
            // 计时器是 PerfHub 按需求方合并的，日志那条路可能还开着。
            hub.demand(.hud, on: true, stepProvider: stepProvider)
        }
        .onDisappear {
            hub.demand(.hud, on: false, stepProvider: stepProvider)
        }
    }

    // MARK: 第一行：四个主指标

    private var topRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 4) {
                Circle().fill(statusColor).frame(width: 5, height: 5)
                Text("监控")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))
            }
            .frame(width: 44, alignment: .leading)

            pair("CPU", "\(Int(r.cpuProcess.rounded()))%", tint: cpuColor)
            pair("帧", String(format: "%.1f", r.fps),
                 tint: r.fps >= 20 ? .white : Color.orange)
            pair("指令", r.stepsText)
            pair("内存", "\(Int(r.footprintMB.rounded()))M")
            Spacer(minLength: 0)
        }
    }

    private func pair(_ label: String, _ value: String,
                      tint: Color = .white) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.40))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(tint)
        }
        .frame(minWidth: 62, alignment: .leading)
    }

    // MARK: 第二行：CPU 条 + 一帧耗时

    private var barRow: some View {
        HStack(spacing: 7) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.10))
                    Capsule()
                        .fill(cpuColor)
                        // 进程总 CPU 可能是多核累加，超过 100% 就按满格画
                        .frame(width: max(2, geo.size.width * min(1, r.cpuProcess / 100)))
                }
            }
            .frame(height: 3.5)

            // 一帧总耗时 + 重绘比例：前者回答「多慢」，后者回答「跳过逻辑有没有在生效」
            HStack(spacing: 6) {
                Text(String(format: "%.1fms", r.frameMS))
                    .font(.system(size: 8.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.58))
                Text("重绘 \(Int((r.paintedRatio * 100).rounded()))%")
                    .font(.system(size: 8.5))
                    .monospacedDigit()
                    .foregroundColor(.white.opacity(0.38))
            }
            .frame(width: 106, alignment: .trailing)
        }
    }

    // MARK: 第三行：线程归属 + 温度

    private var bottomRow: some View {
        HStack(spacing: 10) {
            pair("VM", r.cpuMachine < 0 ? "—" : String(format: "%.0f%%", r.cpuMachine),
                 tint: r.cpuMachine >= 70 ? Color.orange : .white.opacity(0.85))
                .frame(minWidth: 0)
            pair("主", r.cpuMain < 0 ? "—" : String(format: "%.0f%%", r.cpuMain))
                .frame(minWidth: 0)
            pair("拷", String(format: "%.1f", r.copyMS))
                .frame(minWidth: 0)
            pair("编", String(format: "%.1f", r.encodeMS))
                .frame(minWidth: 0)
            pair("温度", r.thermal, tint: thermalColor)
                .frame(minWidth: 0)
            if r.lowPower {
                Text("低电量")
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundColor(Color.orange)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 第四行：把数字翻成人话

    /// 判据顺序按「先排除系统性降频，再看是谁在烧 CPU」。
    /// 这一行才是监控的意义：否则一堆百分比还是不知道该动哪里。
    private var verdict: (String, Color) {
        if r.thermalRaw >= 2 {
            return ("系统已在热降频（\(r.thermal)），此时掉帧不一定是代码问题", Color.orange)
        }
        if r.cpuMachine >= 70, r.machineRunning {
            return ("VM 线程吃满一核：程序在空转轮询，不是在等按键", Color.orange)
        }
        if r.cpuMain >= 55 {
            return ("主线程忙于逐帧编码，降低出图频率收益最大", Color.yellow)
        }
        if r.fps > 0, r.fps < 18 {
            return ("帧率偏低但未过热，瓶颈在 CPU 或编码", Color.yellow)
        }
        if r.cpuProcess < 25 {
            return ("负载很低，发热主要来自屏幕常亮", Color.green.opacity(0.85))
        }
        return ("各项正常", Color.green.opacity(0.85))
    }

    private var verdictRow: some View {
        HStack(spacing: 4) {
            Image(systemName: "info.circle")
                .font(.system(size: 8))
                .foregroundColor(verdict.1)
            Text(verdict.0)
                .font(.system(size: 9))
                .foregroundColor(verdict.1)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
    }

    // MARK: 配色

    private var cpuColor: Color {
        let cpu = r.cpuProcess
        if cpu < 40 { return Color(red: 0.36, green: 0.85, blue: 0.55) }
        if cpu < 70 { return Color(red: 0.95, green: 0.82, blue: 0.35) }
        if cpu < 90 { return Color(red: 0.98, green: 0.62, blue: 0.28) }
        return Color(red: 0.98, green: 0.40, blue: 0.36)
    }

    private var statusColor: Color {
        if r.thermalRaw >= 2 { return Color(red: 0.98, green: 0.40, blue: 0.36) }
        if r.cpuProcess >= 70 { return Color(red: 0.98, green: 0.62, blue: 0.28) }
        return Color(red: 0.36, green: 0.85, blue: 0.55)
    }

    private var thermalColor: Color {
        switch r.thermalRaw {
        case 0:  return .white.opacity(0.85)
        case 1:  return Color.yellow
        default: return Color(red: 0.98, green: 0.45, blue: 0.35)
        }
    }
}
