//
//  LauncherView.swift
//  BB9688
//
//  屏幕上「非虚拟机」的那几屏：开机、程序列表、本机信息。
//  全部按 240×320 的真实像素排版，外层统一缩放，保证和 LCD 的像素格一致。
//

import SwiftUI

// MARK: - 程序列表

struct LauncherScreen: View {
    @ObservedObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            list
            footer
        }
        .frame(width: 240, height: 320)
        .background(Color(red: 0.91, green: 0.93, blue: 0.95))
        // 延到下一次 RunLoop 再扫盘：onAppear 期间 SwiftUI 正在更新视图树，
        // 这里改 @Published 属于「在视图更新里改状态」，会把 ViewGraph 打乱。
        .onAppear { DispatchQueue.main.async { app.refreshPrograms() } }
    }

    private var header: some View {
        HStack {
            Text("BB 程序")
                .font(.system(size: 10, weight: .semibold))
            Spacer()
            Text("▮▮▮ 87%")
                .font(.system(size: 8))
                .opacity(0.85)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 6)
        .frame(height: 20)
        .background(
            LinearGradient(colors: [Color(red: 0.17, green: 0.44, blue: 0.75),
                                    Color(red: 0.11, green: 0.34, blue: 0.60)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var list: some View {
        VStack(spacing: 0) {
            // 程序数量不再固定，超出 6 行时可以滚动；上下选择会跟着把选中行带到中间
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        if app.programCount == 0 {
                            emptyHint
                        }
                        ForEach(Array(app.rows.enumerated()), id: \.element.id) { pair in
                            rowView(pair.element, selected: pair.offset == app.selectedIndex)
                                .id(pair.element.id)
                                .onTapGesture {
                                    app.selectedIndex = pair.offset
                                    app.confirm()
                                }
                        }
                    }
                }
                .onChange(of: app.selectedIndex) { _ in
                    guard app.rows.indices.contains(app.selectedIndex) else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(app.rows[app.selectedIndex].id, anchor: .center)
                    }
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)

            HStack {
                Text("共 \(app.programCount) 个 BB 程序")
                Spacer()
                Text(app.freeSpace)
            }
            .font(.system(size: 9))
            .foregroundColor(Color(red: 0.48, green: 0.55, blue: 0.63))
            .padding(.horizontal, 6)
            .padding(.top, 6)
            .padding(.bottom, 3)
            .overlay(
                Rectangle()
                    .fill(Color(red: 0.79, green: 0.83, blue: 0.88))
                    .frame(height: 1),
                alignment: .top
            )
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 4)
    }

    /// 列表全空时的指引。以前这里只是空白一片，
    /// 用户把文件丢错层级（丢在「9688」根而不是「9688/Programs」）时完全看不出问题在哪。
    private var emptyHint: some View {
        VStack(spacing: 5) {
            Text("没找到 BB 程序")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(Color(red: 0.30, green: 0.37, blue: 0.45))
            Text("把 .bin 和配套的 .LIB 放进\n「文件 › 我的 iPhone › 9688」\n或里面的 Programs 文件夹，回来自动出现")
                .font(.system(size: 8))
                .multilineTextAlignment(.center)
                .foregroundColor(Color(red: 0.48, green: 0.55, blue: 0.63))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 14)
    }

    private func rowView(_ row: BBProgram, selected: Bool) -> some View {        HStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(iconColors(for: row))
                Text(iconGlyph(for: row))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 26, height: 34)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.black.opacity(0.28), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(selected ? .white : Color(red: 0.11, green: 0.16, blue: 0.23))
                    .lineLimit(1)
                Text(row.detail)
                    .font(.system(size: 9))
                    .foregroundColor(selected ? .white.opacity(0.8)
                                             : Color(red: 0.42, green: 0.48, blue: 0.56))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(height: 38)
        .background(
            Group {
                if selected {
                    LinearGradient(colors: [Color(red: 0.25, green: 0.54, blue: 0.85),
                                            Color(red: 0.12, green: 0.38, blue: 0.67)],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    Color.clear
                }
            }
        )
        .cornerRadius(2)
    }

    private var footer: some View {
        Group {
            if let error = app.launchError {
                Text(error)
                    .foregroundColor(Color(red: 0.72, green: 0.13, blue: 0.11))
            } else {
                Text("▲▼ 选择　·　中键运行　·　电源键关机")
                    .foregroundColor(Color(red: 0.36, green: 0.44, blue: 0.53))
            }
        }
        .font(.system(size: 8))
        .lineLimit(1)
        .minimumScaleFactor(0.65)
        .frame(maxWidth: .infinity)
        .frame(height: 15)
        .background(app.launchError == nil
                    ? Color(red: 0.87, green: 0.89, blue: 0.93)
                    : Color(red: 0.99, green: 0.90, blue: 0.89))
        .overlay(
            Rectangle()
                .fill(app.launchError == nil
                      ? Color(red: 0.78, green: 0.82, blue: 0.87)
                      : Color(red: 0.90, green: 0.62, blue: 0.58))
                .frame(height: 1),
            alignment: .top
        )
    }

    private func iconGlyph(for row: BBProgram) -> String {
        switch row.id {
        case "rich": return "富"
        case "flappybird": return "鸟"
        case "man": return "M"
        case "about": return "机"
        case "settings": return "设"
        default:
            // 外部程序：优先用 info.json 里的 icon，否则取标题首字
            if let g = row.glyph, !g.isEmpty { return String(g.prefix(1)) }
            return row.title.first.map(String.init) ?? "?"
        }
    }

    /// 未知程序也要有个稳定的颜色：按 id 散列落到固定色板里，
    /// 同一个程序每次进列表颜色一致，不同程序之间又能区分开。
    private static let palette: [(Color, Color)] = [
        (Color(red: 0.91, green: 0.71, blue: 0.29), Color(red: 0.72, green: 0.50, blue: 0.12)),
        (Color(red: 0.40, green: 0.72, blue: 0.91), Color(red: 0.17, green: 0.49, blue: 0.71)),
        (Color(red: 0.48, green: 0.75, blue: 0.35), Color(red: 0.24, green: 0.50, blue: 0.17)),
        (Color(red: 0.85, green: 0.45, blue: 0.42), Color(red: 0.60, green: 0.20, blue: 0.20)),
        (Color(red: 0.66, green: 0.55, blue: 0.88), Color(red: 0.40, green: 0.29, blue: 0.66)),
        (Color(red: 0.60, green: 0.65, blue: 0.71), Color(red: 0.36, green: 0.41, blue: 0.46))
    ]

    private func iconColors(for row: BBProgram) -> LinearGradient {
        let pair: (Color, Color)
        switch row.id {
        case "rich":
            pair = (Color(red: 0.91, green: 0.71, blue: 0.29), Color(red: 0.72, green: 0.50, blue: 0.12))
        case "flappybird":
            pair = (Color(red: 0.40, green: 0.72, blue: 0.91), Color(red: 0.17, green: 0.49, blue: 0.71))
        case "man":
            pair = (Color(red: 0.48, green: 0.75, blue: 0.35), Color(red: 0.24, green: 0.50, blue: 0.17))
        case "about", "settings":
            // 两个系统项用同一块冷灰：它们不是游戏，颜色上先区分开
            pair = (Color(red: 0.60, green: 0.65, blue: 0.71), Color(red: 0.36, green: 0.41, blue: 0.46))
        default:
            let idx = abs(row.id.hashValue) % LauncherScreen.palette.count
            pair = LauncherScreen.palette[idx]
        }
        return LinearGradient(colors: [pair.0, pair.1], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - 开机

struct BootScreen: View {
    @State private var progress: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            Text("BBK")
                .font(.system(size: 34, weight: .black, design: .default))
                .foregroundColor(Color(red: 0.05, green: 0.31, blue: 0.60))
                .kerning(4)
            Text("BASIC VIRTUAL MACHINE")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(Color(red: 0.56, green: 0.64, blue: 0.74))
                .kerning(2.6)
                .padding(.top, 4)

            ZStack(alignment: .leading) {
                Rectangle()
                    .stroke(Color(red: 0.73, green: 0.78, blue: 0.85), lineWidth: 1)
                    .frame(width: 150, height: 6)
                Rectangle()
                    .fill(LinearGradient(colors: [Color(red: 0.18, green: 0.50, blue: 0.83),
                                                  Color(red: 0.38, green: 0.68, blue: 0.94)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, 146 * progress), height: 4)
                    .padding(.leading, 2)
            }
            .padding(.top, 26)
        }
        .frame(width: 240, height: 320)
        .background(Color(red: 0.984, green: 0.988, blue: 0.996))
        .onAppear {
            progress = 0
            withAnimation(.easeOut(duration: 1.4)) { progress = 1 }
        }
    }
}

// MARK: - 本机信息

struct AboutScreen: View {
    /// 程序列表里的可运行程序数量（磁盘扫描出来的，不是写死的 3）
    var programCount: Int = 0

    private struct Item: Identifiable {
        let id: String
        let value: String
        init(_ id: String, _ value: String) {
            self.id = id
            self.value = value
        }
    }

    private var items: [Item] {
        [
            Item("型号", "BBK 外语通 9688"),
            Item("屏幕", "3.2\" TFT 240×320"),
            Item("虚拟机", "BBVM 1.91 兼容"),
            Item("语言", "BBasic（GBK）"),
            Item("程序", "\(programCount) 个，可自行导入"),
            Item("目录", "文件 › 我的 iPhone › 9688")
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("本机信息")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color(red: 0.07, green: 0.20, blue: 0.36))
                .padding(.bottom, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    Rectangle()
                        .fill(Color(red: 0.81, green: 0.85, blue: 0.90))
                        .frame(height: 1),
                    alignment: .bottom
                )

            VStack(alignment: .leading, spacing: 3) {
                ForEach(items) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(item.id)
                            .font(.system(size: 9))
                            .foregroundColor(Color(red: 0.48, green: 0.55, blue: 0.63))
                            .frame(width: 38, alignment: .leading)
                        Text(item.value)
                            .font(.system(size: 9))
                            .foregroundColor(Color(red: 0.13, green: 0.20, blue: 0.30))
                    }
                }
            }
            .padding(.top, 6)

            Spacer(minLength: 0)

            Text("由 Swift 实现的 BBVM 直接执行 .bin 字节码，不经编译器、不做二次解释。")
                .font(.system(size: 8))
                .foregroundColor(Color(red: 0.53, green: 0.58, blue: 0.66))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
                .overlay(
                    Rectangle()
                        .fill(Color(red: 0.84, green: 0.87, blue: 0.91))
                        .frame(height: 1),
                    alignment: .top
                )
        }
        .padding(10)
        .frame(width: 240, height: 320, alignment: .topLeading)
        .background(Color(red: 0.984, green: 0.988, blue: 0.996))
    }
}
