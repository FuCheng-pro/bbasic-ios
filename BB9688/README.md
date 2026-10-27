# BB9688 · iOS

步步高 9688（BBK 外语通）的 BBVM 虚拟机，SwiftUI 原生实现。
界面是一台机器：机壳、按键、Logo 全部来自真机照片，屏幕上跑的是真实的 `.bin` 字节码。

> 指令集、端口语义与 `.LIB` 格式参考开源项目 [0ximst1ll/bbasic](https://github.com/0ximst1ll/bbasic)（C++ 实现），本文中的 `bbvm.cc` 即出自该仓库。

**两条构建路线，同一批源码：**

| 环境 | 命令 | 说明 |
|---|---|---|
| WSL / Linux | `./build.sh xtool` | 用 [xtool](https://xtool.sh) 交叉编译，不需要 Mac |
| macOS | `./build.sh run` | 用 Xcode + 模拟器 |

```
xtool setup          # 第一次：装 Darwin SDK（约 1~2 GB）
cd BB9688 && xtool dev build
```

或者直接 `open BB9688.xcodeproj`（Xcode 15+，iOS 16+）。

---

## 一、当前进度

| 模块 | 状态 | 说明 |
|---|---|---|
| BBVM 指令集 | ✅ | LD/PUSH/POP/IN/OUT/JMP/JPC/CALL/RET/CMP/CAL/EXIT，指令长度与寻址编码逐条对齐 `bbvm.cc` |
| 端口 0–80 | ✅ | 字符串池、文件 IO、9 张画布、图片资源、画笔图元、延时、按键 |
| 文字渲染 | ✅ | CoreText 实现 `BBTextRenderer`，宋/楷/黑 × 12/16/24；前景色、字宽、行网格按原实现对齐（见四点五） |
| 图形渲染 | ✅ | 软件画布 240×320，Bresenham 直线、矩形、圆、色键贴图 |
| 画面清晰度 | ✅ | vImage Lanczos 重采样 + 十字锐化，按物理像素 1:1 出图（见四点五·7） |
| 整机界面 | ✅ | 照片机壳 + LCD + 按键辉光 + 摇杆/热区 |
| 内置程序 | ✅ | 大富翁 / Flappy Bird / MAN 演示 |
| 程序导入 | ⏳ | 已开 `UIFileSharingEnabled`，还差一个导入面板 |

三个示例都已在无头工具里跑通并逐像素比对过 PC 版截图（见 `Tools/headless`）。

---

## 二、目录

```
BB9688/
├─ BB9688.xcodeproj/            ← make_project.py 生成，勿手改
├─ make_project.py              增删源文件后重跑
├─ Package.swift                ← xtool / SwiftPM 用
├─ xtool.yml                    ← xtool 配置：bundleID、入口产品、Info.plist
├─ Support/Info-xtool.plist     ← xtool 专用（会被 merge 到 xtool 生成的 plist 上）
├─ build.sh
└─ BB9688/
   ├─ App/
   │  ├─ BB9688App.swift        入口 + 展台背景
   │  ├─ AppModel.swift         状态机：关机/开机/列表/运行/关于
   │  └─ AppResources.swift     吸收 Xcode 与 SwiftPM 的资源路径差异
   ├─ Device/
   │  ├─ DeviceMetrics.swift    机身几何（百分比，来自实测）
   │  └─ DeviceView.swift       机壳 + LCD + 辉光 + 热区
   ├─ Screen/
   │  ├─ MachineEngine.swift    VM 线程 + 24fps 取帧 + 程序落盘
   │  └─ CoreTextRenderer.swift 文字渲染
   ├─ Launcher/
   │  └─ LauncherView.swift     开机、程序列表、本机信息（240×320 排版）
   ├─ Core/                     ← 与 UI 完全解耦，可在 PC 上单独编译
   │  ├─ BBVM.swift             指令解释器
   │  ├─ BBVMPorts.swift        IN 0–39 / OUT 0–80
   │  ├─ BBMemory.swift         2MB 线性内存
   │  ├─ BBSurface.swift        32 位画布与图元
   │  ├─ BBScreen.swift         输出光标、换行、LOCATE
   │  ├─ BBRenderer.swift       画布池、资源库（.LIB 解码）、画笔
   │  ├─ BBStorage.swift        文件端口
   │  ├─ BBStringPool.swift     字符串句柄（-1 向下分配）
   │  ├─ BBInput.swift          按键/触摸队列
   │  ├─ BBText.swift           文字渲染协议
   │  └─ BBFoundation.swift     常量、GBK、随机数
   └─ Resources/
      ├─ device-shell.png       机身（屏幕区已挖空）
      ├─ glow-*.png             按键按下时的辉光层
      └─ Programs/              .bin + .LIB，整体以文件夹引用进 bundle
```

### 两条构建路线为什么都能过

| | Xcode | xtool |
|---|---|---|
| 产品类型 | `.app` target | SwiftPM `.library`（xtool 负责链接成可执行） |
| 资源位置 | app bundle 根目录 | `BB9688_BB9688.bundle` |
| 代码里怎么取 | `Bundle.main` | `Bundle.module` |

差异只在 `AppResources.swift` 里用 `#if SWIFT_PACKAGE` 吸收，其它文件不用改。

---

## 三、界面是怎么做的

机身不是画出来的，是从产品图上抠的：

1. 逐行/逐列扫外轮廓，超采样生成 alpha，屏幕玻璃区圆角挖空；
2. 原图左侧有侧键凸起，按 `L(y) = 2·CX − R(y)` 用右侧轮廓镜像出左侧，并把右侧 80px 条带镜像过去补像素 —— 左右严格对称；
3. 按键**不重绘**：按下时叠一层同源照片提亮的辉光（`glow-*.png`，蓝通道泛光 + bloom），`blendMode(.screen)` 贴上去，位置用实测百分比坐标，零失真。

所有几何集中在 `DeviceMetrics.swift`，是百分比，所以任何屏幕尺寸下都不会错位：

| 元素 | x | y | w | h |
|---|---|---|---|---|
| 屏幕 | 11.648% | 12.955% | 76.264% | 57.881% |
| 左椭圆键 | 6.374% | 79.579% | 23.407% | 7.530% |
| 右椭圆键 | 69.341% | 79.706% | 23.077% | 7.403% |
| 摇杆圆心 | 49.505% | 83.376% | 半径 15.03%（按宽度） | |

换一张更清晰的产品图 → 改 `Prototype/build_shell.py` 的 `SRC` 重跑 → 把新 JSON 的数字抄进 `DeviceMetrics.swift`。

---

## 四、按键映射

9688 是**按键机，没有触屏**，所以键位按真机习惯来，不给程序塞它不需要的键。

| 机身键 | 程序列表 | 运行中 |
|---|---|---|
| 摇杆 上 / 下 | 上一个 / 下一个 | `38` / `40` |
| 摇杆 左 / 右 | 上一个 / 下一个 | `37` / `39` |
| 摇杆 中键 | 打开选中项 | `13` Enter |
| 左椭圆键 | 提示「用电源键关机」 | `27` ESC（交给程序，不替你退） |
| 右椭圆键 | 打开选中项 | `13` Enter |
| 机身下方「← 程序列表」 | — | 回程序列表（独立按键） |
| 左侧银键 | 开 / 关机 | 开 / 关机 |

**全部是短按，没有任何长按。**

三条设计原则：

1. **左右两个椭圆键只服务程序本身**（ESC / 回车）。它们一旦兼任「回列表」，
   程序自己的「返回上一级」「确定」就被抢掉，用起来处处别扭 —— 这也是之前
   「按键不合理」的根子。
2. **「回列表」是一枚独立的按键**，只干这一件事、单击即生效。
   机身照片上只有三颗键 + 侧边电源键，挤不出第四个实体键位；而屏幕里每个角都是
   游戏画面（大富翁底部就是状态栏），压在屏内会挡内容。最后放在**机身下方**：
   机身比 iPhone 瘦长，竖屏时下方天然空出 175pt，正够放一枚 44pt 高的胶囊按钮。
   只有屏幕特别矮（`slack < 104`，比如横屏或 SE）时才退回 LCD 右下角那枚小键。
3. **列表里左键不再关机**，改成提示用侧边电源键 —— 误触成本太高。

摇杆判向：

- 阈值 **50% 半径**进入、**38% 半径**退出（滞回，边界不抖）；
- 四向按「主轴分量大的那个」判，斜推不会在 `atan2` 的象限边界上来回跳；
- 方向变化才触发一次，之后每 0.26s 连发；
- 圆心 50% 以内松手 = 中键「确定」；
- **判向用相对圆心**，不是相对落指位置 —— 和真机摇杆的视觉一致。

单点屏幕**不做任何事**（9688 没有触摸屏）。以前会把点击编码 `(y<<16|x)|0x80000000`
塞进按键队列，程序读出来当键码用，这也是「没按它自己动」的来源之一。

**要改键位**：键码集中在 `Device/DeviceView.swift` 顶部的 `enum BBKey`，下面所有逻辑
只引用这些常量；哪颗物理键对应哪个键码，看同一文件里 `handleEnded` 和 `fire` 两个方法。

---

## 四点五、关键修复（踩坑记录）

### 1. 汉字画不出来 —— CoreText 的前景色

`CTLineDraw` **不读上下文的 `setFillColor`**。属性里既没有 `kCTForegroundColorAttributeName`、
`kCTForegroundColorFromContextAttributeName` 又是默认的 `false` 时，CoreText 一律按**黑色**画。
而我们把字形画进「灰度位图当 alpha 蒙版」时铺的是黑底 → 黑底画黑字 → 蒙版全 0 → 屏幕上没有字。

修法：显式给白色前景色。

```swift
NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
```

同时补了两处：

- **字体名归一化**。`UIFont(name:)` 能吃家族名（`"Songti SC"`），但 `CTFontCreateWithName` 只认
  PostScript 名（`"STSongti-SC-Regular"`），喂家族名会**静默**退回 Helvetica —— 于是数字正常、
  汉字全缺。现在统一取 `font.fontName` 再建字体。
- **按字符串挑字体**。用 `CTFontCreateForString` 保证这段文字有字体能画，宋/楷不完整时自动降级。

### 2. LOCATE / 制表列宽

原实现 `FontWidth = TTF_SizeText(" ")`，用的是 `simsun / simkai / simhei`，这三套字体的空格**恰好
0.5 em**，而且它是**按字节**算的宽度（一个汉字 = 2 × FontWidth）。iOS 上换成 PingFang 之类的字体后
空格宽度不一样，`LOCATE` 的列宽、`\t` 的跳格就整体跑偏，棋盘和表格类程序会挤成一团。
现在固定按 `字号 / 2` 取值，对齐原机器。

### 3. 摇杆只会往「下」

原来每个热区都是「`Color.clear` + `.offset` 平移 + 各自挂手势」。`.offset()` 只移绘制不改布局，
手势报出来的 `location` 到底属于哪个坐标系并不直观；一旦落到父坐标系，摇杆算的
`dx=(x-r)/r, dy=(y-r)/r` 就恒为大正数，`atan2(-dy,dx)` 永远落在下半区 —— 于是只有「下」。

现在改成**一整块全尺寸手势层 + 自己命中判定**：手势层没有 offset、和机身同原点，
`location` 天然就是机身坐标，圆心的坐标也在同一个空间里，直接相减即可。
屏幕点击（`forwardTap`）之前有同样的毛病，一并修了。

顺带的手感修正：阈值改成 50%/38% 滞回；方向按住 0.26s 连发；圆心内松手 = 中键「确定」；
电源键热区从 3.2% 机身宽加宽到 34pt。

### 4. 全屏适配

原来的布局是 `padding(.horizontal, 34)` + 底部固定 34pt 提示条 + 浅色展台，等于在白色机身外面又套
了一圈白边，LCD 只有 248×324。

现在的规则（`BB9688App.swift`）：

```
机身宽 = min(屏幕宽, 屏幕高 × 0.5807)       // 宽度优先铺满
```

机身比 iPhone 还瘦长（0.5807 vs 0.461），所以约束永远来自**宽度**；想再放大只能裁机身左右，
那会把真机轮廓和侧边电源键一起切掉，所以不做。配合：展台换成深色、提示条改成浮层、
接触阴影取自机壳 alpha。iPhone 15 上 LCD 从 248×324 变成 300×393（+46% 面积）。

### 5. 没按键，游戏里却自己动

四个来源叠在一起，全部堵掉了：

1. **整机被每帧重建，手势被打断**（根因）。`AppModel` 曾把 `engine.objectWillChange`
   转发给自己，虚拟机 24fps 出一帧，`DeviceView` 就重建一次 —— `DragGesture` 被反复拆掉重装，
   `onEnded` 丢失，`touching` / `stickDirection` / 连发定时器全卡在「按下」状态。
   现在刷新只发生在 `FramebufferView` 里（它单独订阅 `engine`），机壳和手势层不再重算。
2. **连发定时器不会自己收手**。定时器每次醒来先核对 `touching`、`stickDirection`，
   对不上就 `invalidate()`；每次新触摸开始也先 `resetInteraction()` 兜底。
3. **按键队列会积压**。程序在某些画面（加载、过场）不读键盘，UI 照发方向键，等程序回来
   一次性全吃掉 → 手早松了还走好几格。`BBInputQueue` 现在：方向键在队列里去重、
   队列上限 8 个、松手 `dropPendingDirections()`。
4. **死区太小**。原来 32% 半径就判向，手指按在摇杆中间稍偏一点就被读成「下」并开始连发。
   现在 50% 进入 / 38% 退出，且有滞回。

### 6. 大富翁的汉字其实是**位图**，不走字体

这一条推翻了我之前对「汉字缺失」的判断，值得记下来。

用探针跑 `rich.bin` 到游戏内（394 万条指令），`drawChar` 调用次数 **0**。
标题、「单人/多人游戏/游戏说明/退出游戏」、游戏里的「现金 / 存款 / 阿土仔 / 2007 10 10」
全部来自 `RICH.LIB` 里的图片。所以 CoreText 那条修复对大富翁**不生效** —— 它只影响
真正用 `OUT 2/4` 输出文字的程序。

顺手把 `RICH.LIB` 的结构实测了一遍，确认现在的解析是对的：

```
count:u32 | offsets[count]:u32 | 每张图 16 字节定长
每张图：len:u32 | w:u16 | h:u16 | 4 字节 | RGB565 数据 | 4 字节尾部
其中 len = 12 + w*h*2，图间距 = len + 4
```

180 张图逐张核对，`len - w*h*2` 恒等于 12，179 个间距全部等于 `len + 4`，零异常。
所以 `dataStart = offset + 12` 是正确的，不是「多读/少读 4 字节」。

如果 iOS 上大富翁仍然缺字，那就只剩**资源没进包 / 路径大小写**这一条了
（`RICH.LIB` 是大写，程序里也是大写；iOS 区分大小写，Windows 不区分）。
`rich.bin` 里还引用了 `RICH.RLB / 9188.LIB / 9288.LIB / 9288T.LIB` 几个按机型区分的文件名，
这些我们没打包，如果程序按某个机型分支去取，会拿不到。

### 7. 画面发糊 —— 双重缩放踩了两次

大富翁的字既然是位图，它的清晰度就完全取决于「240×320 怎么放到屏幕上」这一件事。

LCD 只有 240×320，在 iPhone 15 上要放大 **1.225 倍 —— 不是整数倍**。原来的链路是：

```swift
Image(decorative: cg)                 // 240×320，interpolation(.none)
    .frame(width: 240, height: 320)   // 1:1 画一遍
    .scaleEffect(1.225)               // ← 再被 Core Animation 用默认线性插值放大一次
```

等于画清楚之后又糊了一遍，而且第二遍用的还是最差的插值。

现在改成一次到位（`Screen/FrameScaler.swift`）：

1. `vImageScale_ARGB8888` + `kvImageHighQualityResampling`（Lanczos 级重采样）；
2. 3×3 十字拉普拉斯锐化把放大丢掉的笔画对比补回来：
   `[0,-18,0, -18,172,-18, 0,-18,0] / 100`（权重和 = 100，亮度不漂移；0.18 是甜点，
   再高会在高饱和色块边缘描白边）；
3. 直接吃 `[UInt32]` 画布 —— `0x00RRGGBB` 小端存进内存就是 `B,G,R,A`，即 4 通道 8 位
   交织，省掉「CGImage → CGContext 再解一遍」，也不会掉进 `CGBitmapInfo` 字节序的坑里。

> **坑：不要在 Scale / Convolve 上写 `_BGRA8888`。** vImage 里只有 alpha 合成类接口
> （`vImagePremultiplyData_BGRA8888`、`vImageOverwriteChannels_ARGB8888` …）才分
> ARGB / BGRA，因为通道顺序会影响结果；缩放和卷积对四个通道做的是同一件事，所以只提供
> 与顺序无关的统一名 `_ARGB8888`。写成 `vImageScale_BGRA8888` 会直接
> `error: cannot find 'vImageScale_BGRA8888' in scope`，喂 BGRA 数据用 `_ARGB8888` 结果是一样的。

配套改动：`FramebufferView` 现在接收 LCD 的**点尺寸**，按 `点尺寸 × displayScale`
算出物理像素尺寸告诉引擎，引擎每帧直接产出这个尺寸的图，UI 端 1:1 贴上，
再没有任何二次缩放。`DeviceView.screenLayer` 也拆成了两条路：运行中走这条，
列表 / 开机 / 本机信息仍是矢量绘制的 240×320 + `scaleEffect`（矢量缩放不会糊）。

效果对比见 `Prototype/compare_scaling.py`（局部 7 倍放大，6 种算法并排）和
`Prototype/preview_clarity.py`（整屏并排）。

> **2026-10-23 修正**：缩放核已经换掉了。原来的 `vImageScale` 高质量重采样（Lanczos）
> 带负瓣，遇到 1px 描边必振铃 —— 实测 240→881 时每行约 80 个采样被顶出 107/255，
> 屏幕上就是「描边旁多出一道影子」。现在 `FrameScaler` 放大走**最近邻**、缩小走
> **面积平均**，两个核都非负，物理上不可能振铃；3×3 拉普拉斯锐化也一并删掉（它本身
> 就是振铃算子）。另外帧泵加了「画面没变就复用上一张图」（`memcmp` 307KB，实测 0ms），
> 静止时 CPU 基本归零。

### 8. HD 资源包（拆文字层）—— 从「放大不糊」到「真的变高清」

> **⚠️ 现状：改成 3× 了（2026-10-26）。**
> 当年放弃的是 **4×**，卡在「960×1280 面积平均到 881×1175」这一项 ——
> 桌面 CPU 实测 13.9ms/帧，24fps 预算才 41.7ms。
> 3× 的画布是 720×960，到屏幕 881×1175 是**放大**（×1.224），走最近邻查表，
> 没有面积平均那一步，量级完全不同；而 1.224 倍放大时一个画布像素基本落在
> 一个屏幕像素上，笔画粗细才均匀 —— 这正是「股票界面不清晰」的根因。
> 倍率在 `MachineEngine.renderScale`，掉帧就改回 `1`，别处不用动。
> HD 覆盖包现在是 **3×**（`Tools/pack_hd_lib.py` 的 `SCALE=3`，必须整除画布倍率），
> 直接放在 `BB9688/Resources/Programs/rich/RICH-HD.LIB` 进安装包。
> 2026-10-27 起它不再是空壳：LIB 066 骰子精灵图已按 3× 重制（见下）。
> `MachineEngine.start()` 对 Documents 里的旧 `*-HD.LIB` 的策略是
> 「与安装包比对，不一致整体替换、孤儿才删」—— 改倍率后老安装能自动升级。
> 下面这一节保留的是当时的设计记录。

`rich/RICH-HD.LIB` 就是这样一个包，**同结构、按 N× 存放**，引擎检测到它就自动
开高清，VM 的坐标逻辑一行不改。

#### 覆盖包里现在有什么

| 图 | 内容 | 为什么引擎算不出来 |
|---|---|---|
| LIB 066 | 骰子精灵图 216×30（8 个 27×30 面：1~6 点、?、BIG） | 原画自带青色 AA 光晕（给蓝底调的）和微色偏抖动灰，3× 放大后是全屏唯一发糊的元素。`Tools/clean_dice_art.py` 清洗（青晕→邻域投票、灰阶吸附、黑点 AA 收紧）后按 3× 重制 |

#### 引擎侧怎么做到「VM 无感」

`BBHD.scale`（`Core/BBFoundation.swift`）是唯一的倍率开关：

| 位置 | 做法 |
|---|---|
| 画布 | `BBScreen.init` 建 240·s × 320·s，但 `outputX/outputY`、`setSize` 仍是逻辑坐标 |
| 图片 | `BBSurface` 多记 `logicalWidth/logicalHeight`；`pictureWidth/Height` 返回**逻辑**尺寸，VM 的排版计算不变 |
| 贴图 | `drawPicture/cloneSurface(Region)/fillSurface/writePixel/readPixel/drawLine/drawRectangle/drawCircle/movePen` 一律 `BBHD.px()` 换算 |
| 文字 | `CoreTextRenderer` 蒙版按 `字号·s` 栅格化，`GlyphMask.advance` 仍是逻辑步进 |
| 显示 | 帧从 960×1280 **往下**缩到屏幕物理像素，此时必须关锐化（`MachineEngine` 里 `sharpen = 0`），否则 Lanczos 重建核会震出振铃 |

资源加载（`BBResourceLibrary.image`）先试 `RICH-HD.LIB` 再试 `RICH.LIB`，两个都不在才返回 nil，
所以没有 HD 包时行为与原来完全一致。

#### 离线重建流程（Python，全在 `Tools/`）

```
Tools/richlib_dump.py        180 张全部解成 PNG + 盘点（尺寸/色数/洋红键占比）
Tools/name_sheet.py          把某家族的文字区拼成一张总览，一次读完所有文字
Tools/textlayer_extract.py   颜色掩码 → 行带 → 列间隙切字 → 按 pitch 归槽（碎片并回整字）
Tools/textlayer_rebuild.py   擦字（膨胀 1px 连抗锯齿一起擦）→ 逐行水平修补 → 4× → 矢量字画回
Tools/pack_hd_lib.py         打包成 RICH-HD.LIB（重绘过的用重绘版 3×，其余不进包由引擎现算）
Tools/clean_dice_art.py      LIB 066 骰子清洗 + 3× 重制（输出喂给 pack_hd_lib.py）
```

两条实战经验：

- **切字不能用连通域**。像素字的细笔画加抗锯齿会被颜色容差切成 3~5 块，39 张卡切出
  286 种「字形」。这套字体是等宽的（名牌 16px、数字 8px），按列间隙切、再按 pitch
  归槽才一刀一个字。
- **洋红 0xFF00FF 是引擎的透明键**，必须先转 alpha 再放大，最后压回洋红底，
  否则边缘会长出一圈粉边（`pack_hd_lib.py` 的 `upscale_keyed`）。

#### 现在的完成度

- 176×121 事件卡家族 38 张：名牌栏文字已换成矢量字（雅黑 Bold，位置/颜色对齐原版）。
- 其余 142 张：按类型 4× 放大（含键的走 alpha 通道）。
- 状态栏的「現金 / 存款 / 阿土仔 / 25000」、标题屏菜单仍是位图 sprite —— 同一套流程
  往下拆即可，`labels/` 里加一行文字就能重建。
- **体积**：4× 全量是 88.5MB RGB565，直接进 app 太大。要上线得改容器
  （ASTC 6×6 ≈ 20MB，或只发重建过的图、其余运行时放大）。

实跑对比（`Prototype/preview_hd_run.py`，无头 keymap 探针出帧）：
`.tmp_build/keys/01-enter1.png`（原版）vs `.tmp_build/keys_hd/01-enter1.png`（HD）。


---

## 五、加一个程序

列表**不再写死**，而是扫 `<Documents>/Programs/`：有什么就列什么。

### 方式 A：内置（进安装包）

1. 建 `BB9688/Resources/Programs/<id>/`，放 `.bin` 和它要的 `.LIB`（**大小写要跟程序里写的一致**，iOS 文件系统区分大小写）；
2. 不用改任何代码 —— 首次启动会把 `Programs/` 整棵树播种到 `Documents/Programs/`；
3. 想给它中文名/专属图标，在目录里加 `info.json`（见下）；
4. 重跑 `python make_project.py`（新增的是文件夹引用，其实不重跑也能进包，但保持工程文件同步更稳）。

### 方式 B：外部导入（不进安装包）

`Info.plist` 已开 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`，
所以直接在 iPhone 的「文件」App 里进 `我的 iPhone › 9688`（根，显示名取自 `CFBundleDisplayName`）：

- 丢一个目录 `我的游戏/`（里面有 `MARIO.bin` + `MARIO.LIB`）→ 列表多一行；
- 或者直接把 `demo.bin` 丢在 `Programs/` 根下 → 也会列出来（id 取去掉扩展名的文件名）；
- **放在 `9688` 根目录（不建 Programs）也能被认出来**，见下面的多位置扫描；
- 回到 App（切前台 / 重新开机）列表自动刷新，不用重启。

> 早期版本只扫 `<Documents>/Programs`，而「文件」App 里打开 App 看到的是 Documents **根**，
> 于是把 `.bin` 丢在根下的人（大多数）看到的是一片空白，像是「读了目录但没反应」。
> 现在两个位置都扫，`Programs/` 优先、同名只留一份。

发现规则（`ProgramStore.discover`）：

| 判据 | 说明 |
|---|---|
| 扫描位置 | `Documents/Programs` → `Documents` 根，依次扫，同名 id 只留先扫到的 |
| 目录里要有 `.bin` | 没有 bin 的目录跳过；优先「目录同名.bin」，否则按名字取第一个 |
| 跳过隐藏项 | `.DS_Store` 这类不列；`*-HD.LIB` 不算程序 |
| 排序 | 内置 `rich / flappybird / man` 固定在最前，其余按标题 |
| 标题 | `info.json.title` → 内置中文名 → 目录名（裸 bin 用去扩展名的文件名） |
| 说明 | `info.json.detail` → `<内置文案或「外部程序」> · <真实 KB>` |
| 图标 | `info.json.icon` 一个字 → 标题首字；未知程序按 id 散列到固定色板 |

另外两处会影响「打得开 / 打不开」的细节：

- **文件名大小写兜底**（`BBFileResolver`）：程序里写死的 `RICH.LIB`、`SAVE.SAV`
  和从 Windows 拷来的 `rich.lib` 对不上时，会做一次大小写不敏感匹配。
  iOS 的 APFS 区分大小写，以前这里会当成「文件不存在」，然后 fopen 建出一个空文件。
- **启动失败必须说话**（`MachineEngine.start` 返回 `String?`）：读不到 bin、目录不对、
  文件不像 BB 程序，都会把原因写回列表底部那一行；程序自己退出也会自动回列表并说明原因。
  以前这些情况一律切到「运行中」的黑屏，看起来就是「点了没反应」。

`info.json` 全部字段可选：

```json
{ "title": "超级玛丽", "detail": "外部程序 · 横版过关", "icon": "玛", "bin": "MARIO.bin" }
```

程序运行用的是 `Documents/Programs/<id>/` 这份可写副本（老程序要写 `.SAV` 存档），
安装包里的那份只当种子；播种是「目标不存在才拷」，所以升级不会覆盖存档或你改过的资源。

---

## 六、移植时保留的坑

为了和老程序行为一致，以下「看起来是 bug」的地方是**故意保留**的：

- `LD` 的掩码写入语义（只覆盖低 N 字节，高字节不动）；
- `SHOWPIC` 的参数在内存里是**逆序**放的（`page+32, pic+28, dx+24, dy+20`）；
- 颜色在不同端口分别按 BGR / RGB 解释，`TRANS_COLOR_END` 会交换 R/B；
- `FillSurface` 不换色而 `Pixel` 换色；
- `CMP` 对 BYTE 会 fallthrough 到 WORD 再按 32 位比较；
- 字符串句柄从 `-1` 向下分配。

`.LIB` 解码这里**修了一个**原实现的 bug：原 C++ 每帧多读 4 字节，导致图片整体偏移 2 像素，本实现按 `len/w/h + 4 字节填充` 的正确布局解析。

---

## 七、已知限制

- 只跑 `.bin`，不带编译器（`bbc` 不移植），App 内不能编辑/编译源码；
- 剑侠风云（812KB + 20MB 资源）没打进包，需要的话按第五节手动加；
- 横屏未适配，锁定竖屏；
- 没有做状态保存，切后台再回来程序会重跑；
- 大富翁的文字全是 `RICH.LIB` 里的位图，不走字体渲染，所以字体那条修复对它无效；
  `rich.bin` 还会按机型引用 `RICH.RLB / 9188.LIB / 9288.LIB / 9288T.LIB`，这些没打包；
- 无头探针在 `Tools/headless/`：`probe`（字体渲染链路）、`keymap`（逐键试探 + 导出 PNG，
  本次就是靠它确认「大富翁 drawChar = 0 次」）。两者都能在 WSL / macOS 上直接重跑。
