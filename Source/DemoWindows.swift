import AppKit

enum DemoWindows {
    static func make() -> [WindowRecord] {
        let samples: [(String, String, String, NSColor)] = [
            ("项目笔记 — 下一步计划", "备忘录", "note.text", .systemYellow),
            ("WindowHop · 窗口切换器", "代码编辑器", "curlybraces", .systemBlue),
            ("周末去哪里", "浏览器", "globe", .systemTeal),
            ("设计参考", "访达", "folder.fill", .systemIndigo),
            ("灵感与草图", "预览", "photo", .systemPink),
            ("轻音乐 · 专注时刻", "音乐", "music.note", .systemRed)
        ]
        let bundleIDs = ["com.apple.Notes", "com.microsoft.VSCode", "com.apple.Safari",
                         "com.apple.finder", "com.apple.Preview", "com.apple.Music"]
        return samples.enumerated().map { index, sample in
            let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIDs[index])
                .map { NSWorkspace.shared.icon(forFile: $0.path) }
                ?? NSImage(systemSymbolName: sample.2, accessibilityDescription: sample.1)
            return WindowRecord(id: "demo-\(index)", pid: 0, title: sample.0, appName: sample.1,
                icon: icon, frame: CGRect(x: 0, y: 0, width: 560, height: 340),
                isMinimized: index == 5, thumbnail: index == 5 ? nil : thumbnail(index: index, color: sample.3))
        }
    }
    static func thumbnail(index: Int, color: NSColor) -> NSImage {
        let size = NSSize(width: 560, height: 340)
        return NSImage(size: size, flipped: false) { rect in
            NSColor(calibratedWhite: index == 1 ? 0.10 : 0.96, alpha: 1).setFill(); rect.fill()
            NSColor(calibratedWhite: index == 1 ? 0.16 : 0.88, alpha: 1).setFill()
            NSRect(x: 0, y: 310, width: 560, height: 30).fill()
            for (x, color) in [(16, NSColor.systemRed), (34, .systemYellow), (52, .systemGreen)] {
                color.withAlphaComponent(0.8).setFill(); NSBezierPath(ovalIn: NSRect(x: x, y: 320, width: 9, height: 9)).fill()
            }
            func text(_ string: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: NSColor, bold: Bool = false) {
                let attrs: [NSAttributedString.Key: Any] = [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .foregroundColor: color]
                (string as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
            }
            switch index {
            case 0:
                NSColor(calibratedRed: 1, green: 0.96, blue: 0.79, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 130, height: 310).fill()
                text("备忘录", 18, 270, 15, .darkGray, bold: true)
                for y in stride(from: 238, to: 60, by: -34) { NSColor.black.withAlphaComponent(0.08).setFill(); NSBezierPath(roundedRect: NSRect(x: 16, y: y, width: 96, height: 22), xRadius: 4, yRadius: 4).fill() }
                text("把想法变成现实", 160, 254, 24, .darkGray, bold: true)
                for (i, s) in ["整理项目资料", "打磨一个顺手的小工具", "留一些时间给新的灵感"].enumerated() {
                    color.setStroke(); let circle = NSBezierPath(ovalIn: NSRect(x: 164, y: 205-i*42, width: 15, height: 15)); circle.lineWidth = 2; circle.stroke()
                    text(s, 192, CGFloat(203-i*42), 16, .darkGray)
                }
            case 1:
                NSColor(calibratedWhite: 0.13, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 120, height: 310).fill()
                text("WINDOWHOP", 16, 275, 12, .lightGray, bold: true)
                for (i, s) in ["Source", "  AppDelegate", "  WindowCatalog", "  Keyboard", "  Overlay", "Scripts"].enumerated() { text(s, 12, CGFloat(246-i*27), 11, .lightGray) }
                let lines = ["import AppKit", "", "final class WindowHop {", "    let idea = \"stay focused\"", "", "    func switchWindow() {", "        preview.show()", "        selection.activate()", "    }", "}"]
                for (i, line) in lines.enumerated() { text("\(i+1)", 134, CGFloat(275-i*24), 12, .gray); text(line, 160, CGFloat(275-i*24), 13, i == 0 || i == 2 ? .systemPink : .systemTeal) }
            case 2:
                text("让周末慢下来", 38, 252, 29, .darkGray, bold: true)
                text("走进自然，发现城市之外的风景", 40, 216, 15, .gray)
                let gradient = NSGradient(starting: NSColor(calibratedRed: 0.64, green: 0.84, blue: 0.83, alpha: 1), ending: NSColor(calibratedRed: 0.17, green: 0.42, blue: 0.40, alpha: 1))!
                gradient.draw(in: NSBezierPath(roundedRect: NSRect(x: 36, y: 26, width: 488, height: 170), xRadius: 10, yRadius: 10), angle: -90)
                NSColor.white.withAlphaComponent(0.24).setFill()
                let path = NSBezierPath(); path.move(to: NSPoint(x: 36, y: 26)); path.line(to: NSPoint(x: 180, y: 148)); path.line(to: NSPoint(x: 300, y: 26)); path.close(); path.fill()
            case 3:
                NSColor(calibratedWhite: 0.90, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 115, height: 310).fill()
                text("个人收藏", 18, 270, 13, .gray, bold: true)
                for (i, s) in ["最近使用", "桌面", "文稿", "下载"].enumerated() { text(s, 22, CGFloat(235-i*34), 14, .darkGray) }
                for i in 0..<6 {
                    let x = 151 + (i%3)*126, y = 190 - (i/3)*118
                    NSColor.systemBlue.withAlphaComponent(0.65).setFill(); NSBezierPath(roundedRect: NSRect(x: x, y: y, width: 76, height: 55), xRadius: 6, yRadius: 6).fill()
                    text(["参考", "草图", "素材", "截图", "归档", "项目"][i], CGFloat(x+18), CGFloat(y-23), 13, .darkGray)
                }
            default:
                for i in 0..<4 {
                    color.withAlphaComponent(CGFloat(0.16+Double(i)*0.08)).setFill()
                    NSBezierPath(roundedRect: NSRect(x: 36+i*122, y: 65+(i%2)*50, width: 105, height: 160), xRadius: 14, yRadius: 14).fill()
                }
                text("IDEAS / 2026", 38, 270, 20, .darkGray, bold: true)
            }
            return true
        }
    }
}
