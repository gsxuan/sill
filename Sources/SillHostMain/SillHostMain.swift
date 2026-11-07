import Foundation
import AppKit
import CoreGraphics
import ApplicationServices
import StreamProtocol
import SillHostCore

/// 被控端主体，抽成可调用函数：命令行（SillHost）和融合 app（SillRemote）共用同一份代码。
///
/// 两个入口：
/// - `runSillHostCLI()`：命令行。解析 `CommandLine.arguments`，出错 exit，自己跑事件循环，永不返回。
/// - `startSillHostInApp(...)`：融合 app 的控制台在**自己的进程里**跑被控端，立即返回。
///
/// 为什么必须在 app 进程内跑：macOS 的 TCC 把「屏幕录制 / 辅助功能」授权绑在 app 的签名身份上，
/// 换一个二进制（内置的 sill-host）就等于没授权 —— 表现是「明明授权了还在提示」加上「窗口列表是空的」。
/// 早先的做法是 app 以 `--host-mode` 重入自己、另起一个子进程，身份对上了，但那个子进程会被
/// LaunchServices 当成同一个 app 的第二个前台实例：Dock 里多一个一直在跳的图标，
/// 一台机器上跑着两个 SillRemote。现在被控端直接跑在控制台进程里，一台机器只有一个进程。
public func runSillHostCLI() {
    // 权限探测必须在安装中文日志层之前处理：ChineseLog 会把 stdout 重定向到
    // 自己的翻译管道，而融合控制台正是通过 stdout 读取子进程 --ax-probe 的输出。
    // 若先安装 ChineseLog，父进程读到的将是空串，导致「被控端子进程视角」复核失效。
    if CommandLine.arguments.contains("--ax-probe") {
        print("辅助功能（被控端子进程视角）：\(AXIsProcessTrusted() ? "已授权" : "未授权")")
        print("屏幕录制（被控端子进程视角）：\(CGPreflightScreenCaptureAccess() ? "已授权" : "未授权")")
        print("可执行文件：\(CommandLine.arguments[0])")
        exit(0)
    }

    // 中文日志输出层：必须在任何 print 之前安装。SILL_LANG=en 可切回英文。
    // 详见 ChineseLog.swift —— 只改写 stdout 文本，不改协议与业务逻辑。
    ChineseLog.install()

    // Line-buffer stdout so the log reads live when piped or redirected (Swift's print is fully
    // buffered off a terminal, which hides the stats line until exit).
    setvbuf(stdout, nil, _IOLBF, 0)

    let plan: HostPlan
    switch HostPlan.make(arguments: CommandLine.arguments) {
    case .success(let p): plan = p
    case .failure(let refusal):
        print(refusal.line)
        exit(2)
    }

    // `SillHost --print-reachability`: the addresses this Mac would give devices away from home, as
    // its Remote Access pane lists them, read once (read-only SystemConfiguration); then exits.
    if CommandLine.arguments.contains("--print-reachability") {
        for line in ReachabilityReport.lines() { print(line) }
        exit(0)
    }

    // `SillHost --print-cable`: what the USB cable rule reads on this Mac (read-only IOKit and
    // CGSession): each interface it looks at, whether it is the cable to an iPhone or iPad, and whether
    // the console is unlocked; then exits.
    if CommandLine.arguments.contains("--print-cable") {
        for line in CableReport.lines() { print(line) }
        exit(0)
    }

    // `SillHost --encoder-selftest`: no capture, no network. Pushes synthetic frames through the real
    // HEVCEncoder (hardware, then software) and reports what came back, so the watchdog and the
    // fallback can be exercised without Screen Recording. Exits when done.
    if CommandLine.arguments.contains("--encoder-selftest") {
        EncoderSelfTest.run()
    }

    // `SillHost --menu-selftest[=APP]`: the menus a device would be sent for APP (a pid, or the start of
    // a running app's name; the frontmost app without it), one level deep, with each read's time. Read-
    // only: nothing is activated or pressed, though each menu read makes the app validate that menu.
    // The "=" is needed: a bare argument is the window match above. Exits 0, or 1 when nothing was read.
    if let app = MenuSelfTest.requested(in: CommandLine.arguments) {
        MenuSelfTest.run(app: app)
    }

    // ScreenCaptureKit talks to the window server through CoreGraphics, which must be
    // initialized on the main thread before any other thread touches it. In a CLI tool
    // nothing does that for us, so prime it here and keep stream setup on the main actor.
    // Otherwise SCStream aborts with "Assertion failed: (did_initialize), CGS_REQUIRE_INIT".
    _ = CGMainDisplayID()

    // `SillHost --virtual-display-selftest [Hz] [WxH]`: creates one 1000×700 pt @2× virtual display (or
    // W×H points), reports whether this process, CoreGraphics and ScreenCaptureKit see it and the mode it
    // came up at, destroys it and exits. Needs no permission for the display itself (SCShareableContent
    // needs Screen Recording; it says so). Runs under the AppKit loop like the real thing.
    if CommandLine.arguments.contains("--virtual-display-selftest") {
        VirtualDisplaySelfTest.run()
    }

    if plan.virtualDisplay {
        // The window server delivers display reconfiguration through the app's event port, which
        // dispatchMain() never drains; only under NSApplication.run() does this process learn the
        // virtual display's modes. The main dispatch queue (Task { @MainActor }, Stats' timer, the
        // signal sources) is serviced by the app's run loop, so nothing else changes.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)   // no Dock icon, no app switcher, can never be activated
        HostShutdown.install { HostRun.coordinator }    // Ctrl-C / kill: put the window back before exiting
        HostRun.start(plan, appKitLoop: true, inApp: false) { _ in exit(1) }
        app.run()
    } else {
        // A signal ends the process as it always did, a device's keys let go first (HostShutdown).
        HostShutdown.installKeyRelease { HostRun.coordinator }
        HostRun.start(plan, appKitLoop: false, inApp: false) { _ in exit(1) }
        dispatchMain()   // today, byte for byte
    }
}

/// 融合 app 的控制台在自己的进程里启动被控端，立即返回：nil 表示已启动，否则是不能启动的原因（一行）。
///
/// 与命令行同一份参数解析和启动流程，区别只有三处：参数和环境变量由控制台给；出错回报给控制台
/// 而不是 exit（`onFailure`）；事件循环用 app 已经在跑的那个（`appKitLoop: true`，虚拟显示器也就能用）。
/// 被控端的每一行日志（已按 SILL_LANG 翻译）经 `onLine` 交给控制台，在 ChineseLog 的读线程上调用。
///
/// 被控端没有「停止」：StreamCoordinator 随进程而生（菜单栏版 Sill.app 也是这样）。一个进程只能
/// 启动一次；换参数或停止，由控制台带着新参数重启自己完成。
@MainActor
public func startSillHostInApp(arguments: [String], environment: [String: String],
                               onLine: @escaping @Sendable (String) -> Void,
                               onFailure: @escaping @MainActor (String) -> Void) -> String? {
    guard !HostRun.started else { return "被控端已在本进程内运行（一个进程只能启动一次）" }
    // 被控端各处（StreamServer 的固定端口、StreamCoordinator 的原始帧开关……）直接读环境变量，
    // 所以要在任何一个被建起来之前写进本进程的环境。
    for (key, value) in environment { setenv(key, value, 1) }
    ChineseLog.install(sink: onLine)
    setvbuf(stdout, nil, _IOLBF, 0)

    let plan: HostPlan
    switch HostPlan.make(arguments: arguments) {
    case .success(let p): plan = p
    case .failure(let refusal): return refusal.line
    }
    HostRun.started = true
    _ = CGMainDisplayID()
    // 信号（远端控制台 pkill、注销）：放回窗口、松开设备按着的键、告别各设备，再退出。
    // 与菜单栏版 Sill.app 一样装这一套：虚拟显示器随时可能开着。
    HostShutdown.install { HostRun.coordinator }
    HostRun.start(plan, appKitLoop: true, inApp: true, onFailure: onFailure)
    return nil
}

/// 控制台退出（⌘Q、注销、重启自己）时调用：与信号同样的收尾，但不 exit，交给 AppKit 结束进程。
@MainActor
public func stopSillHostForQuit() {
    guard HostRun.started else { return }
    HostShutdown.releaseForQuit(coordinator: HostRun.coordinator)
}

/// 一次运行的被控端：命令行参数与环境变量解析出的全部选项。
struct HostPlan {
    var config: HostConfig
    var preselect: String?
    var synthetic: Bool
    var virtualDisplay: Bool
    var audio: Bool
    var internet: Bool
    var pairing: Bool

    /// 参数不成立时要打印的那一行：命令行打印后 exit(2)，app 内回报给控制台。
    struct Refusal: Error { let line: String }

    static func make(arguments: [String]) -> Result<HostPlan, Refusal> {
        let environment = ProcessInfo.processInfo.environment

        // Knobs for the spike: maxFPS, captureScale, bitrate (per 60 fps), prioritizeSpeed. They live in
        // Sources/SillHost/HostConfig.swift now (`HostConfig.standard`); the menu bar app's Settings start from
        // `HostConfig.app`. Change, rebuild, measure.
        var config = HostConfig.standard

        // 融合版新增：性能参数可由控制台透传（120fps 需要降低采集倍率才跑得动，尤其是 Intel 端）。
        // SILL_MAX_FPS 24…120 / SILL_CAPTURE_SCALE 1 或 2 / SILL_BITRATE bits per 60fps。
        if let s = environment["SILL_MAX_FPS"], let n = Int(s) {
            config.maxFPS = min(max(n, 24), 120)
        }
        if let s = environment["SILL_CAPTURE_SCALE"], let d = Double(s) {
            config.captureScale = d >= 1.5 ? 2 : 1
        }
        if let s = environment["SILL_BITRATE"], let n = Int(s) {
            config.bitrate = min(max(n, 1_000_000), 200_000_000)
        }

        // 融合版：`--raw` = 未压缩原始帧（kind 45），等价于 SILL_RAW_FRAMES=1。
        // StreamCoordinator 在 init 时读这个环境变量，所以必须在它被建起来之前设好。
        if arguments.contains("--raw") {
            setenv("SILL_RAW_FRAMES", "1", 1)
        }

        // Optional. Streams the first window whose app name or title matches, before any client asks.
        // Normally left off: the client picks a window from its bar.
        let preselect = arguments.dropFirst().first { !$0.hasPrefix("--") }

        // `SillHost --synthetic`: the Desktop source streams a moving test pattern instead of the screen,
        // so the encoder, its software fallback and the network can be checked without Screen Recording.
        let synthetic = arguments.contains("--synthetic")

        // `SillHost --virtual-display`: a picked window is moved onto its own HiDPI virtual display and
        // that display is captured, so the window keeps repainting whatever covers its old spot on the
        // Mac. Off by default here (Sill.app has it on since 2026-10-27: HostConfig.app). Needs the AppKit
        // event loop: without it this process never sees the display's modes (VirtualDisplay.swift,
        // "Event loop").
        let virtualDisplay = arguments.contains("--virtual-display")
        config.virtualDisplay = virtualDisplay

        // `SillHost --direct-wireless`: also advertise over, and accept connections from, peer-to-peer
        // Wi-Fi (AWDL), so a device with no network in common can connect. Off by default: while it is on
        // the Mac's radio leaves its Wi-Fi channel up to ~97 ms every 524 ms, which is the stutter in
        // CLAUDE.md. A device paired at the --pairing door can still turn it on or off (no other device
        // can: DeviceSettings.accepted); that lasts until SillHost quits.
        config.directWireless = arguments.contains("--direct-wireless")

        // `SillHost --no-clipboard`: share nothing of the clipboard with devices for this run (kind 32,
        // docs/clipboard-plan.md). On by default, as in Sill.app: a device whose Share Clipboard is on is
        // sent the text copied on this Mac while it is connected, and its own text becomes this Mac's.
        // A --synthetic host shares a pasteboard of its own, never this Mac's clipboard.
        config.shareClipboard = !arguments.contains("--no-clipboard")

        // `SillHost --audio`: Send Audio for this run, a beta (docs/audio-plan.md): every connected device that
        // plays the Mac's sound (its hello lists a codec) gets the streamed app's sound, or every app's for the
        // Desktop, or with --synthetic a test tone. Off by default, as in Sill.app: the Mac keeps playing its
        // own sound. A device can turn it on or off from its Settings panel, as in Sill.app (DeviceSettings);
        // that lasts until SillHost quits. Without it the output is what it always was.
        let audio = arguments.contains("--audio")
        config.sendAudio = audio

        // `SillHost --remote[=PORT]`: the remote door for this run (TLS 1.3, paired devices only), on
        // PORT or any free port, so it never collides with Sill.app's 7455. A new in-memory identity and
        // trust list every run. A pairing window is always open (a fresh one after each use or expiry);
        // its code and link are printed here, to this process's stdout only, and again when a device
        // near the Mac asks (kind 21). `--internet` also admits sources outside this Mac's networks and
        // VPNs. TEST ONLY: SILL_TEST_REMOTE_DIR=<dir> keeps the identity and pairings in a 0700
        // directory, on a --synthetic host only.
        let remoteFlag = arguments.first { $0 == "--remote" || $0.hasPrefix("--remote=") }
        let internet = arguments.contains("--internet")
        if internet && remoteFlag == nil {
            return .failure(Refusal(line: "--internet needs --remote."))
        }
        if let remoteFlag {
            config.remoteAccess = true
            config.internetAccess = internet
            if remoteFlag.hasPrefix("--remote=") {
                guard let p = Int(remoteFlag.dropFirst("--remote=".count)), (1024...65535).contains(p) else {
                    return .failure(Refusal(line: "--remote=PORT takes a port from 1024 to 65535."))
                }
                config.remotePort = p
            } else {
                config.remotePort = 0
            }
        }

        // `SillHost --pairing`: the home door speaks TLS 1.3 with both keys pinned and pairing required
        // (docs/home-pairing-plan.md §5), as Sill.app's does: a device pairs once, over the USB cable by
        // itself or with the code or link printed here. A throwaway identity (the one --remote uses when
        // both are given); a pairing window is always open, and its code goes to this process's stdout
        // only. Without it the home door stays plain and open, as it always was: a development host.
        let pairing = arguments.contains("--pairing")

        // TEST ONLY: SILL_TEST_REQUIRE_PAIRING=0 on a --synthetic host: --pairing's TLS home door lets any
        // device in, still over TLS, as Sill.app's does with Require pairing off (Settings › Devices), so an
        // unpaired device's session can be tried headless. Anywhere else TestHooks says it is ignored (the
        // bare app takes `-requirePairing NO` instead).
        if synthetic, environment["SILL_TEST_REQUIRE_PAIRING"] == "0" { config.requirePairing = false }

        return .success(HostPlan(config: config, preselect: preselect, synthetic: synthetic,
                                 virtualDisplay: virtualDisplay, audio: audio, internet: internet, pairing: pairing))
    }
}

/// 进程内唯一的那个被控端。
enum HostRun {
    /// Lives as long as the process. Read by the signal handlers at signal time (HostShutdown): the
    /// coordinator is created asynchronously after they are installed.
    nonisolated(unsafe) static var coordinator: StreamCoordinator?
    /// app 内一个进程只启动一次（`startSillHostInApp`）。
    nonisolated(unsafe) static var started = false

    static func start(_ plan: HostPlan, appKitLoop: Bool, inApp: Bool, onFailure: @escaping @MainActor (String) -> Void) {
        Task { @MainActor in
            do {
                let remote = plan.config.remoteAccess || plan.pairing ? makeRemoteAccess(plan) : nil
                let c = try StreamCoordinator(config: plan.config, synthetic: plan.synthetic, appKitLoop: appKitLoop, remote: remote,
                                              homePairing: plan.pairing, testHooks: true)
                coordinator = c
                await c.start(preselect: plan.preselect)
                if remote != nil, plan.internet {
                    print("Internet access on for this run: the remote door also admits paired devices from outside this Mac's networks and VPNs.")
                }
                remote?.openPairing(requestedBy: nil)
                if plan.synthetic { print("Synthetic mode: pick Desktop on the device (or from a test client) to stream a test pattern.") }
                if plan.virtualDisplay { print("Virtual display mode: a picked window streams from its own HiDPI display; Ctrl-C puts it back.") }
                if let p = ProcessInfo.processInfo.environment["SILL_HOME_PORT"], !p.isEmpty {
                    print("固定直连端口：\(p)（客户端用 --host <本机IP> --port \(p) 连接，不需要 Bonjour）")
                }
                print("\(c.windowCount) windows on screen. Advertising _sill._tcp on the local network.")
                if c.active == .none { print("Nothing is streaming yet: pick a window from the iOS app. Ctrl-C to stop.") }
                if plan.audio {
                    print(plan.synthetic ? "Audio on for this run (beta): devices that play sound get a test tone with the test pattern."
                                         : "Audio on for this run (beta): devices that play sound get the streamed app's sound, or the whole Mac's for the Desktop.")
                }
                Stats.shared.startPrinting()
            } catch {
                print("Error: \(error)")
                if inApp {
                    print("如果是权限问题：系统设置 › 隐私与安全性 › 屏幕录制，打开 \(Bundle.main.bundlePath) 后重启它。")
                } else {
                    print("If this is a permissions error: System Settings › Privacy & Security › Screen Recording, enable Terminal, then run again.")
                }
                onFailure("\(error)")
            }
        }
    }

    /// --remote's and --pairing's identity and pairing: in memory (or, TEST ONLY on a --synthetic host,
    /// in SILL_TEST_REMOTE_DIR), with the code printed here whenever a window opens or is asked for
    /// again. With --pairing alone the window is the home door's only: no remote door, no addresses.
    @MainActor
    private static func makeRemoteAccess(_ plan: HostPlan) -> RemoteAccess {
        let config = plan.config
        var store: IdentityStore = MemoryIdentityStore()
        if plan.synthetic, let dir = ProcessInfo.processInfo.environment["SILL_TEST_REMOTE_DIR"], !dir.isEmpty {
            do { store = try FileIdentityStore(directory: URL(fileURLWithPath: dir)) } catch { print("SILL_TEST_REMOTE_DIR=\(dir) ignored: \(error)") }
        }
        let remote = RemoteAccess(store: store)
        if let problem = remote.identityProblem { print("Remote access unavailable: \(problem)") }
        remote.reopensPairing = true
        remote.logsPairingWindows = false
        remote.userWindowsOpenRemoteDoor = config.remoteAccess
        var first = true
        // The home door's own line: Require pairing is off only under SILL_TEST_REQUIRE_PAIRING=0.
        let homeDoor = config.requirePairing ? "Pairing required for this run (TLS on the home door)."
                                             : "Pairing not required for this run (TLS on the home door; SILL_TEST_REQUIRE_PAIRING=0)."
        remote.onPairingOffer = { offer in
            if first {
                first = false
                if config.remoteAccess {
                    print("Remote access for this run on port \(offer.port) (TLS, paired devices only). Pair with \(offer.groupedCode) or \(offer.url)")
                    if plan.pairing { print(homeDoor) }
                } else {
                    print("\(homeDoor) Pair with \(offer.groupedCode) or \(offer.url)")
                }
            } else if let who = offer.askedBy {
                print("Pairing: \(who) asked; code \(offer.groupedCode) or \(offer.url)")
            } else {
                print("Pairing: \(offer.again ? "code" : "new code") \(offer.groupedCode) or \(offer.url)")
            }
        }
        return remote
    }
}
