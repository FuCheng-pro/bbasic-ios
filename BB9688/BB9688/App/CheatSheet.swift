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
    /// 涨 = 红、跌 = 绿（A 股习惯，和行情软件一致）
    private let up = Color(red: 0.96, green: 0.38, blue: 0.36)
    private let down = Color(red: 0.32, green: 0.80, blue: 0.53)

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
                        casinoSection
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
        Text("地址来自对 rich.bin 的反汇编与内存实测：现金 0x78374+4·i、股价表 0x7A30C+13·i、走路骰子 RND(6) 两个调用点、赌场骰子三个调用点（pc 138695/138755/138815）、手牌表 0x78640+4·(8·玩家+槽)（只读）。改动只写在这几处，不碰别的位置。")
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

    // MARK: - 赌场（赌神 / 赌圣）

    /// 两张卡都做成「常驻」：开关一开，游戏问起就是「有」。
    ///
    /// ⚠️ 2026-10-27 定稿：**不写内存、不塞手牌**。挂的是 VM 的 `callHook`，
    /// 游戏调 `hasCard` 问 8/9 号卡时直接代答「有」（返回一个空槽号），
    /// 手牌表一个字不动 —— 所以手里不会凭空多出一张卡，卖卡/用卡也不受影响。
    ///
    /// 另外：这版移植的赌场**没有实现卡 8/9 的效果**（全程序 `hasCard` 只查
    /// 1/10/16/20/21/22/23/29 号卡，赌场里读手牌只为了画那一排），所以效果
    /// 仍由金手指兜：赌神 = 赢钱再补一份；赌圣 = 骰盅不盖（见 `BBCheat.allowsPicture`）。
    private var casinoSection: some View {
        section(title: "赌场", note: "赌神卡 / 赌圣卡 · 常驻") {
            VStack(spacing: 8) {
                toggleRow("赌神卡",
                          note: "游戏问起就是有 · 赌场赢钱自动再补一份，输了不动",
                          isOn: cheat.godGambler) {
                    cheat.godGambler.toggle()
                }
                toggleRow("赌圣卡",
                          note: "游戏问起就是有 · 进赌场骰盅不盖，三粒点数一直看得见",
                          isOn: cheat.saintGambler) {
                    cheat.saintGambler.toggle()
                }

                if cheat.saintGambler {
                    saintReadout
                    saintStatus
                }

                handStatus
            }
        }
    }

    /// 赌圣读到的点数。数值来自游戏自己掷好的那三粒（栈帧 `[rb-4/8/12]`），
    /// 不是我们另掷的，所以和画面上那三粒永远是同一把。
    private var saintReadout: some View {
        HStack(spacing: 8) {
            Text("这一把")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(Color.white.opacity(0.34))
            if let formula = cheat.casinoFormula, let size = cheat.casinoBigSmall {
                Text(formula)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(gold)
                    .monospacedDigit()
                Text(size)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.75))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(gold.opacity(0.14))
                    )
                Text("≥11 大 / ≤10 小")
                    .font(.system(size: 9))
                    .foregroundColor(Color.white.opacity(0.28))
            } else {
                Text("还没进赌场（进门掷完骰子才有点数）")
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.30))
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(gold.opacity(0.07))
        )
    }

    /// 这张卡游戏到底来问过没有。
    ///
    /// 我们**不往手牌里写卡**，所以手牌表里永远看不到它 —— 能证明「生效了」的
    /// 唯一证据，就是游戏调 `hasCard` 问 8/9 号卡时，我们替它答了「有」。
    /// 答过一次这里就亮。
    /// 赌圣这一串「到底走到哪一步了」——真机上没露骰子时，看这一行就知道卡在哪：
    /// 没进赌场 / 没读到点数 / 还在摇盅。
    private var saintStatus: some View {
        let scene = cheat.inCasino ? "赌场" : "其它场景"
        let pips = cheat.casinoDice.isEmpty
            ? "没读到点数"
            : cheat.casinoDice.map(String.init).joined(separator: "+")
        // 「摇盅中」= 盅还在摇，画面上故意不露骰子；「骰子已露」= 摇完了，三粒已贴上去
        let lid = cheat.cupOpen ? "骰子已露" : "摇盅中"
        // 「第 N 局」会跟着每一次摇盅 +1：真机上这个数不涨，就说明这一局没被
        // 当成新的一局，点数当然不会换（见 `BBCheat.planRound`）。
        let round = cheat.roundNumber > 0 ? "第 \(cheat.roundNumber) 局 · " : ""
        return Text("\(round)\(scene) · \(pips) · \(lid)")
            .font(.system(size: 9.5))
            .foregroundColor(Color.white.opacity(0.42))
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.bottom, 2)
    }

    private var handStatus: some View {
        let god = cheat.cardAsked.contains(BBCheatMap.cardGod)
        let saint = cheat.cardAsked.contains(BBCheatMap.cardSaint)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("游戏问过")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.34))
                chip(text: "赌神", on: god)
                chip(text: "赌圣", on: saint)
                Spacer(minLength: 0)
            }
            Text("不写内存、不塞手牌：游戏问「有没有这张卡」时直接答有。")
                .font(.system(size: 9.5))
                .foregroundColor(Color.white.opacity(0.34))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(gold.opacity(0.07))
        )
    }

    private func chip(text: String, on: Bool) -> some View {
        Text(text)
            .font(.system(size: 11, weight: on ? .semibold : .regular))
            .foregroundColor(on ? gold : Color.white.opacity(0.30))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(gold.opacity(on ? 0.16 : 0.05))
            )
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
                note: "\(BBCheat.Layout.stockCount) 家 · 均价 \(averagePrice) · 约 \(Int(BBCheat.Layout.secondsPerMonth)) 秒一个月") {
            VStack(spacing: 10) {
                trendRow
                rangeRow

                toggleRow("只涨不跌", note: "只防跌，不主动推涨", isOn: cheat.stockNeverFalls) {
                    cheat.stockNeverFalls.toggle()
                }

                recentPanel

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

    /// 趋势三选一：只决定往上还是往下，幅度还是游戏自己算的。
    private var trendRow: some View {
        HStack(spacing: 6) {
            Text("趋势")
                .font(.system(size: 11))
                .foregroundColor(sub)
                .frame(width: 26, alignment: .leading)
            chip("跌", on: cheat.stockTrend < 0, tint: gold) { cheat.stockTrend = -1 }
            chip("原样", on: cheat.stockTrend == 0, tint: gold) { cheat.stockTrend = 0 }
            chip("涨", on: cheat.stockTrend > 0, tint: gold) { cheat.stockTrend = 1 }
        }
    }

    /// 护栏：把价格关在 [下限, 上限] 里。涨跌方向由上面决定，这里只管别跑飞。
    private var rangeRow: some View {
        VStack(spacing: 7) {
            toggleRow("限定区间",
                      note: cheat.stockRange
                        ? "价格只在 \(cheat.stockLower)–\(cheat.stockUpper) 之间"
                        : "涨跌不限幅",
                      isOn: cheat.stockRange) {
                cheat.stockRange.toggle()
            }
            if cheat.stockRange {
                HStack(spacing: 10) {
                    stepper("下限", cheat.stockLower) { cheat.stepLower($0) }
                    stepper("上限", cheat.stockUpper) { cheat.stepUpper($0) }
                    Spacer(minLength: 0)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    /// 一个 `− 值 +` 的小步进器（步长 10）
    private func stepper(_ label: String, _ value: Int,
                         action: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(sub)
            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                action(-10)
            } label: {
                stepGlyph("minus")
            }
            .buttonStyle(.plain)

            Text("\(value)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundColor(ink)
                .frame(minWidth: 34)

            Button {
                UISelectionFeedbackGenerator().selectionChanged()
                action(10)
            } label: {
                stepGlyph("plus")
            }
            .buttonStyle(.plain)
        }
    }

    private func stepGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(gold)
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(gold.opacity(0.13))
            )
    }

    // MARK: - 最近 12 次调价

    /// 只记事实，不做预测 —— 这是上一版踩过的坑：游戏每个月的浮动方向是一次
    /// `RND(2)`（反汇编 0x589F0），记多少历史都推不出偏向，画「预测」等于编。
    /// 但**已经发生过的事**是可以如实摆出来的：每 0.4 秒轮询 20 个价格，
    /// 一变就存一张快照（最多 1 条基线 + 12 次变化），这里画选中那只的逐次涨跌。
    ///
    /// 手动改价也会记一笔，但颜色更淡、顶上有个白点，能和「游戏自己调的」分开。
    private var recentPanel: some View {
        let index = min(max(selectedStock, 0), BBCheat.Layout.stockCount - 1)
        let name = index < cheat.stockNames.count ? cheat.stockNames[index] : "—"
        let series = Array(BBCheatMap.changeSeries(cheat.ticks, index).suffix(12))
        let ups = series.filter { $0.pct > 0.05 }.count
        let downs = series.filter { $0.pct < -0.05 }.count
        let mean = series.isEmpty ? 0 : series.reduce(0.0) { $0 + $1.pct } / Double(series.count)
        let tail = cheat.ticks.suffix(7).map { index < $0.prices.count ? $0.prices[index] : 0 }
        return VStack(spacing: 7) {
            HStack(spacing: 6) {
                Text("最近 12 次")
                    .font(.system(size: 11))
                    .foregroundColor(sub)
                Text(name)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(gold)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(series.count)/12")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundColor(series.isEmpty ? sub : accent)
            }

            TickBars(values: series.map { $0.pct }, manuals: series.map { $0.manual }, slots: 12)
                .frame(height: 72)

            if series.isEmpty {
                Text("还没记录到调价。每个月调一次（约 \(Int(BBCheat.Layout.secondsPerMonth)) 秒），开一局等一会儿就有了。")
                    .font(.system(size: 9.5))
                    .foregroundColor(Color.white.opacity(0.32))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 3) {
                    Text(tail.map(String.init).joined(separator: " → "))
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundColor(Color.white.opacity(0.30))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(ups) 涨 · \(downs) 跌 · 均值 \(String(format: "%+.1f%%", mean)) · 白点 = 我改的")
                        .font(.system(size: 9.5))
                        .monospacedDigit()
                        .foregroundColor(Color.white.opacity(0.34))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
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
                smallButton("−10%", tint: gold) { cheat.nudgeStock(index, -0.1) }
                smallButton("+10%", tint: gold) { cheat.nudgeStock(index, 0.1) }
                smallButton("×2", tint: gold) { cheat.nudgeStock(index, 1.0) }
                smallButton("÷2", tint: gold) { cheat.nudgeStock(index, -0.5) }
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

/// 12 根柱子 = 最近 12 次调价，向上红（涨）、向下绿（跌），长度 = 幅度。
///
/// 固定 12 个槽位（没攒满的打一条灰线），这样「还差几次」一眼可见。
/// 手动改的那一次画成半透明并点一个白点 —— 别让玩家以为自己手改的和行情混在一起。
private struct TickBars: View {
    let values: [Double]
    let manuals: [Bool]
    let slots: Int

    private let maxAbs: Double = 11
    private let upColor = Color(red: 0.96, green: 0.38, blue: 0.36)
    private let downColor = Color(red: 0.32, green: 0.80, blue: 0.53)

    var body: some View {
        Canvas { ctx, size in
            let n = max(1, slots)
            let gap: CGFloat = 3
            let w = max(2, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            let midY = size.height / 2

            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: midY))
            axis.addLine(to: CGPoint(x: size.width, y: midY))
            ctx.stroke(axis, with: .color(Color.white.opacity(0.10)), lineWidth: 0.6)

            for i in 0..<n {
                let x = CGFloat(i) * (w + gap)
                let shown = i >= n - values.count
                guard shown else {
                    // 空槽：一条细灰线，表示「这一次还没发生」
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: midY - 1, width: w, height: 2),
                                  cornerRadius: 1),
                             with: .color(Color.white.opacity(0.07)))
                    continue
                }
                let k = i - (n - values.count)
                let pct = max(-maxAbs, min(maxAbs, values[k]))
                let barH = max(1.5, CGFloat(abs(pct) / maxAbs) * (midY - 4))
                let rising = pct >= 0
                let color = rising ? upColor : downColor
                let rect = rising
                    ? CGRect(x: x, y: midY - barH, width: w, height: barH)
                    : CGRect(x: x, y: midY, width: w, height: barH)
                ctx.fill(Path(roundedRect: rect, cornerRadius: min(2.5, w / 2)),
                         with: .color(manuals[k] ? color.opacity(0.45) : color))

                if manuals[k] {
                    let cy = rising ? rect.minY - 3.5 : rect.maxY + 3.5
                    ctx.fill(Path(ellipseIn: CGRect(x: x + w / 2 - 1.5, y: cy - 1.5,
                                                    width: 3, height: 3)),
                             with: .color(Color.white.opacity(0.55)))
                }
            }
        }
    }
}
