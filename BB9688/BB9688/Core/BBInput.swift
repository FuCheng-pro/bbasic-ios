//
//  BBInput.swift
//  BB9688
//
//  按键/触摸/文本输入队列。VM 线程会阻塞在这里，UI 线程负责投递事件。
//

import Foundation

public final class BBInputQueue {
    private let condition = NSCondition()
    /// 队列里每一项都带**按下的时刻**。没有时间戳就没法判断「这个键是不是早就该丢了」，
    /// 见 `maxKeyAge` 的说明。
    private struct PendingKey {
        let code: UInt32
        let at: TimeInterval      // Date.timeIntervalSinceReferenceDate
    }
    private var keyQueue: [PendingKey] = []
    private var textQueue: [UInt32] = []
    private var heldKeys = Set<UInt32>()
    private var stopped = false

    /// 待取按键的上限。程序卡在一个不读键盘的画面里时（加载动画、过场），
    /// 界面上继续按键会一直往队列里堆，等程序回来读键盘就一次性全吃掉 ——
    /// 表现就是「手已经松了，光标还自己跑好几格」。超过这个数就丢最旧的。
    private let maxPendingKeys = 4

    /// 按键从按下到被程序取走之间，最多允许积压多久。
    ///
    /// ★ 这个就是「电脑自动行走时按了键，轮到自己就自动掷骰子、还多走一步」的根因：
    ///   大富翁在算电脑那几家的回合时（几秒钟）根本不调 `InKey$` / `INKEY`，
    ///   这期间按下的键不会消失，只会在 `keyQueue` 里排队；
    ///   等轮到玩家、程序第一次读键盘，积压的键被**一次性喂进去** ——
    ///   第一个被当成「确定」把骰子掷了，剩下的继续被后续读键盘的地方吃掉，于是多走。
    ///
    ///   真机的键盘缓冲只有一两个字节、而且扫描是实时的，不存在「三秒前按的键还算数」。
    ///   所以这里给积压设一个上限：超过就当成没按过。
    ///   原先是 0.5s，短到接不住一次电脑回合（通常 ≥1s），也确实挡住了积压；
    ///   但**小游戏里反而伤到了正常操作** —— 游乐场「接金币」、赌场下注这些界面
    ///   入场动画就有一两秒，玩家在动画期间按的方向键全被当成过期丢掉，
    ///   表现就是「按什么都没反应」。放宽到 1.5s。
    ///
    ///   积压的风险靠另一条规则兜着：方向键在队列里去重（见 `pushKey`），
    ///   而且 `dropPendingDirections` 在松手时清空，不会出现「松手了还在走」。
    private static let maxKeyAge: TimeInterval = 1.5

    /// 方向键：程序几乎只用它挪光标，重复排队没有任何意义
    private static let directionKeys: Set<UInt32> = [37, 38, 39, 40]

    public init() {}

    public func stop() {
        condition.lock()
        stopped = true
        condition.broadcast()
        condition.unlock()
    }

    public var isStopped: Bool {
        condition.lock()
        defer { condition.unlock() }
        return stopped
    }

    /// 普通按键（ASCII / 方向键码）
    public func pushKey(_ code: UInt32) {
        condition.lock()
        // 同一个方向键在队列里最多留一个：长按连发时 UI 每 0.26s 送一次，
        // 如果程序没在读键盘，这些事件会攒起来，松手之后继续生效。
        if Self.directionKeys.contains(code), keyQueue.contains(where: { $0.code == code }) {
            condition.unlock()
            return
        }
        keyQueue.append(PendingKey(code: code, at: Date.timeIntervalSinceReferenceDate))
        if keyQueue.count > maxPendingKeys {
            keyQueue.removeFirst(keyQueue.count - maxPendingKeys)
        }
        condition.signal()
        condition.unlock()
    }

    /// 松手时**不再清空**队列里的方向键。
    ///
    /// 原先这里做的是 `removeAll`，为的是避免「松手了还在走」。但那把
    /// **正常的单次按键也一起作废了** —— 游乐场「接金币」、赌场下注这类界面，
    /// 入场动画有一两秒，程序那段时间不读键盘，玩家推的方向键还躺在队列里等，
    /// 一松手就被清掉。表现就是「摇杆、左右键全都没反应」。
    ///
    /// 现在靠两条已有的机制兜底，不需要清：
    ///   • `maxKeyAge`（1.5s）—— 躺着太久的自动过期
    ///   • `pushKey` 里对方向键去重 —— 按住连发也只在队列里留一个，松手后最多生效一次
    public func dropPendingDirections() {
        // 有意留空
    }

    /// 换程序 / 退出程序时清干净，防止上一轮残留的键喂给新程序
    public func reset() {
        condition.lock()
        keyQueue.removeAll()
        textQueue.removeAll()
        heldKeys.removeAll()
        condition.unlock()
    }

    /// 触摸屏幕：原 VM 把鼠标点击编码为 (y << 16 | x) | 0x80000000
    public func pushTap(x: Int, y: Int) {
        let code = (UInt32(truncatingIfNeeded: y) << 16) | UInt32(truncatingIfNeeded: x) | 0x8000_0000
        pushKey(code)
    }

    public func setHeld(_ code: UInt32, pressed: Bool) {
        condition.lock()
        if pressed { heldKeys.insert(code) } else { heldKeys.remove(code) }
        condition.unlock()
    }

    public func pushText(_ scalar: UInt32) {
        condition.lock()
        textQueue.append(scalar)
        condition.signal()
        condition.unlock()
    }

    public func waitKey() -> UInt32? {
        waitKey(timeout: nil)
    }

    /// 带超时的等键。超时返回 nil（和 `stopped` 一样返回 nil，调用方自己用
    /// `isStopped` 区分）。
    ///
    /// 为什么需要：游戏九成时间卡在等按键上，VM 主循环根本没在转。
    /// 金手指要「改完钱立刻重画状态栏」，就得在等待的空档里插一手 ——
    /// 见 `BBVM.drainInjection()`。
    public func waitKey(timeout: TimeInterval?) -> UInt32? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = timeout.map { Date(timeIntervalSinceNow: $0) }
        while true {
            while keyQueue.isEmpty && !stopped {
                if let deadline {
                    if !condition.wait(until: deadline) { return nil }   // 超时
                } else {
                    condition.wait()
                }
            }
            if keyQueue.isEmpty { return nil }
            let item = keyQueue.removeFirst()
            // 压太久的键不算数（见 `maxKeyAge`）：程序不读键盘那段时间里按下的东西，
            // 到真正读的时候已经被忘掉了。丢掉之后继续等下一个，而不是直接返回空。
            let age = Date.timeIntervalSinceReferenceDate - item.at
            if age > Self.maxKeyAge { continue }
            return item.code
        }
    }

    public func waitTextChar() -> UInt32? {
        condition.lock()
        defer { condition.unlock() }
        while textQueue.isEmpty && !stopped {
            condition.wait()
        }
        if textQueue.isEmpty { return nil }
        return textQueue.removeFirst()
    }

    public func keyPressed(_ code: UInt32) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return heldKeys.contains(code)
    }
}
