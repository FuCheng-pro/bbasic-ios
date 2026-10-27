#!/usr/bin/env bash
#
#  BB9688 构建脚本
#
#  在 WSL / Linux 上用 xtool 编译（不需要 Mac）：
#      ./build.sh xtool          编译出 .app（release）
#      ./build.sh xtool-ipa      编译并打包成未签名 .ipa（release）
#      ./build.sh xtool-run      编译 + 装到已连接的 iPhone
#      ./build.sh xtool-debug    同上但用 debug 构建（只有排查崩溃时才用，慢一个数量级）
#
#  在 macOS 上用 Xcode 编译：
#      ./build.sh run            编译 + 装进模拟器
#      ./build.sh device         编译真机版
#      ./build.sh archive        出 Release 包
#
set -euo pipefail
cd "$(dirname "$0")"

PROJECT="BB9688.xcodeproj"
SCHEME="BB9688"
BUNDLE_ID="com.bbk.bb9688"
SIM_NAME="${SIM_NAME:-iPhone 15}"

action="${1:-build}"

# ───────────────────────── xtool（WSL / Linux） ─────────────────────────
if [[ "$action" == xtool* ]]; then
  if ! command -v xtool >/dev/null 2>&1; then
    echo "找不到 xtool。安装（在 WSL 里）："
    echo "  git clone https://github.com/xtool-org/xtool.git ~/xtool-src"
    echo "  cd ~/xtool-src && swift build -c release"
    echo "  sudo install .build/release/xtool /usr/local/bin/"
    exit 1
  fi

  # 首次运行需要 Darwin SDK，xtool 会自动提示；也可以先手动跑：
  #   xtool setup
  #
  # ★★ 必须用 release 构建。★★
  #   2026-10-26 真机实测（debug 构建）：BBVM 只有 61 万条指令/秒（占 75% CPU）、
  #   一帧要 78.9ms、整机 CPU 140%、thermalState 已经「过热」、帧率 7fps。
  #   Swift 在 -Onone 下不内联、不做泛型特化、保留全部边界检查 ——
  #   虚拟机的热循环（每步几十次数组访问）和帧缩放（103 万像素逐点循环）
  #   都要慢一到两个数量级。同一份代码在 -O 下是另一台机器。
  #   只有需要符号/断点时才用 xtool-debug。
  CONF=(--configuration release)

  case "$action" in
    xtool)            xtool dev build "${CONF[@]}" ;;
    xtool-ipa)        xtool dev build "${CONF[@]}" --ipa ;;    # 未签名 ipa，用 Sideloadly 自签安装
    xtool-ipa-signed) xtool dev build "${CONF[@]}" --sign --ipa ;;   # 需先 xtool auth login
    xtool-run)        xtool dev run ;;                         # run 不接受 configuration 参数
    xtool-debug)      xtool dev build --ipa ;;                 # 慢一个数量级，仅排查崩溃用
  esac
  exit 0
fi

# ───────────────────────── Xcode（macOS） ─────────────────────────
if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "找不到 xcodebuild，请先安装 Xcode 并执行："
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  echo "（如果在 Linux/WSL 上，请用：./build.sh xtool）"
  exit 1
fi

case "$action" in
  build)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
      -destination "platform=iOS Simulator,name=$SIM_NAME" \
      build
    ;;

  run)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
      -destination "platform=iOS Simulator,name=$SIM_NAME" \
      -derivedDataPath build \
      build

    APP="build/Build/Products/Debug-iphonesimulator/BB9688.app"
    xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
    open -a Simulator
    xcrun simctl install booted "$APP"
    xcrun simctl launch booted "$BUNDLE_ID"
    echo "已在 $SIM_NAME 上启动"
    ;;

  device)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
      -destination "generic/platform=iOS" \
      -allowProvisioningUpdates \
      build
    ;;

  archive)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
      -destination "generic/platform=iOS" \
      -archivePath build/BB9688.xcarchive \
      -allowProvisioningUpdates \
      archive
    echo "产物：build/BB9688.xcarchive"
    ;;

  clean)
    xcodebuild -project "$PROJECT" -scheme "$SCHEME" clean
    rm -rf build .build
    ;;

  *)
    echo "用法: ./build.sh [xtool|xtool-ipa|xtool-ipa-signed|xtool-run|build|run|device|archive|clean]"
    exit 1
    ;;
esac
