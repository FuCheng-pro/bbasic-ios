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

    /// 最近 13 张价格快照（1 条基线 + 12 次变化），面板上画「最近 12 次」用。
    ///
    /// 只记事实：每 0.4 秒轮询，价格变了才追加一张。这里**不做任何推测** ——
    /// 下一步的方向是游戏里一次 RND(2)，多少次历史都推不出偏向。
    @Published private(set) var ticks: [BBCheatMap.PriceTick] = []

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
            // 和「限定区间」「趋势」互斥：托底是「只防跌不推涨」，
            // 和那两个同时开时行为会互相抵消，干脆只留一个。
            if stockNeverFalls {
                if stockRange { stockRange = false }
                if stockTrend != 0 { stockTrend = 0 }
            }
            PerfLog.shared.event("金手指：股价只涨不跌 \(stockNeverFalls ? "开" : "关")")
        }
    }

    /// 股价趋势：+1 涨、-1 跌、0 原样。
    ///
    /// 只掰方向、不改幅度 —— 游戏自己算的涨跌幅（通常 1~5%）原样保留，
    /// 所以看起来是「行情一直在涨」，而不是「数字被拉爆」。
    @Published var stockTrend: Int = 0 {
        didSet {
            guard oldValue != stockTrend else { return }
            store.set(stockTrend, forKey: Keys.stockTrend)
            previousPrices = stockPrices        // 换方向时以当前价为基线
            if stockTrend != 0, stockNeverFalls { stockNeverFalls = false }
            let label = stockTrend > 0 ? "涨" : (stockTrend < 0 ? "跌" : "原样")
            PerfLog.shared.event("金手指：股价趋势 → \(label)")
        }
    }

    /// 上一次看到的 20 个价格（用来判断游戏是不是刚调过价）
    private var previousPrices: [Int] = []

    /// 股价在固定区间内涨跌：跌破下限拉回、超过上限压回。
    @Published var stockRange = false {
        didSet {
            guard oldValue != stockRange else { return }
            store.set(stockRange, forKey: Keys.stockRange)
            if stockRange, stockNeverFalls { stockNeverFalls = false }
            PerfLog.shared.event("金手指：股价区间 \(stockRange ? "开（\(stockLower)–\(stockUpper)）" : "关")")
        }
    }

    /// 区间的下限 / 上限（1...999）
    @Published var stockLower: Int = 20 {
        didSet {
            guard oldValue != stockLower else { return }
            store.set(stockLower, forKey: Keys.stockLower)
            if stockLower > stockUpper { stockUpper = stockLower }
        }
    }

    @Published var stockUpper: Int = 300 {
        didSet {
            guard oldValue != stockUpper else { return }
            store.set(stockUpper, forKey: Keys.stockUpper)
            if stockUpper < stockLower { stockLower = stockUpper }
        }
    }

    /// 调区间：夹到 1...999，并保证下 <= 上
    func stepLower(_ delta: Int) {
        stockLower = min(Layout.priceCap, max(1, stockLower + delta))
    }

    func stepUpper(_ delta: Int) {
        stockUpper = min(Layout.priceCap, max(1, stockUpper + delta))
    }

    /// 「无限金钱」的托底值
    static var cashFloor: Int { Layout.cashCap }

    // MARK: - 赌场（赌神卡 / 赌圣卡 常驻）
    //
    //  两件事分开看：
    //  ① **「有这张卡」怎么让游戏认**：不写内存、不塞手牌 —— 挂 `BBVM.callHook`，
    //     游戏一旦调 `hasCard(player, card)` 问 8/9 号卡，我们直接替它答「有」
    //     （见 `callOverride`）。手牌表里**一个字都不留**，玩家看不到多出来的卡。
    //  ② **效果**：这版移植的赌场从不问 8/9 号卡（10 处 `hasCard` 只查
    //     1/10/16/20/21/22/23/29），所以 ① 目前不会触发游戏行为，
    //     效果必须由这里兜：赌神 = 赢钱再补一份；赌圣 = 读赌场栈帧里掷好的三粒。
    //
    //  卡号 / 手牌表结构见 `BBCheatMap.cardGod`、`handBase`。

    /// 赌神卡常驻：游戏问起就有 + 赌场赢钱彩金加倍
    @Published var godGambler = false {
        didSet {
            guard oldValue != godGambler else { return }
            store.set(godGambler, forKey: Keys.godGambler)
            if !godGambler {
                casinoLock.lock(); casinoRoundArmed = false; casinoLock.unlock()
                if !saintGambler, !cardAsked.isEmpty { cardAsked = [] }
            }
            PerfLog.shared.event("金手指：赌神卡 \(godGambler ? "常驻开" : "常驻关")")
        }
    }

    /// 赌圣卡常驻：游戏问起就有 + 进赌场先看到这一把的点数
    @Published var saintGambler = false {
        didSet {
            guard oldValue != saintGambler else { return }
            store.set(saintGambler, forKey: Keys.saintGambler)
            if !saintGambler {
                casinoLock.lock()
                cupOpenFlag = false
                seenPips = [0, 0, 0]
                casinoLock.unlock()
                if !casinoDice.isEmpty { casinoDice = [] }
                if cupOpen { cupOpen = false }
                if !godGambler, !cardAsked.isEmpty { cardAsked = [] }
            }
            PerfLog.shared.event("金手指：赌圣卡 \(saintGambler ? "常驻开" : "常驻关")")
        }
    }

    /// 游戏有没有问过这两张卡（展示用）。
    ///
    /// 钩子跑在 VM 线程，**不能写 `@Published`** —— 它只往锁里记一笔
    /// `askedCards`，0.4 秒泵再搬到这个属性上（和 `casinoRoundArmed` 一个套路）。
    @Published private(set) var cardAsked: Set<Int> = []
    /// VM 线程写、主线程搬的「问过的卡号」
    private var askedCards: Set<Int> = []

    /// 场景识别是不是认为「现在在赌场」。赌局的清除时机看它。
    @Published private(set) var inCasino = false
    /// 骰盅是不是被我们「顶开」了（面板上直接显示，方便真机排查）
    @Published private(set) var cupOpen = false

    /// 开盖的开关（VM 线程用）。和 `cupOpen` 分开：`@Published` 只能在主线程写。
    ///
    /// 一旦这一把掷过骰子就置上，离开赌场（回到地图 / 场景切走）才清 —— 中间游戏
    /// 会把盖盅那几笔反复贴上来（实测 ~313ms 一次），全都要拦掉。
    private var cupOpenFlag = false

    // MARK: - 赌圣看到的点数（主线程展示用）

    /// 赌圣看到的本局点数（1...6 × 3，按掷的顺序）。没进过赌场是空的。
    ///
    /// 点数不是我们掷的 —— 是赌场自己掷完存在栈帧里的（见 `casinoDiceFromFrame`），
    /// 这里只是「读到」，所以画面上画的和这里显示的必然是同一组。
    @Published private(set) var casinoDice: [Int] = []

    /// 三粒齐了才有值：这一把的合计点数
    var casinoSum: Int? { casinoDice.count == 3 ? casinoDice.reduce(0, +) : nil }

    /// 这一把是大是小（没看到点数时为 nil）。≥11 大、≤10 小。
    var casinoBigSmall: String? {
        guard let sum = casinoSum else { return nil }
        return BBCheatMap.casinoBig(sum: sum) ? "大" : "小"
    }

    /// 这是进门以来的第几局（每次重定值 +1）。面板上显示，用来确认真机上次进
    /// 赌场后是不是每局都重新定过值 —— 不涨就说明「新一段摇盅」没被认出来。
    var roundNumber: Int {
        casinoLock.lock(); defer { casinoLock.unlock() }
        return roundSerial
    }

    /// 「3 + 4 + 2 = 9」这一行
    var casinoFormula: String? {
        guard let sum = casinoSum else { return nil }
        return "\(casinoDice.map(String.init).joined(separator: " + ")) = \(sum)"
    }

    /// 赌场回合进行中（彩金加倍的一次性判定，见 `godGamblerBonus`）
    private var casinoRoundArmed = false
    /// 主线程读 armed 的锁保护版
    private var armedNow: Bool {
        casinoLock.lock(); defer { casinoLock.unlock() }
        return casinoRoundArmed
    }
    /// VM 线程（钩子）和主线程（泵）都要碰的量，统一走这把锁
    private let casinoLock = NSLock()
    /// 连续几拍「不是人类回合」（主线程专用），见 `syncCasinoState`
    private var nonHumanTicks = 0
    /// VM 线程置、主线程消费：看到了棋盘地块
    private var boardSeen = false
    /// 这一把屏幕上的三粒点数（按掷的顺序，1...6，0 = 还没画）。
    ///
    /// 直接来自**画到屏幕上的那一笔**（`seePicture` 从源图 x 反推），所以面板读数
    /// 和画面像素永远同一个数。VM 线程写、主线程读。
    private var seenPips: [Int] = [0, 0, 0]

    /// 进门那一刻预定的三粒（0 基）。VM 线程写、两个线程都读（走锁）。
    ///
    /// 为什么要在进门就定：赌场是「先进门 → 摇盅 → 玩家押注 → 才掷骰」，
    /// 押注时本局点数还不存在（`diceorder` 时间线：进门 11.4s、掷骰 20.7s）。
    /// 想让玩家**押注前**就看到结果，只能进门先从游戏自己的随机序列里抽三个存着，
    /// 等它真掷的时候再原样还给它（`diceOverride`）。这样画面、面板、结算同一组数。
    private var plannedPips: [Int] = []

    /// 骰子条贴图（`RICH.LIB #66`）的句柄，-1 = 没加载。
    ///
    /// 押注前游戏还没画骰面，画面空着 —— 只能由我们把这三粒贴上去。
    /// 在 `attach` 里加载（那时 VM 线程还没起，不会和游戏抢资源表）。
    private var diceStripHandle = -1
    /// 骰子条重试计数（主线程），见 `retryDiceStrip`
    private var stripRetry = 0
    /// 上一组已经贴出去的点数（主线程），用来「每局只记一条日志」
    private var previewLogged: [Int] = []

    /// 上一笔「赌场掷骰」的时刻（VM 线程）。掀开动画紧跟掷骰（实测 0.3~0.9 秒），
    /// 用它挡一下：刚掷完这几帧的盅贴图不许被当成「新一局」。
    private var lastThrowStamp: Double = 0
    /// 本局的骰子游戏已经掷过了（VM 线程）。置上就说明「下一次摇盅」是新一局，
    /// 得重新定值 —— 否则玩家进门后连着押，每局都是同一组点数。
    private var thrownThisRound = false
    /// 「骰盅贴图 → 局」的状态机（VM 线程，锁内使用）。
    ///
    /// 只按「间隔」切段会误伤：开牌后零星几帧盅也算一段，当场重定值就会把屏幕上
    /// 正开着的点数换掉（玩家按旧值押、看到新值，就是「骰子变了但答案不对」）。
    /// 规则见 `BBCheatMap.CupSegmentTracker`。
    private var cupTracker = BBCheatMap.CupSegmentTracker()
    /// 已经就「游戏自己画的骰面 ≠ 预定值」报过警（每局一次）
    private var mismatchLogged = false
    /// 现在是第几局（每次重定值 +1），只给日志用
    private var roundSerial = 0

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
        static let stockTrend = "bb.cheat.stockTrend"
        static let stockRange = "bb.cheat.stockRange"
        static let stockLower = "bb.cheat.stockLower"
        static let stockUpper = "bb.cheat.stockUpper"
        static let cashTarget = "bb.cheat.cashTarget"
        static let godGambler = "bb.cheat.godGambler"
        static let saintGambler = "bb.cheat.saintGambler"
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

        stockTrend = min(1, max(-1, store.integer(forKey: Keys.stockTrend)))
        stockRange = store.bool(forKey: Keys.stockRange)
        let lo = store.integer(forKey: Keys.stockLower)
        let hi = store.integer(forKey: Keys.stockUpper)
        stockLower = min(Layout.priceCap, max(1, lo == 0 ? 20 : lo))
        stockUpper = min(Layout.priceCap, max(stockLower, hi == 0 ? 300 : hi))

        godGambler = store.bool(forKey: Keys.godGambler)
        saintGambler = store.bool(forKey: Keys.saintGambler)
    }

    deinit { pump?.invalidate() }

    // MARK: - 摘要（设置面板那行用）

    var activeCount: Int {
        (diceOff ? 0 : 1) + (infiniteCash ? 1 : 0)
            + ((stockNeverFalls || stockRange || stockTrend != 0) ? 1 : 0)
            + (godGambler ? 1 : 0) + (saintGambler ? 1 : 0)
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
        // 赌圣：拦「盖盅」那一笔 + 顺手记下三粒骰面是哪一帧（判定见 `BBCheatMap`）。
        // 钩子每笔贴图都会被问一次，所以判定第一道必须是纯整数比较，不能带锁。
        vm?.graphics.onPicture = { [weak self] index, dx, dy, w, h, srcX in
            guard let self else { return true }
            return self.seePicture(index: index, dx: dx, dy: dy, w: w, h: h, srcX: srcX)
        }
        // 骰子条在这里加载：此刻 VM 线程还没起（`MachineEngine` 是先 attach 再起线程），
        // 不会和游戏自己的图片加载抢 `resources` 那张表。
        if let vm {
            diceStripHandle = vm.graphics.loadPicture(name: Array("RICH.LIB".utf8),
                                                      index: BBCheatMap.diceStripIndex)
        }
        refresh()
        startPump()
    }

    func detach() {
        pump?.invalidate()
        pump = nil
        vm?.graphics.onPicture = nil
        vm = nil
        unlocked = false
        floor = []
        casinoLock.lock()
        casinoRoundArmed = false
        cupOpenFlag = false
        seenPips = [0, 0, 0]
        plannedPips = []
        casinoLock.unlock()
        diceStripHandle = -1
        nonHumanTicks = 0
        if !casinoDice.isEmpty { casinoDice = [] }
        if inCasino { inCasino = false }
        if cupOpen { cupOpen = false }
        if !cardAsked.isEmpty { cardAsked = [] }
        casinoLock.lock(); askedCards.removeAll(); casinoLock.unlock()
        if cash.contains(where: { $0 != 0 }) { cash = Array(repeating: 0, count: Layout.cashSlots) }
        if !stockPrices.isEmpty {
            stockPrices = []
            stockNames = []
        }
        if !ticks.isEmpty { ticks = [] }
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

        syncCasinoState(seat: seat, memory: mem)
        refreshCash(mem)
        refreshStocks(mem)
    }

    /// 赌场状态搬到主线程：赌圣看到的点数 + 回合标记的过期。
    ///
    /// 「换人了 = 这一局结束了」：赌场发生在自己回合内，回合一旦交出去，
    /// 派彩早该落账了，彩金加倍的窗口必须关掉；点数也不该再挂在那儿。
    /// 但换人**要连续两拍（≈0.8 秒）才算数** —— 赌场切场景那一刻 `currentSeat`
    /// 可能闪一下，只闪一拍就清，会把刚武装的窗口一起抹掉。
    private func syncCasinoState(seat: Int, memory: BBMemory) {
        nonHumanTicks = seat == Self.humanSeat ? 0 : nonHumanTicks + 1
        // 赌场里不算「换人」：那里 `currentSeat` 未必停在人类身上（下注/开牌的
        // 是赌场自己的流程），按换人清掉点数，预知就永远显示不出来。
        let turnOver = !inCasino && nonHumanTicks >= 2

        casinoLock.lock()
        // 换人只解除「赌神加倍」的武装；**点数不在这里清** —— 赌场里那个座位全局
        // 未必停在人类身上，按换人清就等于把预知清掉。收点数交给两条更硬的信号：
        // 回到地图（看到棋盘地块）或场景切走，见 `consumeBoardDrawing` / `noteScene`。
        if turnOver { casinoRoundArmed = false }
        casinoLock.unlock()

        var shown: [Int] = []
        if saintGambler {
            // 优先「屏幕上真画的那三笔」；押注前游戏还没画，就用进门预定的那一组
            // （两者在 `diceOverride` 的保证下是同一组数，切换时不会跳）。
            casinoLock.lock()
            let drawn = seenPips
            let planned = plannedPips
            casinoLock.unlock()
            // 以**预定值**为准：`diceOverride` 保证游戏结算用的就是它。
            // `seenPips`（游戏自己画的那三笔）只用来兜底和报警 —— 拿它当主来源会
            // 出事：开牌动画结束后游戏偶尔还会补画上一局的三粒，读进来就是旧值，
            // 面板和画面一起显示旧值，玩家按它押宝，结算却用的是新的一局。
            if planned.count == 3 {
                shown = planned.map { $0 + 1 }
            } else if drawn.count == 3, drawn.allSatisfy({ $0 > 0 }) {
                shown = drawn
            }
        }

        if shown != casinoDice { casinoDice = shown }

        // 开盖状态搬到界面（这个只是显示用；真正拦贴图看的是 `cupOpenFlag`）
        casinoLock.lock()
        let open = cupOpenFlag
        casinoLock.unlock()
        if open != cupOpen { cupOpen = open }

        // VM 线程记下的「游戏问过哪张卡」搬到界面（问过 = 钩子替它答了「有」）
        casinoLock.lock()
        let asked = askedCards
        askedCards.removeAll()
        casinoLock.unlock()
        if !asked.isEmpty { cardAsked.formUnion(asked) }
    }

    /// `BBVM.callHook` 的实现：游戏问「手里有没有这张卡」时替它回答。
    ///
    /// **不写任何内存** —— 手牌表原样不动，所以玩家手里不会凭空多出一张卡，
    /// 存档、卖卡、用卡的逻辑也完全不受影响。这里只改一个返回值（r3）。
    ///
    /// ⚠️ 跑在 VM 线程：只读开关（单次对齐读，和 `diceOverride` 一样），
    /// 不碰 `@Published`；「问过没有」只往锁里记一笔，由泵搬到界面。
    func callOverride(target: UInt32, frameBase: UInt32) -> UInt32? {
        // 赌场入口（`CALL #133813`）：这是唯一「玩家已进门、还没押注」的时刻，
        // 真正的预知在这一刻发生 —— 把本局三粒先定下来（见 `planRound`）。
        if target == BBCheatMap.casinoEntry {
            // 进门 → 接下来就是摇盅，所以先把骰子收起来（`revealed = false`），
            // 等摇篮完由主线程的 `idle` 放出来。这样画面上是「盅在摇」，不是
            // 三粒骰子从头到尾定在那儿。
            casinoLock.lock()
            cupTracker.begin(at: BBVM.clockSeconds())
            cupOpenFlag = false
            casinoLock.unlock()
            planRound(reason: "进门")
            return nil
        }
        guard target == BBCheatMap.hasCardEntry, unlocked, let mem = vm?.memory else { return nil }
        let god = godGambler
        let saint = saintGambler
        guard god || saint else { return nil }

        let card = Int(Int32(bitPattern: mem.read32(Int(frameBase) + BBCheatMap.hasCardCardOffset)))
        let player = Int(Int32(bitPattern: mem.read32(Int(frameBase) + BBCheatMap.hasCardPlayerOffset)))
        let wanted = (card == BBCheatMap.cardGod && god) || (card == BBCheatMap.cardSaint && saint)
        guard wanted else { return nil }
        guard let slot = BBCheatMap.virtualCardSlot(card: card, player: player,
                                                    humanSeat: Self.humanSeat,
                                                    memory: mem) else { return nil }

        casinoLock.lock()
        askedCards.insert(card)
        casinoLock.unlock()
        return UInt32(slot)
    }

    // MARK: - 赌圣：这一把的点数（面板读数用）

    /// VM 线程：看到棋盘地块（LIB 63）在被重画。
    ///
    /// 只置一个锁里的布尔量 —— 场景识别是**粘性**的，万一进赌场没认出来，
    /// 「离开赌场」就没有事件可等；棋盘地块是地图独有的，用它可以兜底。
    func markBoardDrawing() {
        casinoLock.lock()
        boardSeen = true
        casinoLock.unlock()
    }

    /// 主线程（每帧）：棋盘地块（LIB 63）在重画 = 人已经回到地图 → 这一把收掉。
    ///
    /// 为什么不靠场景识别收：它是**粘性**的，万一停在「赌场」就不动了，开盖状态
    /// 会一直留着（地图上再碰到 86×46 @(14,1) 的图就会被误拦）。棋盘地块是地图
    /// 独有的、赌场里绝不会画，用它当「散场」信号最硬。
    private func endRoundOnBoardDrawing() {
        casinoLock.lock()
        let seen = boardSeen
        boardSeen = false
        let had = cupOpenFlag || !plannedPips.isEmpty || seenPips.contains(where: { $0 > 0 })
        if seen {
            cupOpenFlag = false
            casinoRoundArmed = false
            seenPips = [0, 0, 0]
            plannedPips = []
            // 状态机也要归零：留着 `revealed = true` 会在地图上继续拦
            // 86×46 @(14,1) 的图（万一同尺寸的位置撞上，就少画一笔）
            cupTracker = BBCheatMap.CupSegmentTracker()
        }
        casinoLock.unlock()
        guard seen, had else { return }
        if !casinoDice.isEmpty { casinoDice = [] }
        if cupOpen { cupOpen = false }
        PerfLog.shared.event("赌圣：看到棋盘地块 → 这一把收掉")
    }


    /// 场景变化（主线程，渲染泵每帧调，内部只做一次比较）。
    ///
    /// 离开赌场就收两样东西：这一把的点数、以及「开盖」状态（下一次进赌场重新掷骰
    /// 才会再开）。不靠「换人两拍」去猜。
    func noteScene(_ scene: BBScene) {
        // 先看更硬的那条信号：棋盘地块在重画 = 已经回到地图。
        endRoundOnBoardDrawing()
        let casino = scene == .casino
        guard casino != inCasino else { return }
        inCasino = casino
        PerfLog.shared.event("赌圣：场景=\(scene.rawValue) 赌场=\(casino)")
        guard !casino else { return }
        casinoLock.lock()
        casinoRoundArmed = false
        seenPips = [0, 0, 0]
        plannedPips = []
        cupOpenFlag = false
        cupTracker = BBCheatMap.CupSegmentTracker()
        casinoLock.unlock()
        if !casinoDice.isEmpty { casinoDice = [] }
        if cupOpen { cupOpen = false }
    }

    // MARK: - 赌圣：拦盖盅 + 记点数（VM 线程，每笔贴图调一次）

    /// `BBGraphics.onPicture` 的实现。干两件事，都跟那三粒骰子有关：
    ///
    ///  · **记**：这一笔是 27×30 的骰面 → 从源图 x 反推点数（`v*27` → v+1 点），
    ///    写进 `seenPips`。面板读数用这个，所以面板和画面出自同一个数，不会出现
    ///    「面板说 5 点、屏幕上画 2 点」。（栈帧那三格试过：实测 2/2/1 vs 屏幕 2/5/5，
    ///    后两格被后续代码复用，读不得）
    ///  · **拦**：这一笔是 86×46 @ (14,1) 的骰盅，且这一把已经掷过骰 → 不画。
    ///
    /// ⚠️ 地图一帧几百笔，第一道必须是纯整数比较；过了尺寸才碰 `isCupDraw` 才拿锁。
    func seePicture(index: Int, dx: Int, dy: Int, w: Int, h: Int, srcX: Int) -> Bool {
        if w == BBCheatMap.diceFaceWidth, h == BBCheatMap.diceFaceHeight {
            guard let slot = BBCheatMap.diceFaceIndex(index: index, dx: dx, dy: dy, w: w, h: h),
                  let pip = BBCheatMap.dicePip(sourceX: srcX) else { return true }
            casinoLock.lock()
            // 只在「这一把掷过骰」之后记：地图上偶尔闪过同尺寸的图不会污染读数。
            // 不能用 `cupOpenFlag`（它现在是「骰子露没露」，摇盅期间是 false，
            // 而游戏掷完那三笔正好在露出前后 —— 会漏记，诊断告警就永远不响）
            if thrownThisRound, slot >= 0, slot < 3 { seenPips[slot] = pip }
            // 诊断：游戏自己画出来的三粒如果跟预定值不同，说明 `diceOverride` 没
            // 盖住这一局 —— 那就必然「押注前一个答案、开牌另一个答案」。
            let drawn = seenPips
            let planned = plannedPips
            let warn = !mismatchLogged && planned.count == 3 && drawn.count == 3
                && drawn.allSatisfy({ $0 > 0 }) && drawn != planned.map({ $0 + 1 })
            if warn { mismatchLogged = true }
            casinoLock.unlock()
            if warn {
                PerfLog.shared.event("⚠️ 赌圣：游戏画的 "
                                     + drawn.map(String.init).joined(separator: "+")
                                     + " ≠ 预定 "
                                     + planned.map { "\($0 + 1)" }.joined(separator: "+")
                                     + "（这一局押对也会输，说明掷骰钩子没盖住）")
            }
            return true
        }
        guard w == BBCheatMap.cupWidth, h == BBCheatMap.cupHeight else { return true }
        guard saintGambler,
              BBCheatMap.isCupDraw(index: index, dx: dx, dy: dy, w: w, h: h) else { return true }
        // 盅被我们拦掉不画，但**这一笔回调还是照收** —— 正好拿来切「局」。
        // 每局摇盅都是一串连续的盅贴图，局与局之间断好几秒：新一段 = 新的一局。
        let now = BBVM.clockSeconds()
        casinoLock.lock()
        let needPlan = cupTracker.cup(at: now, thrown: thrownThisRound,
                                      lastThrow: lastThrowStamp,
                                      hasPlan: !plannedPips.isEmpty)
        // 摇盅期间盅要**照常画出来**（真摇盅的样子），只有摇完/开了牌才拦掉换成骰子
        let openNow = cupTracker.revealed
        cupOpenFlag = openNow
        casinoLock.unlock()
        if needPlan { planRound(reason: "摇盅") }
        return !openNow
    }

    /// 这一把掷过骰了 → 从现在起到离开赌场，盖盅那一笔一律不画。
    ///
    /// 正常路径上「露」由 `CupSegmentTracker` 驱动（摇完 / 掷骰那一刻），
    /// 这里只是兜底：万一没拦到入口（换了版本 / 调用点变了），至少掷骰这一刻要开出来。
    private func openCup() {
        casinoLock.lock()
        cupTracker.threw(at: BBVM.clockSeconds())
        cupOpenFlag = true
        casinoLock.unlock()
    }

    /// 门里每一局开始时：「把本局三粒定下来」。
    ///
    /// 赌场是「进门 → 摇盅 → 玩家押注 → 才掷骰」（见 `diceorder` 的时间线：进门
    /// 11.4s、掷骰 20.7s），所以押注那一刻本局点数根本还不存在。想让玩家在**下注
    /// 界面**上就看到结果，只能先从游戏自己的随机序列里抽三个（`pullRand`），
    /// 之后 `diceOverride` 在游戏真掷的时候把这三个原样还给它。
    ///
    /// 于是三处永远是同一组数：押注前画面（我们贴的）、押注后画面（我们贴的）、
    /// 结算用的（游戏按我们给的值算的）。点数仍然出自游戏自己的 RNG。
    ///
    /// 调用点有两个，缺一不可：
    ///  · `callOverride` 的赌场入口 —— 进门就定好（但**先不显示**：接着是摇盅，
    ///    露不露由 `CupSegmentTracker` 决定，摇完才贴）；
    ///  · `seePicture` 的新一段摇盅 —— 玩家进门后连着押的**第二局起**靠这个。
    ///    只在入口抽的话，后面每局都拿同一组，看起来就是「骰子被锁死」。
    ///
    private func planRound(reason: String) {
        guard saintGambler, unlocked, let vm else { return }
        // ★ 先「搅一下」随机流，否则每局都是同一组数（真机反馈：骰子像被锁死）。
        //
        // 为什么固定：整局游戏只在启动时 `OUT port #32, #0`（SRAND(0)，pc 4231）播一次种，
        // 之后是一条完全确定的 LCG（`BBCRandom`）。而赌圣每局固定抽 3 个、又固定把
        // 游戏那三次掷骰整个拦掉（`diceOverride` 命中时 `rng.rand()` 不再被调用），
        // 于是「每局随机流前进的步数」恒定 → 下一局在同一位置抽，抽到的当然还是那三个数。
        // 这里按墙钟毫秒 + 系统熵先跳掉不定步数，位置一变，三粒就变。
        let burn = Int((BBVM.clockSeconds() * 1000).truncatingRemainder(dividingBy: 97))
            + Int.random(in: 0..<89)
        for _ in 0..<burn { _ = vm.pullRand(6) }
        var pips: [Int] = []
        pips.reserveCapacity(3)
        for _ in 0..<3 { pips.append(Int(vm.pullRand(6))) }
        casinoLock.lock()
        plannedPips = pips
        seenPips = [0, 0, 0]
        thrownThisRound = false
        mismatchLogged = false
        roundSerial += 1
        let serial = roundSerial
        casinoLock.unlock()
        PerfLog.shared.event("赌圣：\(reason)预定第 \(serial) 局 "
                             + pips.map { "\($0 + 1)" }.joined(separator: "+")
                             + "（跳过 \(burn) 个随机数）")
    }


    /// 主线程（每帧）：把「本局三粒」贴到画面原位。
    ///
    /// 为什么非贴不可：赌场押注前**根本没画骰面**（要押完才掷），下注界面左上角那个
    /// 骰盅位里只有「CASINO」的立体骰子装饰 —— 它们跟本局结果毫无关系，玩家看到的
    /// 就是「面板 4+5+6、画面还是装饰骰子」。
    ///
    /// 更麻烦的是：游戏自己掷完之后那三笔 `RICH.LIB #66` 其实画在**页面 1**（离屏），
    /// 实测整局下来屏幕那块区域一个像素都没变（`a-押注前` 与 `c-押注后` 差异 = 0）。
    /// 所以不能像最初那样「等游戏自己画出来再停手」—— 一停手骰子就从画面上消失了。
    /// 现在整局都由我们贴：用游戏自己的贴图（`RICH.LIB #66`）和自己的落点
    /// （`diceFaceSlots`），于是画面像素和面板数字永远同一组。
    ///
    /// ⚠️ 判据只认 `plannedPips`，**不认场景识别**：那个是粘性的、还有 0.35 秒节流，
    /// 下注界面一旦没被认成赌场，预知就整段不画（「押宝前看不到、押宝后才对上」）。
    /// `plannedPips` 只在一局之内非空（回地图 / 场景切走就清），不会漏到别的界面。
    func paintCasinoPreview(into pixels: inout [UInt32], width: Int, height: Int, scale: Int) {
        guard saintGambler else { return }
        // 先推进「摇完了没有」：盅还在摇就什么都不贴（让游戏自己把盅画出来），
        // 摇完（或兜底超时）才露三粒。见 `BBCheatMap.CupSegmentTracker`。
        guard tickCupClock() else { return }
        if diceStripHandle < 0 { retryDiceStrip() }
        guard diceStripHandle >= 0, let sprite = vm?.graphics.picture(diceStripHandle) else { return }
        casinoLock.lock()
        let planned = plannedPips
        casinoLock.unlock()
        // 以**预定值**为准，和面板同一来源（见 `syncCasinoState` 的说明）：
        // 画面、面板、结算用的永远同一组数。
        guard planned.count == 3 else { return }
        let pips = planned.map { $0 + 1 }
        let n = BBCheatMap.paintDiceFaces(into: &pixels, width: width, height: height,
                                          sprite: sprite, pips: pips, scale: scale)
        // 每局只记一次，方便真机上「没看到骰子」时分辨是没画还是画错地方
        if n > 0, previewLogged != planned {
            previewLogged = planned
            PerfLog.shared.event("赌圣：押注前贴三粒 \(pips.map(String.init).joined(separator: "+")) "
                                 + "scale=\(scale) 底图=\(sprite.width / 8)x\(sprite.height)")
        }
    }

    /// 主线程（每帧）：推进盅状态机的「静默」部分 —— 摇盅结束、兜底超时都在这儿判定。
    ///
    /// 为什么放主线程：盅贴图只在摇的时候有，摇完就没有事件了，靠 VM 线程永远等不到
    /// 「摇完了」那一刻；帧循环是唯一稳定的节拍。返回「骰子现在该不该露」。
    ///
    /// 摇盅期间不贴、也不拦盅：画面上就是游戏自己的盅在摇（实测 8 秒），
    /// 摇完变回骰盅静止的那一帧起才露出三粒。
    private func tickCupClock() -> Bool {
        let now = BBVM.clockSeconds()
        casinoLock.lock()
        cupTracker.idle(at: now, lastThrow: lastThrowStamp)
        let reveal = cupTracker.revealed
        let changed = reveal != cupOpenFlag
        let planned = plannedPips
        cupOpenFlag = reveal
        casinoLock.unlock()
        if changed {
            // @Published 只能在主线程写；这里本来就在渲染泵（主线程）
            cupOpen = reveal
            if reveal, planned.count == 3 {
                PerfLog.shared.event("赌圣：摇完了 → 露出 "
                                     + planned.map { "\($0 + 1)" }.joined(separator: "+"))
            }
        }
        return reveal
    }

    /// 骰子条加载兜底：`attach` 那一刻资源目录未必就绪（换版本 / 目录还没挂上），
    /// 加载失败就一直 -1，于是整局都不贴。这里按帧节流重试，直到拿到为止。
    private func retryDiceStrip() {
        stripRetry += 1
        guard stripRetry % 30 == 0 else { return }
        guard let vm else { return }
        diceStripHandle = vm.graphics.loadPicture(name: Array("RICH.LIB".utf8),
                                                  index: BBCheatMap.diceStripIndex)
        if diceStripHandle >= 0 {
            PerfLog.shared.event("赌圣：骰子条 #66 补加载成功 handle=\(diceStripHandle)")
        } else if stripRetry == 30 {
            PerfLog.shared.event("赌圣：骰子条 #66 加载失败（押注前贴三粒会失效）")
        }
    }

    private func refreshCash(_ mem: BBMemory) {
        var next = [Int](repeating: 0, count: Layout.cashSlots)
        var toppedUp = false
        let target = min(max(cashTarget, 1), Layout.cashSlots) - 1
        for i in 0..<Layout.cashSlots {
            var value = BBCheatMap.cash(mem, slot: i)

            // 赌神：赌场回合内自己名下的进账再补一份（彩金加倍）。
            // 判定用「上次 0.4 秒快照 → 现值」的增量 —— 派彩是游戏一次性写进
            // 现金数组的（赌场 pc 153542：现金 += [rb-28]），泵一拍就能看到完整 Δ。
            // 补完立刻解除武装：一次进赌场只加倍一次。
            if godGambler, i == Self.humanSeat, i < cash.count,
               let bonus = BBCheatMap.godGamblerBonus(previous: cash[i], current: value,
                                                      armed: armedNow,
                                                      seat: currentSeat,
                                                      humanSeat: Self.humanSeat) {
                value = BBCheatMap.clampCash(value + bonus)
                BBCheatMap.setCash(mem, slot: i, value)
                casinoLock.lock(); casinoRoundArmed = false; casinoLock.unlock()
                toppedUp = true
                PerfLog.shared.event("金手指：赌神卡彩金加倍 +\(bonus)")
            }

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
        if stockTrend != 0 {
            // 趋势：只翻方向，幅度用游戏自己的。区间在这里同时当护栏用。
            prices = BBCheatMap.applyTrend(mem, previous: &previousPrices,
                                           trend: stockTrend,
                                           lower: stockRange ? stockLower : 1,
                                           upper: stockRange ? stockUpper : Layout.priceCap)
        } else if stockRange {
            prices = BBCheatMap.enforcePriceRange(mem, lower: stockLower, upper: stockUpper)
        } else if stockNeverFalls {
            prices = BBCheatMap.enforcePriceFloor(mem, floor: &floor)
        } else {
            for i in 0..<Layout.stockCount { prices[i] = BBCheatMap.stockPrice(mem, i) }
            previousPrices = prices
        }

        var names = stockNames
        if names.count != Layout.stockCount {
            names = (0..<Layout.stockCount).map { BBCheatMap.stockName(mem, $0) }
        }

        if prices != stockPrices { stockPrices = prices }
        if names != stockNames { stockNames = names }

        // 调价记录：变了才追加（0.4 秒轮询，不筛的话全是重复）
        var nextTicks = ticks
        if BBCheatMap.appendTick(&nextTicks, prices) { ticks = nextTicks }
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
    ///
    /// 两条路径：
    ///  · 赌场三粒（`casinoDiceSites`）—— 赌圣会把**进门时预定的值**原样还给它，
    ///    所以押注前看到的、押注后画出来的、结算用的是同一组（见 `planRound`）。
    ///    赌神用「掷过骰 = 这一回合进过赌场」来武装彩金加倍。这三粒**不受**
    ///    「骰子控制」影响。
    ///  · 走路骰子 —— 原有逻辑，两粒分别控制。
    func diceOverride(n: UInt32, frameBase: UInt32) -> UInt32? {
        guard unlocked, let mem = vm?.memory else { return nil }

        // 赌场三粒
        if let index = BBCheatMap.casinoSiteIndex(n: n, frameBase: frameBase, memory: mem) {
            let seat = BBCheatMap.currentSeat(mem)
            let mine = seat == Self.humanSeat
            if mine, godGambler { armCasinoRound() }
            // 赌圣**不要求「座位是我」**：赌场里那个全局未必停在人类身上
            // （下注/开牌走的是赌场自己的流程），按座位卡会把真机上的预知全卡掉。
            // 谁在赌场掷骰就按谁的来，反正画面当下就是那一局。
            if saintGambler {
                casinoLock.lock()
                let planned = plannedPips
                // 记下「这一局已经开始掷了」：紧跟着的盖盅/掀开几帧不许被当成新一局，
                // 而下一段摇盅（新一局）要据此重新定值。
                lastThrowStamp = BBVM.clockSeconds()
                thrownThisRound = true
                // 掷骰了 → 骰子一直露着（盖盅/掀开都拦掉，让玩家直接看结果）
                cupTracker.threw(at: lastThrowStamp)
                cupOpenFlag = true
                casinoLock.unlock()
                if planned.count == 3, index >= 0, index < 3 {
                    // 换成进门预定的那一粒 —— 玩家押注前看到的就是这个数
                    PerfLog.shared.event("赌圣：第 \(index + 1) 粒按预定 \(planned[index] + 1) 点")
                    return UInt32(planned[index])
                }
                // 兜底：没拦到入口（版本不同 / 调用点变了）就退回「掷完再开盖」
                if index == 0 { openCup() }
            }
            PerfLog.shared.event("赌圣：赌场第 \(index + 1) 粒 seat=\(seat) 我=\(mine)")
            return nil
        }

        // 走路骰子
        let wantA = diceA
        let wantB = diceB
        guard wantA > 0 || wantB > 0 else { return nil }
        // 只对玩家：轮到电脑就原样放行（nil）。钩子跑在 VM 线程，只读 `diceOnlyMe`。
        let seat = diceOnlyMe ? Self.humanSeat : nil
        return BBCheatMap.forcedDice(n: n, frameBase: frameBase, memory: mem,
                                    wantA: wantA, wantB: wantB, onlySeat: seat)
    }

    // MARK: - 赌场钩子的线程安全部分（VM 线程调用）

    private func armCasinoRound() {
        casinoLock.lock()
        casinoRoundArmed = true
        casinoLock.unlock()
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

    /// 某一只按百分比微调（±0.1 = ±10%），落在护栏内。
    ///
    /// ⚠️ 「只涨不跌」开着的时候，托底线要跟着一起改 ——
    /// 不然手动压下去的价格会在 0.4 秒内被托底写回来，看起来就是「按钮没反应」。
    func nudgeStock(_ index: Int, _ ratio: Double) {
        guard let mem = vm?.memory, unlocked,
              index >= 0, index < Layout.stockCount else { return }
        let current = BBCheatMap.stockPrice(mem, index)
        var target = Int((Double(current) * (1 + ratio)).rounded())
        target = min(Layout.priceCap, max(1, target))
        if stockRange { target = min(stockUpper, max(stockLower, target)) }
        if target == current { target = current + (ratio > 0 ? 1 : -1) }
        BBCheatMap.setStockPrice(mem, index, target)
        applyToCache(index, target)
        // 这一笔是我们自己动的手，单独标一笔 —— 面板上能和「游戏调的」分开看
        recordManualTick(mem)
    }

    /// 手动改价后立刻记一笔（不等下一次轮询）
    private func recordManualTick(_ mem: BBMemory) {
        var snapshot = [Int](repeating: 0, count: Layout.stockCount)
        for i in 0..<Layout.stockCount { snapshot[i] = BBCheatMap.stockPrice(mem, i) }
        var next = ticks
        BBCheatMap.appendTick(&next, snapshot, manual: true)
        ticks = next
    }

    /// 改完写回缓存 + 同步托底线，界面立刻跟着变
    private func applyToCache(_ index: Int, _ value: Int) {
        guard stockPrices.count == Layout.stockCount else { return }
        var next = stockPrices
        next[index] = value
        stockPrices = next
        if stockNeverFalls, floor.count == Layout.stockCount { floor[index] = value }
    }
}

