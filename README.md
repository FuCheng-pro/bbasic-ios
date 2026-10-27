# bbasic-ios

步步高 9688（BBK 外语通）的虚拟机 iOS 移植 —— 用 SwiftUI 原生复刻了整台机器：
机壳、按键、Logo 全部来自真机照片，屏幕上跑的是真实的 `.bin` 字节码。

> 📖 **详细文档见 [BB9688/README.md](BB9688/README.md)** —— 架构、按键映射、踩坑记录、修复过程全在里面。

## 运行截图

iPhone 真机运行效果 —— 照片机壳 + LCD + 按键辉光，屏幕上跑的是原版 `rich.bin` 字节码（大富翁2）：

![iPhone 真机运行效果](screenshots/device-run.jpg)

## 这是什么

9688 是一台按键式电子词典，上面跑的是一套自有字节码虚拟机（BBVM）。本项目把这套 VM
完整移植到了 iOS：

- **BBVM 指令集**：LD / PUSH / POP / IN / OUT / JMP / CALL / RET / CMP / EXIT 等，
  指令长度与寻址编码逐条对齐原 C++ 实现
- **端口 0–80**：字符串池、文件 IO、9 张画布、图片资源（.LIB 解码）、画笔图元、按键
- **整机界面**：照片机壳 + LCD + 按键辉光 + 摇杆热区，几何全部实测百分比定位
- **画面清晰度**：按物理像素 1:1 出图，最近邻/面积平均缩放，杜绝二次缩放发糊
- **内置程序**：大富翁 / Flappy Bird / MAN 演示，已逐像素比对过 PC 版截图
- **程序导入**：支持「文件」App 往 `Documents/Programs/` 丢目录即可运行

## 快速开始

### 方式一：直接安装（推荐）

不用自己编译 —— 到 [Releases](https://github.com/FuCheng-pro/bbasic-ios/releases) 下载最新的 `BB9688.ipa` 安装即可。

> ipa 未签名，需用 [AltStore / Sideloadly / TrollStore](https://github.com/SignTools/SignTools) 等工具自签后安装，或接入 Xcode 直接部署。

### 方式二：自己编译

本项目使用 [xtool](https://xtool.sh) 编译 —— 在 **WSL / Linux 上交叉编译出 iOS App，全程不需要 Mac**：

```bash
# WSL / Linux（首次需要 xtool setup 安装 Darwin SDK，约 1~2 GB）
./build.sh xtool
```

产物是 `BB9688/xtool/BB9688.ipa`。

有 Mac 的话也可以走 Xcode：直接 `open BB9688/BB9688.xcodeproj`（Xcode 15+，iOS 16+），
或 `./build.sh run` 跑模拟器。

## 仓库结构

```
BB9688/          ← iOS App 本体（本仓库唯一入库的工程）
├─ BB9688/       源码：Core/（VM，纯逻辑可单独编译）、App/、Device/、Screen/、Launcher/
├─ Resources/    机壳图、辉光层、内置程序（.bin + .LIB）
└─ ...           构建脚本、xtool 配置
```

其余逆向分析用的资料（原机资源、反汇编工具、原型脚本）不在仓库内。

## 参考项目

本项目的 VM 指令集、端口语义与 `.LIB` 资源格式均参考了 **[0ximst1ll/bbasic](https://github.com/0ximst1ll/bbasic)**（BBK 字节码虚拟机的 C++ 开源实现）逆向与移植而来，在此致谢。

## 版权声明

本项目（含仓库内代码）仅用于学习与技术研究。仓库及 App 内包含的 `.bin` 字节码程序、`.LIB` 图形资源、音乐等游戏资源**版权归原权利人所有**，本项目不对其主张任何权利。请在已合法拥有相应软件的前提下使用本项目，并于体验后自行删除；如有侵权请联系删除。

## 已知限制

- 只跑 `.bin`，不带编译器；横屏未适配；无状态保存（切后台程序会重跑）
- 大富翁的文字是 `RICH.LIB` 里的位图，不走字体渲染

完整说明与开发记录 → **[BB9688/README.md](BB9688/README.md)**
