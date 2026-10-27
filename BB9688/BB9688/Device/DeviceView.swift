//
//  DeviceView.swift
//  BB9688
//
//  整机：照片机壳 + LCD + 按键辉光 + 热区。
//  机壳与按键全部来自真机照片（Resources/device-shell.png、glow-*.png），
//  「重绘按键」那套做法在这里完全不存在，按下只是把同源提亮层叠上去。
//
//  触摸：整台机器上盖**一整块**全尺寸手势层，自己按坐标做命中判定。
//  不用「每个按键一个 .offset 小视图各挂一个手势」的写法 ——
//  `.offset()` 会把视图移走但不改布局，手势报出来的 location 到底属于谁的坐标系
//  很微妙；一旦落到父坐标系，摇杆算出来的 dx/dy 恒为大正数，就只会往「下」。
//  这块手势层没有 offset、和机身同原点，location 天然就是机身坐标。
//
//  ── 按键映射（9688 是按键机，没有触屏，所以键位要按真机习惯来）──
//
//    按键           程序列表              运行中
//    ---------------------------------------------------------------
//    摇杆 ↑ ↓       上一个 / 下一个       38 / 40
//    摇杆 ← →       上一个 / 下一个       37 / 39
//    摇杆 中键      打开选中项            13  回车（确定）
//    左椭圆键 短按  提示设置在哪          27  ESC（程序里的返回/取消）
//    左键 **连按两下** ——                 回程序列表（系统级退出）
//    右椭圆键 短按  打开选中项            13  回车（确定）
//    侧边电源键     ——（不再是热区）      ——
//
//  关机状态下任何物理键都开机（推摇杆、中键、左右椭圆键）——
//  电源键不接热区之后，总得有一条能按出来的路，否则 App 一关就一直黑着。
//
//  左右两个椭圆键在运行中基本只服务程序本身（ESC / 回车）——
//  那两个键一旦兼任退出，程序自己的「返回上一级」「确定」就被抢掉。
//  唯一的例外是**左键双击**：退出是系统级动作，程序不会自己给这个入口，
//  而设置页只活在程序列表里，进游戏后不给退路就只剩杀 App 一条路。
//  双击不会干扰单次 ESC（第一下照常立刻发出去），
//  也不会在误触时退出（要 0.42 秒内按满两下）。
//
//  ── 屏幕上一个常驻控件都没有 ──
//  监控 / 日志 / 速度 / 返回 / 列表 / 开关机，全部收进**设置页**
//  （程序列表末行「设置」，`SettingsScreen`）。原先它们散在右上角三枚胶囊、
//  机身下方一枚按钮和侧边电源键上：右上角那一排正好压在灵动岛和状态栏底下，
//  下方那枚按钮把「这就是一台 9688」的观感拆掉了。
//
//  整台机器上**没有任何长按**：设置是一个能按出来的页面，不是一个手势。
//  侧边电源键也不再是热区 —— 关机在设置里，开机推一下摇杆。
//

import Foundation
import SwiftUI
import UIKit

/// 送进虚拟机的键码。
///
/// BBasic 用的是 SDL 那套 ASCII 码，原实现（`input_iml.cc`）把 37–40 映射到方向键、
/// 13 回车、27 退出。**要改键位就改这里**，下面所有逻辑都只引用这些常量。
enum BBKey {
    static let left: UInt32 = 37
    static let up: UInt32 = 38
    static let right: UInt32 = 39
    static let down: UInt32 = 40
    static let enter: UInt32 = 13
    static let escape: UInt32 = 27
    static let space: UInt32 = 32
}

struct DeviceView: View {
    @ObservedObject var app: AppModel

    /// 用来把 LCD 矩形对齐到物理像素网格 —— 见 screenLayer 里的说明
    @Environment(\.displayScale) private var displayScale

    /// 当前按住的键（用于点亮辉光）
    @State private var pressed: Set<String> = []
    /// 摇杆当前方向
    @State private var stickDirection: String?
    /// 摇杆长按连发
    @State private var repeatTimer: Timer?

    /// 这一笔触摸落在哪个热区上
    private enum Target: Equatable { case none, stick, back, menu, screen }
    @State private var target: Target = .none
    @State private var touching = false

    /// 这一笔触摸里，摇杆**有没有推出过方向**。
    /// 用来区分「没推 → 按的是中键」和「推出去又推回来 → 只是想换选项」，
    /// 抬手时不能只看向那一刻的方向（那时早已经被清成 nil 了）。
    @State private var stickMoved = false

    private static let repeatInterval: TimeInterval = 0.26

    /// 上一笔触摸事件的时刻（`DragGesture.Value.time`）。
    /// 用它判断「现在这一下是新的一笔触摸，还是同一笔拖拽的后续事件」，
    /// 见 `handleChanged` 里的说明 —— 这是「按钮会存储」那个 bug 的判据。
    @State private var lastTouchTime = Date.distantPast

    /// 新触摸的判定间隔。同一笔拖拽 60Hz 送事件（16ms），
    /// 两次真正抬手再按下必然更长；0.15s 两头都留了余量。
    private static let newGestureGap: TimeInterval = 0.15

    /// 摇杆进入判向的阈值（占半径的比例）。真机摇杆要推出去半程才响，
    /// 以前写 0.32，手指按在摇杆中间稍偏一点就被判成方向 —— 一按就自己走。
    private static let stickEngage: CGFloat = 0.50
    /// 退出判向的阈值：必须比 engage 小，形成滞回，边界上不会反复跳
    private static let stickRelease: CGFloat = 0.38

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height

            ZStack(alignment: .topLeading) {
                screenLayer(W: W, H: H)
                shellLayer(W: W, H: H)
                glowLayers(W: W, H: H)
                touchLayer(W: W, H: H)
            }
            .frame(width: W, height: H)
            .onDisappear { resetInteraction() }
        }
        .aspectRatio(DeviceMetrics.aspect, contentMode: .fit)
    }

    // MARK: - 屏幕

    private func screenLayer(W: CGFloat, H: CGFloat) -> some View {
        let rect = DeviceMetrics.screen.scaled(W, H)
        let scale = min(rect.width / CGFloat(DeviceMetrics.screenWidth),
                        rect.height / CGFloat(DeviceMetrics.screenHeight))

        // ★ 画面区必须严格保持 240:320 = 0.75，不能跟着玻璃区拉伸。
        //   DeviceMetrics.screen 是从机身图量出来的玻璃矩形，实测宽高比是 0.765，
        //   比 4:3.2 宽 2%。之前直接把 960×1280 的帧塞进这个矩形，等于横向拉宽 2%：
        //   圆变椭圆、字宽一点、而且目标像素尺寸和画布不成整数比，重采样怎么调都不干净
        //   —— 屏幕上就是「看上去整体偏了一点」。所以这里等比内切，差值交给黑边。
        let canvas = DeviceMetrics.canvasAspect
        // 再对齐一次物理像素：内切出来的宽是个小数（1175×0.75 = 881.25），
        // 保留这 0.25 就等于让下游每一帧都做一次「缩 0.9997 倍」的重采样。
        // 取整到整像素之后，引擎出图的像素数和这里的布局尺寸严格相等，可以 1:1 直贴。
        let fitted = rect.fitted(aspect: canvas).snappedToPixels(displayScale)

        // 玻璃反光用 .screen 叠在画面上，会整体提亮、压低对比 ——
        // 0.07 的白在黑底上等于凭空加 18/255 的灰，字会显得发灰发糊。
        // 运行中把反光减到 1/2，列表界面照旧（那里本来就该有玻璃感）。
        let glare: Double = app.mode == .running ? 0.032 : 0.07

        return ZStack {
            Color.black

            if app.mode == .running {
                // 尺寸按上面的等比矩形算，UI 端不再自己插值放大。
                FramebufferView(engine: app.engine, size: fitted.size)
            } else {
                // 列表 / 开机 / 本机信息都是矢量绘制的 240×320 界面，缩放不会糊
                screenContent
                    .frame(width: CGFloat(DeviceMetrics.screenWidth),
                           height: CGFloat(DeviceMetrics.screenHeight))
                    .scaleEffect(scale, anchor: .center)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(RoundedRectangle(cornerRadius: rect.width * 0.018, style: .continuous))
        .overlay(
            // 玻璃反光 + 轻微暗角
            LinearGradient(
                colors: [Color.white.opacity(glare), Color.white.opacity(glare * 0.2),
                         Color.clear, Color.white.opacity(glare * 0.42)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .blendMode(.screen)
            .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: rect.width * 0.018, style: .continuous)
                .stroke(Color.black.opacity(0.55), lineWidth: 1)
                .allowsHitTesting(false)
        )
        .offset(x: rect.minX, y: rect.minY)
    }

    @ViewBuilder
    private var screenContent: some View {
        switch app.mode {
        case .off:
            Color(red: 0.03, green: 0.035, blue: 0.05)
        case .boot:
            BootScreen()
        case .launcher:
            LauncherScreen(app: app)
        case .about:
            AboutScreen(programCount: app.programCount)
        case .settings:
            SettingsScreen(app: app)
        case .running:
            // 运行中的画面由 screenLayer 单独走 FramebufferView（需要知道 LCD 的实际尺寸），
            // 这里只是让 switch 完整，永远不会被显示。
            Color.black
        }
    }

    // MARK: - 机壳

    private func shellLayer(W: CGFloat, H: CGFloat) -> some View {
        Group {
            if let shell = AppArtwork.shell {
                Image(uiImage: shell)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: W, height: H)
                    // 阴影取自机壳自身的 alpha（屏幕那块是透明的），
                    // 所以投出来就是机身轮廓的投影，不会把屏幕也糊黑
                    .shadow(color: Color.black.opacity(0.45), radius: 26, x: 0, y: 14)
            } else {
                // 资源缺失时至少把热区留住，方便定位问题
                RoundedRectangle(cornerRadius: 40, style: .continuous)
                    .stroke(Color.gray.opacity(0.4), lineWidth: 2)
                    .frame(width: W, height: H)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 辉光

    private func glowLayers(W: CGFloat, H: CGFloat) -> some View {
        ForEach(Array(DeviceMetrics.glows.keys.sorted()), id: \.self) { key in
            if let box = DeviceMetrics.glows[key], let art = AppArtwork.glow(key) {
                let rect = box.scaled(W, H)
                Image(uiImage: art)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: rect.width, height: rect.height)
                    .opacity(pressed.contains(key) ? 1 : 0)
                    .animation(.easeOut(duration: 0.06), value: pressed.contains(key))
                    .blendMode(.screen)
                    .allowsHitTesting(false)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }

    // MARK: - 热区（一整块，自己判命中）

    private func touchLayer(W: CGFloat, H: CGFloat) -> some View {
        Color.clear
            .frame(width: W, height: H)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleChanged(value, W: W, H: H)
                    }
                    .onEnded { value in
                        handleEnded(value, W: W, H: H)
                    }
            )
    }

    private func handleChanged(_ value: DragGesture.Value, W: CGFloat, H: CGFloat) {
        let p = value.location

        // ★ 判定「这是新的一笔触摸」不能靠 `!touching`。
        //
        //   `touching` 只有在 onEnded 里才会落回 false，而 onEnded 会被系统手势吞掉
        //   （下拉通知中心、来电、切后台、面板弹出、来电横幅……）。一旦吞掉，
        //   `touching` 就一直挂着 true、`target` 也还记着上一轮那个按钮。
        //   用户再碰一下、松手，`handleEnded` 认的是**旧 target** —— 于是一个字都没按，
        //   程序却收到了「确定」：「按钮好像会存储，我一操作就自己开始了」。
        //
        //   同一笔拖拽的事件间隔是 16ms 量级，两次触摸之间必然远大于这个阈值，
        //   用它比用任何标志位都可靠。
        let isNewGesture = value.time.timeIntervalSince(lastTouchTime) > Self.newGestureGap
        lastTouchTime = value.time

        if isNewGesture || !touching {
            resetInteraction()
            touching = true
            target = hitTest(p, W: W, H: H)

            switch target {
            case .back:  pressed.insert("back")
            case .menu:  pressed.insert("menu")
            case .stick: pressed.insert("center")
            default:     break
            }
        }

        if target == .stick {
            updateStick(p, W: W, H: H)
        }
    }

    /// 机身坐标 → LCD 逻辑像素（0..239 / 0..319）。
    ///
    /// 用的是 `screenLayer` 里同一个「等比内切 + 对齐物理像素」矩形，
    /// 所以点在黑边上不会被算成画面内的点。
    private func screenPoint(_ p: CGPoint, W: CGFloat, H: CGFloat) -> (Int, Int)? {
        let rect = DeviceMetrics.screen.scaled(W, H)
        let fitted = rect.fitted(aspect: DeviceMetrics.canvasAspect).snappedToPixels(displayScale)
        guard fitted.width > 0, fitted.height > 0, fitted.contains(p) else { return nil }
        let fx = (p.x - fitted.minX) / fitted.width
        let fy = (p.y - fitted.minY) / fitted.height
        let x = Int(fx * CGFloat(DeviceMetrics.screenWidth))
        let y = Int(fy * CGFloat(DeviceMetrics.screenHeight))
        return (min(max(x, 0), DeviceMetrics.screenWidth - 1),
                min(max(y, 0), DeviceMetrics.screenHeight - 1))
    }

    private func handleEnded(_ value: DragGesture.Value, W: CGFloat, H: CGFloat) {
        let p = value.location
        var claimed = target
        let direction = stickDirection
        // 必须在 `resetInteraction()` 之前取走：它会把这一笔的摇杆状态清掉，
        // 而下面判断「是不是按了中键」要用的正是**抬手之前**的记录。
        let moved = stickMoved

        // 抬手的位置已经不在那个按键上了 → 这一下按真机是「取消」。
        // 以前认的是按下时的 target，手指从按键上滑出去再松开照样触发；
        // 面板一弹、手指顺势划走，就变成「我没按它，它自己按了」。
        // 摇杆不在此列：方向在拖动过程中就已经发出去了，抬手时只看是不是中键。
        if claimed == .back || claimed == .menu, hitTest(p, W: W, H: H) != claimed {
            claimed = .none
        }

        resetInteraction()
        touching = false
        target = .none

        switch claimed {
        case .back:
            // 左键：短按 = 程序里的返回（ESC）。
            //
            // 曾经还有一条「0.42 秒内连按两下 = 回程序列表」，已经去掉了：
            // 赌场、游乐场这类界面里玩家会连续按左键取消/返回，
            // 连按两下就整局退出，体感就是「这两个场景不能操作」。
            // 退出改走快捷面板里那个显式的「返回程序列表」，不再占用左键。
            switch app.mode {
            case .running:  app.sendKey(BBKey.escape)
            case .about, .settings: app.back()
            case .launcher: app.hint("设置在最下面一行")
            case .off:      app.boot()
            case .boot:     break
            }

        case .menu:
            // 右键和左边对称，运行中只服务程序（回车/确定），不做系统级退出
            switch app.mode {
            case .running:  app.sendKey(BBKey.enter)
            case .launcher: app.confirm()
            case .about:    app.back()
            case .settings: app.settingsActivate()
            case .off:      app.boot()
            default:        break
            }

        case .screen:
            // 屏幕点击 = 鼠标左键。
            //
            // 原 VM（reference/bbasic/src/bbvm/input_iml.cc）里 WaitKey 是**键盘和鼠标共用
            // 一条通道**的：KEYDOWN 返回键码，MOUSEBUTTONDOWN 且 OnlyKeyboard==false 时
            // 返回 `(y<<16|x) | 0x80000000`。赌场、游乐场调的就是 WaitKey(false) ——
            // 只给方向键和回车是动不了的，必须点屏幕。
            //
            // 以前这里整个禁掉了（理由写着「9688 不是触屏」），结果那两个场景
            // 进得去、动不了。现在按原 VM 的语义把点击喂回去。
            //
            // 只认「点」不认「划」：总位移超过 12pt 当成拖拽，避免手指从屏幕上滑过
            // 时被当成点击（这机器的手势层同时还在处理摇杆和按键）。
            if app.mode == .running {
                let travel = hypot(value.translation.width, value.translation.height)
                if travel < 12, let pt = screenPoint(p, W: W, H: H) {
                    app.tap(x: pt.0, y: pt.1)
                }
            } else if app.mode == .off {
                // 关机状态点一下当开机。电源键已经不接热区了，
                // 留一条能叫醒它的路，免得有人以为 App 卡死。
                app.boot()
            }

        case .stick:
            // 只有「从头到尾没推出方向」才算按了中键。
            //
            // ★ 必须看 `stickMoved`，不能只看抬手这一刻的 `direction`。
            //   摇杆推出去选完、再推回中心再松手，`stickDirection` 会在回中心那一刻
            //   被清成 nil（见 `updateStick`），于是「推出过又回中」和「压根没推」
            //   在抬手时长得一模一样 —— 程序列表里表现为：只是推摇杆换了个选中项，
            //   一松手就直接把程序启动了（用户：『按钮好像会存储，我一操作就开始』）。
            //   真机上 4 向是摇臂、中键是独立的按钮，推过方向不可能等于按了中键。
            if direction == nil, !moved {
                switch app.mode {
                case .launcher: app.confirm()
                case .running:  app.sendKey(BBKey.enter)
                case .settings: app.settingsActivate()
                case .off:      app.boot()
                default:        break
                }
            }

        case .none:
            break
        }
    }

    private func hitTest(_ p: CGPoint, W: CGFloat, H: CGFloat) -> Target {
        // 侧边电源键**不再是热区**：开关机已经收进隐藏菜单（长按机头）。
        // 照片上那道银键还在（壳是实拍的，不能擦掉），但按它什么都不发生 ——
        // 一台机器上同一个功能有两个入口，久了必然出现「按这个没反应」的困惑。

        // 摇杆（圆）
        let radius = DeviceMetrics.stickRadius * W
        let center = CGPoint(x: DeviceMetrics.stickCenter.x * W,
                             y: DeviceMetrics.stickCenter.y * H)
        let dx = p.x - center.x
        let dy = p.y - center.y
        if dx * dx + dy * dy <= radius * radius { return .stick }

        if DeviceMetrics.backButton.scaled(W, H).contains(p) { return .back }
        if DeviceMetrics.menuButton.scaled(W, H).contains(p) { return .menu }
        if DeviceMetrics.screen.scaled(W, H).contains(p) { return .screen }
        return .none
    }

    // MARK: - 摇杆判向

    private func updateStick(_ p: CGPoint, W: CGFloat, H: CGFloat) {
        let radius = DeviceMetrics.stickRadius * W
        guard radius > 0 else { return }
        let center = CGPoint(x: DeviceMetrics.stickCenter.x * W,
                             y: DeviceMetrics.stickCenter.y * H)

        let dx = p.x - center.x
        let dy = p.y - center.y
        let distance = sqrt(dx * dx + dy * dy) / radius

        // 松开阈值跟着当前状态走（滞回）
        let threshold = stickDirection == nil ? Self.stickEngage : Self.stickRelease
        if distance < threshold {
            if stickDirection != nil {
                stickDirection = nil
                stopRepeat()
                app.flushInput()
                pressed.remove("up"); pressed.remove("down")
                pressed.remove("left"); pressed.remove("right")
                pressed.insert("center")
            }
            return
        }

        // 从这里往下就是「推出了方向」。记一笔：这笔触摸之后哪怕再推回中心，
        // 抬手时也不能算作按了中键（判据见 `handleEnded` 的 `.stick` 分支）。
        stickMoved = true

        // 四向按「主轴分量大的那个」判，比 atan2 分象限稳，斜推不会在边界抖
        let direction: String
        if abs(dx) >= abs(dy) {
            direction = dx > 0 ? "right" : "left"
        } else {
            direction = dy > 0 ? "down" : "up"
        }

        guard direction != stickDirection else { return }
        stickDirection = direction
        pressed.remove("up"); pressed.remove("down")
        pressed.remove("left"); pressed.remove("right")
        pressed.remove("center")
        pressed.insert(direction)

        stopRepeat()          // 换方向先掐掉旧连发，免得两个方向交替推
        fire(direction)
        beginRepeat(direction)
    }

    /// 一个方向键真正要干的事
    private func fire(_ direction: String) {
        // 设置页：上下换行。左右**故意不接动作** —— 斜推时判向偶尔落到左右，
        // 若左右也改值，速度会莫名其妙跳档。
        if app.mode == .settings {
            switch direction {
            case "up":   app.settingsMove(-1)
            case "down": app.settingsMove(1)
            default:     break
            }
            return
        }
        // 关机状态下推摇杆就是开机（电源键已经不是热区，这是唯一的物理开机方式）
        if app.mode == .off {
            app.boot()
            return
        }
        switch direction {
        case "up":    app.move(-1); app.sendKey(BBKey.up)
        case "down":  app.move(1);  app.sendKey(BBKey.down)
        case "left":  app.sendKey(BBKey.left)
        default:      app.sendKey(BBKey.right)
        }
    }

    /// 按住不放时连发，和真机一样。定时器每次醒来都先核对状态，
    /// 方向变了、手指抬了、视图走了就自尽 —— 不让它变成脱缰的野马。
    private func beginRepeat(_ direction: String) {
        stopRepeat()
        let timer = Timer(timeInterval: Self.repeatInterval, repeats: true) { [self] _ in
            DispatchQueue.main.async {
                // 方向变了、手指抬了、视图走了 —— 定时器自己下台
                guard self.touching, self.stickDirection == direction else {
                    self.stopRepeat()
                    return
                }
                self.fire(direction)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
    }

    /// 把这一笔触摸留下的所有瞬时状态清干净
    private func resetInteraction() {
        stopRepeat()
        stickDirection = nil
        stickMoved = false
        pressed.removeAll()
        app.flushInput()
    }
}

// MARK: - 虚拟机画面

/// 画面这一格**不订阅** engine 的每一帧，只订阅它的状态（运行中 / 退出原因）。
/// 24fps 的那条路已经彻底离开 SwiftUI：引擎写 `CALayer.contents`，
/// 外层的机壳、按键、手势层一帧都不会被重建 ——
/// 否则 DragGesture 每秒被拆掉重装二十几次，onEnded 丢失，摇杆就会「粘住」，
/// 表现成「手早松了，游戏里还自己走」。
///
/// 画面清晰度也在这里把关：engine 产出的图已经是「LCD 点尺寸 × displayScale」的
/// 物理像素图（最近邻放大 / 面积平均缩小，都不振铃），所以这里只做 1:1 贴图。
struct FramebufferView: View {
    @ObservedObject var engine: MachineEngine
    /// LCD 在屏幕上的点尺寸
    let size: CGSize

    @Environment(\.displayScale) private var displayScale

    /// 引擎要产出的**整数**像素尺寸
    private var pixelSize: CGSize {
        CGSize(width: max(1, (size.width * displayScale).rounded()),
               height: max(1, (size.height * displayScale).rounded()))
    }

    /// 由整数像素尺寸反推的点尺寸。
    ///
    /// ★ 这两个尺寸必须严格互为倒数，否则画面会「右边一小节跑到左边」。
    ///   原来的布局用的是 `fitted.size`，它是 293.75pt（881.25px），而引擎产出
    ///   `round(881.25) = 881px`。差这 0.25px，SwiftUI 就会拿 `.high`（Lanczos 级）
    ///   把整张图重采样一遍：最左一格的目标像素中心映射到源坐标 -0.5 附近，
    ///   4 抽头里有个 `src[-1]` 越界；缓冲区是紧贴排布的，`-1` 正好是**上一行最后一格**
    ///   —— 也就是右边缘。于是每一行最左边都贴一条右边缘的内容。
    ///   画面上的观感就是「所有位图都有右侧一小条跑到左侧」，而且和资源、和 HD/SD 无关，
    ///   只跟这条显示链路有关。
    ///   这里把布局尺寸取整到像素，引擎再按同一个整数出图，1:1 贴上去，不做任何重采样。
    private var pointSize: CGSize {
        CGSize(width: pixelSize.width / displayScale,
               height: pixelSize.height / displayScale)
    }

    var body: some View {
        ZStack {
            Color.black
            // ★ 这里**不再**是 `Image(decorative: cg)`。
            //
            //   以前每出一帧（24fps）就换一个 `Image` 值，等于让 SwiftUI 每秒做 24 次
            //   视图 diff。2026-10-26 12:19 的崩溃就死在那一轮 diff 里：
            //     ViewGraph.beginNextUpdate → doDecrementSlow → _swift_release_dealloc
            //   x0 = 0、故障地址 0xfffffffffffffff0 —— 释放了一个根本不存在的对象。
            //   屏幕内容只是一张位图，交给 `CALayer.contents` 就够：
            //   引擎每出一帧直接写图层内容（主线程、普通属性赋值），
            //   SwiftUI 这边一帧都不重建，也就没有 diff 会被打乱。
            LCDLayerView(engine: engine,
                         pixelSize: pixelSize,
                         displayScale: displayScale)
                .frame(width: pointSize.width, height: pointSize.height)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .onAppear { engine.setOutputPixelSize(pixelSize) }
        .onChange(of: pixelSize) { _ in engine.setOutputPixelSize(pixelSize) }
    }
}

/// 只负责把 `CGImage` 贴到 `layer.contents` 的一层 UIView。
/// 没有子视图、没有 layoutSubviews、没有 draw(_:) —— CA 直接上传纹理。
final class LCDPlainView: UIView {
    override class var layerClass: AnyClass { CALayer.self }
}

/// `FramebufferView` 的贴图层。
struct LCDLayerView: UIViewRepresentable {
    let engine: MachineEngine
    /// 引擎要产出的整数像素尺寸
    let pixelSize: CGSize
    let displayScale: CGFloat

    func makeUIView(context: Context) -> LCDPlainView {
        let view = LCDPlainView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.layer.contentsGravity = .resize
        view.layer.magnificationFilter = .nearest
        view.layer.minificationFilter = .nearest
        view.layer.isOpaque = true
        attach(to: view)
        // 视图是「运行中」才出现的，挂上来的这一刻引擎里可能已经有帧了
        // （帧泵比视图早一点起来），先贴一张，避免闪一下黑。
        if let cg = engine.image { view.layer.contents = cg }
        engine.setOutputPixelSize(pixelSize)
        return view
    }

    func updateUIView(_ view: LCDPlainView, context: Context) {
        view.layer.contentsScale = displayScale
        attach(to: view)
        // 尺寸没变时 `setOutputPixelSize` 是空操作，不会额外出图
        engine.setOutputPixelSize(pixelSize)
        // 从列表切回运行态时，引擎里可能已经有一帧了，先贴上去免得闪一下黑
        if view.layer.contents == nil, let cg = engine.image {
            view.layer.contents = cg
        }
    }

    /// 引擎每出一帧就往这个图层写一次。`weak view` 保证视图被拆掉后不会留悬空引用。
    private func attach(to view: LCDPlainView) {
        engine.frameSink = { [weak view] cg in
            view?.layer.contents = cg
        }
    }
}

// MARK: - 百分比 → 点

extension CGRect {
    func scaled(_ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(x: minX * width,
               y: minY * height,
               width: self.width * width,
               height: self.height * height)
    }

    /// 在本矩形内按给定宽高比**等比内切**并居中（不会拉伸，多出来的部分是黑边）
    func fitted(aspect: CGFloat) -> CGRect {
        guard aspect > 0, width > 0, height > 0 else { return self }
        if height * aspect <= width {
            // 高度顶满，左右各留一条黑边
            let w = height * aspect
            return CGRect(x: minX + (width - w) / 2, y: minY, width: w, height: height)
        }
        // 宽度顶满，上下各留一条黑边
        let h = width / aspect
        return CGRect(x: minX, y: minY + (height - h) / 2, width: width, height: h)
    }

    /// 四条边都对齐到整物理像素（scale = displayScale）。
    ///
    /// 取整之后 `width * scale` 是整数，引擎按同一个整数出图，
    /// 布局尺寸和图像像素数严格相等 —— SwiftUI 就不会再做一次重采样。
    /// 留着小数的后果见 `FramebufferView.pointSize` 的注释。
    func snappedToPixels(_ scale: CGFloat) -> CGRect {
        guard scale > 0 else { return self }
        return CGRect(x: (minX * scale).rounded() / scale,
                      y: (minY * scale).rounded() / scale,
                      width: max(1, (width * scale).rounded()) / scale,
                      height: max(1, (height * scale).rounded()) / scale)
    }
}
