import Foundation
import Darwin

/// 中文日志输出层（本地化改动，不碰上游协议与业务逻辑）。
///
/// SillHost 是一个命令行进程，所有用户可见信息都经 stdout 输出。这里在进程启动最早期
/// 把 stdout 接到一根管道上，由一个后台线程逐行做短语替换后再写回真正的 stdout。
/// 好处是一处改动覆盖 StreamServer / StreamCoordinator / Stats / LockPolicy 等全部
/// 70 多个源文件的 274 条日志，不需要改任何业务代码，也不会影响 wire format。
///
/// 设 SILL_LANG=en 可随时切回原始英文输出。
enum ChineseLog {

    // 长的短语排在前面，避免短词先替换掉长短语的一部分。
    private static let phrases: [(String, String)] = [
        // 最长的最优先：否则 "installed apps:" 会先被 " apps" 拆成 "installed 个应用:"。
        ("installed apps:", "已安装应用："),
        // 长短语必须排在单词替换之前，否则 "Streaming" 会被拆成 "串流ing"。
        ("Streaming a synthetic test pattern at", "正在以"),
        ("Synthetic capture:", "合成画面采集："),
        ("Catalog →", "目录 →"),
        ("Client hello:", "客户端信息："),
        ("Client left:", "客户端已离开："),
        (" windows, ", " 个窗口，"),
        (" icons, ", " 个图标，"),
        (" apps", " 个应用"),
        ("串流ing", "正在串流"),
        ("Locked: this Mac's screen is locked; devices see none of it until it is unlocked, and only a paired device types at it.",
         "已锁定：此 Mac 屏幕处于锁定状态，解锁前客户端看不到画面，且只有已配对设备可以输入。"),
        ("If this is a permissions error: System Settings › Privacy & Security › Screen Recording, enable Terminal, then run again.",
         "如果是权限问题：系统设置 › 隐私与安全性 › 屏幕录制，允许「终端」后重新运行。"),
        ("Synthetic mode: pick Desktop on the device (or from a test client) to stream a test pattern.",
         "合成画面模式：在客户端选择「桌面」即可串流测试图案（无需屏幕录制权限）。"),
        ("Internet access on for this run: the remote door also admits paired devices from outside this Mac's networks and VPNs.",
         "本次已开放公网访问：远程入口也接受本机网络与 VPN 之外的已配对设备。"),
        ("Virtual display mode: a picked window streams from its own HiDPI display; Ctrl-C puts it back.",
         "虚拟显示器模式：选中的窗口会在独立的 HiDPI 虚拟屏上串流；按 Ctrl-C 还原。"),
        ("windows on screen. Advertising _sill._tcp on the local network.",
         "个窗口可见。正在局域网广播 _sill._tcp 服务。"),
        ("Nothing is streaming yet: pick a window from the iOS app. Ctrl-C to stop.",
         "尚未开始串流：请在客户端选择一个窗口。按 Ctrl-C 停止。"),
        ("Remote access for this run on port", "本次远程访问入口端口"),
        ("(TLS, paired devices only). Pair with", "（TLS，仅限已配对设备）。配对码"),
        ("--remote=PORT takes a port from 1024 to 65535.", "--remote=PORT 的端口须在 1024–65535 之间。"),
        ("--internet needs --remote.", "--internet 需要同时指定 --remote。"),
        ("Hardware encoder probe: responding after", "硬件编码器探测："),
        ("Client connected:", "客户端已连接："),
        ("Client disconnected", "客户端已断开"),
        ("installed apps:", "已安装应用："),
        ("(+ icons ", "（图标 "),
        (", off the main thread)", "，后台线程）"),
        (" in ", " 用时 "),
        (" ms", " 毫秒"),
        ("SILL_TEST_REMOTE_DIR=", "测试目录 SILL_TEST_REMOTE_DIR="),
        (" ignored:", " 已忽略："),
        ("Remote access unavailable:", "远程访问不可用："),
        ("Pairing required for this run (TLS on the home door).", "本次要求配对（家庭入口启用 TLS）。"),
        ("Pairing not required for this run (TLS on the home door; SILL_TEST_REQUIRE_PAIRING=0).",
         "本次不要求配对（家庭入口启用 TLS；SILL_TEST_REQUIRE_PAIRING=0）。"),
        ("Pairing: ", "配对："),
        (" asked; code ", " 请求配对；配对码 "),
        ("Error: ", "错误："),
        ("No windows", "没有窗口"),
        ("No screen recording permission", "没有屏幕录制权限"),
        ("Screen Recording", "屏幕录制"),
        ("Accessibility", "辅助功能"),
        ("Local Network", "本地网络"),
        ("permission", "权限"),
        ("Permission", "权限"),
        (" refused", " 被拒绝"),
        ("Refused ", "已拒绝 "),
        ("needs ", "需要 "),
        (" or later.", " 或更高版本。"),
        ("Update Sill", "请升级 Sill"),
        ("keep using", "才能继续使用"),
        ("connected", "已连接"),
        ("disconnected", "已断开"),
        (" windows", " 个窗口"),
        (" clients", " 个客户端"),
        (" client", " 个客户端"),
        ("idle", "空闲"),
        ("enc.out", "编码输出"),
        ("enc.probeOK", "编码器探测通过"),
        ("encode", "编码"),
        ("Encoder", "编码器"),
        ("hardware", "硬件"),
        ("software", "软件"),
        ("fallback", "回退"),
        ("keyframe", "关键帧"),
        ("frame", "帧"),
        ("source", "画面源"),
        ("Source", "画面源"),
        ("window", "窗口"),
        ("Window", "窗口"),
        ("Desktop", "桌面"),
        ("device", "设备"),
        ("Device", "设备"),
        ("session", "会话"),
        ("Session", "会话"),
        ("stream", "串流"),
        ("Stream", "串流"),
        ("picked", "已选择"),
        ("selected", "已选择"),
        ("closed", "已关闭"),
        ("ready", "就绪"),
        ("failed", "失败"),
        ("refused", "被拒绝"),
        ("unavailable", "不可用"),
        ("advertising", "正在广播"),
        ("Advertising", "正在广播"),
        ("Stopped", "已停止"),
        ("stopped", "已停止"),
        ("started", "已启动"),
        ("Starting", "正在启动"),
        ("paused", "已暂停"),
    ]

    /// 每个进程只装一次：重复 dup2 会把翻译管道再套一层。
    nonisolated(unsafe) private static var installed = false

    /// 在任何 print 之前调用一次。SILL_LANG=en 时不翻译；没有 `sink` 时也就完全不介入。
    /// `sink`：融合 app 在自己进程里跑被控端时，用它拿到每一行（已翻译）显示在控制台并落盘，
    /// 在读线程上调用。
    static func install(sink: (@Sendable (String) -> Void)? = nil) {
        let translates = ProcessInfo.processInfo.environment["SILL_LANG"] != "en"
        guard translates || sink != nil, !installed else { return }
        installed = true
        let original = dup(STDOUT_FILENO)
        guard original >= 0 else { return }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return }
        dup2(fds[1], STDOUT_FILENO)
        close(fds[1])
        setvbuf(stdout, nil, _IOLBF, 0)

        let reader = fds[0]
        DispatchQueue.global(qos: .utility).async {
            let raw = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
            defer { raw.deallocate() }
            var pending = Data()
            while true {
                let n = Darwin.read(reader, raw, 8192)
                if n <= 0 { break }
                pending.append(raw, count: n)
                while let nl = pending.firstIndex(of: 0x0A) {
                    let lineData = pending.prefix(upTo: nl)
                    pending = Data(pending.suffix(from: pending.index(after: nl)))
                    let line = String(data: lineData, encoding: .utf8) ?? ""
                    let out = translates ? translate(line) : line
                    let text = Array((out + "\n").utf8)
                    _ = text.withUnsafeBufferPointer { buf in
                        Darwin.write(original, buf.baseAddress, buf.count)
                    }
                    sink?(out)
                }
            }
            if !pending.isEmpty, let tail = String(data: pending, encoding: .utf8) {
                let out = translates ? translate(tail) : tail
                let text = Array(out.utf8)
                _ = text.withUnsafeBufferPointer { buf in
                    Darwin.write(original, buf.baseAddress, buf.count)
                }
                sink?(out)
            }
        }
    }

    private static func isWordByte(_ c: Character) -> Bool {
        c.isLetter && c.asciiValue.map { ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) } == true
            || (c.isNumber && c.asciiValue.map { $0 >= 48 && $0 <= 57 } == true)
    }

    /// 纯英文词条（首尾都是字母数字）必须整词匹配。
    /// 之前用 contains 直接把 "encode" 替进 "encoder" 里，日志出现「编码r」这种乱码；
    /// "or " 更会把 "for" 变成 "f或"。带空格/符号的词条（如 " windows, "）仍按子串替换。
    private static let compiled: [(regex: NSRegularExpression?, literal: String, zh: String)] = {
        phrases.map { en, zh in
            let wholeWord = en.first.map(isWordByte) == true && en.last.map(isWordByte) == true
            guard wholeWord else { return (nil, en, zh) }
            let pattern = "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: en) + "(?![A-Za-z0-9])"
            return (try? NSRegularExpression(pattern: pattern), en, zh)
        }
    }()

    private static func translate(_ line: String) -> String {
        var s = line
        // 只在含 ASCII 字母的行上做替换，纯数字/符号行原样输出。
        guard s.unicodeScalars.contains(where: { $0.value >= 65 && $0.value <= 122 }) else { return s }
        for entry in compiled {
            if let regex = entry.regex {
                let range = NSRange(s.startIndex..., in: s)
                s = regex.stringByReplacingMatches(in: s, range: range,
                                                   withTemplate: NSRegularExpression.escapedTemplate(for: entry.zh))
            } else if s.contains(entry.literal) {
                s = s.replacingOccurrences(of: entry.literal, with: entry.zh)
            }
        }
        return s
    }
}
