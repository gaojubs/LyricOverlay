import AppKit
import ApplicationServices

/// 调试: 把 Music 的无障碍树写到文件, 再连续采样几次文字节点的位置, 看是否随歌词滚动变化
enum AXDump {
    static func run(to path: String) -> Never {
        try? dump().write(toFile: path, atomically: true, encoding: .utf8)
        exit(0)
    }

    private static func dump() -> String {
        var out = ""
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            return "NOT_TRUSTED: 请在 系统设置 › 隐私与安全性 › 辅助功能 中打开 LyricOverlay\n"
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).first else {
            return "Music 没有运行\n"
        }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 2)

        var nodes = 0
        var texts: [AXUIElement] = []
        func walk(_ e: AXUIElement, _ d: Int) {
            nodes += 1
            guard d < 60, nodes < 50000 else { return }
            let role = str(e, kAXRoleAttribute) ?? "?"
            let sub = str(e, kAXSubroleAttribute).map { "/\($0)" } ?? ""
            let id = str(e, kAXIdentifierAttribute).map { " #\($0)" } ?? ""
            let text = [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute]
                .compactMap { str(e, $0) }.first(where: { !$0.isEmpty }) ?? ""
            let f = frame(e).map { " @\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? ""
            out += String(repeating: "  ", count: d) + "\(role)\(sub)\(id) \(text.prefix(100))\(f)\n"
            if role == kAXStaticTextRole as String, !text.isEmpty { texts.append(e) }
            for c in children(e) { walk(c, d + 1) }
        }
        // 早先调试时打开过增强模式, 它会拖慢窗口动画; 这里复原, 读歌词不需要它
        AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        let t0 = CACurrentMediaTime()
        walk(root, 0)
        // 有些应用的窗口不在 children 里
        var wins = (raw(root, kAXWindowsAttribute) as? [AXUIElement]) ?? []
        for a in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let w = raw(root, a) { wins.append(w as! AXUIElement) }
        }
        out += "\n== AXWindows: \(wins.count)\n"
        for w in wins { walk(w, 1) }
        // 歌词: Lyrics 分组 › 滚动区域 › 分组 › 按钮
        func find(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
            if str(e, kAXRoleAttribute) == kAXGroupRole as String, str(e, kAXDescriptionAttribute) == "Lyrics" { return e }
            guard d < 30 else { return nil }
            for c in children(e) { if let r = find(c, d + 1) { return r } }
            return nil
        }
        var lyricButtons: [AXUIElement] = []
        if let lyr = wins.lazy.compactMap({ find($0, 0) }).first, let scroll = children(lyr).first {
            lyricButtons = children(scroll).flatMap { children($0) }.filter { str($0, kAXRoleAttribute) == kAXButtonRole as String }
        }
        out += "\n== 歌词按钮 \(lyricButtons.count)\n"
        // 每个可见行: 分组和按钮的全部简单属性, 用来找「当前行」标记
        func attrs(_ e: AXUIElement) -> String {
            var names: CFArray?
            AXUIElementCopyAttributeNames(e, &names)
            let skip: Set<String> = ["AXParent", "AXWindow", "AXTopLevelUIElement", "AXChildren", "AXChildrenInNavigationOrder"]
            return ((names as? [String]) ?? []).filter { !skip.contains($0) }.map { n -> String in
                var v = String(describing: raw(e, n) ?? "nil" as AnyObject)
                if let r = v.range(of: "value = ") { v = String(v[r.upperBound...].prefix(40)) }
                return "\(n)=\(v.prefix(50))"
            }.joined(separator: " ")
        }
        if let sa = lyricButtons.first.flatMap({ raw($0, kAXParentAttribute) }).flatMap({ raw($0 as! AXUIElement, kAXParentAttribute) }) {
            out += "滚动区域: \(attrs(sa as! AXUIElement))\n"
        }
        for btn in lyricButtons {
            guard let f = frame(btn), f.minY > 0, f.minY < 1100 else { continue }
            out += "-- y=\(Int(f.minY)) \(str(btn, kAXDescriptionAttribute) ?? "")\n"
            if let g = raw(btn, kAXParentAttribute) { out += "   分组: \(attrs(g as! AXUIElement))\n" }
            out += "   按钮: \(attrs(btn))\n"
        }
        texts = lyricButtons
        out += String(format: "\n== 节点 %d, 遍历耗时 %.0f ms, 文字节点 %d\n", nodes, (CACurrentMediaTime() - t0) * 1000, texts.count)

        // 高频采样: 只在坐标变化时记一行, 看更新是逐帧插值还是直接跳到终点
        let secs = Double(ProcessInfo.processInfo.environment["AX_SAMPLE_SECS"] ?? "") ?? 2
        func ys() -> [CGFloat] {
            texts.map { e in
                guard let v = raw(e, "AXFrame") else { return .nan }
                var r = CGRect.zero
                AXValueGetValue(v as! AXValue, .cgRect, &r)
                return r.minY
            }
        }
        let start = CACurrentMediaTime()
        var prev = ys(), samples = 0, readTotal = 0.0
        out += String(format: "\n== 高频采样 %.0fs\n", secs)
        while CACurrentMediaTime() - start < secs {
            let t = CACurrentMediaTime()
            let cur = ys()
            let rd = CACurrentMediaTime() - t
            samples += 1; readTotal += rd
            let changed = cur.indices.filter { cur[$0] != prev[$0] && !(cur[$0].isNaN && prev[$0].isNaN) }
            if !changed.isEmpty {
                let vis = cur.indices.filter { cur[$0] > 0 && cur[$0] < 1000 }
                let deltas = Set(changed.map { Int((cur[$0] - prev[$0]).rounded()) }).sorted()
                let top = vis.first.map { "#\($0) y=\(String(format: "%.1f", cur[$0]))" } ?? "-"
                out += String(format: "t=%7.1fms read=%4.1fms 变化%2d行 ", (t - start) * 1000, rd * 1000, changed.count)
                    + "Δ=\(deltas.prefix(8)) 顶部可见 \(top)\n"
            }
            prev = cur
        }
        out += String(format: "== 共采样 %d 次, 平均读取 %.1f ms\n", samples, readTotal * 1000 / Double(max(samples, 1)))
        return out
    }

    private static func raw(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
    private static func str(_ e: AXUIElement, _ a: String) -> String? { raw(e, a) as? String }
    private static func children(_ e: AXUIElement) -> [AXUIElement] { (raw(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = raw(e, kAXPositionAttribute), let s = raw(e, kAXSizeAttribute) else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pt)
        AXValueGetValue(s as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }
}
