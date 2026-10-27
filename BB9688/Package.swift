// swift-tools-version:5.9
//
//  Package.swift
//  BB9688
//
//  xtool 用的构建描述。注意 xtool 的模型和 Xcode 不同：
//    · 应用要声明成 **library** 产品，入口仍是源码里的 `@main struct App`；
//    · xtool 自己负责链接成可执行文件、生成 Info.plist、签名、装包。
//
//  Xcode 走的是 BB9688.xcodeproj，两条路共用同一批源文件。
//  资源位置差异用 SWIFT_PACKAGE 宏在 AppResources.swift 里吸收。
//

import PackageDescription

let package = Package(
    name: "BB9688",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(name: "BB9688", targets: ["BB9688"])
    ],
    targets: [
        .target(
            name: "BB9688",
            path: "BB9688",
            exclude: ["Info.plist"],
            resources: [
                .copy("Resources/device-shell.png"),
                .copy("Resources/glow-back.png"),
                .copy("Resources/glow-center.png"),
                .copy("Resources/glow-down.png"),
                .copy("Resources/glow-left.png"),
                .copy("Resources/glow-menu.png"),
                .copy("Resources/glow-right.png"),
                .copy("Resources/glow-up.png"),
                .copy("Resources/Programs"),
                .copy("Resources/Music")
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
