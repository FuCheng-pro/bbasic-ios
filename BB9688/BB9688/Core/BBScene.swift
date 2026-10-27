//
//  BBScene.swift
//  BB9688
//
//  「游戏当前在哪个界面」的判定，只靠 SHOWPIC 的资源号，不碰游戏内存。
//
//  为什么可以这么做（实测依据）：
//    大富翁的地图界面**每帧重绘整个棋盘**，一帧 200~480 笔 SHOWPIC，
//    其中棋盘地块图（LIB 第 63 张）的累计面积能到屏幕的 30~66 倍；
//    而标题画面只在进入时贴一次全屏图（第 1 张），覆盖率约 1 倍。
//    两者的量级差了两个数量级，用「窗口内累计面积」就能干净分开。
//
//  判定是**粘性**的：规则不满足时保持当前场景，不回落。
//  因为地图静止等玩家输入时不再重绘，累计值会衰减到 0，
//  若允许回落就会在「棋盘 ↔ 未知」之间反复横跳，音乐跟着抽搐。
//
//  ⚠️ Core 目录的约定：只许 Foundation，不许 UIKit / AVFoundation。
//  这个文件只做判定，发声在 Audio/ 层。
//

import Foundation

/// 游戏界面。`boot` 是「还没认出来」，不是真的开机画面。
public enum BBScene: String, CaseIterable {
    case boot
    case title
    case board
    /// 赌场（CASINO）。BBK 版用一张 240×320 全屏图，和标题一样是「贴一次满屏」，
    /// 所以只能靠图号区分，不能只靠覆盖率。
    case casino
    /// 游乐场（777 格）。小碗接金币。判定靠「那只碗」（LIB 110）。
    case park
    /// 黑市（买卡片）。界面是纯文字列表，靠商品名识别。
    case market
    /// 每月结算（银行利息 + 排行表）。没有专属图，靠文字识别。
    case settle
    /// 破产 / 倒闭。
    case bankrupt
}

/// 一条识别规则：看到 `libIndex` 这张图、且窗口内累计覆盖面积达到 `minCoverage` 屏，就认为进了 `scene`。
public struct BBSceneRule {
    public let scene: BBScene
    public let libIndex: Int
    /// 单位是「屏」。贴满一次整屏 = 1.0。
    public let minCoverage: Double
    /// 数值大的先匹配。
    ///
    /// 为什么需要它：地图界面每帧重绘棋盘，累计能到 30~60 屏；
    /// 而赌场是一张贴满全屏的图、只贴 1 次，覆盖率才 1.0。
    /// 如果单纯比「谁的面积大」，刚从地图进赌场那几秒会被地图的残留量压住，
    /// 音乐要等残留衰减完才切 —— 表现为「进赌场后音乐慢半拍」。
    /// 给「一整屏的切换型界面」高优先级，就能立刻切过去。
    public let priority: Int

    public init(scene: BBScene, libIndex: Int, minCoverage: Double, priority: Int = 0) {
        self.scene = scene
        self.libIndex = libIndex
        self.minCoverage = minCoverage
        self.priority = priority
    }

    /// 大富翁（rich.bin）的规则，来自无头探针实测：
    ///
    ///   标题   LIB 1   全屏 240×320，贴一次          → 覆盖率 ≈ 1.0
    ///   赌场   LIB 151 全屏 240×320，贴一次          → 覆盖率 ≈ 1.0
    ///   地图   LIB 63  棋盘地块，每帧反复贴           → 覆盖率 32 ~ 66
    ///   选人   LIB 63  也出现，但只贴 1~2 次          → 覆盖率 0.75 ~ 1.5
    ///
    /// 阈值取 5.0：离选人态（1.5）和地图态（32）都有足够余量。
    ///
    /// ⚠️ 标题和赌场**覆盖率一样**，区分只能看图号。所以图号是硬编码的，
    /// 换一个游戏就必须重采（规则表本来就是数据，改这里即可）。
    /// 赌场有两套画面：
    ///   151 —— CASINO 主界面（大 / 小 / 押注倍率），整屏一张
    ///   155~161 —— 进入下注后的骰子与倍率盘，七张小图拼出来，单张只占 15~20%
    /// 两条规则都要给，否则进了下注界面 151 一消失、地图的残留量还没衰减完，
    /// 就会被判回 board —— 表现是「赌场里音乐突然跳回地图曲」。
    /// 155 在别处没出现过（200 回合采样里只在赌场出现），拿来当赌场的第二个指纹。
    ///
    /// 游乐场那两条（110 是那只接金币的碗，40×13）：
    ///   碗只在游乐场出现，比只用「画笔在动」更准 —— 画笔还可能被别的东西触发。
    ///   覆盖率阈值压到 0.003 是因为碗本身只有 520 像素，占屏 0.7%。
    public static let rich = [
        BBSceneRule(scene: .title,  libIndex: 1,   minCoverage: 0.8,  priority: 10),
        BBSceneRule(scene: .casino, libIndex: 151, minCoverage: 0.8,  priority: 10),
        BBSceneRule(scene: .casino, libIndex: 155, minCoverage: 0.10, priority: 10),
        BBSceneRule(scene: .park,   libIndex: 110, minCoverage: 0.003, priority: 10),
        // ⚠️ 黑市**暂时没有可靠判据**，这里故意不写规则。
        //
        // 曾经拿 LIB 105~109（154×197 的五张立绘）当黑市指纹，是错的：
        // 和用户的黑市截图逐项比对后确认，那是**另一个角色** ——
        //   105~109：蓬松卷发、白底红领结、戴项链、手持蓝色文件夹
        //   黑市商人：平整刘海、黄橙上衣配紫领、无项链、空手
        // 翻遍全部 182 张图（240×320 / 240×150 / 154×197 / 176×121 / 106×396 / 576×720）
        // 都没有那个黄衣商人 —— 说明它是程序画的，或者用了别的资源。
        // 宁可留空，也不能用错的判据：那样会在别处误播 RICHZ。
        BBSceneRule(scene: .board,  libIndex: 63,  minCoverage: 5.0,  priority: 1),
    ]
}

/// 把 SHOWPIC 的 `(资源号, 面积)` 流变成 `BBScene`。
///
/// 线程约定：`feed` 在 VM 线程被高频调用（每帧几百次），`tick` 在渲染泵（主线程）每帧调一次。
/// 两者会同时碰 `accum`，所以内部用一把非递归锁串起来。
/// 锁只护「累加 + 评估」，`onChange` 回调放到锁外发 —— 否则订阅方在回调里
/// 再回头调本类的方法就会自锁。
public final class BBSceneDetector {

    public var scene: BBScene {
        lock.lock(); defer { lock.unlock() }
        return _scene
    }
    /// 场景真的变了才回调（同值不重复报）。在调用 `tick` / `reset` 的线程上同步触发。
    public var onChange: ((BBScene) -> Void)?

    public var rules: [BBSceneRule]
    public var isEnabled = true

    private var _scene: BBScene = .boot
    /// 一屏多少像素，用来把面积换算成「几屏」
    private let screenArea: Double
    /// 资源号 → 窗口内累计覆盖面积（单位：屏）
    private var accum: [Int: Double] = [:]
    /// 窗口内的画笔操作次数。实测：标题 / 选人 / 棋盘 / 股票 / 新闻，
    /// 这几个界面的画笔操作**全是 0** —— 这个游戏几乎不用画笔，全靠贴图。
    /// 所以只要看到画笔在动，就基本可以断定是「画出来」的小游戏。
    private var paintOps = 0

    /// 屏幕上最近画过的一串字（GBK 字节）。
    /// 黑市没有任何图能代表它，只能靠商品名认 —— 见 `marketWords`。
    private var textTail: [UInt8] = []
    /// 最近一次命中黑市关键词的时刻。初值给一个很远的过去 = 「从没命中过」。
    private var textHitAt: TimeInterval = -1_000
    private var settleHitAt: TimeInterval = -1_000
    private var bankruptHitAt: TimeInterval = -1_000
    /// 最近一次 `tick` 的时间。`feedText` 在 VM 线程上跑，拿不到 tick 的参数，
    /// 必须共用同一个时间基准 —— 否则一个用 Date()、一个用测试注入的时钟，
    /// 「命中后 2.5 秒过期」就永远算不对。
    private var clockNow: TimeInterval = 0

    /// 黑市商品名。这几个词只会出现在黑市的商品列表里，
    /// 组成 UTF-8 之外的 GBK 双字节序列，逐字累积到 `textTail` 里比对。
    private static let marketWords: [[UInt8]] = [
        [0xB4, 0xDF, 0xC3, 0xDF, 0xB7, 0xFB],   // 催眠符（简繁同形）
        [0xCB, 0xCD, 0xC9, 0xF1, 0xB7, 0xFB],   // 送神符（简繁同形）
        [0xD9, 0x8F, 0xB5, 0xD8, 0xBF, 0xA8],   // 購地卡（繁）
        [0xB9, 0xBA, 0xB5, 0xD8, 0xBF, 0xA8],   // 购地卡（简）
        [0xBC, 0xDE, 0xB5, 0x9C, 0xBF, 0xA8],   // 嫁禍卡
        [0xBC, 0xDE, 0xBB, 0xF6, 0xBF, 0xA8],   // 嫁祸卡
        [0xCF, 0xDD, 0xBA, 0xA6, 0xBF, 0xA8],   // 陷害卡（简繁同形）
    ]

    /// 每月结算界面的用词。实测这个版本的游戏文本以**简体**为主
    /// （采样里是「是否买下此地?」「路过银行」），所以简体繁体的表都放进去。
    private static let settleWords: [[UInt8]] = [
        [0xBD, 0xE1, 0xCB, 0xE3],   // 结算
        [0xBD, 0x59, 0xCB, 0xE3],   // 結算
        [0xC0, 0xFB, 0xCF, 0xA2],   // 利息
        [0xC5, 0xC5, 0xD0, 0xD0],   // 排行
    ]

    /// 倒闭 / 破产。
    private static let bankruptWords: [[UInt8]] = [
        [0xB5, 0xB9, 0xB1, 0xD5],   // 倒闭
        [0xB5, 0xB9, 0xE9, 0x5D],   // 倒閉
        [0xC6, 0xC6, 0xB2, 0xFA],   // 破产
        [0xC6, 0xC6, 0xAE, 0x61],   // 破產
    ]

    /// 命中后维持多久。黑市界面一直在重画这两列商品名，所以会不断刷新；
    /// 离开黑市后约 2.5 秒自然过期。
    private let marketHold: TimeInterval = 2.5

    /// 窗口内累计多少笔画笔操作算「画面是画出来的」。
    ///
    /// 目前**不参与判定** —— 游乐场已经能用「那只碗」（LIB 110）精确认出来，
    /// 而画笔信号会把画东西的黑市也卷进来。留着这个量和 `feedPaint` 是为了
    /// 将来遇到既没贴图又没特征物的界面时还有一条退路。
    public var minPaintOps = 3

    private let lock = NSLock()
    private var lastTick: TimeInterval = 0
    /// 多久评估一次。太密会被单帧的抖动带偏，太疏会慢半拍。
    private let evaluateInterval: TimeInterval = 0.35
    /// 每次评估后旧累计值的保留比例
    private let decay: Double = 0.5

    public init(width: Int = 240, height: Int = 320, rules: [BBSceneRule] = BBSceneRule.rich) {
        self.screenArea = Double(max(1, width * height))
        self.rules = rules
    }

    /// VM 线程：每笔 SHOWPIC 喂一次。只做累加，不评估。
    public func feed(libIndex: Int, area: Int) {
        guard isEnabled else { return }
        lock.lock()
        accum[libIndex, default: 0] += Double(area) / screenArea
        lock.unlock()
    }

    /// VM 线程：每笔画笔操作喂一次。`type` 保留但当前不区分粗细 ——
    /// 圆和填充对「是不是小游戏」的判断力一样，先不细分。
    public func feedPaint() {
        guard isEnabled else { return }
        lock.lock()
        paintOps += 1
        lock.unlock()
    }

    /// VM 线程：每画一个字符喂一次。只维护一个短尾巴做子串比对，开销可忽略。
    public func feedText(_ bytes: [UInt8]) {
        guard isEnabled, !bytes.isEmpty else { return }
        lock.lock()
        textTail.append(contentsOf: bytes)
        if textTail.count > 128 {
            textTail.removeFirst(textTail.count - 128)
        }
        for w in Self.marketWords where textTail.count >= w.count {
            if textTail.suffix(w.count).elementsEqual(w) {
                textHitAt = clockNow      // 和 tick 同一基准
                break
            }
        }
        for w in Self.settleWords where textTail.count >= w.count {
            if textTail.suffix(w.count).elementsEqual(w) {
                settleHitAt = clockNow
                break
            }
        }
        for w in Self.bankruptWords where textTail.count >= w.count {
            if textTail.suffix(w.count).elementsEqual(w) {
                bankruptHitAt = clockNow
                break
            }
        }
        lock.unlock()
    }

    /// 渲染泵：每帧调一次，内部按时间节流。
    public func tick(now: TimeInterval = Date().timeIntervalSince1970) {
        guard isEnabled else { return }

        lock.lock()
        guard now - lastTick >= evaluateInterval else { lock.unlock(); return }
        lastTick = now
        clockNow = now

        // 文字类判定，优先级：破产 > 结算 > 黑市。
        // 破产是全屏事件，盖住一切；结算排在黑市前面 —— 结算界面里也可能
        // 还残留着上一屏的商品名（尾巴里），不能让黑市把它抢走。
        let byText: BBScene?
        if (now - bankruptHitAt) < marketHold {
            byText = .bankrupt
        } else if (now - settleHitAt) < marketHold {
            byText = .settle
        } else if (now - textHitAt) < marketHold {
            byText = .market
        } else {
            byText = nil
        }
        if let scene = byText {
            for key in Array(accum.keys) {
                accum[key] = (accum[key] ?? 0) * decay
            }
            paintOps = Int(Double(paintOps) * decay)
            lock.unlock()
            setScene(scene)
            return
        }

        // 游乐场靠「那只碗」（LIB 110）认，不是靠画笔。
        //
        // 画笔信号只做旁证、不参与判定：黑市（买卡片）如果也画东西，
        // 单看「画笔在动」就会把它误判成游乐场、播错曲。
        // 碗是游乐场的必要条件（没碗接什么金币），而且只在那一屏出现，
        // 用它当判据既准又不会串场。
        let winner = winnerLocked()

        // 衰减。先拷一份 key 再改，避免边遍历边写。
        for key in Array(accum.keys) {
            accum[key] = (accum[key] ?? 0) * decay
        }
        paintOps = Int(Double(paintOps) * decay)
        lock.unlock()

        // 一条都不满足 → 保持现状（粘性），不回落成 boot
        if let winner { setScene(winner) }
    }

    /// 换游戏 / 重新起机时清空，别把上一局的地图残留带过来
    public func reset() {
        lock.lock()
        accum.removeAll()
        paintOps = 0
        textTail.removeAll()
        textHitAt = -1_000
        settleHitAt = -1_000
        bankruptHitAt = -1_000
        lastTick = 0
        let changed = _scene != .boot
        _scene = .boot
        lock.unlock()
        if changed { onChange?(.boot) }
    }

    /// 先按优先级、再按覆盖率挑一个胜出者。
    ///
    /// 顺序：优先级高的规则一旦满足就直接赢（一整屏的界面切换要立刻响应）；
    /// 同优先级之间才比覆盖率。
    private func winnerLocked() -> BBScene? {
        var winner: (scene: BBScene, priority: Int, coverage: Double)?
        for rule in rules {
            let coverage = accum[rule.libIndex] ?? 0
            guard coverage >= rule.minCoverage else { continue }
            guard let best = winner else {
                winner = (rule.scene, rule.priority, coverage)
                continue
            }
            if rule.priority > best.priority
                || (rule.priority == best.priority && coverage > best.coverage) {
                winner = (rule.scene, rule.priority, coverage)
            }
        }
        return winner?.scene
    }

    private func setScene(_ new: BBScene) {
        lock.lock()
        guard new != _scene else { lock.unlock(); return }
        _scene = new
        lock.unlock()
        onChange?(new)
    }
}
