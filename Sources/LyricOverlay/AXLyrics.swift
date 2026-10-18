import AppKit
import ApplicationServices

/// 无障碍树里的一行歌词 (frame 为全局 CG 坐标, 左上角原点)
struct AXLine: Equatable {
    let id: Int
    let text: String
    let frame: CGRect
    let selected: Bool   // 分组的 AXSelected: Music 当前唱到的那一行
}

/// 从 Music 的无障碍树读整首歌词:
///   窗口 › … › 分组 "Lyrics" › 滚动区域 › 分组 › 按钮 (描述 = 歌词文字)
/// 注意: 坐标是排版终点, 滚动动画期间没有中间值; 可见行还会比屏幕外的行晚约 0.5s 更新。
/// 所以这里只负责文字和排版, 动画交给画面跟踪 (见 FrameProcessor)。
final class AXLyrics: @unchecked Sendable {
    private let queue = DispatchQueue(label: "lyric.ax", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var scrollArea: AXUIElement?
    private var lastLookup: CFTimeInterval = 0
    private var last: [AXLine]?

    /// 有变化时在 ax 队列上回调
    var onLines: (([AXLine]) -> Void)?

    static func ensureTrusted() -> Bool {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    func start(interval: TimeInterval = 0.05) {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: interval)
            t.setEventHandler { [weak self] in self?.poll() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            last = nil
        }
    }

    private func poll() {
        let lines = read()
        if lines != last {
            last = lines
            onLines?(lines)
        }
    }

    private func read() -> [AXLine] {
        if scrollArea == nil {
            // 没打开歌词时整棵树搜索比较贵, 限频
            let now = CACurrentMediaTime()
            guard now - lastLookup > 0.5 else { return [] }
            lastLookup = now
            scrollArea = findScrollArea()
        }
        guard let sa = scrollArea else { return [] }
        guard let groups = Self.raw(sa, kAXChildrenAttribute) as? [AXUIElement] else {
            scrollArea = nil   // 元素失效 (关掉了歌词 / 换了界面)
            return []
        }
        var out: [AXLine] = []
        for g in groups {
            // 歌词行是 分组 › 按钮; 直接挂在滚动区域下的按钮是 "Instrumental Break" 之类的占位, 尺寸为 0
            let selected = (Self.raw(g, kAXSelectedAttribute) as? Bool) ?? false
            for b in (Self.raw(g, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                var vals: CFArray?
                let names = [kAXDescriptionAttribute, "AXFrame"] as CFArray
                guard AXUIElementCopyMultipleAttributeValues(b, names, [], &vals) == .success,
                      let arr = vals as? [AnyObject], arr.count == 2,
                      let text = arr[0] as? String, !text.isEmpty,
                      CFGetTypeID(arr[1]) == AXValueGetTypeID() else { continue }
                var f = CGRect.zero
                AXValueGetValue(arr[1] as! AXValue, .cgRect, &f)
                guard f.width > 1, f.height > 1 else { continue }
                out.append(AXLine(id: out.count, text: text, frame: f, selected: selected))
            }
        }
        return out
    }

    private func findScrollArea() -> AXUIElement? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).first?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        let wins = (Self.raw(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []

        // 1) 按描述找 "Lyrics" 分组 (随系统语言本地化)
        let names: Set<String> = ["Lyrics", "歌词", "歌詞", "가사"]
        var fallback: AXUIElement?
        func walk(_ e: AXUIElement, _ d: Int) -> AXUIElement? {
            let role = Self.raw(e, kAXRoleAttribute) as? String
            let kids = (Self.raw(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            if role == kAXGroupRole as String, let desc = Self.raw(e, kAXDescriptionAttribute) as? String, names.contains(desc),
               let sa = kids.first(where: { Self.raw($0, kAXRoleAttribute) as? String == kAXScrollAreaRole as String }) {
                return sa
            }
            // 2) 兜底: 子元素多为「分组 › 按钮」的滚动区域
            if fallback == nil, role == kAXScrollAreaRole as String {
                let rows = kids.prefix(8).filter {
                    ((Self.raw($0, kAXChildrenAttribute) as? [AXUIElement])?.first).flatMap { Self.raw($0, kAXRoleAttribute) as? String } == kAXButtonRole as String
                }
                if rows.count >= 3 { fallback = e }
            }
            guard d < 30 else { return nil }
            for c in kids { if let r = walk(c, d + 1) { return r } }
            return nil
        }
        for w in wins { if let r = walk(w, 0) { return r } }
        return fallback
    }

    private static func raw(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }
}
