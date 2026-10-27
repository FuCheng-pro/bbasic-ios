//
//  QuickPanel.swift
//  BB9688
//
//  右上角齿轮展开的系统面板。
//
//  为什么要有它（和 LCD 里那个像素风设置页并存）：
//  • 设置页（`SettingsScreen`）是**机器自己的界面** —— 只在程序列表里能进，
//    用摇杆点，画在 240×320 的 LCD 里。它是「拟物」那一层。
//  • 这个面板是**系统那一层**：齿轮浮在展台上，任何状态都能点开，
//    包括**正在玩游戏的时候**。退出程序、调速度、开日志，不必先回列表。
//    上一轮的教训就是这个：所有入口都塞进机器界面之后，进了游戏就出不来。
//
//  两层共用同一份状态（`BBSettings` + `AppModel`），所以不存在「两边显示不一样」。
//  视觉上刻意分开：LCD 里是纸白点阵，这里是深色玻璃 —— 一个属于机器，一个属于 iOS。
//

import SwiftUI
import UIKit

struct QuickPanelView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var settings: BBSettings

    /// 面板宽度（由 `RootView` 按屏幕宽度夹过，最宽 262）
    var width: CGFloat
    /// 关闭面板。所有会离开本视图的动作都先调它，避免面板停在半空
    var onClose: () -> Void

    /// 速度档位是否展开。默认收起：七个档位铺开有 78pt 高，
    /// 而设置面板被打开时十有八九是为了「返回」或「看日志有没有在记」。
    @State private var speedOpen = false

    // MARK: - 令牌

    /// 强调色：和机身上那三枚蓝色背光键同一个色相（色相 217°，明度更高一档，
    /// 保证在深色玻璃上达到 4.5:1 对比度）
    private let accent = Color(red: 0.40, green: 0.62, blue: 1.00)
    /// 关机用暖红，和其他行区分开：它是一次性的、不可撤销的动作
    private let danger = Color(red: 0.98, green: 0.44, blue: 0.42)
    /// 金手指的金色。不跟强调蓝混用：它不是一个「设置」，是一层外挂
    private let gold = Color(red: 0.98, green: 0.78, blue: 0.36)
    private let ink = Color.white.opacity(0.92)
    private let sub = Color.white.opacity(0.40)
    private let hairline = Color.white.opacity(0.075)

    /// 一行的高度。44 是 iOS 的最小可点尺寸，这里不为了紧凑去砍它
    private let rowH: CGFloat = 44

    // MARK: - 主体

    var body: some View {
        VStack(spacing: 0) {
            header

            group {
                toggleRow(icon: "speedometer", title: "运行监控",
                          note: app.mode == .running ? nil : "进游戏后显示",
                          isOn: settings.showPerf) {
                    settings.showPerf.toggle()
                }

                divider

                toggleRow(icon: "doc.text", title: "运行日志",
                          note: settings.logEnabled ? "记录中" : nil,
                          isOn: settings.logEnabled) {
                    settings.logEnabled.toggle()
                }

                divider

                speedRow

                divider

                tapRow(icon: "tray.full", title: "日志文件", value: "查看 · 分享") {
                    onClose()
                    app.showLogSheet = true
                }
            }

            // ── 运行中才有的一段 ────────────────────────────────
            if app.mode == .running {
                sectionTitle("这局")
                group {
                    tapRow(icon: "wand.and.stars", title: "金手指",
                           value: app.cheat.summary, tint: gold) {
                        close { app.showCheatSheet = true }
                    }
                    divider
                    tapRow(icon: "chevron.backward.2", title: "返回程序列表",
                           value: app.currentTitle ?? "", tint: ink, strong: true) {
                        close { app.home() }
                    }
                    divider
                    tapRow(icon: "arrow.uturn.backward", title: "程序内返回", value: "ESC") {
                        close { app.sendKey(BBKey.escape) }
                    }
                }
            }

            // ── 电源 ────────────────────────────────────────────
            sectionTitle("电源")
            group {
                tapRow(icon: "power", title: "关机", tint: danger) {
                    close { app.shutdown() }
                }
            }
            // 最后一块（电源）下面留一口气，卡片不能贴着内容收边
            Color.clear.frame(height: 12)
        }
        .frame(width: width)
        .background(card)
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 0.8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: Color.black.opacity(0.55), radius: 26, x: 0, y: 14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置面板")
    }

    // MARK: - 结构

    /// 先关面板再执行动作：`app.home()` 会把机身整块重画，
    /// 面板留在一个正在消失的界面上，动画会抖一下。
    private func close(_ work: @escaping () -> Void) {
        onClose()
        // 让收起动画先跑一帧，动作引发的界面切换才不会和面板的缩放叠在一起
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("设置")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(ink)

            Spacer(minLength: 0)

            Text(modeLabel)
                .font(.system(size: 10.5))
                .foregroundColor(sub)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 11)
    }

    /// 当前状态的一行说明。面板里所有开关的作用域都跟它有关
    /// （「运行监控」在列表页打开是关着的，只有进了游戏才看得见），
    /// 所以必须写在最上面，否则改完没反应会以为坏了。
    private var modeLabel: String {
        switch app.mode {
        case .running:  return "运行中 · \(app.currentTitle ?? "程序")"
        case .launcher: return "程序列表"
        case .about:    return "本机信息"
        case .settings: return "设置页"
        case .boot:     return "开机中"
        case .off:      return "已关机"
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Color.white.opacity(0.32))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0, content: content)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 0.6)
            )
            // 按下时整行会刷一层底色，不裁圆角的话四个角会露出直角的亮斑
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 10)
    }

    private var divider: some View {
        Rectangle()
            .fill(hairline)
            .frame(height: 0.7)
            .padding(.leading, 42)
    }

    private var card: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.067, green: 0.075, blue: 0.090).opacity(0.72))
        }
    }

    // MARK: - 行

    private func toggleRow(icon: String, title: String, note: String?,
                           isOn: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeOut(duration: 0.16)) { action() }
        } label: {
            HStack(spacing: 10) {
                glyph(icon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(ink)
                    if let note {
                        Text(note)
                            .font(.system(size: 9.5))
                            .foregroundColor(sub)
                    }
                }
                Spacer(minLength: 6)
                miniToggle(isOn)
            }
            .padding(.horizontal, 12)
            .frame(height: note == nil ? rowH : rowH + 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "开" : "关")
    }

    private func tapRow(icon: String, title: String, value: String? = nil,
                        tint: Color? = nil, strong: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 10) {
                glyph(icon, tint: tint ?? Color.white.opacity(0.55))
                Text(title)
                    .font(.system(size: 13, weight: strong ? .semibold : .medium))
                    .foregroundColor(tint ?? ink)
                Spacer(minLength: 6)
                if let value, !value.isEmpty {
                    Text(value)
                        .font(.system(size: 10.5))
                        .foregroundColor(sub)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Image(systemName: "chevron.forward")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.22))
            }
            .padding(.horizontal, 12)
            .frame(height: rowH)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityLabel(title)
    }

    /// 速度行：点一下展开七个档位。
    /// 不做「点一下切一档」：七档循环要点七次才能回到原处，试听手感时最烦这个。
    ///
    /// 「≈ N 万条/秒」一律走 `BBSettings.wanSteps`（返回 `Int`），不要在本文件里另算一份。
    /// 2026-10-26 这里曾内联写过一个 `static func wan(_:) -> Int`，
    /// 里面直接返回 `(... ).rounded()` —— `Double.rounded()` 返回的是 `Double`，
    /// 于是 `cannot convert return expression of type 'Double' to return type 'Int'`。
    /// 换算规则只该有一处，多了必然漂移。
    private var speedRow: some View {
        VStack(spacing: 0) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.easeInOut(duration: 0.2)) { speedOpen.toggle() }
            } label: {
                HStack(spacing: 10) {
                    glyph("timer", tint: speedOpen ? accent : Color.white.opacity(0.55))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("速度")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(ink)
                        Text("≈ \(settings.wanSteps) 万条/秒")
                            .font(.system(size: 9.5))
                            .foregroundColor(sub)
                    }
                    Spacer(minLength: 6)
                    Text(settings.speedLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundColor(speedOpen ? accent : Color.white.opacity(0.72))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.22))
                        .rotationEffect(.degrees(speedOpen ? 180 : 0))
                }
                .padding(.horizontal, 12)
                .frame(height: rowH + 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())

            if speedOpen {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4),
                          spacing: 6) {
                    ForEach(BBSettings.speedLevels, id: \.self) { v in
                        chip(v)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func chip(_ v: Double) -> some View {
        let on = abs(v - settings.speed) < 0.001
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeOut(duration: 0.14)) { settings.speed = v }
        } label: {
            Text(BBSettings.label(v))
                .font(.system(size: 11, weight: on ? .semibold : .regular))
                .monospacedDigit()
                .foregroundColor(on ? Color.white : Color.white.opacity(0.60))
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? accent.opacity(0.88) : Color.white.opacity(0.07))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(BBSettings.label(v))，\(BBSettings.wanSteps(for: v)) 万条每秒")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    // MARK: - 零件

    private func glyph(_ name: String, tint: Color = Color.white.opacity(0.55)) -> some View {
        Image(systemName: name)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(tint)
            .frame(width: 18, alignment: .center)
    }

    /// 34×20 的迷你开关。比系统 `Toggle` 好在：颜色、圆角、动效都能对上这套深色玻璃，
    /// 而系统开关在深色面板里是一块突兀的绿色。
    private func miniToggle(_ on: Bool) -> some View {
        Capsule()
            .fill(on ? accent : Color.white.opacity(0.16))
            .frame(width: 34, height: 20)
            .overlay(
                Circle()
                    .fill(Color.white)
                    .frame(width: 16, height: 16)
                    .shadow(color: Color.black.opacity(0.28), radius: 1, x: 0, y: 1)
                    .padding(2),
                alignment: on ? .trailing : .leading
            )
            .animation(.easeOut(duration: 0.16), value: on)
    }
}

/// 行按下去整行压暗一点：面板里没有别的高亮，这是唯一的「我收到了」反馈
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.06 : 0))
    }
}

