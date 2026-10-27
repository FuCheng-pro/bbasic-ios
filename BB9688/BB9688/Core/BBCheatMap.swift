//
//  BBCheatMap.swift
//  BB9688
//
//  「大富翁」金手指的**纯逻辑**：地址表 + 内存读写 + 自检。
//
//  为什么和 `App/BBCheat.swift` 拆开：
//  这一层不依赖 SwiftUI/UIKit，可以在 Windows 上用无头探针（`Tools/headless/cheattest`）
//  直接编译验证 —— 金手指最怕的就是「地址写错了一个字节，游戏崩了才知道」。
//  上面那层只管「什么时候调、调完通知界面」。
//
//  ── 地址是怎么定下来的（复现步骤，别删）───────────────────────────
//  1. 无头跑游戏到棋盘，把 0..0x90000 的内存整块 dump（`Tools/headless/cheatprobe`）。
//  2. 现金：状态栏显示 25000，在全内存里搜 25000，落在 0x78374/0x78378/…（4 连值），
//     再逐个写 111111/222222/333333/444444，状态栏跟着变 → 就是它。
//  3. 股价：在 bin 里搜 GBK「大众汽车」找到 0x7A31C（文件偏移），
//     减去 16 字节 "BBE" 头 = 0x7A30C；结构 9 字节名字 + int32 价格，步长 13，共 20 条。
//     代码侧对得上：初始化循环 `PUSH #500492`（= 0x7A30C）循环 `#20` 次。
//  4. 骰子：反汇编里 `RND(6)` 只有两处调用点，实测返回地址 0xEC0E / 0xEC4A。
//
//  ⚠️ 全部是 **VM 内存地址**。bin 文件偏移 = 地址 + 16（装载时剥掉了 16 字节头）。
//

import Foundation

public enum BBCheatMap {

    // MARK: - 布局

    public enum Layout {
        /// 当前玩家座位（0..3），每回合切换。实测序列 0→1→2→3→0，各 20 次掷骰。
        /// 「骰子只对人类生效」就靠它判断现在轮到谁。
        public static let currentPlayer = 0x7467C

        /// 状态栏绘制函数的入口（VM pc）。
        ///
        /// 怎么定的：给 VM 挂「谁在读现金数组」的旁路（`memReadHook`），
        /// 只有 5 处代码读 `0x78374`，其中 `0x32535` / `0x32676` 每次成对出现
        /// （现金 + 贷款各一次），反查它所在的函数 → 序言在 asm 列 0x320CA，
        /// 也就是 pc `0x320BA`。函数本身不收参数，一进来就画 240×80 的底栏。
        ///
        /// 用途：改完钱注入调用它一次，状态栏立刻显示新数字，不用等下一回合。
        public static let hudRefresh: UInt32 = 0x320BA

        /// 现金数组首地址。每名玩家一个 int32，下标 0..3（数组长 8，索引被 clamp 到 7）
        public static let cashBase = 0x78374
        public static let cashStride = 4
        public static let cashSlots = 4

        /// 证券交易所表首地址
        public static let stockBase = 0x7A30C
        public static let stockStride = 13
        public static let stockPriceOffset = 9
        public static let stockCount = 20

        /// 价格上限：股票页的价格栏按 3 位数排版，超过 999 会把涨幅挤出去
        public static let priceCap = 999
        /// 现金上限：状态栏能正常显示 6 位数（实测 777777 不串行）
        public static let cashCap = 999_999
    }

    /// 掷骰子的两处 `RND(6)`，用**返回地址**认（详见文件头）。
    ///
    /// 顺序 = 骰子 1、骰子 2。这个顺序不是猜的：两处 `CALL` 在代码里前后相邻
    /// （`0xEC09` 先、`0xEC45` 后），先掷的那一粒就是画面上左边那一粒 ——
    /// 已用「骰子1=1、骰子2=6」的截图核对过左右。
    public static let diceSites: [UInt32] = [0x0EC0E, 0x0EC4A]

    /// 帧里返回地址的偏移。实测：`[rb+4]` 是栈上的指针，`[rb+8]` 才是 CALL 的下一条，
    /// `[rb+12]` 是入参 n（用 13 个不同调用点交叉验证过，全部吻合）。
    public static let returnAddressOffset = 8

    // MARK: - 自检

    /// 「大众汽车」的 GBK 字节。这张表是程序启动后从 DATA 段灌进内存的，
    /// 所以刚 load 完读不到 —— 自检必须能反复做，而不是开局判一次死刑。
    public static let nameProbe: [UInt8] = [0xB4, 0xF3, 0xD6, 0xDA, 0xC6, 0xFB, 0xB3, 0xB5]

    /// 内存里那张表是不是大富翁的股价表
    public static func looksLikeRich(_ memory: BBMemory) -> Bool {
        for (i, b) in nameProbe.enumerated() where memory.read8(Layout.stockBase + i) != b {
            return false
        }
        return true
    }

    // MARK: - 现金

    public static func cash(_ memory: BBMemory, slot: Int) -> Int {
        guard slot >= 0, slot < Layout.cashSlots else { return 0 }
        return Int(Int32(bitPattern: memory.read32(Layout.cashBase + slot * Layout.cashStride)))
    }

    public static func setCash(_ memory: BBMemory, slot: Int, _ value: Int) {
        guard slot >= 0, slot < Layout.cashSlots else { return }
        writeInt(memory, Layout.cashBase + slot * Layout.cashStride, clampCash(value))
    }

    public static func clampCash(_ value: Int) -> Int {
        min(Layout.cashCap, max(0, value))
    }

    // MARK: - 股价

    public static func stockPriceAddress(_ index: Int) -> Int {
        Layout.stockBase + index * Layout.stockStride + Layout.stockPriceOffset
    }

    public static func stockPrice(_ memory: BBMemory, _ index: Int) -> Int {
        guard index >= 0, index < Layout.stockCount else { return 0 }
        return Int(Int32(bitPattern: memory.read32(stockPriceAddress(index))))
    }

    public static func setStockPrice(_ memory: BBMemory, _ index: Int, _ value: Int) {
        guard index >= 0, index < Layout.stockCount else { return }
        writeInt(memory, stockPriceAddress(index), min(Layout.priceCap, max(1, value)))
    }

    /// 公司名（GBK，最多 8 字节 + 结尾 0）
    public static func stockName(_ memory: BBMemory, _ index: Int) -> String {
        guard index >= 0, index < Layout.stockCount else { return "" }
        let base = Layout.stockBase + index * Layout.stockStride
        var bytes: [UInt8] = []
        for i in 0..<9 {
            let b = memory.read8(base + i)
            if b == 0 { break }
            bytes.append(b)
        }
        return GBKCodec.decode(bytes)
    }

    /// 「只涨不跌」：把被压低的价格写回托底线，并把抬高的价格记成新的托底。
    ///
    /// `floor` 是调用方持有的基线（初值应为打开开关那一刻的现价）。
    /// 长度不对时**先用当前价铺满**再比较 —— 否则会拿一串 0 当底线，等于把股价清零。
    /// 返回处理后的 20 个价格，调用方拿去刷界面。
    @discardableResult
    public static func enforcePriceFloor(_ memory: BBMemory, floor: inout [Int]) -> [Int] {
        var prices = [Int](repeating: 0, count: Layout.stockCount)
        for i in 0..<Layout.stockCount {
            prices[i] = stockPrice(memory, i)
        }
        if floor.count != Layout.stockCount { floor = prices }

        for i in 0..<Layout.stockCount {
            if prices[i] < floor[i], floor[i] > 0 {
                prices[i] = floor[i]
                setStockPrice(memory, i, prices[i])
            } else {
                floor[i] = prices[i]
            }
        }
        return prices
    }

    // MARK: - 骰子

    /// 该不该、以及改成几点（两粒分别指定）。
    ///
    /// `wantA` / `wantB` = 1...6（0 = 这一粒不控制，放行原始随机值）。
    /// `onlySeat` 非 nil 时只有「轮到这个座位」才改写 —— 这是「只对玩家生效」的实现：
    /// 人类的掷骰和电脑走的是同一段代码，不筛座位的话四个玩家全都掷 6，
    /// 一局就变成了「大家都横着走」。
    ///
    /// 座位号来自 `Layout.currentPlayer`（实测 0→1→2→3 轮换）。
    /// 返回 nil 表示不干预。
    ///
    /// 只认 `n == 6` 且返回地址在 `diceSites` 里的调用 —— 别的 `RND(6)`
    /// （赌场、抽卡里的）保持原样，免得「开了骰子惊喜，结果抽卡也全变成同一张」。
    public static func forcedDice(n: UInt32,
                                 frameBase: UInt32,
                                 memory: BBMemory,
                                 wantA: Int,
                                 wantB: Int,
                                 onlySeat: Int? = nil) -> UInt32? {
        guard n == 6 else { return nil }
        if let seat = onlySeat, currentSeat(memory) != seat { return nil }

        let ret = memory.read32(Int(frameBase) + returnAddressOffset)
        guard let index = diceSites.firstIndex(of: ret) else { return nil }

        let want = index == 0 ? wantA : wantB
        guard want >= 1, want <= 6 else { return nil }
        return UInt32(want - 1)          // RND(6) 返回 0..5，显示的点数 = 返回值 + 1
    }

    /// 当前轮到谁（0..3）。读到越界值就按 0 处理，避免数组下标炸掉。
    public static func currentSeat(_ memory: BBMemory) -> Int {
        let raw = Int(Int32(bitPattern: memory.read32(Layout.currentPlayer)))
        return (0..<Layout.cashSlots).contains(raw) ? raw : 0
    }

    // MARK: - 私有

    private static func writeInt(_ memory: BBMemory, _ address: Int, _ value: Int) {
        memory.write(address, UInt32(bitPattern: Int32(clamping: value)), sizeBytes: 4)
    }
}
