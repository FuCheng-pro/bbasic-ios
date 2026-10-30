//
//  BB9688App.swift
//  BB9688
//
//  步步高 9688 的 BBVM 虚拟机。整个 App 就是一台机器：外面什么都不放。
//

import SwiftUI
import UIKit

@main
struct BB9688App: App {
    @StateObject private var app = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                // 机身是白色塑料，展台用深色才立得起来；
                // 浅色背景会让白色的机身外缘和背景糊成一片，那就是「白边」的来源。
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase

    /// 监控 / 日志 / 速度都从 `BBSettings` 来。
    /// 原先这里是三个 `@AppStorage`，但设置页在 LCD 里用摇杆改值，
    /// 「改完要不要重开采样」这种副作用需要一个确定的发生点 —— 见 BBSettings 的注释。
    @ObservedObject private var settings = BBSettings.shared

    /// 右上角齿轮展开的面板。**不持久化**：它是临时面板，
    /// 记住「上次开着」只会在下次启动时莫名挡一层。
    @State private var showPanel = false

    /// 齿轮的视觉直径。34 是「看得见、点得到」和「不抢机身」之间的折中：
    /// 再小就要在噪点背景上瞪眼找，再大就开始像悬浮窗了。
    private static let gearSize: CGFloat = 34
    /// 齿轮上沿离安全区的距离
    private static let gearPadTop: CGFloat = 4
    /// 齿轮下沿到机身顶的距离
    private static let gearGap: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let H = geo.size.height

            // 宽度优先铺满整个屏幕；只有屏幕特别矮（iPhone SE 那种）时才让高度说话。
            // 机身比 iPhone 还瘦长（0.5807 vs 0.461），所以约束永远来自宽度 ——
            // 想再放大只能裁机身左右，那会把真机轮廓和侧边电源键一起切掉，不做。
            let deviceW = min(W, H * DeviceMetrics.aspect)
            let deviceH = deviceW / DeviceMetrics.aspect

            // ── 顶部操作带 ────────────────────────────────────────────────
            // 整个界面 `ignoresSafeArea`（机身要画到屏幕最边上），所以拿不到
            // SwiftUI 的安全区，只能自己去窗口问一次状态栏/灵动岛的高度。
            // 上一轮那排胶囊的顶边算出来是 21.5pt —— 正压进灵动岛，用户说的
            // 「挡住了」就是它。这次所有系统控件都从安全区之下开始。
            let safeTop = Self.safeTop
            let bandTop = safeTop + Self.gearPadTop
            let bandBottom = bandTop + Self.gearSize + Self.gearGap

            let slack = max(0, H - deviceH)
            // 顶部腾得出操作带吗？腾得出就让机身从带子下面开始；
            // 腾不出（矮屏）宁可让齿轮压在机头上，也不为了按钮把机器缩小一圈 ——
            // 这台机器的尺寸是用户认过的，不能因为一个系统按钮回退。
            let reserveBand = slack >= bandBottom + 56
            let deviceTop = reserveBand ? bandBottom : slack * 0.34
            let bottomGap = max(0, H - deviceTop - deviceH)

            ZStack(alignment: .top) {
                backdrop(deviceW: deviceW, deviceH: deviceH)

                // 机身底部的接触阴影，让机器像是立在台面上（画在机身下层）
                Ellipse()
                    .fill(RadialGradient(
                        colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                        center: .center,
                        startRadius: 1, endRadius: deviceW * 0.55
                    ))
                    .frame(width: deviceW * 1.02, height: deviceH * 0.075)
                    .blur(radius: 16)
                    .offset(y: deviceTop + deviceH - deviceH * 0.030)
                    .allowsHitTesting(false)

                // 金手指挂在机身上而不是根视图上：SwiftUI 对「同一个视图挂两个 `.sheet`」
                // 的支持一直不稳（旧系统上只有最后一个生效），
                // 日志面板已经占了根视图那一个，这个只能挂到别处。
                DeviceView(app: app)
                    .frame(width: deviceW, height: deviceH)
                    .offset(y: deviceTop)
                    .sheet(isPresented: $app.showCheatSheet) {
                        CheatSheet(cheat: app.cheat)
                    }

                // 监控条贴在机头顶部的白塑料区：LCD 从机身 11% 处才开始，
                // 这条 60pt 的条子落在它上面，既不挡画面也不压按键。
                // 只在展开时创建视图。注意：收起后**采样定时器未必停** ——
                // 日志开着的话 `PerfHub` 还要每秒采一次写文件（见 `syncPerf`）。
                if app.mode == .running, settings.showPerf {
                    PerfHUDView(stepProvider: { [engine = app.engine] in engine.vmStepCount },
                                width: min(deviceW - 40, 360))
                        .offset(y: deviceTop + 7)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }

                if bottomGap > 60 {
                    // ⚠️ padding 必须写在 frame **之前**：写反了 padding 会撑到
                    // 全尺寸 frame 外面，整块被居中后只剩一半偏移 —— 顶部操作带
                    // 那样写会把齿轮顶回灵动岛底下。
                    hint
                        .padding(.bottom, 34)          // 让开 Home 指示条
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .allowsHitTesting(false)
                }

                // 右上角齿轮。它会一直存在（关机/开机动画时除外），
                // 因为「正在玩游戏却出不去」的根因就是入口只在机器界面里。
                if app.mode != .off, app.mode != .boot {
                    gearButton
                        .padding(.top, bandTop)
                        .padding(.trailing, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                if showPanel {
                    panelLayer(W: W, H: H, top: bandBottom + 6)
                }
            }
            .frame(width: W, height: H)
        }
        .ignoresSafeArea()
        // 用户去「文件」里拖了新的程序目录再切回来，列表要自己长出新行。
        // 只在列表态刷新：运行中重建 rows 会打断 VM 的手势/按键状态。
        .onChange(of: scenePhase) { phase in
            if phase == .active, app.mode == .launcher || app.mode == .off {
                app.refreshPrograms()
            }
            // 切前后台写进日志：iOS 在后台会把进程挂起，
            // 前后两条样本之间出现「一大段空白」时，靠这两行才能解释清楚。
            switch phase {
            case .active:   PerfLog.shared.event("App 回到前台")
            case .background: PerfLog.shared.event("App 进入后台")
            default: break
            }
        }
        // 监控 / 日志 / 运行态，任一变化都重新决定「要不要采样」。
        // 三个入口都走同一个 `syncPerf()`，状态才不会各说各话。
        // 速度不在这里处理：`BBSettings.speed` 的 didSet 自己负责同步 VM。
        .onAppear { syncPerf() }
        .onChange(of: settings.showPerf) { _ in syncPerf() }
        .onChange(of: settings.logEnabled) { _ in syncPerf() }
        .onChange(of: app.mode) { _ in
            syncPerf()
            // 状态一变（返回 / 关机 / 程序退出）就收起面板：
            // 面板里写的是「这局」的东西，换了局再留着就是错的。
            withAnimation(.easeIn(duration: 0.16)) { showPanel = false }
            // 返回列表 / 关机 / 程序退出时顺手关掉金手指面板：
            // 它写的是「这一局」的内存，换局之后那些数字已经没有意义了
            app.showCheatSheet = false
        }
        .sheet(isPresented: $app.showLogSheet) {
            PerfLogSheet(enabled: $settings.logEnabled)
        }
    }

    /// 把「界面上的三个开关」翻译成「采样层要干的事」。
    ///
    /// 采样本来是监控条自己 onAppear/onDisappear 起停的，但日志要能在
    /// **监控条收起来**的情况下继续记 —— 所以起停权收回到这里：
    /// 谁要看数谁声明需求，需求空了一起停，计时器不会白转。
    private func syncPerf() {
        let running = app.mode == .running
        let provider: () -> UInt64 = { [engine = app.engine] in engine.vmStepCount }

        PerfHub.shared.demand(.hud, on: running && settings.showPerf, stepProvider: provider)
        PerfHub.shared.demand(.log, on: running && settings.logEnabled, stepProvider: provider)
        PerfLog.shared.setActive(settings.logEnabled)
    }

    // MARK: - 系统入口

    /// 状态栏 / 灵动岛的高度（点）。
    ///
    /// 整个界面 `ignoresSafeArea`（机身要画到屏幕最边上），SwiftUI 的安全区
    /// 在这里读不到值，只能自己去窗口问一次。本 App 只有竖屏、不旋转，
    /// 取一次的结果在整个生命周期里都成立。
    @MainActor
    private static var safeTop: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?.keyWindow
            ?? scenes.first?.keyWindow
        return window?.safeAreaInsets.top ?? 47
    }

    /// 右上角齿轮。
    ///
    /// 它和机身的关系是**系统与设备**的关系：齿轮是 iOS 侧的东西，
    /// 所以用深色玻璃 + 白图标；机器侧的东西一律是纸白点阵（见 `SettingsScreen`）。
    /// 两层刻意不共用一套视觉，混在一起就成了「App 里套了个 App」。
    private var gearButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            // 面板一出来就会吃掉机身上的手势，onEnded 于是永远不来。
            // 先把按住状态全松开，免得面板开着的这段时间游戏里有个键一直按着
            // （轮询型程序的表现是「小鸟自己往上飞」）。
            app.releaseHeldKeys()
            withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                showPanel.toggle()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color(red: 0.085, green: 0.094, blue: 0.112).opacity(0.94))
                    .overlay(
                        Circle().stroke(Color.white.opacity(showPanel ? 0.28 : 0.15),
                                        lineWidth: 0.8)
                    )

                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundColor(Color.white.opacity(showPanel ? 0.98 : 0.76))
                    // 展开时转 30°：齿轮转动是最省事的「我开了」提示，
                    // 比换图标颜色更早被余光捕捉到。
                    .rotationEffect(.degrees(showPanel ? 30 : 0))

                // 记录中在角上点一颗红点：不开面板也知道日志在不在写。
                // 位置贴着圆边、外面描一圈底色，深色背景上才立得住。
                if settings.logEnabled {
                    Circle()
                        .fill(Color(red: 0.98, green: 0.35, blue: 0.33))
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle().stroke(Color(red: 0.085, green: 0.094, blue: 0.112),
                                            lineWidth: 1.4)
                        )
                        .offset(x: 11.5, y: -11.5)
                }
            }
            .frame(width: Self.gearSize, height: Self.gearSize)
            .shadow(color: Color.black.opacity(0.5), radius: 9, x: 0, y: 3)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        // 视觉 34，可点 44 —— 圆比 44 小时手指会频繁按到边缘外
        .frame(width: 44, height: 44)
        .accessibilityLabel("设置")
        .accessibilityHint("展开运行监控、日志、速度、返回程序列表")
    }

    /// 遮罩 + 面板。
    ///
    /// 遮罩不是装饰：面板浮在机身上，没有遮罩时「点空白关闭」无处落手，
    /// 而且机身的按键热区会继续响应 —— 点一下面板外面，游戏里的人物就动了。
    /// 所以这里盖一层 28% 的黑，既压暗机身表示「现在归面板」，也吃掉所有触摸。
    private func panelLayer(W: CGFloat, H: CGFloat, top: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            Color.black.opacity(0.28)
                .frame(width: W, height: H)
                .contentShape(Rectangle())
                .onTapGesture { closePanel() }
                .transition(.opacity)

            QuickPanelView(app: app,
                           settings: settings,
                           width: min(262, W - 24),
                           onClose: { closePanel() })
                .padding(.top, top)
                .padding(.trailing, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .topTrailing)))
        }
    }

    private func closePanel() {
        withAnimation(.easeIn(duration: 0.16)) { showPanel = false }
    }

    /// 展台：深色冷灰底 + 机身背后一团柔光
    private func backdrop(deviceW: CGFloat, deviceH: CGFloat) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.075, green: 0.082, blue: 0.098),
                         Color(red: 0.129, green: 0.141, blue: 0.165)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [Color.white.opacity(0.16), Color.white.opacity(0)],
                center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 1, endRadius: max(deviceW, deviceH) * 0.62
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var hint: some View {
        switch app.mode {
        case .off:
            hintText("推一下摇杆开机")
        case .launcher:
            hintText("摇杆选择　中键运行　右上角齿轮是设置")
        case .running:
            // 运行中不再浮提示：右上角齿轮就是出口，看得见摸得着。
            // （左键双击那条快捷方式还在，只是不再需要拿文字教一遍。）
            EmptyView()
        default:
            EmptyView()
        }
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .regular))
            .foregroundColor(Color.white.opacity(0.62))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(Color.white.opacity(0.07))
            )
            .transition(.opacity)
    }
}
