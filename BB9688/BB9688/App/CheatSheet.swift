//
//  CheatSheet.swift
//  BB9688
//
//  金手指面板。系统那一层（深色玻璃），和右上角设置面板同一套视觉；
//  不进 LCD —— 它不是机器的一部分，是「外挂」。
//
//  布局取舍：
//  · 骰子两行、每行 7 个 chip（关 / 1~6）：两粒可以分别固定（比如 3 + 5），
//    也可以一键「两粒同值」。比 Picker 快，一眼看到当前值。
//  · 金钱按玩家分行，每行带自己的加钱按钮。不做「只给当前玩家加」——
//    玩家的下标和「谁是人类」在游戏里没有可靠标记，与其猜错，
//    不如把 4 个人的余额都摆出来，谁是谁一目了然。
//  · 股价给一张 20 行的实时表，**点名字选中**再单独调那一只：
//    20 行 × 5 个按钮点不准，而且「调哪一只」本来就该由点一下决定。
//

import SwiftUI
import UIKit

struct CheatSheet: View {
    @ObservedObject var cheat: BBCheat
    @Environment(\.dismiss) private var dismiss

    /// 股价表里当前选中的那一只（单只操作的靶子）
    @State private var selectedStock = 0

    private let accent = Color(red: 0.40, green: 0.62, blue: 1.00)
    private let gold = Color(red: 0.98, green: 0.78, blue: 0.36)
    private let ink = Color.white.opacity(0.92)
    private let sub = Color.white.opacity(0.42)

    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.062, blue: 0.075).ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(spacing: 14) {
                        if !cheat.unlocked {
                            unavailableNote
                        }
                        diceSection
                        moneySection
                        stockSection
                        footerNote
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 4)
                    .padding(.bottom, 28)
                }
            }
        }
        .presentationDragIndicator(.visible)
        // 两档高度：`.medium` 时上半屏还能看到 LCD，边调边看；
        // 股价表那种长内容拖到 `.large`。
        .presentationDetents([.medium, .large])
        .onAppear { cheat.refresh() }
    }

    // MARK: - 头

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("金手指")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(ink)

            Text("大富翁")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(gold)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(gold.opacity(0.14))
                )

            Spacer(minLength: 0)

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                dismiss()
            } label: {
                Text("完成")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(accent.opacity(0.14)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var unavailableNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(gold)
            Text("当前程序里没找到大富翁的数据表，金手指不会写任何内存。先进一局大富翁再打开这里。")
                .font(.system(size: 11.5))
                .foregroundColor(sub)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(gold.opacity(0.08))
        )
    }

    private var footerNote: some View {
        Text("地址来自对 rich.bin 的反汇编与内存实测：现金 0x78374+4·i、股价表 0x7A30C+13·i、骰子 RND(6) 的两个调用点。改动只写在这几处，不碰别的位置。")
            .font(.system(size: 10.5))
            .foregroundColor(Color.white.opacity(0.30))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    // MARK: - 骰子

    private var diceSection: some View {
        section(title: "骰子", note: cheat.diceSummary) {
            VStack(spacing: 6) {
                diceRow("骰 1", value: cheat.diceA, tint: accent) { setDice(a: $0) }
                diceRow("骰 2", value: cheat.diceB, tint: accent) { setDice(b: $0) }

                toggleRow("只对我生效",
                          note: cheat.diceOnlyMe
                            ? "轮到电脑时保持原样随机 · 当前：\(cheat.seatLabel)"
                            : "四个玩家一起控制 · 当前：\(cheat.seatLabel)",
                          isOn: cheat.diceOnlyMe) {
                    cheat.diceOnlyMe.toggle()
                }

                HStack(spacing: 6) {
                    smallButton("两粒同值", tint: accent) {
                        // 拿已经设过的那一粒当源；两粒都没设过才默认为 6。
                        // （直接写死 6 的话，用户点这个按钮会发现点数被自己改了。）
                        let v = cheat.diceA > 0 ? cheat.diceA : (cheat.diceB > 0 ? cheat.diceB : 6)
                        cheat.diceA = v
                        cheat.diceB = v
                    }
                    smallButton("全部不控制", tint: accent) {
                        cheat.diceA = 0
                        cheat.diceB = 0
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// 一粒骰子：左边一个标签 + 7 个 chip（关 / 1...6）
    private func diceRow(_ label: String, value: Int, tint: Color,
                         action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(sub)
                .frame(width: 30, alignment: .leading)

            chip("关", on: value == 0, tint: tint) { action(0) }
            ForEach(1...6, id: \.self) { v in
                chip("\(v)", on: value == v, tint: tint, mono: true) { action(v) }
            }
        }
    }

    /// 点数字就设成那个点数，取消要走左边的「关」。
    ///
    /// 不做「再点一次取消」：骰子在面板里是最常点的一栏，
    /// 连点两下同一个数字（想确认一下）结果把它关掉了，很难理解。
    private func setDice(a value: Int) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeOut(duration: 0.14)) { cheat.diceA = value }
    }

    private func setDice(b value: Int) {
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.easeOut(duration: 0.14)) { cheat.diceB = value }
    }

    // MARK: - 金钱

    private var moneySection: some View {
        section(title: "金钱",
                note: cheat.infiniteCash ? "托底 \(BBCheat.cashFloor.formatted())" : "状态栏会立刻刷新") {
            VStack(spacing: 8) {
                ForEach(0..<BBCheat.Layout.cashSlots, id: \.self) { i in
                    cashRow(i)
                }

                HStack(spacing: 6) {
                    smallButton("全员 +5 万", tint: accent) {
                        cheat.addCashToAll(50_000)
                    }
                    smallButton("全员 ×10", tint: accent) {
                        cheat.multiplyCashAll(10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)

                toggleRow("无限金钱", note: "低于 99 万就自动补回来", isOn: cheat.infiniteCash) {
                    cheat.infiniteCash.toggle()
                }

                if cheat.infiniteCash {
                    HStack(spacing: 6) {
                        Text("给谁")
                            .font(.system(size: 11))
                            .foregroundColor(sub)
                        ForEach(1...BBCheat.Layout.cashSlots, id: \.self) { n in
                            chip("\(n)", on: cheat.cashTarget == n, tint: gold, mono: true) {
                                cheat.cashTarget = n
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
    }

    private func cashRow(_ index: Int) -> some View {
        let value = index < cheat.cash.count ? cheat.cash[index] : 0
        return HStack(spacing: 8) {
            Text("玩家 \(index + 1)")
                .font(.system(size: 12.5))
                .foregroundColor(ink)

            Text(value.formatted())
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundColor(value >= BBCheat.cashFloor ? gold : ink.opacity(0.86))

            Spacer(minLength: 4)

            smallButton("+5 万", tint: accent) { cheat.addCash(slot: index, 50_000) }
            smallButton("×10", tint: accent) { cheat.multiplyCash(slot: index, 10) }
        }
    }

    // MARK: - 股价

    private var stockSection: some View {
        section(title: "股价",
                note: "\(BBCheat.Layout.stockCount) 家公司 · 均价 \(averagePrice)") {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    smallButton("全部翻倍", tint: accent) { cheat.boostStocks(2) }
                    smallButton("全部 +50%", tint: accent) { cheat.boostStocks(1.5) }
                    smallButton("全拉到 999", tint: accent) {
                        cheat.setAllStocks(BBCheat.Layout.priceCap)
                    }
                    Spacer(minLength: 0)
                }

                toggleRow("只涨不跌", note: "游戏把价格压下去就写回原来的高点",
                          isOn: cheat.stockNeverFalls) {
                    cheat.stockNeverFalls.toggle()
                }

                singleStockBar

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                    GridItem(.flexible(), spacing: 10)],
                          spacing: 4) {
                    // 用下标而不是 `enumerated()`：Swift 不允许对元组取 keyPath，
                    // `ForEach(Array(x.enumerated()), id: \.offset)` 是编译不过的。
                    ForEach(0..<BBCheat.Layout.stockCount, id: \.self) { i in
                        stockCell(i)
                    }
                }
            }
        }
    }

    /// 单只股票的操作条。上面是「选中的是哪一家 + 现价」，下面一排是动作。
    ///
    /// 为什么先选后调、而不是每行塞四个按钮：20 行 × 4 个按钮在手机上点不准，
    /// 而且「我要调哪一只」这件事本来就该由点一下决定。默认选中第一家。
    private var singleStockBar: some View {
        let index = min(max(selectedStock, 0), BBCheat.Layout.stockCount - 1)
        let name = index < cheat.stockNames.count ? cheat.stockNames[index] : "—"
        let price = index < cheat.stockPrices.count ? cheat.stockPrices[index] : 0
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text("这一只")
                    .font(.system(size: 11))
                    .foregroundColor(sub)
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(gold)
                Text("\(price)")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(ink)
                Spacer(minLength: 0)
                Text("点下面的名字切换")
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.26))
            }
            HStack(spacing: 6) {
                smallButton("×2", tint: gold) { cheat.boostStock(index, 2) }
                smallButton("+50%", tint: gold) { cheat.boostStock(index, 1.5) }
                smallButton("−50%", tint: gold) { cheat.boostStock(index, 0.5) }
                smallButton("拉满", tint: gold) {
                    cheat.setStock(index, BBCheat.Layout.priceCap)
                }
                smallButton("砸到 1", tint: gold) { cheat.setStock(index, 1) }
                Spacer(minLength: 0)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(gold.opacity(0.07))
        )
    }

    private var averagePrice: Int {
        let values = cheat.stockPrices.filter { $0 > 0 }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / values.count
    }

    private func stockCell(_ index: Int) -> some View {
        let name = index < cheat.stockNames.count ? cheat.stockNames[index] : "—"
        let price = index < cheat.stockPrices.count ? cheat.stockPrices[index] : 0
        let on = index == selectedStock
        return Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeOut(duration: 0.12)) { selectedStock = index }
        } label: {
            HStack(spacing: 6) {
                Text(name)
                    .font(.system(size: 11.5, weight: on ? .medium : .regular))
                    .foregroundColor(on ? gold : ink.opacity(0.80))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                Text("\(price)")
                    .font(.system(size: 11.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(on ? gold
                                     : (price >= BBCheat.Layout.priceCap
                                        ? gold.opacity(0.9) : Color.white.opacity(0.55)))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(on ? gold.opacity(0.13) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 零件

    private func section<Content: View>(title: String, note: String?,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(ink)
                Spacer(minLength: 0)
                if let note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundColor(sub)
                }
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 0.6)
        )
    }

    private func chip(_ title: String, on: Bool, tint: Color,
                      mono: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: on ? .semibold : .regular,
                              design: mono ? .rounded : .default))
                .monospacedDigit()
                .foregroundColor(on ? Color.black.opacity(0.86) : Color.white.opacity(0.62))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(on ? tint : Color.white.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
    }

    private func smallButton(_ title: String, tint: Color,
                             action: @escaping () -> Void) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tint)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
    }

    private func toggleRow(_ title: String, note: String, isOn: Bool,
                           action: @escaping () -> Void) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeOut(duration: 0.16)) { action() }
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(ink)
                    Text(note)
                        .font(.system(size: 9.5))
                        .foregroundColor(sub)
                }
                Spacer(minLength: 6)
                Capsule()
                    .fill(isOn ? accent : Color.white.opacity(0.16))
                    .frame(width: 34, height: 20)
                    .overlay(
                        Circle()
                            .fill(Color.white)
                            .frame(width: 16, height: 16)
                            .shadow(color: Color.black.opacity(0.28), radius: 1, x: 0, y: 1)
                            .padding(2),
                        alignment: isOn ? .trailing : .leading
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "开" : "关")
    }
}
