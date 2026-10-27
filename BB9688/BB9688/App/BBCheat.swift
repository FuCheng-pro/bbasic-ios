//
//  BBCheat.swift
//  BB9688
//
//  「大富翁」金手指 —— 可观察状态 + 定时托底。
//
//  ── 职责边界 ────────────────────────────────────────────────────
//  地址、自检、读写这些「会不会写坏内存」的事全在 `Core/BBCheatMap.swift`，
//  那一层不依赖 UI，能在 Windows 上无头测。这个文件只负责三件事：
//    ① 把内存里的数字变成 `@Published`，面板才能实时显示；
//    ② 每 0.4 秒把「无限金钱 / 股价只涨不跌」这两项**持续生效**的托底做掉；
//    ③ 给 VM 的 `randomHook` 提供一个骰子改写入口。
//
//  ── 为什么托底用轮询而不是挂钩子 ────────────────────────────────
//  「游戏改完我再改回来」天然适合轮询：一拍只读 24 个 int，成本可以忽略。
//  挂到内存写入路径上要往 VM 最热的 `putMem` 里塞判断，不值当。
//
//  ── 线程 ────────────────────────────────────────────────────────
//  `diceOverride` 跑在 **VM 线程**，只读 `dice` 和内存，绝不碰 `@Published`；
//  其余方法都跑在主线程（按钮、定时器）。这块在 2026-10-26 崩过一次，
//  「VM 线程里改可观察状态」正是那次的根因，不要再犯。
//

import Foundation
import SwiftUI

final class BBCheat: ObservableObject {

    typealias Layout = BBCheatMap.Layout

    // MARK: - 对外状态

    /// 地址自检通过（确认跑的是大富翁）。不通过时所有操作都是空操作。
    @Published private(set) var unlocked = false
    /// 4 个玩家的现金
    @Published private(set) var cash: [Int] = Array(repeating: 0, count: Layout.cashSlots)
    /// 20 家公司的名字（从内存里按 GBK 解出来的，是游戏里的真名）
    @Published private(set) var stockNames: [String] = []
    /// 20 家公司的现价
    @Published private(set) var stockPrices: [Int] = []

    /// 骰子 1（画面左边那粒）的点数：0 = 不控制，1...6 = 固定成它
    @Published var diceA: Int = 0 {
        didSet {
            guard oldValue != diceA else { return }
            store.set(diceA, forKey: Keys.diceA)
            PerfLog.shared.event("金手指：骰子 1 → \(diceA == 0 ? "不控制" : "固定 \(diceA)")")
        }
    }

    /// 骰子 2（画面右边那粒）
    @Published var diceB: Int = 0 {
        didSet {
            guard oldValue != diceB else { return }
            store.set(diceB, forKey: Keys.diceB)
            PerfLog.shared.event("金手指：骰子 2 → \(diceB == 0 ? "不控制" : "固定 \(diceB)")")
        }
    }

    /// 骰子只对「我」生效（默认开）。
    ///
    /// 关掉就是四个玩家一起控制 —— 调试/看戏时有用，正常玩别关：
    /// 电脑也走 12 格的话，一局就变成「谁也没法堵谁」。
    @Published var diceOnlyMe = true {
        didSet {
            guard oldValue != diceOnlyMe else { return }
            store.set(diceOnlyMe, forKey: Keys.diceOnlyMe)
            PerfLog.shared.event("金手指：骰子只对玩家 \(diceOnlyMe ? "生效" : "关闭（作用于全部）")")
        }
    }

    /// 人类的座位号。实测依据（`Tools/headless/turnprobe`）：
    /// 停止按键 12 秒 —— 电脑座位 3 自己掷了 40 次骰，座位 0 一次没掷、
    /// 最后卡在等输入。所以单人游戏的人类 = 座位 0。
    static let humanSeat = 0

    /// 现在轮到谁（0..3）。面板上那句「当前回合」用它，
    /// 也让用户理解「为什么我设了骰子这会儿不动」—— 因为轮到电脑了。
    @Published private(set) var currentSeat = 0

    /// 一粒都不控制
    var diceOff: Bool { diceA == 0 && diceB == 0 }

    var seatLabel: String {
        "玩家 \(currentSeat + 1)\(currentSeat == Self.humanSeat ? "（我）" : "（电脑）")"
    }

    /// 两粒一样时显示「固定 N」，不一样时显示「a + b」
    var diceSummary: String {
        if diceOff { return "原样随机" }
        let text: String
        if diceA == diceB {
            text = "两粒都固定为 \(diceA)"
        } else {
            let a = diceA == 0 ? "随机" : "\(diceA)"
            let b = diceB == 0 ? "随机" : "\(diceB)"
            text = "\(a) + \(b)"
        }
        return diceOnlyMe ? "\(text) · 只对我" : text
    }

    /// 「无限金钱」保底给哪一位（1...4）。默认第 1 位 —— 单人游戏里人类玩家就是第一个。
    ///
    /// 为什么不给全员保底：这游戏的胜负是「把别人搞破产」，
    /// 四个人的钱都托底，这局就永远结束不了。宁可让用户明确选一个。
    @Published var cashTarget: Int = 1 {
        didSet {
            guard oldValue != cashTarget else { return }
            store.set(cashTarget, forKey: Keys.cashTarget)
            PerfLog.shared.event("金手指：金钱保底对象 → 玩家 \(cashTarget)")
        }
    }

    /// 现金托底：低于 `cashFloor` 就补回去
    @Published var infiniteCash = false {
        didSet {
            guard oldValue != infiniteCash else { return }
            store.set(infiniteCash, forKey: Keys.cash)
            PerfLog.shared.event("金手指：无限金钱 \(infiniteCash ? "开" : "关")")
        }
    }

    /// 股价只涨不跌：游戏把价格压下去就写回上一次的高点
    @Published var stockNeverFalls = false {
        didSet {
            guard oldValue != stockNeverFalls else { return }
            store.set(stockNeverFalls, forKey: Keys.stock)
            // 托底基线是「打开这一刻的现价」，不是历史最高价
            floor = stockNeverFalls ? stockPrices : []
            PerfLog.shared.event("金手指：股价只涨不跌 \(stockNeverFalls ? "开" : "关")")
        }
    }

    /// 「无限金钱」的托底值
    static var cashFloor: Int { Layout.cashCap }

    // MARK: - 内部

    private weak var vm: BBVM?
    private var pump: Timer?
    /// 「只涨不跌」的托底价，和 `stockPrices` 同下标
    private var floor: [Int] = []
    /// 上次注入状态栏重绘的时间（限流用）
    private var lastHUDRefresh = 0.0
    private let store = UserDefaults.standard

    private enum Keys {
        static let diceA = "bb.cheat.diceA"
        static let diceOnlyMe = "bb.cheat.diceOnlyMe"
        static let diceB = "bb.cheat.diceB"
        /// 旧版只有一个「骰子」设置，迁移时拿它给两粒都赋初值
        static let diceLegacy = "bb.cheat.dice"
        static let cash = "bb.cheat.cash"
        static let stock = "bb.cheat.stock"
        static let cashTarget = "bb.cheat.cashTarget"
    }

    init() {
        // init 里赋值不触发 didSet，所以不会写盘、不会写日志
        // 旧版本存的是单值 `bb.cheat.dice`（两粒一起改），迁移成两粒同值
        let legacy = min(max(store.integer(forKey: Keys.diceLegacy), 0), 6)
        diceA = min(max(store.integer(forKey: Keys.diceA), 0), 6)
        diceB = min(max(store.integer(forKey: Keys.diceB), 0), 6)
        if diceA == 0, diceB == 0, legacy > 0 {
            diceA = legacy
            diceB = legacy
        }
        infiniteCash = store.bool(forKey: Keys.cash)
        // 没存过时 `bool(forKey:)` 返回 false，而这一项的默认值是「开」，
        // 所以要用 object(forKey:) 判断「有没有存过」
        diceOnlyMe = (store.object(forKey: Keys.diceOnlyMe) as? Bool) ?? true
        stockNeverFalls = store.bool(forKey: Keys.stock)
        cashTarget = min(max(store.integer(forKey: Keys.cashTarget), 1), Layout.cashSlots)
    }

    deinit { pump?.invalidate() }

    // MARK: - 摘要（设置面板那行用）

    var activeCount: Int {
        (diceOff ? 0 : 1) + (infiniteCash ? 1 : 0) + (stockNeverFalls ? 1 : 0)
    }

    var summary: String {
        guard unlocked else { return "不可用" }
        return activeCount == 0 ? "未启用" : "已开 \(activeCount) 项"
    }

    // MARK: - 挂接

    /// 每局开始时调一次。
    ///
    /// 放行条件只有一条：**内存里真出现了那张股价表**（程序启动后从 DATA 段灌进去的，
    /// 首项是 GBK「大众汽车」）。不看 bin 长度 —— 换个版本的大富翁长度就变了，
    /// 但表还在原地址上；反过来，别的程序哪怕长度碰巧相同，也不会有这张表。
    /// 所以 attach 这一刻通常还是 `unlocked == false`，之后每 0.4 秒自检一次，
    /// 游戏把表灌进来就自动放行（面板上那句「先开一局」也是这个意思）。
    func attach(_ vm: BBVM?) {
        detach()
        self.vm = vm
        refresh()
        startPump()
    }

    func detach() {
        pump?.invalidate()
        pump = nil
        vm = nil
        unlocked = false
        floor = []
        if cash.contains(where: { $0 != 0 }) { cash = Array(repeating: 0, count: Layout.cashSlots) }
        if !stockPrices.isEmpty {
            stockPrices = []
            stockNames = []
        }
    }

    private func startPump() {
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pump = timer
    }

    // MARK: - 刷新 / 托底

    func refresh() {
        guard let mem = vm?.memory else { return }

        if !unlocked, BBCheatMap.looksLikeRich(mem) { unlocked = true }
        guard unlocked else { return }

        let seat = BBCheatMap.currentSeat(mem)
        if seat != currentSeat { currentSeat = seat }

        refreshCash(mem)
        refreshStocks(mem)
    }

    private func refreshCash(_ mem: BBMemory) {
        var next = [Int](repeating: 0, count: Layout.cashSlots)
        var toppedUp = false
        let target = min(max(cashTarget, 1), Layout.cashSlots) - 1
        for i in 0..<Layout.cashSlots {
            var value = BBCheatMap.cash(mem, slot: i)
            // 只补选中的那一位；欠款（负现金）也一并补平
            if infiniteCash, i == target, value < BBCheat.cashFloor {
                value = BBCheat.cashFloor
                BBCheatMap.setCash(mem, slot: i, value)
                toppedUp = true
            }
            next[i] = value
        }
        if next != cash { cash = next }
        if toppedUp { refreshHUD(force: false) }
    }

    private func refreshStocks(_ mem: BBMemory) {
        // 托底判定在 Core 里（`enforcePriceFloor`），这样它能被无头测试覆盖；
        // 这里只管「关着的时候只读、开着的时候让它去改」。
        var prices = [Int](repeating: 0, count: Layout.stockCount)
        if stockNeverFalls {
            prices = BBCheatMap.enforcePriceFloor(mem, floor: &floor)
        } else {
            for i in 0..<Layout.stockCount { prices[i] = BBCheatMap.stockPrice(mem, i) }
        }

        var names = stockNames
        if names.count != Layout.stockCount {
            names = (0..<Layout.stockCount).map { BBCheatMap.stockName(mem, $0) }
        }

        if prices != stockPrices { stockPrices = prices }
        if names != stockNames { stockNames = names }
    }

    // MARK: - 让状态栏立刻刷新

    /// 改完钱请游戏重画一次状态栏。
    ///
    /// 为什么需要：状态栏只在**换人**的时候重绘，直接改内存后画面还是旧数字，
    /// 要等到下一回合才更新 —— 用起来像「点了没反应」。
    /// 这里直接调游戏自己的绘制函数（`BBCheatMap.Layout.hudRefresh`），
    /// 由 `BBVM.requestSubroutineCall` 注入执行一次，寄存器原样恢复。
    ///
    /// `force = false` 走限流：「无限金钱」每 0.4 秒会补一次钱，
    /// 每次都重绘会把 VM 拖出不必要的开销，所以托底那条路最多 0.8 秒刷一次。
    private func refreshHUD(force: Bool = true) {
        guard unlocked, let vm else { return }
        let now = BBVM.clockSeconds()
        if !force, now - lastHUDRefresh < 0.8 { return }
        lastHUDRefresh = now
        vm.requestSubroutineCall(BBCheatMap.Layout.hudRefresh)
    }

    // MARK: - 骰子（VM 线程调用）

    /// `BBVM.randomHook` 的实现。**不要在这里改任何 `@Published`。**
    func diceOverride(n: UInt32, frameBase: UInt32) -> UInt32? {
        // 先读两个值到局部变量：`@Published` 属性从 VM 线程读是安全的（单次对齐读），
        // 但不要在同一个表达式里反复跨线程取，免得读到「改了一半」的组合。
        let wantA = diceA
        let wantB = diceB
        guard wantA > 0 || wantB > 0, unlocked, let mem = vm?.memory else { return nil }
        // 只对玩家：轮到电脑就原样放行（nil）。钩子跑在 VM 线程，只读 `diceOnlyMe`。
        let seat = diceOnlyMe ? Self.humanSeat : nil
        return BBCheatMap.forcedDice(n: n, frameBase: frameBase, memory: mem,
                                    wantA: wantA, wantB: wantB, onlySeat: seat)
    }

    // MARK: - 金钱

    // ⚠️ 一律**从内存读当前值再算**，不要拿 `cash` 这个缓存数组当输入：
    //    缓存是 0.4 秒前的快照，游戏这期间可能刚扣过钱，
    //    在旧值上 +5 万会把游戏刚才扣掉的又加回去（等于白送）。
    func addCash(slot: Int, _ delta: Int) {
        guard let mem = vm?.memory, unlocked, slot >= 0, slot < Layout.cashSlots else { return }
        let value = BBCheatMap.clampCash(BBCheatMap.cash(mem, slot: slot) + delta)
        BBCheatMap.setCash(mem, slot: slot, value)
        var next = cash
        next[slot] = value
        cash = next
        refreshHUD()
    }

    func multiplyCash(slot: Int, _ factor: Int) {
        guard let mem = vm?.memory, unlocked, slot >= 0, slot < Layout.cashSlots else { return }
        let value = BBCheatMap.clampCash(BBCheatMap.cash(mem, slot: slot) * factor)
        BBCheatMap.setCash(mem, slot: slot, value)
        var next = cash
        next[slot] = value
        cash = next
        refreshHUD()
    }

    /// 只给「还在局里」的人加钱：现金 <= 0 的槽位不动（那是没参战的角色）
    func addCashToAll(_ delta: Int) {
        guard let mem = vm?.memory, unlocked else { return }
        var next = cash
        for i in 0..<Layout.cashSlots {
            let current = BBCheatMap.cash(mem, slot: i)
            guard current > 0 else { continue }
            next[i] = BBCheatMap.clampCash(current + delta)
            BBCheatMap.setCash(mem, slot: i, next[i])
        }
        cash = next
        refreshHUD()
    }

    func multiplyCashAll(_ factor: Int) {
        guard let mem = vm?.memory, unlocked else { return }
        var next = cash
        for i in 0..<Layout.cashSlots {
            let current = BBCheatMap.cash(mem, slot: i)
            guard current > 0 else { continue }
            next[i] = BBCheatMap.clampCash(current * factor)
            BBCheatMap.setCash(mem, slot: i, next[i])
        }
        cash = next
        refreshHUD()
    }

    // MARK: - 股价

    /// 只调一只股票。倍数 < 1 就是砸盘。
    ///
    /// ⚠️ 「只涨不跌」开着的时候，托底线要跟着一起改 ——
    /// 不然手动砸下去的价格会在 0.4 秒内被托底写回来，看起来就是「按钮没反应」。
    func boostStock(_ index: Int, _ factor: Double) {
        guard let mem = vm?.memory, unlocked,
              index >= 0, index < Layout.stockCount else { return }
        let current = BBCheatMap.stockPrice(mem, index)
        let target = min(Layout.priceCap, max(1, Int((Double(current) * factor).rounded())))
        BBCheatMap.setStockPrice(mem, index, target)
        applyToCache(index, target)
    }

    /// 把某一只直接设成某个价（1...999）
    func setStock(_ index: Int, _ value: Int) {
        guard let mem = vm?.memory, unlocked,
              index >= 0, index < Layout.stockCount else { return }
        let target = min(Layout.priceCap, max(1, value))
        BBCheatMap.setStockPrice(mem, index, target)
        applyToCache(index, target)
    }

    /// 改完写回缓存 + 同步托底线，界面立刻跟着变
    private func applyToCache(_ index: Int, _ value: Int) {
        guard stockPrices.count == Layout.stockCount else { return }
        var next = stockPrices
        next[index] = value
        stockPrices = next
        if stockNeverFalls, floor.count == Layout.stockCount { floor[index] = value }
    }

    /// 全部乘一个倍数（翻倍 = 2.0）。同样以内存现价为输入，不用缓存。
    func boostStocks(_ factor: Double) {
        guard let mem = vm?.memory, unlocked else { return }
        var next = [Int](repeating: 0, count: Layout.stockCount)
        for i in 0..<Layout.stockCount {
            let current = BBCheatMap.stockPrice(mem, i)
            next[i] = min(Layout.priceCap, max(1, Int((Double(current) * factor).rounded())))
            BBCheatMap.setStockPrice(mem, i, next[i])
        }
        stockPrices = next
        if stockNeverFalls { floor = next }
    }

    /// 全部拉到一个固定价（999 = 顶格）
    func setAllStocks(_ value: Int) {
        guard let mem = vm?.memory, unlocked else { return }
        let target = min(Layout.priceCap, max(1, value))
        var next = [Int](repeating: target, count: Layout.stockCount)
        for i in 0..<Layout.stockCount {
            next[i] = target
            BBCheatMap.setStockPrice(mem, i, target)
        }
        stockPrices = next
        if stockNeverFalls { floor = next }
    }
}
