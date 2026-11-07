# Sill

把你 Mac 上的任意窗口，带到你的 iPhone 和 iPad 上。

Sill 把你 Mac 上的某个窗口、或整个桌面，显示在你的 iPhone 或 iPad 上。你在设备上用触摸、触控板、键盘或 Apple Pencil 操作它。Mac 端的 Sill 捕获窗口，编码成 HEVC 视频，发送到你设备上的 Sill 应用；你的点按、点击、滚动和按键则回传到 Mac。Mac 与设备可以在同一局域网内连接、通过 USB 线连接、在没有共同网络时用「直接无线连接」，或经你自己的 VPN（如 Tailscale）通过「远程访问」连接。中间没有账号，也没有服务器。

**[getsill.app](https://getsill.app)** ·
[Mac 版下载](https://getsill.app/download) ·
[支持](https://getsill.app/support) ·
[隐私](https://getsill.app/privacy) ·
[条款](https://getsill.app/terms)

> 说明：本仓库在 upstream Sill 的基础上，另附带一个 Mac-to-Mac 有线（雷雳）直连的融合控制台 **雷雳直连（BoltLink）**，见 [../BoltLink/README.md](../BoltLink/README.md)。iPhone/iPad 的移动端远程功能原样保留，未作删改。

[![CI](https://github.com/Saffsanity/sill/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Saffsanity/sill/actions/workflows/ci.yml)

[![Download on the App Store](https://tools.applemediaservices.com/api/badges/download-on-the-app-store/black/en-us?size=250x83)](https://apps.apple.com/app/id6816359860)

Mac 版 Sill 是从 [getsill.app](https://getsill.app/download) 下载的免费、经公证（notarized）的应用；用 [Homebrew](https://brew.sh) 也可以 `brew install --cask saffsanity/sill/sill`，安装的是同一份下载，来自 Sill 自己的 [tap](https://github.com/Saffsanity/homebrew-sill)。iPhone 和 iPad 版 Sill 在 [App Store](https://apps.apple.com/app/id6816359860) 上免费，你也可以从源码自行构建（见下文）。

想在正式版发布前尝鲜：iPhone 和 iPad 版 Sill 有 [TestFlight 公开测试](https://testflight.apple.com/join/6v7nqyn3)，Mac 版 Sill 在 GitHub 上有 [nightly 构建](https://github.com/Saffsanity/sill/releases/tag/nightly)，像正式版一样经过公证但不提供支持。你的设备会保持配对（nightly 使用正式版的身份），并且 Sill 的更新检查永远不会推送 nightly：日常请使用上面的正式版。

## 截图

下面是 App Store 里的 iPad 截图；在 iPhone 和 iPhone Duo 上，Sill 有自己的布局。

| [!["你的 Mac，在你的 iPad 上。" 横持的 iPad 上显示 Mac 的天气应用，上方是 Sill 的窗口缩略图与按钮栏。](design/screenshots/ipad-1.jpg)](design/screenshots/ipad-1.jpg) | [!["笔记本模式。" 竖持的 iPad，上半是 Mac 的时钟应用，下方是 Sill 的栏、一排按键和触控板。](design/screenshots/ipad-2.jpg)](design/screenshots/ipad-2.jpg) | [!["清晰流畅。" 竖持 iPad 上的 Sill 设置面板，含 Mac 的画质、分辨率与帧率设置。](design/screenshots/ipad-3.jpg)](design/screenshots/ipad-3.jpg) |
| :---: | :---: | :---: |
| [!["配对一次，始终私密。" iPad 上的「连接到 Mac」界面，列出一台标记为「有线」的 Mac，下方是「添加 Mac」。](design/screenshots/ipad-4.jpg)](design/screenshots/ipad-4.jpg) | [!["启动任意 Mac 应用。" 横持 iPad 上的 Sill 应用列表，含搜索框、当前打开的应用与 Mac 上已安装的全部应用。](design/screenshots/ipad-5.jpg)](design/screenshots/ipad-5.jpg) | [!["每个窗口，一键即达。" 横持 iPad 上，长按 Sill 栏里的窗口缩略图会出现关闭、最小化与全屏。](design/screenshots/ipad-6.jpg)](design/screenshots/ipad-6.jpg) |

## 系统要求

- 一台 Apple silicon 或 Intel 处理器的 Mac，运行 macOS 14 或更高版本。
- 一部 iPhone 或 iPad，运行 iOS 17 / iPadOS 17 或更高版本。
- 在 Mac 上，Sill 会请求「屏幕录制」权限以显示你的窗口，以及「辅助功能」权限以代你点击、滚动、输入并移动/缩放它显示的窗口。macOS 15 或更高版本还需允许「本地网络」。在 iPhone 或 iPad 上，Sill 会请求「本地网络」以找到你的 Mac，以及在你扫描 Mac 的配对码时请求相机（你也可以手动输入配对码）。
- 你的 Mac 与设备需在同一网络、用 USB 线相连、或在彼此附近并开启「直接无线连接」。离家在外时，用你自己的 VPN（如 Tailscale）并开启「远程访问」。

## 工作原理

- **Mac 版 Sill** 常驻菜单栏。当你的设备选中某个窗口或整个桌面时，Sill 用 ScreenCaptureKit 捕获它，并用 VideoToolbox 在你 Mac 的硬件视频编码器上编码成 HEVC（硬件编码器忙时改用软件编码）。没有设备连接时，它什么都不捕获。
- **画面** 经加密连接（TLS 1.3）直接送到你 iPhone 或 iPad 上的 Sill 应用，由它解码并显示。当编码器或链路跟不上时，Sill 丢帧而不是排队，让画面保持最新。
- **你的输入** 沿原路返回：点按与点击、带惯性的滚动、屏幕触控板、按键与输入的文本，以及作为指针的 Apple Pencil。Mac 版 Sill 把它转成鼠标和键盘事件，这需要「辅助功能」权限。画面一显示，接在设备上的键盘就能在 Mac 上输入（含 Esc），触控板或鼠标会滚动其指针下方的窗口。中文、日文、韩文等用输入法组字语言，用你在设备上设置的键盘输入：你在设备上组字并选字，选定的内容会输入到 Mac。听写也能在 Mac 上输入。设置面板里的「反向滚动」会把单指滚动和屏幕触控板的滚动方向反过来。三指像 Mac 触控板一样轻扫和捏合：调度中心、应用程序窗口、各个空间、应用与显示桌面，都通过你 Mac 上对应的键盘快捷键触发。捏合画面可围绕两指之间的点缩放，最高 5×；两指移动已放大的画面，一直捏合到最小则重新显示整个画面。
- **在 iPhone 上** 竖持时，画面在上、按钮/按键/触控板在下。设置面板里的「更大画面」让窗口画面占据窗口缩略图区域的空间，一直到键盘弹出为止；桌面则保持常规布局。开启虚拟显示器时（除非你在 Mac 版 Sill 里关掉），Mac 会让窗口填满更高的画面；关闭时，先用 Aa 设好窗口的文字大小。
- **剪贴板** 在两端都开启「共享剪贴板」时双向同步：你在 Mac 上复制的文本可在设备上粘贴，Sill 里的「粘贴」会把你在设备上复制的内容粘贴到 Mac 光标处（关闭「立即粘贴到…」时，它只进入 Mac 的剪贴板，你再按 ⌘V）。Sill 从不自行读取设备的剪贴板。
- **来自 Mac 的声音** 是 beta 功能，默认开启；Mac 上 Sill 菜单或设置里的「发送声音（Beta）」，或 iPhone/iPad 上 Sill 设置面板里的同名开关可开关它。Mac 版 Sill 捕获窗口所属应用的声音（桌面则捕获所有应用），每台已连接的设备都会比画面稍滞后地播放它，绝不会超前。你的 Mac 也会继续播放；某台设备设置面板里的「静音」只在该设备上静音。
- **在 iPhone Duo 上**，Sill 跟随转轴：完全摊平时 Mac 填满内屏；半开时画面在折痕上方、触控板和按键在下方；合上时 Sill 运行在外屏。你触摸的任何东西都不会压在折痕上。
- **你使用的应用的菜单** 也会到达你的设备：在 iPadOS 26 或更高版本的 iPad 自有菜单栏里，以及在 Sill 栏的「菜单」按钮后面。Mac 版 Sill 通过「辅助功能」在你打开每个菜单时从应用读取它，并选中你挑选的项。当有人在 Mac 上移动鼠标时，你的设备会显示指针所在位置。
- **设备上的连接界面** 把每台 Mac 显示为一个磁贴，已配对的 Mac 会以你上次会话结束时的屏幕作为磁贴画面。画面会留在设备上，直到你移除它或忘记这台 Mac。「连接到 Mac」旁边的按钮改为列出它们，Sill 会记住你选了哪种。
- **一段简短导览** 会在设备首次显示 Mac 画面时介绍 Sill 的控制方式，并在某次新增控制的更新后再介绍一次，新增内容标记为「新」；设置面板里的「查看导览」可再看一次。
- **在附近**，设备用 Bonjour 在局域网里找到你的 Mac。通过 USB 线时，Mac 显示为「有线」，连接走这条线。没有共同网络时，「直接无线连接」（默认关闭）像 AirDrop 那样通过点对点 Wi-Fi 连接。
- **配对**：每台 iPhone 或 iPad 与你的 Mac 配对一次。在设备上点你的 Mac，Mac 会显示一个码：扫描它，或输入它的 12 位数字。通过 USB 线时设备会自动配对。此后双方都知道对方的密钥，每一次连接（无论在附近还是异地）都锁定到这些密钥。在 Mac 版 Sill 的设置里，「设备」列出你配对过的设备，你可以在此移除任意一台。如果你通过「屏幕共享」或其他远程桌面应用使用 Mac（像用一台没有显示器的 Mac 那样），Sill 的配对窗口默认不会显示在那里，直到你在同一处打开「向屏幕共享显示配对窗口」。它默认关闭：开启时，任何能远程看到你 Mac 屏幕的人都能读到这个码。
- **离家在外**，「远程访问」（默认关闭）让你配对过的设备通过你自己的 VPN 或你在路由器上转发的端口访问你的 Mac；设备会在下次于家中开启「远程访问」连接时学到怎么做。异地设备会有自己的画质，默认在标准分辨率下为「低」，直到你在异地或 Sill 设置里另选，这样慢连接不会一上来就用你家里的画质；家里的设备一连接，你的家庭画质就恢复。当你的设备回到家里、你的网络列出你的 Mac 时，会话会自动切回你的网络。
- **当链路跟不上时**，Mac 版 Sill 会注意到它正在积压帧并告诉你的设备，设备会在画面上提示，并在其设置里提供一个链路能承受的画质。
- **文字大小**：设备上的 Aa 会通过「辅助功能」调整你所串流窗口的大小，让其文字以你选的大小显示，并在串流期间保持该大小——在虚拟显示器上，或（关闭虚拟显示器时）在 Mac 的屏幕上。当 Sill 停止显示该窗口时，窗口回到它自己的大小和位置：你选了另一个窗口或桌面、你的最后一台设备断开、或你退出 Sill。关闭虚拟显示器时，你期间在 Mac 上移动过的窗口会保持新位置，且 Aa 从「关」开始（保持窗口原样）：把 Aa 滑回「关」，被 Sill 调整过的窗口会立刻还原。Aa 调整的是窗口，所以显示桌面时它是灰的。
- **虚拟显示器** 默认开启，除非你在 Mac 版 Sill 的 Sill 菜单或设置里、或在 iPhone/iPad 版 Sill 的设置面板里关闭它。它把你所串流的窗口移到 Mac 上一块为其单独创建、按设备尺寸设定的显示器上，这样即使被其他窗口遮挡也会持续更新。串流期间该窗口会离开 Mac 的屏幕，结束后回到原处。这块显示器使用一个私有的 macOS API，这也是 Mac 版 Sill 从网站分发而非 Mac App Store 的原因之一；如果某次 macOS 更新破坏了它，Sill 会在窗口原处串流它。

需要知道的是：Sill 一次只显示一个窗口或整个桌面，并且它会把 Mac 的声音作为 beta 功能（默认开启）在你的设备上播放。虚拟显示器开启时，你设备显示的窗口在停止前不会出现在 Mac 的屏幕上。剪贴板只承载文本，一次最多 256 KB，且只在同时具备该能力的两个应用之间。你的 Mac 需要处于唤醒状态并开着 Sill；Sill 未必能唤醒它。重启后，只有在有人登录、且开启了「登录时启动」时 Sill 才会打开。
只有你配对过的 iPhone 和 iPad 能连接，除非你在「设置 › 设备」里关闭「需要配对」；关闭后你网络上的任何设备都能连（仍然是加密的）。家中的配对功能随 Mac 版 Sill 0.4.0 与 iPhone/iPad 版 Sill 0.5 (2) 一同到来，且两者互相需要：iPhone/iPad 应用会把更旧的 Mac 版 Sill 显示为「更新 Sill」，而更旧的 iPhone/iPad 应用无法在家连接到 0.4.0 或更高版本的 Mac 版 Sill。自 0.5.1 起，两个应用每次发布共用一个版本号。使用 0.3.1 或更早的 Mac 版 Sill 时，局域网、线缆和「直接无线连接」上的连接都不加密，任何能到达你 Mac 的东西都能不配对就连接：请更新它。
Nightly 构建：每晚只要 main 有变化，就会有一个据它构建、经公证的 Mac 版 Sill 进入 [nightly 预发布](https://github.com/Saffsanity/sill/releases/tag/nightly)，iPhone/iPad 版则推送给 TestFlight 的测试者。nightly 的测试少于正式版、可能出问题；Sill 的更新检查永远不会推送 nightly，从 nightly 的 Mac 版 Sill 回到正式版会保留其设置和已配对设备。

## 打赏

Sill 是免费的，没有广告、没有追踪、没有订阅。如果它对你有用，通过 [GitHub Sponsors](https://github.com/sponsors/Saffsanity) 打赏能帮助支付开发者账号费用。打赏不解锁任何东西：每个功能都是免费的。谁在赞助 Sill、谁做出了贡献、以及如何加入他们：见 [getsill.app/contribute](https://getsill.app/contribute)。

## 从源码构建

你需要一台装有 Xcode 的 Mac（Sill 用 Xcode 27 构建；iPhone/iPad 应用需要 Xcode 27.1 或更高版本，以支持 iPhone Duo 的转轴与折痕），并将其选为活动的开发者目录、接受其许可协议。

Mac 版 Sill，在仓库目录下：

```
Scripts/make-app.sh --install --open
```

它会用 SwiftPM 构建 Sill.app，用你的 Apple Development 身份签名，替换 /Applications/Sill.app 并打开它。如果那是你下载的 Mac 版 Sill，请重新授予「屏幕录制」和「辅助功能」并重新配对每台设备：下载版把它的密钥和已配对设备保存在数据保护钥匙串中，只有带项目描述文件的 Developer ID 构建才能读取，而你自己构建的版本把它们保存在你的登录钥匙串里。不加 `--install` 时它只构建 `.build/Sill.app`。没有 Apple Development 身份时它会 ad-hoc 签名，那样每次构建后都得重新授予「屏幕录制」和「辅助功能」。

若只在被控端本机上工作，`swift run -c release SillHost` 会在命令行运行同一个被控端，只有一点不同：除非你加 `--pairing`，它的家门是明文敞开的——没有配对、没有加密，你网络上的任何设备都能连接它，所以只在开发时这样运行。App Store 上的 iPhone/iPad 版 Sill 永远不会拨打这样的门（会提示「更新 Sill」）；本仓库的 Debug 构建可以（见 [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)，家中的配对）。加 `--synthetic` 会串流一个测试图案，无需「屏幕录制」。

iPhone/iPad 应用：

1. 打开 `iOSClient/Sill.xcodeproj`。
2. 在 Sill target 的 Signing & Capabilities 里选择你的团队，并把 bundle identifier `me.saffer.sill` 改成你自己的。
3. 在与 Mac 同一网络的 iPhone 或 iPad 上运行它，点你的 Mac。第一次，用本仓库构建的 Mac 版 Sill 会要求你配对：扫描它显示的码，或用 USB 线连接设备。

[docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) 有其余内容：每个命令行标志、测试工具与模拟器框架、权限及如何重置、远程访问、故障排查与发布。

## 贡献

欢迎提 issue：bug 报告、问题和想法。提 pull request 时，请遵循 [CLAUDE.md](CLAUDE.md) 里的约定和决策：只用 Swift 和 Apple 框架、不用第三方依赖、不需要服务器、延迟优先于画质。开始任何较大的工作前先开一个 issue。提 pull request 前，`Tests/checks/run-all.sh` 会运行与 CI 相同的纯检查，约五分钟、无需设备。
贡献按项目的许可证接受。请按 [SECURITY.md](SECURITY.md) 所述私下报告安全问题，不要开公开 issue。这些规则连同赞助者与贡献者，都在 [getsill.app/contribute](https://getsill.app/contribute)。

## 许可证

Sill 依据 [Apache License 2.0](LICENSE) 授权。
版权所有 2026 Noah Saffer。
