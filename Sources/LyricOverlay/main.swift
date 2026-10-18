// LyricOverlay — Apple Music 实时歌词翻译叠加层
//
// 流程:
//   无障碍树 (20Hz): 整首歌词的文字 + 每行排版位置 → 整首预翻译, 并作为定位基准
//   ScreenCaptureKit 以屏幕最高刷新率只抓 Music 窗口:
//     每帧计算歌词列的行亮度曲线, 与基准帧做互相关 → 垂直滚动偏移 (≈1ms), 补上无障碍树没有的滚动动画
//   当无障碍树里可见行的位置与画面跟踪结果对上时, 切换到新基准 (无缝)
//   翻译: Apple 本地翻译 (默认) 或 OpenRouter (整首一次请求, 带上下文)
//   叠加层: 透明、鼠标穿透的面板, 贴在 Music 窗口上, 在每行歌词上方画译文

import AppKit
import CoreMedia
import NaturalLanguage
import ScreenCaptureKit
import Translation

// MARK: - 配置

struct Config {
    var target = Locale.Language(identifier: "zh-Hans")
    var debug = false
    var fakeTranslate = false   // 调试排版: 不调翻译, 直接显示 "译·原文"
    var dumpAXPath: String?

    static func parse() -> Config {
        var c = Config()
        var it = CommandLine.arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--to": if let v = it.next() { c.target = Locale.Language(identifier: v) }
            case "--debug": c.debug = true
            case "--fake-translate": c.fakeTranslate = true
            case "--dump-ax": c.dumpAXPath = it.next()
            case "-h", "--help":
                print("""
                用法: LyricOverlay [--to zh-Hans] [--debug] [--fake-translate] [--dump-ax 文件]
                环境变量: OPENROUTER_API_KEY (可选, 用 LLM 翻译)  OPENROUTER_MODEL (默认 google/gemini-2.5-flash)
                """)
                exit(0)
            default: print("忽略未知参数 \(a)")
            }
        }
        return c
    }
}

let config = Config.parse()
let musicBundleID = "com.apple.Music"
/// 间奏等占位行 (无障碍树里也是一行, 但不需要翻译)
let lyricPlaceholders: Set<String> = ["Instrumental Break", "器乐间奏", "間奏", "器樂間奏", "간주"]

// MARK: - 歌词行

struct LyricLine: Equatable {
    var id: Int             // 在整首歌词里的序号 (同一首歌内稳定)
    var text: String
    var rect: CGRect        // 窗口坐标 (pt, 左上角原点), 对应跟踪基准帧
    var rowHeight: CGFloat  // 单行歌词的行高, 用来定译文字号
    var selected = false    // Music 当前唱到的那一行
}

// MARK: - 逐行跟踪 (每行歌词各自的亮度曲线互相关)
//
// Apple Music 的滚动不是整体平移: 每行有各自带延迟的弹簧动画, 从上往下像波浪一样依次移动。
// 所以每行单独跟踪: 记下这一行所在位置的行亮度曲线 (只取这一行文字的横向范围), 每帧在上一帧位置附近搜索。

/// 像素缓冲区的只读视图 (调用方负责加锁)
struct Frame {
    let base: UnsafePointer<UInt8>
    let width: Int, height: Int, bytesPerRow: Int

    /// 行 [y0, y1) 在列 [x0, x1) 上的平均亮度, 再做局部归一化
    func profile(y0: Int, y1: Int, x0: Int, x1: Int) -> [Float] {
        let a = max(0, min(x0, width - 1)), b = max(a + 1, min(x1, width))
        let ya = max(0, y0), yb = min(height, y1)
        guard yb > ya else { return [] }
        var out = [Float](repeating: 0, count: yb - ya)
        for y in ya..<yb {
            let row = base + y * bytesPerRow
            var s = 0, n = 0, x = a
            while x < b {
                let p = row + x * 4
                s += Int(p[0]) + Int(p[1]) + Int(p[2])
                n += 1
                x += 4
            }
            out[y - ya] = Float(s) / Float(max(n, 1))
        }
        return Self.normalize(out, radius: 60)
    }

    /// 局部归一化: 减局部均值、除局部标准差。
    /// 当前行高亮时比其它行亮得多, 不归一化的话亮度变化会主导匹配。
    static func normalize(_ p: [Float], radius r: Int) -> [Float] {
        let n = p.count
        guard n > 2 else { return p }
        var s1 = [Double](repeating: 0, count: n + 1), s2 = s1
        for i in 0..<n { s1[i + 1] = s1[i] + Double(p[i]); s2[i + 1] = s2[i] + Double(p[i]) * Double(p[i]) }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let a = max(0, i - r), b = min(n, i + r + 1), k = Double(b - a)
            let mean = (s1[b] - s1[a]) / k
            let sd = max(((s2[b] - s2[a]) / k - mean * mean).squareRoot(), 2)
            out[i] = Float(max(-3, min(3, (Double(p[i]) - mean) / sd)))
        }
        return out
    }
}

/// 一行歌词的跟踪状态 (像素单位)
struct LineTrack {
    var line: LyricLine              // 基准排版 (窗口 pt)
    var ax: CGRect                   // 无障碍树最新位置 (窗口 pt)
    var axChangedAt: CFTimeInterval = 0
    var ref: [Float] = []            // 基准帧里这一行所在条带的亮度曲线
    var refY0 = 0                    // 条带起始行
    var x0 = 0, x1 = 0
    var offset = 0                   // 当前相对基准的垂直位移 (像素)
    var lastMotion: CFTimeInterval = 0
    var tracking = false             // 本帧是否在画面里匹配成功 (条带在画面外或基准为空时为 false)
    var motionAnchor = 0             // 上次记为「在动」时的位移; 累计超过 3px 才算在动, 跟踪抖动不算
    var needsCapture = false         // 启动/换歌时可能正赶上滚动动画, 等画面稳定再截参考曲线
    var history: [(t: CFTimeInterval, y: CGFloat)] = []   // 最近的实际位置 (窗口 pt), 换基准时连续, 供邻行按延迟参照

    /// 当前实际位置 (窗口 pt)
    func y(scale: CGFloat) -> CGFloat { line.rect.minY + CGFloat(offset) / scale }

    /// t 时刻 (或之前最近一次记录) 的实际位置
    func y(at t: CFTimeInterval, scale: CGFloat) -> CGFloat {
        history.last(where: { $0.t <= t })?.y ?? history.first?.y ?? y(scale: scale)
    }

    mutating func record(_ t: CFTimeInterval, scale: CGFloat) {
        history.append((t, y(scale: scale)))
        if history.count > 40 { history.removeFirst(history.count - 40) }
    }

    static let pad = 24              // 条带上下多取的像素, 包含行间空白, 匹配更稳
    static let window = 96           // 每帧搜索范围, 必须小于行距的一半, 否则可能跳到相邻行

    /// 用当前帧重新记录基准
    mutating func capture(_ f: Frame, scale: CGFloat) {
        offset = 0
        motionAnchor = 0
        needsCapture = false
        x0 = Int(line.rect.minX * scale); x1 = Int(line.rect.maxX * scale)
        refY0 = Int(line.rect.minY * scale) - Self.pad
        let y1 = Int(line.rect.maxY * scale) + Self.pad
        // 条带大半在画面外就不跟踪
        guard refY0 >= -Self.pad / 2, y1 <= f.height + Self.pad / 2 else { ref = []; return }
        ref = f.profile(y0: refY0, y1: y1, x0: x0, x1: x1)
        refY0 = max(0, refY0)
    }

    /// 返回位移是否变化
    mutating func update(_ f: Frame) -> Bool {
        tracking = false
        guard ref.count > 2 * Self.pad else { return false }
        let w = Self.window
        let c0 = refY0 + offset - w
        let cur = f.profile(y0: c0, y1: c0 + ref.count + 2 * w, x0: x0, x1: x1)
        let cStart = max(0, c0)   // cur[0] 对应的行
        func cost(_ s: Int) -> Float {
            // ref[i] ≈ 画面第 refY0 + s + i 行
            let lo = max(0, cStart - (refY0 + s)), hi = min(ref.count, cStart + cur.count - (refY0 + s))
            guard hi - lo >= ref.count * 3 / 5 else { return .infinity }
            var acc: Float = 0, i = lo
            let d = refY0 + s - cStart
            while i < hi { acc += abs(ref[i] - cur[i + d]); i += 2 }
            return acc / Float((hi - lo + 1) / 2)
        }
        var best = offset, bestC = cost(offset)
        var s = offset - w
        while s <= offset + w { let c = cost(s); if c < bestC { bestC = c; best = s }; s += 2 }
        for s in (best - 1)...(best + 1) { let c = cost(s); if c < bestC { bestC = c; best = s } }
        guard bestC.isFinite else { return false }
        tracking = true
        guard best != offset else { return false }
        offset = best
        return true
    }
}

// MARK: - 帧处理 (在 capture 队列上运行)

final class FrameProcessor: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "lyric.frames", qos: .userInteractive)
    private var tracks: [LineTrack] = []
    private var axLines: [AXLine] = []
    private var axDirty = false
    private var needReset = true
    private var winFrame: CGRect = .zero
    private var pixelScale: CGFloat = 2
    private var lastPB: CVPixelBuffer?
    private var lastSig = ""
    private var fpsCount = 0, idleCount = 0, rebaseCount = 0, workTime: CFTimeInterval = 0, fpsStamp = CACurrentMediaTime()

    /// (歌词行, 垂直偏移 pt) — 在主线程回调; 行位置已包含跟踪位移, 偏移恒为 0
    var onSnapshot: (@MainActor ([LyricLine], CGFloat) -> Void)?

    func setWindowFrame(_ r: CGRect) { queue.async { self.winFrame = r; self.axDirty = true } }
    func reset() { queue.async { self.needReset = true } }

    func setAX(_ lines: [AXLine]) {
        queue.async { [self] in
            axLines = lines
            axDirty = true
            if let pb = lastPB { process(pb) }   // 画面静止时没有新帧, 也要及时更新
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid, let pb = sb.imageBuffer else { return }
        if let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
           let raw = att[.status] as? Int, let st = SCFrameStatus(rawValue: raw), st != .complete { idleCount += 1; return }
        lastPB = pb
        let t0 = CACurrentMediaTime()
        process(pb)

        if config.debug {
            fpsCount += 1
            let now = CACurrentMediaTime()
            workTime += now - t0
            if now - fpsStamp >= 2 {
                let moving = tracks.filter { $0.offset != 0 }.count
                print(String(format: "capture %.1f fps (+%d idle), %.2f ms/帧, %d 行 (%d 行有位移), 换基准 %d 次",
                             Double(fpsCount) / (now - fpsStamp), idleCount, workTime * 1000 / Double(fpsCount),
                             tracks.count, moving, rebaseCount))
                fpsCount = 0; idleCount = 0; workTime = 0; rebaseCount = 0; fpsStamp = now
            }
        }
    }

    private func process(_ pb: CVPixelBuffer) {
        guard winFrame.height > 0 else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let raw = CVPixelBufferGetBaseAddress(pb) else { return }
        let f = Frame(base: raw.assumingMemoryBound(to: UInt8.self),
                      width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb),
                      bytesPerRow: CVPixelBufferGetBytesPerRow(pb))
        pixelScale = CGFloat(f.height) / winFrame.height
        let now = CACurrentMediaTime()

        if axDirty { mergeAX(f, now: now); axDirty = false }

        let h = winFrame.height
        for i in tracks.indices {
            // 无障碍树在滚动动画开始时就报终点, 画面约 0.6s 后才到位; 静止 0.8s 后再截, 免得截到别的行
            if tracks[i].needsCapture {
                tracks[i].line.rect = tracks[i].ax
                if now - tracks[i].axChangedAt > 0.8 { tracks[i].capture(f, scale: pixelScale) }
                continue
            }
            _ = tracks[i].update(f)
            if abs(tracks[i].offset - tracks[i].motionAnchor) > 3 {
                tracks[i].motionAnchor = tracks[i].offset
                tracks[i].lastMotion = now
            }
        }
        for i in tracks.indices where tracks[i].tracking { tracks[i].record(now, scale: pixelScale) }
        // 刚进出画面边缘的行跟踪不到: 按无障碍树的排版挂在最近的可跟踪邻行上
        // (位置 = 邻行实际位置 + 两行在无障碍树里的间距), 让它跟着滑入/滑出而不是卡住。
        // 滚动是从上往下的波浪, 每往下一行约晚 45ms 启动: 参照上方行时取它稍早时刻的位置。
        let tracked = tracks.indices.filter { tracks[$0].tracking }
        if !tracked.isEmpty {
            for i in tracks.indices where !tracks[i].tracking && !tracks[i].needsCapture {
                guard let j = tracked.min(by: { abs($0 - i) < abs($1 - i) }), abs(j - i) <= 4 else { continue }
                let yj = j < i ? tracks[j].y(at: now - 0.045 * Double(i - j), scale: pixelScale) : tracks[j].y(scale: pixelScale)
                let yi = yj + (tracks[i].ax.minY - tracks[j].ax.minY)
                let off = Int(((yi - tracks[i].line.rect.minY) * pixelScale).rounded())
                guard off != tracks[i].offset else { continue }
                tracks[i].offset = off
                if abs(off - tracks[i].motionAnchor) > 3 { tracks[i].motionAnchor = off; tracks[i].lastMotion = now }
                trace("挂靠 #\(tracks[i].line.id) ← #\(tracks[j].line.id) y=\(Int(yi))")
            }
        }

        for i in tracks.indices where !tracks[i].needsCapture {
            // 逐行换基准: 无障碍树给的新位置与这一行的跟踪结果对上时, 无缝切换
            let t = tracks[i]
            let tracked = t.line.rect.minY + CGFloat(t.offset) / pixelScale
            let differs = t.ax != t.line.rect
            if differs, abs(t.ax.minY - tracked) < 6 { rebase(i, f, "对上"); continue }
            // 两个位置都在画面外: 看不到也跟踪不了, 直接用无障碍树的
            let offscreen = { (y: CGFloat) in y > h + 20 || y + t.line.rect.height < -20 }
            if differs, offscreen(tracked), offscreen(t.ax.minY) { rebase(i, f, "画面外"); continue }
            // 兜底: 这一行在画面和无障碍树里都静止一段时间后强制对齐 (手动滚动 / 缩放 / 漂移)
            if differs || t.offset != 0, now - t.axChangedAt > 0.7, now - t.lastMotion > 0.25 { rebase(i, f, "兜底") }
        }

        if traceOn {
            let vis = tracks.filter { let y = $0.line.rect.minY + CGFloat($0.offset) / pixelScale; return y > -40 && y < winFrame.height }
            let sig = vis.map { t -> String in
                let y = Int(t.line.rect.minY + CGFloat(t.offset) / pixelScale)
                return "#\(t.line.id)[\(t.line.text.prefix(4))] y=\(y) ax=\(Int(t.ax.minY))\(t.tracking ? "" : "*")\(t.needsCapture ? "?" : "")"
            }.joined(separator: " | ")
            if sig != lastSig { lastSig = sig; trace(sig) }
        }
        let snap = tracks.map { t -> LyricLine in
            var l = t.line
            l.rect.origin.y += CGFloat(t.offset) / pixelScale
            return l
        }
        let cb = onSnapshot
        Task { @MainActor in cb?(snap, 0) }
    }

    private let traceOn = ProcessInfo.processInfo.environment["LYRIC_TRACE"] != nil
    private let traceStart = CACurrentMediaTime()
    private func trace(_ msg: @autoclosure () -> String) {
        guard traceOn else { return }
        print(String(format: "%7.0f ", (CACurrentMediaTime() - traceStart) * 1000) + msg())
    }

    private func rebase(_ i: Int, _ f: Frame, _ why: String = "") {
        let t = tracks[i]
        if t.ax.minY > -50, t.ax.minY < winFrame.height + 50 || t.line.rect.minY + CGFloat(t.offset) / pixelScale < winFrame.height + 50 {
            trace("换基准[\(why)] #\(t.line.id) 跟踪y=\(Int(t.line.rect.minY + CGFloat(t.offset) / pixelScale)) → ax y=\(Int(t.ax.minY)) tracking=\(t.tracking)")
        }
        tracks[i].line.rect = tracks[i].ax
        tracks[i].capture(f, scale: pixelScale)
        rebaseCount += 1
    }

    /// 合入无障碍树的最新结果; 换歌 (行数或文字变了) 时全部重建
    private func mergeAX(_ f: Frame, now: CFTimeInterval) {
        let hs = axLines.map(\.frame.height).sorted()
        let row = hs.isEmpty ? 0 : hs[hs.count / 2]   // 中位行高 ≈ 单行歌词
        let rects = axLines.map { $0.frame.offsetBy(dx: -winFrame.minX, dy: -winFrame.minY) }
        let sameSong = !needReset && tracks.count == axLines.count && zip(tracks, axLines).allSatisfy { $0.line.text == $1.text }
        if sameSong {
            for i in tracks.indices { tracks[i].line.selected = axLines[i].selected }
            for i in tracks.indices where tracks[i].ax != rects[i] {
                if traceOn, rects[i].minY > -50, rects[i].minY < winFrame.height + 50 {
                    trace("ax #\(tracks[i].line.id) y \(Int(tracks[i].ax.minY)) → \(Int(rects[i].minY))")
                }
                tracks[i].ax = rects[i]
                tracks[i].axChangedAt = now
            }
            return
        }
        needReset = false
        tracks = zip(axLines, rects).map { a, r in
            var t = LineTrack(line: LyricLine(id: a.id, text: a.text, rect: r, rowHeight: row, selected: a.selected), ax: r, axChangedAt: now)
            t.needsCapture = true
            return t
        }
    }
}

// MARK: - 翻译 (整首预取, 按行缓存)

@MainActor final class Translator {
    private var cache: [String: String] = [:]   // "" = 不需要/无法翻译
    private var pending: Set<String> = []
    private var sessions: [String: TranslationSession] = [:]
    private var warned: Set<String> = []
    private let target: Locale.Language
    // 环境变量优先; 从「应用程序」启动时没有 shell 环境, 用 defaults write com.gao.LyricOverlay OPENROUTER_API_KEY ... 配置
    private let orKey = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]
        ?? UserDefaults.standard.string(forKey: "OPENROUTER_API_KEY")
    private let orModel = ProcessInfo.processInfo.environment["OPENROUTER_MODEL"]
        ?? UserDefaults.standard.string(forKey: "OPENROUTER_MODEL") ?? "google/gemini-2.5-flash"
    var onUpdate: (() -> Void)?

    init(target: Locale.Language) {
        self.target = target
        print(config.fakeTranslate ? "翻译: 假翻译 (调试排版)" : orKey != nil ? "翻译: OpenRouter (\(orModel))" : "翻译: Apple 本地翻译")
    }

    func translation(for text: String) -> String? {
        if let t = cache[text] { return t.isEmpty ? nil : t }
        if !pending.contains(text) { prefetch([text]) }
        return nil
    }

    /// 歌词一出现就把整首送去翻译
    func prefetch(_ texts: [String]) {
        var seen = Set<String>()
        let todo = texts.filter { cache[$0] == nil && !pending.contains($0) && seen.insert($0).inserted }
        guard !todo.isEmpty else { return }
        pending.formUnion(todo)
        Task { await translate(todo) }
    }

    private func translate(_ texts: [String]) async {
        defer { pending.subtract(texts) }
        if config.fakeTranslate {
            for t in texts { cache[t] = "译·" + t }
            onUpdate?(); return
        }
        // 整首的主语言: 纯汉字的日文行单独检测会被认成中文, 用整首的语言纠正
        let song = Self.detect(texts.joined(separator: "\n"))
        var need: [(String, Locale.Language)] = []
        for t in texts {
            if lyricPlaceholders.contains(t) { cache[t] = ""; continue }
            guard var lang = Self.detect(t) else { cache[t] = ""; continue }
            if lang.languageCode == target.languageCode, let song, song.languageCode != target.languageCode,
               t.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) { lang = song }
            if lang.languageCode == target.languageCode { cache[t] = ""; continue }   // 已是目标语言
            need.append((t, lang))
        }
        guard !need.isEmpty else { return }

        if orKey != nil {
            let lines = need.map(\.0)
            let batch = await openRouterBatch(lines)
            for (i, t) in lines.enumerated() {
                if let b = batch { cache[t] = b[i] } else { cache[t] = await openRouter(t) ?? "" }
            }
        } else {
            for (t, src) in need {
                cache[t] = await apple(t, src) ?? ""
                if config.debug { print("[\(src.minimalIdentifier)] \(t) → \(cache[t] ?? "")") }
            }
        }
        onUpdate?()
    }


    private static func detect(_ text: String) -> Locale.Language? {
        let rec = NLLanguageRecognizer()
        rec.processString(text)
        return rec.dominantLanguage.map { Locale.Language(identifier: $0.rawValue) }
    }

    private func apple(_ text: String, _ src: Locale.Language) async -> String? {
        let key = src.minimalIdentifier
        let session: TranslationSession
        if let s = sessions[key] { session = s } else {
            session = TranslationSession(installedSource: src, target: target)
            sessions[key] = session
        }
        do { return try await session.translate(text).targetText }
        catch {
            if warned.insert(key).inserted {
                print("⚠️ Apple 翻译 \(key) → \(target.minimalIdentifier) 失败: \(error)\n   请到 系统设置 › 通用 › 语言与地区 › 翻译语言 下载该语言, 或设置 OPENROUTER_API_KEY")
            }
            return nil
        }
    }

    private var targetName: String {
        Locale(identifier: "en").localizedString(forIdentifier: target.minimalIdentifier) ?? target.minimalIdentifier
    }

    /// 整首一次请求, 模型能看到上下文; 返回条数对不上则返回 nil 退回逐行
    private func openRouterBatch(_ lines: [String]) async -> [String]? {
        guard let input = try? JSONSerialization.data(withJSONObject: lines),
              let content = await chat(
                system: "You translate song lyrics into \(targetName). The user sends a JSON array of lyric lines from one song, in order. Reply with ONLY a JSON array of exactly the same length: the translation of each line, using the whole song as context, natural and concise, poetic where fitting. No notes or romanization.",
                user: String(decoding: input, as: UTF8.self)),
              let a = content.firstIndex(of: "["), let b = content.lastIndex(of: "]"),
              let arr = try? JSONSerialization.jsonObject(with: Data(content[a...b].utf8)) as? [String],
              arr.count == lines.count else {
            if config.debug { print("整首翻译失败, 改为逐行") }
            return nil
        }
        if config.debug { for (s, t) in zip(lines, arr) { print("\(s) → \(t)") } }
        return arr
    }

    private func openRouter(_ text: String) async -> String? {
        await chat(system: "You translate song lyrics into \(targetName). Reply with only the translation of the given line: natural, concise, poetic where fitting. No quotes, notes or romanization.",
                   user: text)
    }

    private func chat(system: String, user: String) async -> String? {
        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(orKey!)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": orModel, "temperature": 0.3,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let msg = (json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any]
            return (msg?["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            if warned.insert("openrouter").inserted { print("⚠️ OpenRouter 请求失败: \(error)") }
            return nil
        }
    }
}

// MARK: - 叠加层窗口

/// One Euro 滤波: 静止时强平滑去抖, 快速移动时放开截止频率减少拖尾
struct OneEuro {
    var minCutoff = 1.0, beta = 0.02, dCutoff = 1.0
    private(set) var value: Double?
    private var dx = 0.0

    mutating func reset(_ v: Double) { value = v; dx = 0 }

    mutating func filter(_ v: Double, dt: Double) -> Double {
        guard let prev = value else { value = v; return v }
        func alpha(_ fc: Double) -> Double { let r = 2 * .pi * fc * dt; return r / (r + 1) }
        dx += alpha(dCutoff) * ((v - prev) / dt - dx)
        let x = prev + alpha(minCutoff + beta * abs(dx)) * (v - prev)
        value = x
        return x
    }
}

/// 一条译文标签 (按歌词行 id 保持身份), 位置经滤波后逐帧更新
final class LabelState {
    let layer = CATextLayer()
    var translation = ""
    var fontSize: CGFloat = 0
    var size = CGSize.zero
    var target = CGPoint.zero  // 标签左上角目标位置
    var fx = OneEuro(), fy = OneEuro()
    var goneAt: CFTimeInterval?    // 不在最新歌词列表里的时刻, 之后淡出
    var alpha = 0.0                // 当前不透明度, 平滑趋向目标值 (出现时淡入, 消失时淡出)
    var blurLevel: Double?         // 模糊档位 (AMLL 的 px 值); 0 = 当前行, nil = 不知道当前行
    var rightAligned = false
    var blur = 0.0, dim = 1.0      // 当前模糊半径 / 亮度, 平滑过渡
    var appliedBlur = -1.0
    var rowHeight: CGFloat = 0
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    var onTick: ((CFTimeInterval) -> Void)?
    private var link: CADisplayLink?

    func startTicking() {
        if link == nil {
            link = displayLink(target: self, selector: #selector(tick(_:)))
            link?.add(to: .main, forMode: .common)
        }
        link?.isPaused = false
    }
    func stopTicking() { link?.isPaused = true }
    @objc private func tick(_ l: CADisplayLink) { onTick?(l.targetTimestamp) }
}

@MainActor final class Overlay {
    private let panel: NSPanel
    private let view = FlippedView()
    private var states: [Int: LabelState] = [:]
    private var lastTick: CFTimeInterval = 0

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // 普通层级, 紧贴在 Music 窗口上方: 别的窗口挡住 Music 时也挡住译文, 只在 Music 露出来的地方可见
        panel.level = .normal
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true   // 译文按与当前行的距离做高斯模糊
        panel.contentView = view
        view.onTick = { [weak self] t in MainActor.assumeIsolated { self?.tick(t) } }
    }

    var isVisible: Bool { panel.isVisible }

    /// 显示并放到 Music 窗口正上方
    func show(above music: CGWindowID) {
        panel.order(.above, relativeTo: Int(music))
        view.startTicking()
    }

    func hide() { panel.orderOut(nil); view.stopTicking() }

    /// Music 被点到前面后会盖住译文层, 检查后重新贴到它上方
    func keepAbove(_ music: CGWindowID) {
        guard panel.isVisible,
              let above = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow], music) as? [[String: Any]] else { return }
        // 列表从前往后排, 紧挨在 Music 上面的是最后一个
        let next = above.last { ($0[kCGWindowLayer as String] as? Int) == 0 }
        if (next?[kCGWindowNumber as String] as? Int) != panel.windowNumber {
            panel.order(.above, relativeTo: Int(music))
        }
    }

    /// cg: 全局 CoreGraphics 坐标 (主屏左上角原点)
    func setFrame(cg: CGRect) {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let ns = NSRect(x: cg.minX, y: primaryH - cg.maxY, width: cg.width, height: cg.height)
        if panel.frame != ns { panel.setFrame(ns, display: false) }
    }

    /// 只更新目标位置; 真正的绘制在 tick 里按屏幕刷新率平滑进行
    func render(_ lines: [LyricLine], shift: CGFloat, translator: Translator) {
        let now = CACurrentMediaTime()
        let height = panel.frame.height
        var seen = Set<Int>()
        // 字号: 按单行歌词的行高 (排除间奏占位) 等比计算,
        // 例如单行约 60pt → 22pt, 约 34pt → 12.5pt
        let real = lines.filter { !lyricPlaceholders.contains($0.text) }
        let base = Self.singleRowHeight(real.map(\.rect.height)) ?? 60
        // 不设上限, 跟着 Music 的歌词字号等比缩放; 按 0.5pt 取整, 避免细微变化时反复重排文字
        let fs = (max(base * 0.37, 9) * 2).rounded() / 2
        // 不带时间轴的静态歌词: 同一段内行与行紧挨着, 行间放不下译文, 先不叠加 (否则会和原文叠成一团)
        let gaps = zip(real, real.dropFirst()).map { $1.rect.minY - $0.rect.maxY }.sorted()
        if let mid = gaps.isEmpty ? nil : gaps[gaps.count / 2], mid < fs * 1.2 + 6 {
            for (_, st) in states where st.goneAt == nil { st.goneAt = now }
            return
        }
        // 对唱时另一位歌手的行整体右移、文字右对齐
        let colLeft = lines.map(\.rect.minX).min() ?? 0
        let selected = lines.indices.filter { lines[$0].selected }
        for (k, line) in lines.enumerated() {
            let top = line.rect.minY + shift
            // 窗口外附近的行也保留标签, 由边缘渐隐控制可见度, 这样能平滑滑入滑出
            guard top > -line.rect.height - 200, top < height + 200,
                  let tr = translator.translation(for: line.text) else { continue }
            let st = states[line.id] ?? newState(line.id)
            let right = line.rect.minX > colLeft + 20

            if st.translation != tr || st.fontSize != fs || st.rightAligned != right {
                st.translation = tr
                st.fontSize = fs
                st.rightAligned = right
                let para = NSMutableParagraphStyle()
                para.alignment = right ? .right : .left
                let attr = NSAttributedString(string: tr, attributes: [
                    .font: NSFont.systemFont(ofSize: fs, weight: .semibold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: para,
                ])
                let maxW = max(80, line.rect.width)
                let sz = attr.boundingRect(with: CGSize(width: maxW, height: 400), options: [.usesLineFragmentOrigin]).size
                st.size = CGSize(width: ceil(sz.width) + 2, height: ceil(sz.height))
                st.layer.string = attr
                st.layer.alignmentMode = right ? .right : .left
            }
            st.rowHeight = line.rowHeight
            // 译文底边留一点空隙, 不压住原文
            let x = right ? line.rect.maxX - st.size.width : line.rect.minX
            st.target = CGPoint(x: x, y: top - st.size.height - 6)

            // 模糊档位, 照 AMLL (applemusic-like-lyrics) 的 resolveBlurLevel:
            // 当前行 0; 其它行 1 + 距离, 已唱过的 (上方) 行距离再 +1; 上限 5
            if let lo = selected.first, let hi = selected.last {
                let d = k < lo ? lo - k + 1 : k > hi ? k - hi : 0
                st.blurLevel = selected.contains(k) ? 0 : Double(min(1 + d, 5))
            } else {
                st.blurLevel = nil
            }
            st.goneAt = nil
            seen.insert(line.id)
        }
        for (id, st) in states where !seen.contains(id) && st.goneAt == nil { st.goneAt = now }
    }

    /// 单行歌词的行高: 按 2pt 分组, 取占比至少两成的组里最矮的一组。
    /// 和声小字行 (字号小) 和折成多行的长句都只占少数, 不会把它带偏
    static func singleRowHeight(_ hs: [CGFloat]) -> CGFloat? {
        guard !hs.isEmpty else { return nil }
        var buckets: [Int: [CGFloat]] = [:]
        for h in hs { buckets[Int(h / 2), default: []].append(h) }
        let need = max(2, hs.count / 5)
        let pick = buckets.keys.sorted().first { buckets[$0]!.count >= need } ?? buckets.max { $0.value.count < $1.value.count }!.key
        let b = buckets[pick]!
        return b.reduce(0, +) / CGFloat(b.count)
    }

    private func newState(_ id: Int) -> LabelState {
        let st = LabelState()
        st.layer.isWrapped = true
        st.layer.contentsScale = panel.backingScaleFactor
        st.layer.shadowColor = NSColor.black.cgColor
        st.layer.shadowOpacity = 0.8
        st.layer.shadowRadius = 3
        st.layer.shadowOffset = .zero
        st.layer.opacity = 0
        view.layer?.addSublayer(st.layer)
        states[id] = st
        return st
    }

    private func tick(_ t: CFTimeInterval) {
        let dt = min(max(lastTick == 0 ? 1.0 / 120 : t - lastTick, 0.001), 0.1)
        lastTick = t
        let scale = panel.backingScaleFactor
        func px(_ v: Double) -> CGFloat { (CGFloat(v) * scale).rounded() / scale }   // 对齐像素, 防止文字发虚闪烁

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let height = Double(panel.frame.height)
        func smooth(_ v: Double) -> Double { let t = max(0, min(1, v)); return t * t * (3 - 2 * t) }
        for (id, st) in states {
            // 新标签或跳变过大 (换了一行) 直接就位, 不做滑动
            if let y = st.fy.value, abs(Double(st.target.y) - y) < Double(max(st.rowHeight * 2, 80)) {} else {
                st.fx.reset(Double(st.target.x)); st.fy.reset(Double(st.target.y))
            }
            let x = st.fx.filter(Double(st.target.x), dt: dt)
            let y = st.fy.filter(Double(st.target.y), dt: dt)
            st.layer.frame = CGRect(x: px(x), y: px(y), width: st.size.width, height: st.size.height)

            // 上下边缘渐隐, 和 Music 自己的歌词边缘遮罩一致; 不在列表里的行淡出
            let fade = max(Double(st.rowHeight) * 1.2, 100)
            let topEdge = 40.0, bottomEdge = height - 20
            let edge = smooth((y - topEdge) / fade) * smooth((bottomEdge - (y + Double(st.size.height))) / fade)
            let target = st.goneAt == nil ? edge : 0
            st.alpha += (target - st.alpha) * (1 - exp(-dt / 0.08))
            if st.goneAt != nil, st.alpha < 0.01 { st.layer.removeFromSuperlayer(); states[id] = nil; continue }

            // 像 Music 一样: 当前行清晰明亮, 其它行按档位模糊并压暗。
            // AMLL 的档位是给约 40pt 的歌词用的; 译文字小, 按字号等比缩小后再减半, 对照实际画面和 Music 的模糊程度相当
            let (blurT, dimT): (Double, Double) = st.blurLevel.map { lv in
                lv == 0 ? (0, 1) : (lv * Double(st.fontSize) / 40 * 0.5, 0.6)
            } ?? (0, 1)
            let k = 1 - exp(-dt / 0.12)   // ≈ CSS transition 0.4s ease
            st.blur += (blurT - st.blur) * k
            st.dim += (dimT - st.dim) * k
            if abs(st.blur - st.appliedBlur) > 0.05 {
                st.appliedBlur = st.blur
                st.layer.filters = st.blur < 0.1 ? nil
                    : [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: st.blur * Double(scale)])!]
            }
            st.layer.opacity = Float(st.alpha * st.dim)
        }
        CATransaction.commit()
    }
}

// MARK: - 主控: 前台检测 / 抓取 / 窗口跟随

@MainActor final class Controller: NSObject, SCStreamDelegate {
    private let processor = FrameProcessor()
    private let ax = AXLyrics()
    private var lastWinFrame: CGRect = .zero
    private let overlay = Overlay()
    private let translator = Translator(target: config.target)
    private var stream: SCStream?
    private var streamConfig: SCStreamConfiguration?
    private var windowID: CGWindowID = 0
    private var windowSize: CGSize = .zero
    private var starting = false
    private var lastSnap: ([LyricLine], CGFloat) = ([], 0)
    private var followTimer: Timer?
    private var fps = 60
    private var statusItem: NSStatusItem?
    private var watchTimer: Timer?
    private var hasLyrics = false
    private var lyricsGoneAt: CFTimeInterval = 0
    private var zTick = 0

    func start() {
        // 菜单栏图标 (应用没有 Dock 图标, 从这里退出)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "quote.bubble", accessibilityDescription: "歌词翻译")
        let menu = NSMenu()
        menu.addItem(withTitle: "Apple Music 歌词翻译", action: nil, keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            print("需要屏幕录制权限: 系统设置 › 隐私与安全性 › 屏幕与系统录音 › 打开 LyricOverlay 后重启本程序")
        }
        if !AXLyrics.ensureTrusted() {
            print("需要辅助功能权限 (读取歌词): 系统设置 › 隐私与安全性 › 辅助功能 › 打开 LyricOverlay")
        }
        let proc = processor
        ax.onLines = { [weak self] lines in
            proc.setAX(lines)
            if config.debug { print("无障碍树: \(lines.count) 行歌词") }
            Task { @MainActor in
                guard let self else { return }
                self.translator.prefetch(lines.map(\.text))
                if self.hasLyrics, lines.isEmpty { self.lyricsGoneAt = CACurrentMediaTime() }
                let had = self.hasLyrics
                self.hasLyrics = !lines.isEmpty
                if self.hasLyrics != had { self.watch() }
            }
        }
        processor.onSnapshot = { [weak self] lines, shift in
            guard let self else { return }
            lastSnap = (lines, shift)
            overlay.render(lines, shift: shift, translator: translator)
        }
        translator.onUpdate = { [weak self] in
            guard let self else { return }
            overlay.render(lastSnap.0, shift: lastSnap.1, translator: translator)
        }
        // 只要 Music 窗口在屏幕上露出来、并且显示着歌词就工作, 不要求在前台
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.watch() } }
        watchTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watch() }
        }
        RunLoop.main.add(watchTimer!, forMode: .common)
        watch()
        print("运行中 — 打开 Apple Music 的歌词即可 (菜单栏图标可退出)")
    }

    /// 屏幕上可见的 Music 主窗口 (最大的那个)
    private func visibleMusicWindow() -> (id: CGWindowID, frame: CGRect)? {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: musicBundleID).first?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        return list.compactMap { w -> (CGWindowID, CGRect)? in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
                  ((w[kCGWindowAlpha as String] as? Double) ?? 1) > 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd as CFDictionary), r.width > 200, r.height > 200 else { return nil }
            return (id, r)
        }.max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }
    }

    /// 每 0.5s: Music 窗口可见就读歌词; 有歌词才抓画面 (没歌词时不白跑 120Hz)
    private func watch() {
        guard let win = visibleMusicWindow() else {
            stopCapture(); ax.stop(); hasLyrics = false
            return
        }
        ax.start()
        if stream != nil, win.id != windowID { stopCapture() }   // 换了窗口
        if hasLyrics, stream == nil { Task { await startCapture(win.id) } }
        if !hasLyrics, stream != nil, CACurrentMediaTime() - lyricsGoneAt > 3 { stopCapture() }
    }

    private func startCapture(_ target: CGWindowID) async {
        guard stream == nil, !starting else { return }
        starting = true
        defer { starting = false }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let win = content.windows.first(where: { $0.windowID == target }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            let sc = CGFloat(filter.pointPixelScale)
            cfg.width = Int(win.frame.width * sc)
            cfg.height = Int(win.frame.height * sc)
            fps = screen(for: win.frame)?.maximumFramesPerSecond ?? 60
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = false
            cfg.queueDepth = 6
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(processor, type: .screen, sampleHandlerQueue: processor.queue)
            processor.reset()
            processor.setWindowFrame(win.frame)
            lastWinFrame = win.frame
            try await s.startCapture()
            guard hasLyrics, visibleMusicWindow()?.id == target else { try? await s.stopCapture(); return }
            stream = s; streamConfig = cfg; windowID = win.windowID; windowSize = win.frame.size
            overlay.setFrame(cg: win.frame)
            overlay.show(above: windowID)
            startFollowTimer()
            print("开始抓取 Music 窗口 \(Int(win.frame.width))×\(Int(win.frame.height)) @\(sc)x, \(fps)Hz")
        } catch {
            print("抓取失败: \(error)\n   检查屏幕录制权限 (系统设置 › 隐私与安全性 › 屏幕与系统录音)")
        }
    }

    private func startFollowTimer() {
        followTimer?.invalidate()
        followTimer = Timer(timeInterval: 1.0 / Double(fps), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followWindow() }
        }
        RunLoop.main.add(followTimer!, forMode: .common)
    }

    private func stopCapture() {
        followTimer?.invalidate(); followTimer = nil
        overlay.hide()
        if let s = stream { stream = nil; Task { try? await s.stopCapture() } }
    }

    /// 跟随窗口移动/缩放
    private func followWindow() {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let w = info.first, let bd = w[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bd as CFDictionary) else {
            stopCapture(); return   // 窗口关闭了
        }
        let onScreen = (w[kCGWindowIsOnscreen as String] as? Bool) ?? false
        if !onScreen { overlay.hide(); return }   // 最小化 / 切到别的桌面
        if !overlay.isVisible { overlay.show(above: windowID) }
        overlay.setFrame(cg: rect)
        zTick += 1
        if zTick % 2 == 0 { overlay.keepAbove(windowID) }
        if rect != lastWinFrame { lastWinFrame = rect; processor.setWindowFrame(rect) }
        guard let s = stream, let cfg = streamConfig else { return }
        let scr = screen(for: rect)
        let newFPS = scr?.maximumFramesPerSecond ?? fps
        guard rect.size != windowSize || newFPS != fps else { return }
        if rect.size != windowSize {   // 缩放
            windowSize = rect.size
            let sc = scr?.backingScaleFactor ?? 2
            cfg.width = Int(rect.width * sc); cfg.height = Int(rect.height * sc)
            processor.reset()
        }
        if newFPS != fps {             // 拖到了刷新率不同的显示器
            fps = newFPS
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
            startFollowTimer()
            print("切换到 \(fps)Hz")
        }
        Task { try? await s.updateConfiguration(cfg) }
    }

    /// 窗口中心所在的显示器 (rect 为 CG 全局坐标)
    private func screen(for rect: CGRect) -> NSScreen? {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let p = NSPoint(x: rect.midX, y: primaryH - rect.midY)
        return NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("抓取中断: \(error)")
        Task { @MainActor in
            self.stopCapture()
            self.watch()
        }
    }
}

// MARK: - 入口

setvbuf(stdout, nil, _IOLBF, 0)
if let p = config.dumpAXPath { AXDump.run(to: p) }
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = MainActor.assumeIsolated { Controller() }
MainActor.assumeIsolated { controller.start() }
signal(SIGINT) { _ in exit(0) }
app.run()
