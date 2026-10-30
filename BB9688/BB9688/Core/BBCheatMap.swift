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

        /// 证券交易所的**模板表**（只读）：一条记录 = 9 字节 GBK 公司名 + 4 字节初始价。
        /// 名字从这里取；**价格不在这里** —— 2026-10-27 才搞清：这张表只在开局被读一次
        /// 用来初始化运行时数组，之后游戏再不碰它（改它没有任何效果）。
        public static let stockBase = 0x7A30C
        public static let stockStride = 13
        public static let stockPriceOffset = 9

        /// **运行时价格数组**：20 个 int32，间距 4 字节。游戏每次调价写这里，
        /// 股票页显示的也是这里。定位方式：监听全内存写，找「写进去的值落在
        /// 10...400 的连续 20 个地址」——只有这一段符合。
        ///
        /// ## 下标和「第几家公司」是对得上的（2026-10-27 复核）
        ///
        /// 三条独立证据，别再怀疑这个顺序：
        /// 1. **初始化就是按记录顺序搬的**：启动时同一段循环逐条读模板记录
        ///    （READ 字符串拿公司名 → READ 整数拿初价，读地址正是
        ///    `0x7A30C + 13i + 9`，i = 0…19），再用**同一个计数器**写进
        ///    `0x7884C + 4i`。也就是说 slot i 天生就是「第 i 条记录」。
        /// 2. **数值能对上号**：开局快照里 `price[i] / 模板初价[i]` 全部落在
        ///    0.91…1.10（正是那一轮随机系数的范围）；若下标错位，比值会乱到
        ///    几十倍（比如拿 150 去比 22）。
        /// 3. **内存里只有一份价格数组**（全内存搜「20 个值都落在当前价格集合内」
        ///    的连续 dword 段，只有 0x7884C 一处），所以不存在「排序后的副本」；
        ///    两条会遍历它的代码路径也都是 0→19 递增，没有按价格重排。
        ///
        /// 因此面板里 `stockName(i)` 和 `stockPrice(i)` 用的是同一家公司，可以放心配。
        public static let stockPriceBase = 0x7884C
        /// **浮动系数**：20 个 float，就是涨跌幅百分比（实测 -8.1 ~ +10.9）。
        public static let stockCoefBase = 0x788A0
        public static let stockCount = 20

        /// 价格上限：股票页的价格栏按 3 位数排版，超过 999 会把涨幅挤出去
        public static let priceCap = 999
        /// 现金上限：状态栏能正常显示 6 位数（实测 777777 不串行）
        public static let cashCap = 999_999

        /// 调价节奏：游戏内一个月大约这么多秒（实测 26.1 / 26.2 / 27.5 / 28.0 / 29.4），
        /// 只用于界面文案，别拿它当定时器。
        public static let secondsPerMonth = 28.0
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

    // MARK: - 手牌（赌神卡 / 赌圣卡「常驻」）

    //  ⚠️ 2026-10-27 定稿，别再绕回去：
    //  第一版：自己监视赌场、自己在面板上显示点数 / 自己补彩金 → 用户否掉（不要自建 UI）。
    //  第二版：把卡**塞进手牌表**让游戏自己认 → 用户否掉（不要动内存里的卡）。
    //  现在：**内存一个字都不写**，只在游戏调用 `hasCard` 时替它回答「有这张卡」。
    //  见 `hasCardEntry` / `virtualCardSlot` / `BBCheat.callOverride`。
    //
    //  代价要说清楚：这个移植版的赌场从不问 8/9 号卡（全程序 10 处 `hasCard` 只查
    //  1/10/16/20/21/22/23/29），所以「回答有」目前不会触发任何游戏行为 ——
    //  效果仍由金手指自己兜（赌神加倍 / 赌圣读点数），只是不再往手牌里塞东西。

    /// 卡片编号（DATA 表 `0x79F34` 的顺序，**0 基**）。
    ///
    /// 34 条记录、按拼音排序，一条 = 名字\0 描述\0 价格 u16 + 2 字节填充：
    /// `0 保险 1 查封 2 拆屋 3 除障 4 催眠 5 地雷 6 冬眠 7 冻结 8 赌神 9 赌圣 10 复仇 …`
    public static let cardGod = 8        // 赌神卡：赌技必胜的秘笈（赢钱彩金加倍）
    public static let cardSaint = 9      // 赌圣卡：赌场中有预知能力

    /// 手牌表（**只读**，我们不写）：8 名玩家 × 8 个槽位，每个 int32，
    /// **值 = 卡号 + 1**（0 = 空槽），下标 = `玩家 * 8 + 槽位`。
    ///
    /// 三条独立证据（`Tools/.rich_disasm.txt`）：
    /// 1. `hasCard`（pc 356124）把槽位值读出来先 `-1`，再跟传进来的卡号比 ——
    ///    也就是「存的是卡号 + 1」（`PUSH #1` → `CAL r0 <- r0 - r1` → `CMP ? r1`）。
    /// 2. 卖卡/用卡那条路（pc 181012）同样先 `-1`，再拿它当索引查价格表 `0x746FC`。
    /// 3. 买卡成功那段（pc 177774）就是往这张表写值，寻址方式完全一样
    ///    （`玩家*8 + 槽`，游戏自己 clamp 到 63）。
    ///
    /// ⚠️ 2026-10-27 复核：三处用的常量都是 **493120 = 0x78640**（`LD i r0 <- #493120`，
    /// 见 pc 177744 / 181012 / 356549）。之前这里写成 `0x786C0`（= 493248，全文不存在
    /// 这个常量），偏移了 0x80 —— 正好错开 4 名玩家，`virtualCardSlot` 会在别人手里
    /// 找空槽。以反汇编常量为准。
    public static let handBase = 0x78640
    public static let handPlayers = 8
    public static let handSlots = 8

    /// `hasCard(player, card)` 的入口 pc，以及对外的第 1/2 个参数在帧里的偏移。
    ///
    /// 从函数序言反推：`PUSH rb; LD rb <- rs; rs -= 12` → 帧基址 = 调用前 rs - 8，
    /// 于是 `[rb+12]` = 最后压进去的那个参数（卡号）、`[rb+16]` = 玩家号。
    /// 和函数体里的用法对得上：`[rb+16] * 8 + 槽` 当索引，`[rb+12]` 拿去比卡号。
    public static let hasCardEntry: UInt32 = 356124
    public static let hasCardCardOffset = 12
    public static let hasCardPlayerOffset = 16

    /// 槽位里的原始值（0 = 空）
    public static func handValue(_ memory: BBMemory, player: Int, slot: Int) -> Int {
        guard let address = handAddress(player: player, slot: slot) else { return 0 }
        return Int(Int32(bitPattern: memory.read32(address)))
    }

    /// 槽位值 → 卡号（空槽返回 nil）
    public static func handCard(_ memory: BBMemory, player: Int, slot: Int) -> Int? {
        let value = handValue(memory, player: player, slot: slot)
        return value > 0 ? value - 1 : nil
    }

    /// 这名玩家手里有没有这张卡，有就返回**第一个**槽位
    public static func handSlot(of card: Int, player: Int, memory: BBMemory) -> Int? {
        for slot in 0..<handSlots where handCard(memory, player: player, slot: slot) == card {
            return slot
        }
        return nil
    }

    /// 游戏问「你有这张卡吗」时，我们替它回答的槽位。nil = 不插手，让游戏自己查。
    ///
    /// 四条规矩：
    /// 1. 只答人类玩家、只答开关管着的那两张卡。
    /// 2. 手里**真有**这张卡就返回 nil —— 真卡比虚拟卡优先，别让我们的答案
    ///    把游戏原本的卡（和它会引发的消耗）挡掉。
    /// 3. 答的是**一个空槽**。万一调用方拿这个槽号去「用卡 / 卖卡」，
    ///    动到的是一格空的，不会误伤玩家真正的卡；没空槽就不插手（返回 nil）。
    /// 4. **永远不答 0 号槽**。调用方判「有没有」的写法是
    ///    `CMP 返回值 ? 0` + `JPC A`（小于等于 → 没卡），也就是「> 0 才叫有卡」
    ///    （见 pc 63461 与 63588 两处）。答 0 会被当成「没有」，白答。
    ///    没找到也没卡时函数自己返回 -1，同样走「没有」。
    public static func virtualCardSlot(card: Int, player: Int, humanSeat: Int,
                                       memory: BBMemory) -> Int? {
        guard player == humanSeat, (0..<handPlayers).contains(player) else { return nil }
        guard card == cardGod || card == cardSaint else { return nil }
        if handSlot(of: card, player: player, memory: memory) != nil { return nil }
        // 从 1 号槽起找：0 号槽在调用方眼里等于「没有」（见规矩 4）
        for slot in 1..<handSlots where handValue(memory, player: player, slot: slot) == 0 {
            return slot
        }
        return nil
    }

    private static func handAddress(player: Int, slot: Int) -> Int? {
        guard (0..<handPlayers).contains(player), (0..<handSlots).contains(slot) else { return nil }
        let index = min(handPlayers * handSlots - 1, player * handSlots + slot)
        return handBase + index * 4
    }

    // MARK: - 赌场（两张卡的效果）

    //  ⚠️ 2026-10-27 复核结论，别再白费功夫去找「游戏内部的卡效果」：
    //  这个移植版的赌场**根本没有读卡 8/9 的代码** —— 全程序 10 处 `hasCard`
    //  （pc 356124）传的卡号只有 1/10/16/20/21/22/23/29；赌场大函数
    //  （pc 133813–154400）里对 0x78640 的唯一引用是 pc 148264 调 `0x3E166`
    //  **画手牌那一排**。所以「卡在手里」只能让画面显示这张卡，
    //  效果必须由金手指自己兜（见 `godGamblerBonus` 与 `BBCheat.saintGambler`）。

    /// 赌场三粒骰子的 `RND(6)` 调用点（返回地址 = CALL + 5）。
    ///
    /// 反汇编 pc 138695 / 138755 / 138815 处的 `PUSH #6; CALL #4267`。
    /// 赌场流程是「进门先掷三粒（存 [rb-4]/[rb-8]/[rb-12]）→ 亮一下骰面
    /// （pc 139130/139430/139730 按 27 像素取帧）→ 盖骰盅（pc 140126，86×46）
    /// → 下注 → 开牌」，所以点数在下注前就定了 —— 这是赌圣能「预知」的前提。
    public static let casinoDiceSites: [UInt32] = [0x021DCC, 0x021E08, 0x021E44]

    /// 这条 RND 是不是赌场的骰子。0...2 = 第几粒（掷的顺序），nil = 不是。
    ///
    /// 三粒**一律不改写**（含赌圣）：改了就成「出千」而不是「预知」，
    /// 画面上的骰子和游戏算的输赢也会对不上。这里只是「认出来、记下来」。
    public static func casinoSiteIndex(n: UInt32, frameBase: UInt32, memory: BBMemory) -> Int? {
        guard n == 6 else { return nil }
        let ret = memory.read32(Int(frameBase) + returnAddressOffset)
        return casinoDiceSites.firstIndex(of: ret)
    }

    /// 三粒合计 ≥ 11 为大，≤ 10 为小（骰宝通行算法，原版赌场也是这么比的）
    public static func casinoBig(sum: Int) -> Bool { sum >= 11 }

    /// 栈帧里那三格 → 第几粒（0 基，按掷的顺序）。**只给测试用**，产品不用它取点数。
    ///
    /// 反汇编：第一粒掷完写 `[rb-4]`、第二粒 `[rb-8]`、第三粒 `[rb-12]`
    /// （亮骰面时也是按 `[rb-4] → [rb-8] → [rb-12]` × 27 取帧）。
    /// 监视窗口的基址取 `rb-12`，于是偏移 0/4/8 对应第 3/2/1 粒。
    ///
    /// ⚠️ 实测这三格**事不可靠**：`casinoconfirm` 在同一局里同时读栈帧和屏幕，
    /// 栈帧是 2/2/1、屏幕上是 2/5/5 —— 后两格被后续代码复用成了别的中间值，
    /// 而且骰盅的宽高 86/46 也写在同一个位置。所以最终点数一律以**屏幕贴图**为准
    /// （见 `diceFaceIndex`），这三个格只用来验证「游戏确实在这里存过骰子」。
    public static func diceIndex(forWatchOffset offset: UInt32) -> Int? {
        guard offset % 4 == 0, offset < 12 else { return nil }
        return 2 - Int(offset) / 4
    }

    // MARK: - 赌圣：骰盅不盖
    //
    //  这版移植的赌场**没有实现赌圣卡**。但它自己会摆三粒骰面、再拿骰盅盖住 ——
    //  `casinodraw` 探针把贴图顺序原样抓下来了：
    //
    //      SHOWPIC #66 (45, 2) src=(v1*27,0) 27×30   ← 第 1 粒
    //      SHOWPIC #66 (26,16) src=(v2*27,0) 27×30   ← 第 2 粒
    //      SHOWPIC #66 (60,16) src=(v3*27,0) 27×30   ← 第 3 粒
    //      SHOWPIC #152...161 (14,1) 86×46           ← 骰盅，正好把上面三粒盖住
    //
    //  三粒本来就是**品字形**（上 1 居中、下 2 并排），位置/大小/配色都是原生的。
    //  所以「预知」不需要另画一套：把盖盅那几笔拦掉就行。
    //
    //  ── 但「什么时候掷骰」很反直觉（`diceorder` 探针的时间线） ──
    //  进赌场后整整 8 秒，屏幕上只有骰盅在**摇**（#152…161 循环），一次掷骰都没有；
    //  直到玩家按下注（押宝）那一刻才 `RND×3 → 画三粒 → 盖盅 → 掀开`。
    //  也就是说：**本局点数在押宝之后才产生**，押宝前屏幕上根本没有本局骰面。
    //
    //  因此只「拦盅」是不够的 —— 押宝前露出来的是上一局的残留。真正的预知要在
    //  进门时就把三粒定下来（`BBCheat.planRound`），押宝后游戏掷骰时再原样还给
    //  它（`diceOverride` 返回预定值），这样画面、面板、结算永远是同一组。
    //
    //  拦截点：`BBGraphics.onPicture`（返回 false = 这一笔不画）。
    //
    //  ── 点数从哪来 ──
    //  读栈帧不可靠（`casinoconfirm`：栈帧 2/2/1，屏幕上 2/5/5，那三格会被复用）。
    //  所以点数一律取「屏幕上真画的那一笔」：`onPicture` 给的源图 x 就是 `v*27`。
    //  但押宝前游戏还没画，这时显示的只能是进门时预定的那一组（见上）。

    /// 赌场大函数入口（`CALL #133813`，全程序只有 98687 一处调用）。
    ///
    /// 进门时机就靠它：拦这一次 CALL 拿到「玩家已经走进赌场、还没押宝」的那一刻，
    /// 在这里把本局三粒定下来，并把骰盅按住不许盖。
    public static let casinoEntry: UInt32 = 133813

    /// 骰盅：`RICH.LIB #152...161`，十帧，每帧 86×46，游戏画在 (14,1)
    ///
    /// 实测的帧序是**递减**的：155 → 155 → 154 → 153 → 152（200ms 内），也就是
    /// 「从盖到掀开」。掀完就再也不画了，底下那三粒一直露着 —— 所以「开牌」在这个
    /// 赌场里就是**把盅撤走**，不是重画骰子（`casinodraw` 的流水里整套只有 3 笔 #66）。
    /// 我们要做的就是让这几帧一笔都不出现，等价于永远处于「开牌后」。
    public static let cupFrameRange = 152...161
    public static let cupWidth = 86
    public static let cupHeight = 46
    public static let cupOriginX = 14
    public static let cupOriginY = 1

    /// 骰面：`RICH.LIB #66`，一条 8 帧 × 27 宽的长条（前 6 帧 = 1...6 点），每粒 27×30
    public static let diceStripIndex = 66
    public static let diceFaceWidth = 27
    public static let diceFaceHeight = 30
    /// 三粒的落点（品字形：上 1 居中、下 2 并排），顺序 = 掷的顺序
    public static let diceFaceSlots: [(x: Int, y: Int)] = [(45, 2), (26, 16), (60, 16)]

    /// 这一笔贴图是不是「盖盅」。
    ///
    /// 尺寸和位置一起认：86×46 这个尺寸本身不唯一，但赌场这只盅的位置是写死的 (14,1)。
    /// 两个都对上才拦 —— 宁可漏一次，也不要在别的界面误伤一笔。
    /// 资源序号认不出来（-1）时只按尺寸/位置判断。
    public static func isCupDraw(index: Int, dx: Int, dy: Int, w: Int, h: Int) -> Bool {
        guard w == cupWidth, h == cupHeight,
              dx == cupOriginX, dy == cupOriginY else { return false }
        return index < 0 || cupFrameRange.contains(index)
    }

    /// 两次「骰盅贴图」之间隔多久，就算**新的一局**开始（秒）。
    ///
    /// 摇盅期间盅是连续贴的：实测 `diceorder` 一局内相邻两笔最多隔 500ms
    /// （16656→16672 是同帧，16672→16750 是同一串动画，最长 17266→17766 也就 500ms），
    /// 而「掷完掀开」到「下一局再摇盅」至少隔好几秒（实测 21594 掀完，23s 后才有下一段）。
    /// 取 1.2 秒：比局内的 0.5 秒宽两倍多，又远小于局间的数秒。
    public static let cupSegmentGap: Double = 1.2

    /// 掷骰之后的「收尾窗口」（秒）：这期间的盅贴图属于本局的盖盅/掀开/看结果，
    /// 一律不许重定值（实测掷骰 20672 → 掀完 21594，约 0.9 秒；真机 3× 渲染更慢，
    /// 给到 4 秒。宁可在极慢的机器上少换一局，也不能把已经押注的那局换掉）。
    public static let cupSettleWindow: Double = 4.0

    /// 一段盅贴图要**持续多久**才认成「新一局的摇盅」（秒）。
    ///
    /// 光看「间隔 > `cupSegmentGap`」不够：开牌之后游戏还会零星贴几帧盅（盖盅/掀开/
    /// 收尾），那一帧就是一段的开始 —— 当场重定值，屏幕上正开着的点数会被换成下一组，
    /// 而游戏已经按旧值结算完了，玩家就会看到「骰子变了、答案不对」。
    /// 所以要多等一会儿：真摇盅是 8 秒的连续动画（12.2s→20.6s），撑得住 3 秒；
    /// 收尾那几帧凑不满 3 秒。
    public static let cupShakeConfirm: Double = 3.0

    /// 这一笔骰盅贴图是不是「新一段摇盅」（= 新的一局）。
    ///
    /// 为什么需要它：`planRound` 只在**进门**抽一次（`CALL #133813`），可玩家进门后
    /// 往往连着押好几局、根本不重新进门 —— 于是每局都拿同一组预定值，看起来就是
    /// 「骰子被锁死了」。盅每局都会重新摇，用它切段最稳。
    public static func isNewCupSegment(now: Double, last: Double) -> Bool {
        guard last > 0 else { return true }
        return now - last > cupSegmentGap
    }

    /// 进门后一直没见到盅贴图时，多久之后无论如何都把骰子露出来（秒）。
    ///
    /// 正常路径：进门 0.8 秒后开始摇盅（`diceorder` 11.4s → 12.2s）、摇 8 秒。
    /// 万一这台机器上盅不是用贴图画出来的，我们就永远等不到「摇完」那一刻 ——
    /// 那也不能一直不露，超时直接露。
    public static let cupNoStreamFallback: Double = 6.0

    /// 把「骰盅贴图」流切成「局」的状态机，同时决定**骰子什么时候露出来**。
    ///
    /// 放在 Core 里是为了能拿 `diceorder` 实测到的时间戳回放（`cheattest` [12]）——
    /// 这段逻辑最容易出的事就是「把开牌收尾当成新一局」和「摇盅期间就把骰子摆出来」，
    /// 在真机上分别表现为「骰子变了、答案不对」和「骰子从一开始就定住不动」，都很贵。
    ///
    /// 一局的时间线（实测）：进门 → 摇盅 8 秒 → 押注 → 掷骰 → 盖盅 → 掀开。
    /// 骰子只在**摇完之后**才该出现在画面上，所以露出（`revealed`）由盅的贴图流驱动：
    ///
    ///  · 一段新的盅贴图开始 → 收起（那就是「摇盅」，让游戏自己把盅画出来）；
    ///  · 盅不再贴了（距上一笔 > `cupSegmentGap`）→ 摇完 → 露出三粒；
    ///  · 掷骰那一刻起 → 一直露着（盖盅/掀开都要拦掉，让玩家直接看到点数）；
    ///  · 距上次掷骰 < `cupSettleWindow` → 那些盅帧是盖盅/掀开，不算摇盅；
    ///  · 进门后 `cupNoStreamFallback` 秒还没见过盅 → 兜底露出（盅不走贴图）。
    ///
    /// 重定值（`planned`）另外一套：一段要持续 ≥ `cupShakeConfirm` 才算真在摇盅，
    /// 每段最多一次，且本局已有值、还没掷过时不动（押注前数字不许跳）。
    public struct CupSegmentTracker {
        /// 上一笔盅贴图的时刻（0 = 还没见过）
        public private(set) var lastCup: Double = 0
        /// 当前这一段的起点
        public private(set) var start: Double = 0
        /// 这一段已经重定过值
        public private(set) var planned = false
        /// 盅正在连续贴（= 正在摇盅）
        public private(set) var shaking = false
        /// 这一段已确认为「真在摇盅」（持续够长）
        public private(set) var shakeConfirmed = false
        /// 骰子该露出来了吗（= 拦掉盖盅、把三粒贴到画面上）
        public private(set) var revealed = false
        /// 这次进赌场的时刻（兜底计时用）
        public private(set) var visitStart: Double = 0

        public init() {}

        /// 进门：一切重来，先别露（接着就是摇盅）。
        public mutating func begin(at now: Double) {
            lastCup = 0
            start = 0
            planned = false
            shaking = false
            shakeConfirmed = false
            revealed = false
            visitStart = now
        }

        /// 喂一笔盅贴图。返回 true 表示「现在该重新定值了」。
        @discardableResult
        public mutating func cup(at now: Double, thrown: Bool, lastThrow: Double,
                                 hasPlan: Bool) -> Bool {
            let newSeg = BBCheatMap.isNewCupSegment(now: now, last: lastCup)
            if newSeg {
                start = now
                planned = false
                shakeConfirmed = false
            }
            lastCup = now
            let justThrown = lastThrow > 0 && now - lastThrow < BBCheatMap.cupSettleWindow
            if justThrown {
                // 掷完的盖盅/掀开：露着别动
                shaking = false
                revealed = true
                return false
            }
            shaking = true
            // 新的摇盅开始了 → 把上一局的结果收起来，让游戏自己的盅画出来
            if newSeg { revealed = false }
            if now - start >= BBCheatMap.cupShakeConfirm { shakeConfirmed = true }
            let need = shakeConfirmed && !planned && (!hasPlan || thrown)
            if need { planned = true }
            return need
        }

        /// 主线程每帧调：没有新盅贴图时负责「摇完了」和兜底这两个判断。
        public mutating func idle(at now: Double, lastThrow: Double) {
            let justThrown = lastThrow > 0 && now - lastThrow < BBCheatMap.cupSettleWindow
            if justThrown {
                shaking = false
                revealed = true
                return
            }
            if shaking, now - lastCup > BBCheatMap.cupSegmentGap {
                shaking = false
                // 摇完了 → 露。只有「确认摇过」（段够长）才露：段刚开始就卡顿
                // 1.2 秒的话，那更像是一帧杂图，不是摇盅结束。
                if shakeConfirmed { revealed = true }
            }
            // 兜底只数「距离最后一次见到盅（没见过就数进门）」的时间：正常摇盅期间
            // `lastCup` 一直在刷新，不会误触；盅根本不走贴图、或者只闪了一下就没了，
            // 6 秒后照样把骰子露出来，免得预知永远不显示。
            let anchor = max(lastCup, visitStart)
            if !revealed, !shaking, anchor > 0,
               now - anchor > BBCheatMap.cupNoStreamFallback {
                revealed = true
            }
        }

        /// 掷骰那一刻：从现在起到离开赌场，骰子一直露着。
        public mutating func threw(at now: Double) {
            shaking = false
            revealed = true
        }

        /// 兼容旧调用（只关心「该不该重定值」）
        @discardableResult
        public mutating func tick(now: Double, thrown: Bool, lastThrow: Double,
                                  hasPlan: Bool) -> Bool {
            cup(at: now, thrown: thrown, lastThrow: lastThrow, hasPlan: hasPlan)
        }
    }

    /// 这一笔贴图是不是「三粒骰面之一」。是的话返回是第几粒（0 基）。
    ///
    /// 只认尺寸 + 落点：骰面是 27×30，三个落点写死在赌场里。资源序号只做加分项
    /// （认得出就必须是 #66），认不出也放过 —— 免得换个资源表顺序就全哑了。
    public static func diceFaceIndex(index: Int, dx: Int, dy: Int, w: Int, h: Int) -> Int? {
        guard w == diceFaceWidth, h == diceFaceHeight else { return nil }
        guard index < 0 || index == diceStripIndex else { return nil }
        return diceFaceSlots.firstIndex { $0.x == dx && $0.y == dy }
    }

    /// 源图 x → 点数（1...6）。骰子条每帧 27 宽，第 v 帧 = v+1 点。
    ///
    /// 超出 6 帧的（比如空白帧）返回 nil，宁可不显示也不显示错的。
    public static func dicePip(sourceX: Int) -> Int? {
        guard sourceX >= 0, sourceX % diceFaceWidth == 0 else { return nil }
        let frame = sourceX / diceFaceWidth
        guard frame < 6 else { return nil }
        return frame + 1
    }

    /// 把三粒骰面直接画进一帧像素（呈屏帧，主线程）。
    ///
    /// 为什么需要自己画：赌场是「进门 → 摇盅 → 押注 → 才掷骰」，押注那一刻游戏
    /// 根本还没画骰面（`diceorder` 探针：进门 11.4s、掷骰 20.7s）。要在下注界面上
    /// 看到结果，只能由我们把进门时预定的那三粒贴上去。
    ///
    /// 用的是**游戏自己的贴图和落点**（`RICH.LIB #66`、`diceFaceSlots`），所以画出来
    /// 和它押注后自己画的一模一样，切换时无缝。
    ///
    /// `scale` = **呈屏帧**相对 VM 逻辑坐标的倍数，也就是 `BBHD.scale`（1 或 3）。
    /// 注意它**不等于**源图的倍数：`RICH-HD.LIB` 里没有 #66 的时候，引擎拿到的是
    /// 1× 的骰子条，而画布是 3× 的 —— 以前两边一起乘，画出来的骰子只有 1/3 大、
    /// 蹲在格子左上角，于是「押注前画面和面板对不上」。现在一律最近邻采样：
    /// 源帧多大都行，落点永远是 `diceFaceSlots × scale` 那一格。
    ///
    /// 返回实际落笔的骰子粒数（0 = 什么都没画，给自检和日志用）。
    @discardableResult
    public static func paintDiceFaces(into pixels: inout [UInt32], width: Int, height: Int,
                                      sprite: BBSurface, pips: [Int], scale: Int) -> Int {
        let frameW = sprite.width / 8      // 一条 8 帧，前 6 帧 = 1...6 点
        let frameH = sprite.height
        guard frameW > 0, frameH > 0, width > 0, height > 0 else { return 0 }
        let s = max(1, scale)
        let key = BBGraphics.colorKey & 0xFFFFFF
        var painted = 0
        for (i, pip) in pips.enumerated() {
            guard i < diceFaceSlots.count, pip >= 1, pip <= 6 else { continue }
            let slot = diceFaceSlots[i]
            let x0 = slot.x * s
            let y0 = slot.y * s
            let dw = diceFaceWidth * s
            let dh = diceFaceHeight * s
            let sx0 = (pip - 1) * frameW
            painted += 1
            for y in 0..<dh {
                let ty = y0 + y
                guard ty >= 0, ty < height else { continue }
                let srcRow = (y * frameH / dh) * sprite.width + sx0
                let dstRow = ty * width + x0
                for x in 0..<dw {
                    let tx = x0 + x
                    guard tx >= 0, tx < width else { continue }
                    let color = sprite.pixels[srcRow + x * frameW / dw] & 0xFFFFFF
                    if color == key { continue }     // 洋红透明键
                    pixels[dstRow + x] = color
                }
            }
        }
        return painted
    }

    /// 赌神卡：赌场回合内、轮到人类、现金比上次快照多了 Δ → 再补一份 Δ。
    ///
    /// 输了（现金没涨）或条件不满足返回 nil，绝不倒扣 —— 和原卡「输钱不作用」一致。    /// `armed` = 自上次解除以来见过赌场掷骰（见 `BBCheat.armCasinoRound`）；
    /// 座位不是人类就不补，电脑赢钱跟金手指没关系。
    public static func godGamblerBonus(previous: Int, current: Int,
                                       armed: Bool, seat: Int, humanSeat: Int) -> Int? {
        guard armed, seat == humanSeat, current > previous else { return nil }
        return current - previous
    }

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
        Layout.stockPriceBase + index * 4
    }

    /// 某只股票的浮动系数（涨跌幅 %，负数是跌）
    public static func stockCoef(_ memory: BBMemory, _ index: Int) -> Float {
        guard index >= 0, index < Layout.stockCount else { return 0 }
        return Float(bitPattern: memory.read32(Layout.stockCoefBase + index * 4))
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

    /// 「控制趋势」：游戏调完价之后，把**方向**掰到指定的一边，幅度照原样。
    ///
    /// 这是最「不离谱」的做法：波动大小还是游戏自己算的（通常每次 1~5%），
    /// 我们只决定往上还是往下，不制造跳变、不硬拉到某个数字。
    ///
    /// `previous` 是上一次看到的 20 个价格。某个价格**变了**就说明游戏刚调过，
    /// 此时按方向重算；没变就不动（我们不去主动推价格）。
    ///
    /// `trend`：+1 涨、-1 跌、0 原样。
    @discardableResult
    public static func applyTrend(_ memory: BBMemory,
                                  previous: inout [Int],
                                  trend: Int,
                                  lower: Int,
                                  upper: Int) -> [Int] {
        var lo = min(Layout.priceCap, max(1, lower))
        var hi = min(Layout.priceCap, max(1, upper))
        if lo > hi { swap(&lo, &hi) }

        var current = [Int](repeating: 0, count: Layout.stockCount)
        for i in 0..<Layout.stockCount {
            current[i] = stockPrice(memory, i)
        }
        if previous.count != Layout.stockCount {
            previous = current
            return current
        }
        guard trend != 0 else {
            previous = current
            return current
        }

        for i in 0..<Layout.stockCount {
            // 先夹护栏。**这一步不看「有没有变化」** —— 用户刚把上限调到 500 时，
            // 手上那些 900 的股票要立刻被拉回来，而不是等下一次游戏调价。
            let base = min(hi, max(lo, previous[i]))
            var now = current[i]
            if now != base {
                let clamped = min(hi, max(lo, now))
                if clamped != now {
                    setStockPrice(memory, i, clamped)
                    now = clamped
                }
            }
            defer { current[i] = now }

            // 再谈趋势：只对「游戏刚调过」的那一只生效。
            // 幅度用游戏给的（|now - base|），我们只决定正负号。
            guard base > 0, now != base else { continue }

            var magnitude = abs(now - base)
            if magnitude == 0 { magnitude = 1 }
            let target = min(hi, max(lo, trend > 0 ? base + magnitude : base - magnitude))

            // 已经顶到边界、方向推不动了：停在原地，别在边界上来回抖
            if target != now {
                setStockPrice(memory, i, target)
                now = target
            }
        }
        previous = current
        return current
    }

    /// 「在区间内涨跌」：把所有价格夹进 `[lower, upper]`。
    ///
    /// 和 `enforcePriceFloor` 的区别：那个的底线会跟着价格往上爬（只涨不跌），
    /// 这个的上下限是**固定**的 —— 价格可以涨也可以跌，就是出不了这个笼子。
    ///
    /// 边界处理：下限至少 1、上限至多 `priceCap`（999），且保证 `lower <= upper`；
    /// 传反了也不会把价格压成 0 —— 内部会交换。
    @discardableResult
    public static func enforcePriceRange(_ memory: BBMemory, lower: Int, upper: Int) -> [Int] {
        var lo = min(Layout.priceCap, max(1, lower))
        var hi = min(Layout.priceCap, max(1, upper))
        if lo > hi { swap(&lo, &hi) }

        var prices = [Int](repeating: 0, count: Layout.stockCount)
        for i in 0..<Layout.stockCount {
            let current = stockPrice(memory, i)
            let clamped = min(hi, max(lo, current))
            if clamped != current {
                setStockPrice(memory, i, clamped)
            }
            prices[i] = clamped
        }
        return prices
    }

    // MARK: - 调价记录
    //
    // 「最近几次到底怎么动的」是能如实记下来的：每 0.4 秒轮询一次 20 个价格，
    // 变了就存一张快照。**只记事实，不猜下一步** —— 下一步的方向在游戏里
    // 是一次 RND(2)，记多少历史都推不出偏向（见 predictprobe / 反汇编 0x589F0）。

    /// 一张价格快照（20 家）。`manual` = 这一次是我们自己在面板上动的手。
    public struct PriceTick {
        public let prices: [Int]
        public let manual: Bool

        public init(prices: [Int], manual: Bool = false) {
            self.prices = prices
            self.manual = manual
        }
    }

    /// 记录上限：1 条基线 + 12 次变化。基线的用处是「第一次变化要有参照物」。
    public static let tickCap = 13

    /// 价格变了才追加，超长从头截断。返回是否真的新增了一条。
    ///
    /// 价格没变时**不追加**（0.4 秒轮询一次，不筛的话列表全是重复）；
    /// 但如果这次是手动改的，就把最后一条的 `manual` 标上，方便界面上区分
    /// 「游戏调的」和「我调的」。
    @discardableResult
    public static func appendTick(_ ticks: inout [PriceTick], _ prices: [Int],
                                  manual: Bool = false, cap: Int = tickCap) -> Bool {
        guard prices.count == Layout.stockCount else { return false }
        if let last = ticks.last, last.prices == prices {
            if manual, !last.manual {
                ticks[ticks.count - 1] = PriceTick(prices: prices, manual: true)
            }
            return false
        }
        ticks.append(PriceTick(prices: prices, manual: manual))
        if ticks.count > cap { ticks.removeFirst(ticks.count - cap) }
        return true
    }

    /// 某一只股票逐次涨跌（百分比，正 = 涨）。长度 = `ticks.count - 1`。
    public static func changeSeries(_ ticks: [PriceTick], _ index: Int)
        -> [(pct: Double, manual: Bool)] {
        guard index >= 0, index < Layout.stockCount, ticks.count >= 2 else { return [] }
        var out: [(pct: Double, manual: Bool)] = []
        out.reserveCapacity(ticks.count - 1)
        for i in 1..<ticks.count {
            let from = ticks[i - 1].prices[index]
            let to = ticks[i].prices[index]
            guard from > 0 else { continue }
            out.append((Double(to - from) / Double(from) * 100.0, ticks[i].manual))
        }
        return out
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
