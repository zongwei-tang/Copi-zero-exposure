//
//  ZeroExposure.swift
//  Copi
//
//  0 暴露复制/粘贴：文字只在 Copi 和目标 App 之间传递，不经过系统剪贴板（也不经过任何其他进程不需要授权就能读到的剪贴板）。
//
//  各类 App 能走的路径不一样（依据是对 WebKit / Chromium / Gecko 源码和 KeePassXC、Espanso 等实现的调研）：
//   - 原生文本控件：直接读写 kAXSelectedText（SystemUtilities.swift 里已有）；
//   - Safari / WKWebView：粘贴用 WebKit 公开的 AXTextOperation（Grammarly 也是这么做的，Safari 18.2 起支持，
//     走真正的编辑命令，能撤销）；复制用 text marker 读选区；
//   - Chrome 系浏览器和 Electron：可编辑的 <input>/<textarea> 粘贴时整体改写 AXValue；复制用 text marker 并按段落重建换行；
//   - 密码框、单行输入框（以及以上都不行的原生输入框）、富文本编辑器：模拟键入（和密码管理器的自动填充一样），
//     换行用 ⇧↩（聊天框里单独的 ↩ 是发送）；当前是拼音等输入法时不键入；
//   - 认不出焦点控件、但焦点所在的 App 正开着 Secure Input（几乎一定是密码框）：同样模拟键入；
//   - 终端：只键入单行文字，并且避开 vim、less 这类把按键当命令的全屏程序（真正的粘贴有 bracketed paste 保护，键入没有）；
//   - VS Code 系编辑器、JetBrains、网页里的代码编辑器：它们逐字处理键入（自动补全括号引号、确认补全候选），
//     只键入不会触发这些的单行文字（API key、token 之类大多如此）；Google Docs 自动改大小写、引号，不键入。
//  找不到 0 暴露路径时，由调用方决定：默认拒绝并通知（Copi 的文字绝不放上系统剪贴板）；用户打开"允许剪贴板回退"后
//  退回加固过的剪贴板方式。用户放行的 App 照常使用系统剪贴板（见 ZeroExposurePolicy）。
//
//  能看到这些文字的，只有目标 App 本身和已经拿到辅助功能/输入监控/录屏权限的程序——后者本来就能直接读输入框、记录按键，
//  不在 Copi 的防护范围内。
//

import Foundation
import AppKit
import Carbon
import ApplicationServices
import IOKit
import Defaults
import UserNotifications

// MARK: - 策略

enum ZeroExposurePolicy {
    // 0 暴露（默认）：Copi 的文字绝不放上系统剪贴板，做不到就拒绝并通知。任意线程可用
    static var isStrict: Bool {
        !Defaults[.allowClipboardFallback]
    }

    // 用户放行、照常使用系统剪贴板的 App
    static func usesNormalClipboard(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else {
            return false
        }
        return Defaults[.normalClipboardApps].contains(bundleID)
    }

    // 密码管理器（和钥匙串访问这类保管密码的 App）：在它们里面复制的内容一律按机密处理（不显示、90 秒后清除）
    private static let passwordManagerBundleIDPrefixes = [
        "com.1password.", "com.agilebits.", "com.bitwarden.", "in.sinew.Enpass", "org.keepassxc.", "com.apple.Passwords",
        "com.dashlane.", "me.proton.pass", "com.lastpass.", "com.callpod.keeper", "com.nordpass.", "com.roboform.",
        "com.apple.keychainaccess", "com.markmcguill.strongbox", "com.hicknhacksoftware.MacPass", "com.outercorner.Secrets",
        "net.antelle.keeweb",
    ]

    static func isPasswordManager(_ bundleID: String?) -> Bool {
        guard let bundleID else {
            return false
        }
        return passwordManagerBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    static func allowNormalClipboard(for bundleID: String) {
        var apps = Defaults[.normalClipboardApps]
        guard !bundleID.isEmpty, !apps.contains(bundleID) else {
            return
        }
        apps.append(bundleID)
        Defaults[.normalClipboardApps] = apps
    }
}

// MARK: - Secure Input 的归属

// 当前是哪个进程开着 Secure Event Input（浏览器、原生 App 在密码框获得焦点时开启，终端的"安全键盘输入"也会）。
// 系统把它记在 IORegistry 根节点的 IOConsoleUsers 里，不需要任何权限就能读。任意线程可用。
// 这个记录并不总是准的：后台进程、命令行工具开启时记的是当时的前台 App，开启者退出后也可能残留（锁屏时 loginwindow 还会泄漏）。
// 所以只把它当作旁证，用的时候还要有别的证据（见 revealPasswordField）。
enum SecureInputOwner {
    static var pid: pid_t? {
        guard IsSecureEventInputEnabled() else {
            return nil
        }
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else {
            return nil
        }
        defer { IOObjectRelease(root) }
        guard let property = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0),
              let sessions = property.takeRetainedValue() as? [[String: Any]] else {
            return nil
        }
        // 自己这个登录会话（快速切换用户时会有多个）；没有就用正在使用屏幕的那个
        let uid = getuid()
        let session = sessions.first { ($0["kCGSSessionUserIDKey"] as? NSNumber)?.uint32Value == uid }
            ?? sessions.first { ($0["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == true }
        // 没开启时这个 key 根本不存在
        guard let number = session?["kCGSSessionSecureInputPID"] as? NSNumber, number.int32Value > 0 else {
            return nil
        }
        return number.int32Value
    }
}

private let chromiumCacheLock = NSLock()
private var chromiumCache: [pid_t: Bool] = [:]

// Chrome 系浏览器和 Electron App：包里有 "<名字> Framework.framework"（Google Chrome Framework、Electron Framework……）。
// 它们的无障碍树按需构建，没建好时焦点只是整个窗口或网页，认不出密码框
func isChromiumApp(pid: pid_t) -> Bool {
    chromiumCacheLock.lock()
    let cached = chromiumCache[pid]
    chromiumCacheLock.unlock()
    if let cached {
        return cached
    }
    var isChromium = false
    if let frameworks = NSRunningApplication(processIdentifier: pid)?.bundleURL?.appendingPathComponent("Contents/Frameworks"),
       let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) {
        isChromium = names.contains { $0.hasSuffix(" Framework.framework") }
    }
    chromiumCacheLock.lock()
    chromiumCache[pid] = isChromium
    chromiumCacheLock.unlock()
    return isChromium
}

// 进程号会被复用：App 退出后把按进程号缓存的判断清掉
func forgetAppEngineCache(pid: pid_t) {
    chromiumCacheLock.lock()
    chromiumCache[pid] = nil
    chromiumCacheLock.unlock()
    typingChunkCacheLock.lock()
    typingChunkCache[pid] = nil
    typingChunkCacheLock.unlock()
    editorDataFolderCacheLock.lock()
    editorDataFolderCache[pid] = nil
    editorDataFolderCacheLock.unlock()
    geckoCacheLock.lock()
    geckoCache[pid] = nil
    geckoCacheLock.unlock()
}

// MARK: - 识别目标

enum WebEngine {
    case webKit
    case chromium
    case gecko
}

// 只有网页元素才有的属性（WebKit 和 Chromium 给每个网页元素都加了这些）
let webOnlyAttributeNames: Set<String> = ["AXDOMIdentifier", "AXDOMClassList", "ChromeAXNodeId"]

private let geckoBundleIDPrefixes = [
    "org.mozilla.", "net.waterfox.", "io.gitlab.librewolf", "app.zen-browser.", "org.torproject.", "net.mullvad.",
]
private let geckoCacheLock = NSLock()
private var geckoCache: [pid_t: Bool] = [:]

// Firefox 及其各种分支（Floorp、LibreWolf、Zen、Thunderbird……）：包里都有 Gecko 的 XUL 库
private func isGeckoApp(pid: pid_t, bundleIdentifier: String?) -> Bool {
    if let bundleIdentifier, geckoBundleIDPrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) {
        return true
    }
    geckoCacheLock.lock()
    let cached = geckoCache[pid]
    geckoCacheLock.unlock()
    if let cached {
        return cached
    }
    let isGecko = NSRunningApplication(processIdentifier: pid)?.bundleURL
        .map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/XUL").path) } ?? false
    geckoCacheLock.lock()
    geckoCache[pid] = isGecko
    geckoCacheLock.unlock()
    return isGecko
}

// 虚拟机、远程桌面：键盘输入会被转成客户机的扫描码，模拟键入的字符对不上；粘贴只能经过它们的剪贴板同步
private let remoteDesktopBundleIDPrefixes = [
    "com.parallels.", "com.vmware.fusion", "com.vmware.horizon", "com.omnissa.", "com.utmapp.", "org.virtualbox.",
    "com.microsoft.rdc", "com.apple.ScreenSharing", "com.citrix.", "com.realvnc.", "com.teamviewer.", "com.philandro.anydesk",
    "com.p5sys.jump", "com.apple.iphonesimulator", "com.apple.ScreenContinuity", "tv.parsec.www", "com.carriez.rustdesk",
    "com.moonlight-stream.", "codes.rambo.VirtualBuddy", "com.amazon.workspaces", "com.lemonmojo.RoyalTSX", "com.edovia.screens",
]

// 被远程控制的这台 Mac 上跑的服务端（菜单栏里的代理）
private let remoteHostAgentBundleIDPrefixes = ["com.realvnc.", "com.teamviewer.", "com.philandro.anydesk", "com.carriez.rustdesk", "com.p5sys.jump"]

// 虚拟机、远程桌面、模拟器
func isRemoteDesktopApp(_ bundleID: String?) -> Bool {
    guard let bundleID else {
        return false
    }
    return remoteDesktopBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
}

// 正在运行、会把本机剪贴板同步出去（客户机、远程电脑、模拟器）的 App 的名字（包括粘贴目标自己）
func runningClipboardSyncers() -> [String] {
    var names: [String] = []
    for app in NSWorkspace.shared.runningApplications {
        // 用户开着的 App（虚拟机、远程桌面的窗口）都算；只在后台跑的代理里，被远程控制的这台 Mac 上的服务端（VNC、TeamViewer、
        // AnyDesk、RustDesk、Jump Desktop Connect）在有人连进来时会同步剪贴板，也算；Citrix 的帮手、Parallels Toolbox 这类不算
        guard let bundleID = app.bundleIdentifier, remoteDesktopBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }),
              app.activationPolicy == .regular || remoteHostAgentBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) else {
            continue
        }
        let name = app.localizedName ?? bundleID
        if !names.contains(name) {
            names.append(name)
        }
    }
    return names
}

// 主线程：退回剪贴板方式之前（每个退回的地方都要）调用，这是唯一的一道检查。有会把本机剪贴板同步出去的 App 在运行时（粘贴目标
// 本身就是虚拟机、远程桌面也算），第一次只提醒（文字会被它们带到那台电脑的剪贴板、剪贴板历史里，粘贴完也一直留着），
// 8 秒内用户亲手再粘贴一次才退回剪贴板
func remoteClipboardConfirmationBeforeFallback(_ text: String, targetPID: pid_t?) -> UnavailableReason? {
    let syncers = runningClipboardSyncers()
    guard !syncers.isEmpty, RemoteClipboardGuard.confirmation.needsConfirmation(key: "\(targetPID ?? -1)\u{0}\(text)") else {
        return nil
    }
    return .remoteClipboard(syncers)
}

// ⇧↩ 在这些 App 里不是换行：电子表格是确认单元格并跳到别的格（后面的文字会覆盖别的格），Xcode playground、Mathematica 会执行代码
private let multiLineTypingDenyBundleIDPrefixes = [
    "com.microsoft.Excel", "com.apple.iWork.Numbers", "com.apple.dt.Xcode", "com.wolfram.Mathematica", "org.libreoffice",
]

private let typingChunkCacheLock = NSLock()
private var typingChunkCache: [pid_t: Int] = [:]

// 每个按键事件最多能带几个 UTF-16 单元：标准 OpenJDK 的 Swing 程序只取第一个字符（JetBrains 自带的运行时没有这个问题），
// 内嵌 QtWebEngine 的程序最多留 3 个。其余（Cocoa、Chromium、WebKit、终端）整串都收
private func typingChunkLimit(pid: pid_t) -> Int {
    typingChunkCacheLock.lock()
    let cached = typingChunkCache[pid]
    typingChunkCacheLock.unlock()
    if let cached {
        return cached
    }
    var limit = KeystrokeTyper.chunkLimit
    if let contents = NSRunningApplication(processIdentifier: pid)?.bundleURL?.appendingPathComponent("Contents") {
        let fileManager = FileManager.default
        func exists(_ path: String) -> Bool {
            fileManager.fileExists(atPath: contents.appendingPathComponent(path).path)
        }
        let plugIns = (try? fileManager.contentsOfDirectory(atPath: contents.appendingPathComponent("PlugIns").path)) ?? []
        let bundlesJava = exists("runtime") || exists("Java") || plugIns.contains { $0.lowercased().contains("jdk") || $0.lowercased().contains("jre") }
        if bundlesJava, !exists("jbr") {
            limit = 1
        } else if exists("Frameworks/QtWebEngineCore.framework") {
            limit = 1
        }
    }
    typingChunkCacheLock.lock()
    typingChunkCache[pid] = limit
    typingChunkCacheLock.unlock()
    return limit
}

let fileManagerBundleIDs: Set<String> = ["com.apple.finder", "com.binarynights.ForkLift", "com.cocoatech.PathFinder", "com.marta.Marta"]

// JetBrains 系 IDE：编辑器在 Java 事件线程上异步应用 Accessibility 写入，没法确认；逐字处理键入（自动补全括号引号），
// 只能键入不会触发自动补全的单行文字（见 isSafeForCodeEditor）
private let javaIDEBundleIDPrefixes = ["com.jetbrains.", "com.google.android.studio"]

// VS Code 系编辑器（Electron）：编辑器本身是 Monaco（靠 AXDOMClassList 认出来，按代码编辑器处理），搜索框、命令面板这些普通输入框
// 照常走 Chromium 的路径。无障碍树还没建好、认不出是什么的时候不要乱写（编辑器的输入框是个代理节点，写进去没用）
private let electronCodeEditorBundleIDPrefixes = [
    "com.microsoft.VSCode", "com.vscodium", "com.todesktop.230313mzl4w4u92", "com.exafunction.windsurf",
]

// 网页里的代码编辑器：只渲染可见部分（读出来的选区会被截断），输入走隐藏的代理输入框（写进去没用，键入又会触发自动补全括号、缩进）
private let codeEditorClassNames: Set<String> = [
    "cm-content", "cm-editor", "CodeMirror", "monaco-editor", "native-edit-context", "inputarea", "ime-text-area",
    "ace_editor", "ace_text-input",
]

// 网页里的终端（VS Code 的集成终端、浏览器里的云端 Shell……）：看不到里面正在运行什么程序，不键入
private let webTerminalClassNames: Set<String> = ["xterm", "xterm-helper-textarea", "xterm-screen"]

// 开着 Vim 模式的 CodeMirror（Obsidian、LeetCode……）：普通模式下键入的字母是命令
private let vimModeClassNames: Set<String> = ["cm-vimMode", "cm-fat-cursor"]

// Google Docs：同样只渲染可见部分、输入走代理节点，而且默认开着自动大写、智能引号、自动替换——键入会改掉内容
private let wordProcessorClassNames: Set<String> = [
    "kix-appview-editor", "docs-texteventtarget-iframe", "kix-canvas-tile-content",
]

// Google Sheets 的单元格编辑框：可以键入，但单元格里换行要按 ⌘↩（↩、⇧↩ 会确认单元格并跳到别的格）
private let spreadsheetClassNames: Set<String> = ["cell-input"]

// Google Docs、Sheets、Slides 也按网址认（Firefox 不提供 AXDOMClassList）
private let wordProcessorHosts: Set<String> = ["docs.google.com"]

// ⇧↩ 确定是换行（而不是发送、确认单元格、运行代码）的地方：只有这些 App、网页的富文本编辑器才用 ⇧↩ 键入多行文字。
// 普通的 <textarea> 里 ⇧↩ 也是换行（浏览器的默认行为）
private let softNewlineBundleIDPrefixes = [
    "com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.microsoft.teams", "notion.id", "com.anthropic.claudefordesktop",
    "com.openai.chat", "org.whispersystems.signal-desktop", "com.linear", "im.riot.app", "Mattermost.Desktop", "com.facebook.archon",
    "com.tdesktop.Telegram",
]
private let softNewlineHosts: Set<String> = [
    "mail.google.com", "app.slack.com", "discord.com", "teams.microsoft.com", "teams.live.com", "www.notion.so", "notion.so",
    "claude.ai", "chatgpt.com", "chat.openai.com", "gemini.google.com", "web.whatsapp.com", "web.telegram.org",
    "outlook.office.com", "outlook.office365.com", "outlook.live.com", "www.messenger.com", "app.element.io", "linear.app",
    "github.com", "gitlab.com",
]

// Firefox 里认不出代码编辑器（没有 AXDOMClassList），只对没有代码编辑器的纯聊天、邮件网站按富文本处理
private let geckoRichTextHosts: Set<String> = [
    "mail.google.com", "app.slack.com", "discord.com", "teams.microsoft.com", "teams.live.com", "web.whatsapp.com",
    "web.telegram.org", "outlook.office.com", "outlook.office365.com", "outlook.live.com", "www.messenger.com", "app.element.io",
]

// JetBrains 终端工具窗口的名字（各种界面语言）
private let ideTerminalLabels = ["terminal", "终端", "終端", "ターミナル", "터미널", "терминал"]

private enum IDEFocusPlace {
    case editor
    case terminal
    // 中途读不到（超时、层级太深）
    case unknown
}

enum WebEditorKind {
    case code
    // 开着 Vim 模式的代码编辑器
    case vimCode
    case terminal
    case wordProcessor
    // Google Sheets 的单元格编辑框
    case spreadsheet
    // 认不出来：Firefox 不提供 AXDOMClassList，或者往上找的过程中途读不到了。可能是代码编辑器、电子表格，按最保守的方式处理
    case unknown
}

// 终端里正在运行的程序：只在 shell 提示符（或者 sudo 这类在等密码的程序）前键入。vim 普通模式、less、htop 会把按键当命令，
// tmux、ssh 里面运行着什么看不到——真正的粘贴有 bracketed paste 保护，模拟键入没有
let terminalPromptPrograms: Set<String> = [
    "zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh", "nu", "pwsh", "xonsh", "elvish",
    "sudo", "su", "doas", "login", "passwd",
]
// 这两个终端的窗口标题总是显示当前标签页前台正在运行的程序
private let jobTitleTerminalBundleIDs: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]

// 终端前台进程组里的一个进程
struct ForegroundProcess {
    let pid: pid_t
    let name: String
    // 它的控制终端（dev_t）
    let tty: Int32
}

// 提示符前的程序里真正的 shell（不算在等密码的 sudo 这类）
let terminalPasswordPrograms: Set<String> = ["sudo", "su", "doas", "login", "passwd"]

// 前台进程组里的这个进程停在提示符前：shell；或者 sudo 这类程序、并且终端正处在读密码的状态（关了回显、开着 canonical 模式）。
// sudo 这类程序认证之后会运行别的命令：新版 sudo 默认（use_pty）把命令放在另一个伪终端上，这个终端的前台组里只剩 sudo，
// 它把终端设成 raw 模式转发按键——这时键入的文字会到达 sudo 运行的程序（例如 `sudo vim` 的普通模式，字母就是命令）
func isAtPrompt(_ process: ForegroundProcess) -> Bool {
    guard terminalPromptPrograms.contains(process.name) else {
        return false
    }
    return !terminalPasswordPrograms.contains(process.name) || passwordIsBeingRead(tty: process.tty)
}

// 读密码（readpassphrase、getpass）时终端关掉回显、保留 canonical 模式（整行读）。sudoers 设了 pwfeedback（输入时显示星号）时
// sudo 关掉 canonical 模式一个个字符读，但保留输出处理（OPOST）；转发按键给 use_pty 里的命令时设成 raw 模式，连 OPOST 也关掉
private func passwordIsBeingRead(tty: Int32) -> Bool {
    guard let path = terminalDevicePath(tty) else {
        return false
    }
    let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else {
        return false
    }
    defer { close(fd) }
    var modes = termios()
    guard tcgetattr(fd, &modes) == 0, modes.c_lflag & tcflag_t(ECHO) == 0 else {
        return false
    }
    return modes.c_lflag & tcflag_t(ICANON) != 0 || modes.c_oflag & tcflag_t(OPOST) != 0
}

// 前台进程组里不在提示符前的程序的名字（通知里用）：组里还有别的程序时，sudo 这类只是把它启动起来的那个，说别的程序的名字
func programName(in group: [ForegroundProcess]) -> String? {
    group.first { !isAtPrompt($0) && !terminalPasswordPrograms.contains($0.name) }?.name ?? group.first { !isAtPrompt($0) }?.name
}

private enum TerminalForeground {
    // 停在提示符前；shells：相关标签页里的 shell 进程（多行粘贴要看它们支不支持 bracketed paste、行编辑器是不是在读）。
    // 有标签页停在 sudo 的密码提示时为空
    case prompt(shells: [ForegroundProcess])
    // 别的程序（认不出时为 nil）
    case other(String?)
}

// 代码编辑器里能安全键入的字符：引号、括号会自动补全或包住选中内容，"." "(" ";" "," ":" 会确认自动补全的候选，
// "/**" 会补全成注释，"<" 会补全 HTML 标签，HTML 标签里键入 "=" 会自动补上引号（只允许末尾的 base64 填充 "=" / "=="）。
// 第一个字符还必须是字母或数字：有选中内容时第一个键入的字符如果是 "_" "*" 这类，Markdown 里会把选中内容包起来而不是替换掉
private let codeEditorSafeCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -+/@~%#$^!?&_".unicodeScalars)

private func isSafeForCodeEditor(_ text: String) -> Bool {
    var body = text
    for _ in 0..<2 where body.hasSuffix("=") {
        body.removeLast()
    }
    guard let first = body.unicodeScalars.first, first.isASCII,
          first.properties.isAlphabetic || ("0"..."9").contains(first) else {
        return false
    }
    return body.unicodeScalars.allSatisfy { codeEditorSafeCharacters.contains($0) }
}

private let editorDataFolderCacheLock = NSLock()
private var editorDataFolderCache: [pid_t: String?] = [:]

// 基于 VS Code 的编辑器（VS Code、Cursor、Windsurf、VSCodium、Positron……）：包里的 product.json 写着它在用户目录下的数据文件夹
// （".vscode"、".cursor"……），插件装在那里的 extensions 目录。不是这类编辑器时为 nil
func vscodeDataFolderName(pid: pid_t) -> String? {
    editorDataFolderCacheLock.lock()
    if let cached = editorDataFolderCache[pid] {
        editorDataFolderCacheLock.unlock()
        return cached
    }
    editorDataFolderCacheLock.unlock()
    var name: String?
    if let url = NSRunningApplication(processIdentifier: pid)?.bundleURL?.appendingPathComponent("Contents/Resources/app/product.json"),
       let data = try? Data(contentsOf: url),
       let product = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
        name = product["dataFolderName"] as? String
    }
    editorDataFolderCacheLock.lock()
    editorDataFolderCache[pid] = .some(name)
    editorDataFolderCacheLock.unlock()
    return name
}

private let vimEmulationCacheLock = NSLock()
private var vimEmulationCache: [String: (checkedAt: Date, installed: Bool)] = [:]

private let screenReaderSupportLock = NSLock()
private var screenReaderSupportCache: [pid_t: (checkedAt: Date, enabled: Bool)] = [:]

// JetBrains 系 IDE 开着"支持屏幕阅读器"：编辑器通过辅助功能给出的是折叠后看到的文字（折叠的代码换成 "..."），读出来的不是
// 真正的内容，按它删除会删掉没复制到的代码。看这个 IDE 自己的配置目录（App 包里 product-info.json 的 dataDirectoryName；
// 升级后旧版本的目录还留着，不能都算）；读不到时才看所有目录。按进程一分钟查一次
func jetBrainsScreenReaderSupportEnabled(pid: pid_t) -> Bool {
    screenReaderSupportLock.lock()
    if let cached = screenReaderSupportCache[pid], Date().timeIntervalSince(cached.checkedAt) < 60 {
        screenReaderSupportLock.unlock()
        return cached.enabled
    }
    screenReaderSupportLock.unlock()
    let fileManager = FileManager.default
    let support = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    let app = NSRunningApplication(processIdentifier: pid)
    var folders: [URL] = []
    if let productInfo = app?.bundleURL?.appendingPathComponent("Contents/Resources/product-info.json"),
       let data = try? Data(contentsOf: productInfo),
       let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let dataDirectory = json["dataDirectoryName"] as? String, !dataDirectory.isEmpty {
        let vendor = app?.bundleIdentifier?.hasPrefix("com.jetbrains.") == true ? "JetBrains" : "Google"
        folders = [support.appendingPathComponent("\(vendor)/\(dataDirectory)")]
    } else {
        for vendor in ["JetBrains", "Google"] {
            let vendorFolder = support.appendingPathComponent(vendor)
            folders += ((try? fileManager.contentsOfDirectory(atPath: vendorFolder.path)) ?? []).map { vendorFolder.appendingPathComponent($0) }
        }
    }
    let enabled = folders.contains { folder in
        guard let contents = try? String(contentsOf: folder.appendingPathComponent("options/ide.general.xml"), encoding: .utf8) else {
            return false
        }
        return contents.range(of: #"name="supportScreenReaders"\s+value="true""#, options: .regularExpression) != nil
    }
    screenReaderSupportLock.lock()
    screenReaderSupportCache[pid] = (Date(), enabled)
    screenReaderSupportLock.unlock()
    return enabled
}

// 代码编辑器装了 Vim 模拟插件（VSCodeVim、VSCode Neovim、IdeaVim）：普通模式下键入的字母是命令。看不出当前是不是普通模式，
// 装了就不键入。插件目录一分钟查一次
private func hasVimEmulation(for target: FocusedTarget) -> Bool {
    guard let bundleID = target.bundleIdentifier else {
        return false
    }
    vimEmulationCacheLock.lock()
    if let cached = vimEmulationCache[bundleID], Date().timeIntervalSince(cached.checkedAt) < 60 {
        vimEmulationCacheLock.unlock()
        return cached.installed
    }
    vimEmulationCacheLock.unlock()
    let fileManager = FileManager.default
    let home = fileManager.homeDirectoryForCurrentUser
    func entries(_ path: String) -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: home.appendingPathComponent(path).path)) ?? []
    }
    var installed = false
    if target.isJavaIDE {
        let vendor = bundleID.hasPrefix("com.jetbrains.") ? "Library/Application Support/JetBrains" : "Library/Application Support/Google"
        installed = entries(vendor).contains { product in
            entries("\(vendor)/\(product)/plugins").contains { $0.lowercased().hasPrefix("ideavim") }
        }
    } else if let dataFolder = vscodeDataFolderName(pid: target.pid) {
        installed = entries("\(dataFolder)/extensions").contains {
            $0.lowercased().hasPrefix("vscodevim.vim-") || $0.lowercased().hasPrefix("asvetliakov.vscode-neovim-")
        }
    }
    vimEmulationCacheLock.lock()
    vimEmulationCache[bundleID] = (Date(), installed)
    vimEmulationCacheLock.unlock()
    return installed
}

// 终端 App 里每个 tty 前台进程组里的全部程序名：同一组里的别的进程也算（`sudo vim` 里 vim 和 sudo 在同一组，
// 管道、脚本启动的 less 也是）。只看这个终端的子孙进程，iTerm2 还要看托管它会话的服务进程（不是它的子进程）。找不到时返回 nil
private func terminalForegroundGroups(pid terminalPID: pid_t, bundleID: String?) -> [[ForegroundProcess]]? {
    guard let processes = allProcesses() else {
        return nil
    }
    var childIndexes: [pid_t: [Int]] = [:]
    var membersByGroup: [pid_t: [Int]] = [:]
    for (index, process) in processes.enumerated() {
        childIndexes[process.kp_eproc.e_ppid, default: []].append(index)
        // 已经退出、只等父进程回收的僵尸进程不算前台在运行的程序
        if process.kp_proc.p_stat != CChar(SZOMB) {
            membersByGroup[process.kp_eproc.e_pgid, default: []].append(index)
        }
    }
    var roots = [terminalPID]
    if bundleID == "com.googlecode.iterm2" {
        let uid = getuid()
        roots += processes.filter { processName($0).hasPrefix("itermserver") && $0.kp_eproc.e_pcred.p_ruid == uid }.map { $0.kp_proc.p_pid }
    }
    // 每个有控制终端（e_tdev 不是 NODEV）的子孙进程：记下它的终端的前台进程组
    var foreground: [pid_t: Int32] = [:]
    var pending = roots
    var visited = Set<pid_t>()
    while let current = pending.popLast() {
        guard visited.insert(current).inserted else {
            continue
        }
        for index in childIndexes[current] ?? [] {
            let process = processes[index]
            if process.kp_eproc.e_tdev != -1, process.kp_eproc.e_tpgid > 0 {
                foreground[process.kp_eproc.e_tpgid] = process.kp_eproc.e_tdev
            }
            pending.append(process.kp_proc.p_pid)
        }
    }
    guard !foreground.isEmpty else {
        return nil
    }
    // 组里一个进程都找不到（刚退出）时是空数组，调用方按认不出处理
    return foreground.map { group, tty in
        (membersByGroup[group] ?? []).filter { processes[$0].kp_eproc.e_tdev == tty }
            .map { ForegroundProcess(pid: processes[$0].kp_proc.p_pid, name: processName(processes[$0]), tty: tty) }
    }
}

// 终端所有标签页的前台进程组（看不出焦点在哪个标签页时用：kitty、还没有 tty 属性的 Ghostty、终端里的 tmux）；
// 读不到、有的组认不出时为 nil
func terminalForegroundGroups(of target: FocusedTarget) -> [[ForegroundProcess]]? {
    guard let groups = terminalForegroundGroups(pid: target.pid, bundleID: target.bundleIdentifier), !groups.isEmpty,
          !groups.contains(where: { $0.isEmpty }) else {
        return nil
    }
    return groups
}

// 本机全部进程；读不到时为 nil
private func allProcesses() -> [kinfo_proc]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
        return nil
    }
    // 两次调用之间可能多出几个进程，多留些空间
    size += size / 8
    var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
    guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else {
        return nil
    }
    return Array(processes.prefix(size / MemoryLayout<kinfo_proc>.stride))
}

// 文字怎么到达终端
enum TerminalDelivery {
    // 整段一次写进终端（编辑器扩展、终端自己的脚本接口）
    case singleWrite
    // 逐个按键键入：ESC 和后面的字符分几次到达 shell
    case keystrokes
}

// 一次写进终端的内容（编辑器扩展的 sendText、iTerm2 的 write text）。shells：前台进程组里的 shell；atPasswordPrompt：组里还有
// sudo 这类在等密码的程序。
//  - shell 的行编辑器正在读、认得 bracketed paste：和真正的粘贴一样包上 ESC[200~ … ESC[201~（shell 整段插入编辑缓冲区、不执行）。
//    单行文字也包上：vi 模式的命令模式里，原样送进去的字母是命令；
//  - 否则（密码提示、脚本里的 read、还在启动的 shell、不认得这个标记的 shell）只原样送不含控制字符的单行文字（去掉末尾的换行——
//    真正的粘贴也不会因为它执行命令），并且 shell 不能开着 vi 模式
func terminalPayload(for text: String, shells: [ForegroundProcess], atPasswordPrompt: Bool) -> Result<String, UnavailableReason> {
    var body = KeystrokeTyper.normalizedNewlines(text)
    while body.hasSuffix("\n") {
        body.removeLast()
    }
    guard !body.isEmpty else {
        return .failure(.noRoute)
    }
    let hasControls = body.unicodeScalars.contains { $0.properties.generalCategory == .control }
    // 密码提示：标记会成为密码的一部分
    if atPasswordPrompt || shells.isEmpty {
        return hasControls ? .failure(.multiLine) : .success(body)
    }
    if shells.allSatisfy({ shellAcceptsBracketedPaste(pid: $0.pid, delivery: .singleWrite) && lineEditorIsReading(tty: $0.tty) }) {
        guard let sanitized = sanitizedForBracketedPaste(body) else {
            return .failure(.noRoute)
        }
        return .success("\u{1b}[200~" + sanitized + "\u{1b}[201~")
    }
    guard !hasControls else {
        return .failure(.multiLine)
    }
    guard !shells.contains(where: { shellMayUseViMode(pid: $0.pid) }) else {
        return .failure(.viMode)
    }
    return .success(body)
}

// 终端设备的路径（"/dev/ttys003"）
func terminalDevicePath(_ tty: Int32) -> String? {
    guard tty != -1, let name = devname(dev_t(tty), mode_t(S_IFCHR)) else {
        return nil
    }
    let device = String(cString: name)
    return device.isEmpty || device.hasPrefix("?") ? nil : "/dev/" + device
}

// shell 的行编辑器（zsh 的 ZLE、bash 的 readline、fish）正在读这个终端：它们读一行命令时都会关掉终端的 canonical 模式和回显，
// 并且改掉回车、换行的转换（ZLE 同时打开 ICRNL 和 INLCR，readline、fish 两个都关掉）。脚本里的 read、还在执行配置文件的 shell
// （例如 oh-my-zsh 启动时的更新提示）、sudo 的密码提示要么开着 canonical 模式或回显，要么（`read -s -n 1` 这类按任意键继续）
// 保留默认的只有 ICRNL——这时 shell 不认 bracketed paste，多行文字里的换行会被当成回车
func lineEditorIsReading(tty: Int32) -> Bool {
    guard let path = terminalDevicePath(tty) else {
        return false
    }
    let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
    guard fd >= 0 else {
        return false
    }
    defer { close(fd) }
    var modes = termios()
    guard tcgetattr(fd, &modes) == 0, modes.c_lflag & tcflag_t(ICANON | ECHO) == 0 else {
        return false
    }
    return modes.c_iflag & tcflag_t(ICRNL | INLCR) != tcflag_t(ICRNL)
}

// 括号里的内容：换行用 \r（终端自己粘贴时也这样），Tab 保留；别的 C0 控制字符和 DEL 换成 Unicode 里对应的图形符号（ESC 变成 ␛），
// 免得提前结束粘贴或者被当成按键。含 C1 控制字符时返回 nil
func sanitizedForBracketedPaste(_ body: String) -> String? {
    var result = String.UnicodeScalarView()
    for scalar in body.unicodeScalars {
        switch scalar.value {
        case 0x0A:
            result.append("\r")
        case 0x09:
            result.append(scalar)
        case 0x00...0x1F:
            result.append(Unicode.Scalar(0x2400 + scalar.value)!)
        case 0x7F:
            result.append("\u{2421}")
        case 0x80...0x9F:
            return nil
        default:
            result.append(scalar)
        }
    }
    return String(result)
}

// 读 shell 的配置文件：任何一个里面出现任何一个关键字
private func configFilesMention(_ paths: [String], _ needles: [String]) -> Bool {
    paths.contains { path in
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return needles.contains { contents.contains($0) }
    }
}

// zsh 的配置文件。exec 时的 ZDOTDIR 往往不是用户真正的配置目录：XDG 风格的配置在 ~/.zshenv 里才设 ZDOTDIR；VS Code、Ghostty、kitty
// 的 shell integration 把 ZDOTDIR 换成自己的目录，原来的放在 USER_ZDOTDIR、GHOSTTY_ZSH_ZDOTDIR、KITTY_ORIG_ZDOTDIR 里。
// 这些目录都读（多读只会让判断更保守）；~/.zshenv 里的 ZDOTDIR 认不出指向哪里时返回 nil
private func zshConfigFiles(environment: [String: String]) -> [String]? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    func expand(_ value: String) -> String? {
        var path = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let xdg = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        for (pattern, replacement) in [("${XDG_CONFIG_HOME:-$HOME/.config}", xdg), ("${XDG_CONFIG_HOME}", xdg), ("$XDG_CONFIG_HOME", xdg),
                                       ("${HOME}", home), ("$HOME", home)] {
            path = path.replacingOccurrences(of: pattern, with: replacement)
        }
        if path.hasPrefix("~") {
            path = home + path.dropFirst()
        }
        return path.hasPrefix("/") && !path.contains("$") ? path : nil
    }
    var directories = [home]
    for key in ["ZDOTDIR", "USER_ZDOTDIR", "GHOSTTY_ZSH_ZDOTDIR", "KITTY_ORIG_ZDOTDIR"] {
        if let value = environment[key], !value.isEmpty, let path = expand(value) {
            directories.append(path)
        }
    }
    for file in [home + "/.zshenv", "/etc/zshenv"] {
        guard let contents = try? String(contentsOfFile: file, encoding: .utf8) else {
            continue
        }
        for line in contents.components(separatedBy: .newlines) {
            guard let range = line.range(of: #"ZDOTDIR=\S+"#, options: .regularExpression) else {
                continue
            }
            guard let path = expand(String(line[range].dropFirst("ZDOTDIR=".count))) else {
                return nil
            }
            directories.append(path)
        }
    }
    var seen = Set<String>()
    let unique = directories.filter { seen.insert($0).inserted }
    return unique.flatMap { directory in [".zshenv", ".zprofile", ".zshrc", ".zlogin"].map { directory + "/" + $0 } }
        + ["/etc/zshenv", "/etc/zprofile", "/etc/zshrc", "/etc/zlogin"]
}

// bash（readline）的配置文件
private func bashConfigFiles(environment: [String: String]) -> [String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var files = [home + "/.inputrc", "/etc/inputrc", home + "/.bashrc", home + "/.bash_profile", home + "/.bash_login", home + "/.profile"]
    if let inputrc = environment["INPUTRC"], !inputrc.isEmpty {
        files.append(inputrc)
    }
    return files
}

// shell 在提示符前收到 ESC[200~ … ESC[201~ 时会整段插入编辑缓冲区、不执行（键位表里绑着 bracketed paste）：
//  - zsh 5.1 起三个默认键位表里都绑着。zle_bracketed_paste 只管通知终端打开这个模式，不影响绑定；
//    逐键送时 ESC 后面的字符要在 KEYTIMEOUT 之内到达，改过 KEYTIMEOUT 的（zsh-vi-mode 插件改成 10 毫秒）不冒险；
//  - bash 4.4 起（readline 7）绑着；vi 模式的命令模式里没有，用 vi 模式的不冒险。macOS 自带的 /bin/bash 是 3.2，没有；
//  - fish 3、4 都认得，但 fish 4 让终端用 kitty 键盘协议，逐键送的 ESC 到不了 shell：只接受一次写入。
// 配置文件里改过这个绑定（出现 "200~"）的都不冒险
func shellAcceptsBracketedPaste(pid: pid_t, delivery: TerminalDelivery) -> Bool {
    guard let executable = processExecutablePath(pid: pid) else {
        return false
    }
    let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    let environment = processEnvironment(pid: pid) ?? [:]
    switch URL(fileURLWithPath: resolved).lastPathComponent {
    case "zsh":
        guard let files = zshConfigFiles(environment: environment), !configFilesMention(files, ["200~"]) else {
            return false
        }
        return delivery == .singleWrite || !configFilesMention(files, ["KEYTIMEOUT", "zsh-vi-mode"])
    case "bash":
        guard let version = bashVersion(executable: resolved), version.major > 4 || (version.major == 4 && version.minor >= 4) else {
            return false
        }
        return !configFilesMention(bashConfigFiles(environment: environment), ["200~", "editing-mode vi", "set -o vi"])
    case "fish":
        return delivery == .singleWrite
    default:
        return false
    }
}

// shell 在提示符前会打开终端的 bracketed paste 模式（终端自己的粘贴据此给内容加上标记）：zsh 5.1 起（没改过 zle_bracketed_paste）、
// bash 5.1 起（没关掉 enable-bracketed-paste）、fish。Ghostty 的 input text 和真正的粘贴一样由终端决定加不加标记，要看这个
func shellEnablesBracketedPasteMode(pid: pid_t) -> Bool {
    guard let executable = processExecutablePath(pid: pid) else {
        return false
    }
    let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    let environment = processEnvironment(pid: pid) ?? [:]
    switch URL(fileURLWithPath: resolved).lastPathComponent {
    case "zsh":
        guard let files = zshConfigFiles(environment: environment) else {
            return false
        }
        return !configFilesMention(files, ["zle_bracketed_paste", "200~"])
    case "bash":
        guard let version = bashVersion(executable: resolved), version.major > 5 || (version.major == 5 && version.minor >= 1) else {
            return false
        }
        return !configFilesMention(bashConfigFiles(environment: environment), ["enable-bracketed-paste", "200~", "editing-mode vi", "set -o vi"])
    case "fish":
        return true
    default:
        return false
    }
}

// shell 可能开着 vi 键位（命令模式里键入的字母是命令）：配置里写了 vi 模式；zsh 还会在 $EDITOR / $VISUAL 含 "vi" 时默认用 vi 键位，
// 除非配置里（或 oh-my-zsh）明确改成 emacs 键位。认不出时按可能处理
func shellMayUseViMode(pid: pid_t) -> Bool {
    guard let executable = processExecutablePath(pid: pid) else {
        return true
    }
    let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    let environment = processEnvironment(pid: pid) ?? [:]
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    switch URL(fileURLWithPath: resolved).lastPathComponent {
    case "zsh":
        guard let files = zshConfigFiles(environment: environment) else {
            return true
        }
        if configFilesMention(files, ["bindkey -v", "bindkey -A viins", "zsh-vi-mode", "vi-mode"]) {
            return true
        }
        let editorIsVi = [environment["VISUAL"], environment["EDITOR"]].contains { $0?.contains("vi") == true }
            || configFilesMatch(files, #"(EDITOR|VISUAL)=\S*vi"#)
        return editorIsVi && !configFilesMention(files, ["bindkey -e", "oh-my-zsh.sh"])
    case "bash":
        return configFilesMention(bashConfigFiles(environment: environment), ["set -o vi", "editing-mode vi"])
    case "fish":
        let config = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        var files = [config + "/fish/config.fish", config + "/fish/fish_variables", config + "/fish/functions/fish_user_key_bindings.fish"]
        files += ((try? FileManager.default.contentsOfDirectory(atPath: config + "/fish/conf.d")) ?? []).map { config + "/fish/conf.d/" + $0 }
        return configFilesMention(files, ["fish_vi_key_bindings", "fish_hybrid_key_bindings"])
    default:
        return false
    }
}

// 配置文件里有一行匹配这个正则
private func configFilesMatch(_ paths: [String], _ pattern: String) -> Bool {
    paths.contains { path in
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            return false
        }
        return contents.range(of: pattern, options: .regularExpression) != nil
    }
}

private let bashVersionLock = NSLock()
private var bashVersionCache: [String: (major: Int, minor: Int)?] = [:]

// bash 的版本：macOS 自带的是 3.2；Homebrew、Nix 装的路径里带着版本号；别的问它自己（--version，结果按路径缓存）
func bashVersion(executable path: String) -> (major: Int, minor: Int)? {
    if path == "/bin/bash" || path == "/bin/sh" {
        return (3, 2)
    }
    bashVersionLock.lock()
    let cached = bashVersionCache[path]
    bashVersionLock.unlock()
    if let cached {
        return cached
    }
    func parse(_ text: String, _ pattern: String) -> (major: Int, minor: Int)? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges == 3,
              let majorRange = Range(match.range(at: 1), in: text), let minorRange = Range(match.range(at: 2), in: text),
              let major = Int(text[majorRange]), let minor = Int(text[minorRange]) else {
            return nil
        }
        return (major, minor)
    }
    var version = parse(path, #"bash[-/](?:interactive-)?(\d+)\.(\d+)"#)
    if version == nil {
        // 不运行它（程序文件由别的程序决定，不能带着 Copi 的权限运行）：bash 的程序文件里有 "@(#)Bash version 5.2.37(1) release" 这样的字样
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped), data.count < 64 * 1024 * 1024,
           let range = data.range(of: Data("Bash version ".utf8)) {
            let tail = String(decoding: data[range.upperBound..<min(range.upperBound + 16, data.count)], as: UTF8.self)
            version = parse("version " + tail, #"version (\d+)\.(\d+)"#)
        }
    }
    bashVersionLock.lock()
    bashVersionCache[path] = version
    bashVersionLock.unlock()
    return version
}

// 进程的环境变量（只能读同一用户的进程）；读不到时为 nil
func processEnvironment(pid: pid_t) -> [String: String]? {
    var argumentLimit: Int32 = 0
    var limitSize = MemoryLayout<Int32>.size
    var limitMIB: [Int32] = [CTL_KERN, KERN_ARGMAX]
    guard sysctl(&limitMIB, 2, &argumentLimit, &limitSize, nil, 0) == 0, argumentLimit > 0 else {
        return nil
    }
    var size = Int(argumentLimit)
    var buffer = [UInt8](repeating: 0, count: size)
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
        return nil
    }
    // 布局：argc、程序路径、补齐用的 0、各个参数、各个环境变量（都以 0 结尾）
    var argumentCount = 0
    for (offset, byte) in buffer.prefix(MemoryLayout<Int32>.size).enumerated() {
        argumentCount |= Int(byte) << (8 * offset)
    }
    var index = MemoryLayout<Int32>.size
    while index < size, buffer[index] != 0 {
        index += 1
    }
    while index < size, buffer[index] == 0 {
        index += 1
    }
    while argumentCount > 0, index < size {
        while index < size, buffer[index] != 0 {
            index += 1
        }
        index += 1
        argumentCount -= 1
    }
    var environment: [String: String] = [:]
    while index < size {
        let start = index
        while index < size, buffer[index] != 0 {
            index += 1
        }
        guard index > start else {
            break
        }
        let entry = String(decoding: buffer[start..<index], as: UTF8.self)
        if let separator = entry.firstIndex(of: "=") {
            environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
        }
        index += 1
    }
    return environment
}

// 进程的程序文件路径
func processExecutablePath(pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else {
        return nil
    }
    return String(cString: buffer)
}

// 某个进程（通常是终端里的 shell）所在终端的前台进程组里的全部进程；读不到时为 nil
func foregroundGroup(ofProcess pid: pid_t) -> [ForegroundProcess]? {
    guard let processes = allProcesses(),
          let shell = processes.first(where: { $0.kp_proc.p_pid == pid }),
          shell.kp_eproc.e_tdev != -1, shell.kp_eproc.e_tpgid > 0 else {
        return nil
    }
    let tty = shell.kp_eproc.e_tdev
    let group = shell.kp_eproc.e_tpgid
    return processes
        .filter { $0.kp_eproc.e_pgid == group && $0.kp_eproc.e_tdev == tty && $0.kp_proc.p_stat != CChar(SZOMB) }
        .map { ForegroundProcess(pid: $0.kp_proc.p_pid, name: processName($0), tty: tty) }
}

// 某个终端设备（"/dev/ttys003"）前台进程组里的全部进程；读不到、组里没有进程时为 nil
func foregroundGroup(ofTerminalDevice path: String) -> [ForegroundProcess]? {
    var info = stat()
    guard path.hasPrefix("/dev/"), stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFCHR, let processes = allProcesses() else {
        return nil
    }
    let tty = Int32(bitPattern: UInt32(truncatingIfNeeded: info.st_rdev))
    guard let group = processes.first(where: { $0.kp_eproc.e_tdev == tty && $0.kp_eproc.e_tpgid > 0 })?.kp_eproc.e_tpgid else {
        return nil
    }
    let members = processes
        .filter { $0.kp_eproc.e_pgid == group && $0.kp_eproc.e_tdev == tty && $0.kp_proc.p_stat != CChar(SZOMB) }
        .map { ForegroundProcess(pid: $0.kp_proc.p_pid, name: processName($0), tty: tty) }
    return members.isEmpty ? nil : members
}

private func processName(_ process: kinfo_proc) -> String {
    var command = process.kp_proc.p_comm
    return withUnsafeBytes(of: &command) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }.lowercased()
}

extension FocusedTarget {
    var attributeNames: [String] {
        guard !axBudgetExhausted else {
            return []
        }
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success, let names = names as? [String] else {
            return []
        }
        return names
    }

    var parameterizedAttributeNames: [String] {
        guard !axBudgetExhausted else {
            return []
        }
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success, let names = names as? [String] else {
            return []
        }
        return names
    }

    func webEngine(attributeNames names: [String]) -> WebEngine? {
        if names.contains("ChromeAXNodeId") {
            return .chromium
        }
        if isGeckoApp(pid: pid, bundleIdentifier: bundleIdentifier) {
            return .gecko
        }
        if names.contains("AXDOMIdentifier") || names.contains("AXDOMClassList") {
            return .webKit
        }
        return nil
    }

    var value: String? {
        copyAXAttribute(element, kAXValueAttribute) as? String
    }

    var childCount: Int? {
        guard !axBudgetExhausted else {
            return nil
        }
        var count: CFIndex = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success else {
            return nil
        }
        return count
    }

    func isSettable(_ attribute: String) -> Bool {
        guard !axBudgetExhausted else {
            return false
        }
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    var applicationName: String {
        NSRunningApplication(processIdentifier: pid)?.localizedName ?? "this app"
    }

    // 单行、没有子节点的原子输入框（网页里的 <input>；原生的 NSTextField）
    var isAtomicSingleLineField: Bool {
        guard let role, role == kAXTextFieldRole || role == kAXComboBoxRole else {
            return false
        }
        return childCount == 0
    }

    // 往上几层有没有网页代码编辑器、网页终端、Google Docs（见 codeEditorClassNames 等）。Firefox 不提供 AXDOMClassList，
    // 中途读不到父节点（超时）时也没法判断：都返回 .unknown，由调用方按最保守的方式处理
    func webEditorKind(engine: WebEngine) -> WebEditorKind? {
        if engine == .gecko {
            // Firefox：按 aria 标签认出 xterm.js 终端（"Terminal input"）和 Monaco（aria-roledescription "editor"），
            // 按网址认出 Google Docs 和没有代码编辑器的聊天、邮件网站，其余认不出
            for attribute in [kAXDescriptionAttribute, kAXTitleAttribute, kAXRoleDescriptionAttribute] {
                guard let label = copyAXAttribute(element, attribute) as? String else {
                    continue
                }
                if label.localizedCaseInsensitiveContains("terminal") {
                    return .terminal
                }
                if label.caseInsensitiveCompare("editor") == .orderedSame || label.hasPrefix("Editor content") {
                    return .code
                }
            }
            if let url = webPageURL, let host = url.host?.lowercased() {
                // Firefox 认不出 Google Sheets 的单元格编辑框（没有 class），整个网站按文字处理器拒绝
                if wordProcessorHosts.contains(host) {
                    return .wordProcessor
                }
                if geckoRichTextHosts.contains(host) {
                    return nil
                }
            }
            return .unknown
        }
        var node: AXUIElement? = element
        for _ in 0..<8 {
            guard let current = node else {
                // 还没走到网页根节点就读不到父节点了
                return .unknown
            }
            if axBudgetExhausted {
                return .unknown
            }
            if let classes = copyAXAttribute(current, "AXDOMClassList") as? [String] {
                if classes.contains(where: { vimModeClassNames.contains($0) }) {
                    return .vimCode
                }
                if classes.contains(where: { webTerminalClassNames.contains($0) }) {
                    return .terminal
                }
                if classes.contains(where: { codeEditorClassNames.contains($0) }) {
                    // Vim 模式的 class 可能在编辑器根节点（更上一层）上；Ace 的 Vim 模式是 "normal-mode"
                    return classes.contains("normal-mode") || ancestorsHaveVimMode(from: current) ? .vimCode : .code
                }
                if classes.contains(where: { wordProcessorClassNames.contains($0) }) {
                    return .wordProcessor
                }
                if classes.contains(where: { spreadsheetClassNames.contains($0) }) {
                    return .spreadsheet
                }
            }
            if (copyAXAttribute(current, kAXRoleAttribute) as? String) == "AXWebArea" {
                break
            }
            node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
        }
        // Google Docs 的键盘输入在一个 about:blank 的 iframe 里，那里够不着外面的 class：再按网址认一遍
        // 只有真的找到了单元格编辑框才算电子表格（评论框、查找框、对话框里的 ⌘↩ 是提交）
        guard let host = webPageHost, wordProcessorHosts.contains(host) else {
            return nil
        }
        return .wordProcessor
    }

    private func ancestorsHaveVimMode(from start: AXUIElement) -> Bool {
        var node = asAXElement(copyAXAttribute(start, kAXParentAttribute))
        for _ in 0..<3 {
            guard let current = node else {
                return false
            }
            if let classes = copyAXAttribute(current, "AXDOMClassList") as? [String],
               classes.contains(where: { vimModeClassNames.contains($0) || $0 == "normal-mode" }) {
                return true
            }
            node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
        }
        return false
    }

    // 所在网页的网址（往上找到网页根节点读它的 AXURL；about:blank 这类脚本创建的 iframe 没有主机名，继续往外找）；找不到时为 nil
    var webPageURL: URL? {
        var node: AXUIElement? = element
        for _ in 0..<60 {
            guard let current = node, !axBudgetExhausted else {
                return nil
            }
            if (copyAXAttribute(current, kAXRoleAttribute) as? String) == "AXWebArea",
               let url = copyAXAttribute(current, kAXURLAttribute) as? URL, let host = url.host, !host.isEmpty {
                return url
            }
            node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
        }
        return nil
    }

    var webPageHost: String? {
        webPageURL?.host?.lowercased()
    }

    // 在这里 ⇧↩ 是不是换行（见 softNewlineBundleIDPrefixes）：原生的多行文本视图、已知的聊天和邮件 App、网页。
    // 别的网页里认不出：网页电子表格的编辑框、搜索框（Google 的搜索框就是 <textarea>）里 ⇧↩ 会确认、提交
    func shiftReturnIsSoftNewline(engine: WebEngine?) -> Bool {
        if let bundleID = bundleIdentifier, softNewlineBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return true
        }
        guard engine != nil else {
            // 原生的多行文本视图（AppKit 的 NSTextView）：⇧↩ 和 ↩ 一样插入换行。认得出它的办法是选中的文字可以直接改写
            // （AXSelectedText 可写）：Qt、Tk、Java 这些界面库只让改整段值，它们的 ⇧↩ 可能是别的意思（Jupyter QtConsole、Spyder
            // 的 ⇧↩ 是运行代码）。认不出引擎的网页节点也不算
            return !hasWebAreaAncestor && isSettable(kAXSelectedTextAttribute)
        }
        return webPageHost.map { softNewlineHosts.contains($0) } ?? false
    }

    var isJavaIDE: Bool {
        guard let bundleID = bundleIdentifier else {
            return false
        }
        return javaIDEBundleIDPrefixes.contains { bundleID.hasPrefix($0) }
    }

    var isElectronCodeEditorApp: Bool {
        if let bundleID = bundleIdentifier, electronCodeEditorBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            return true
        }
        return vscodeDataFolderName(pid: pid) != nil
    }

    var isTerminalApp: Bool {
        bundleIdentifier.map { knownTerminalBundleIDs.contains($0) } ?? false
    }

    // 终端 App 里焦点在终端画面上，而不是同一窗口里的输入框（查找框、iTerm2 的 Composer、Ghostty 的命令面板）。终端画面的
    // 选中文字不能改写（iTerm2 的 AXValue 却是可写的，不能拿它判断）；没有辅助功能信息的终端（Alacritty 等）也算终端画面
    var isTerminalSurface: Bool {
        switch role {
        case kAXTextFieldRole?, "AXSearchField"?, kAXComboBoxRole?:
            return false
        case kAXTextAreaRole?:
            return !isSettable(kAXSelectedTextAttribute)
        default:
            return true
        }
    }

    // JetBrains 的文件编辑器（不是终端、控制台、单行输入框）：只有文件编辑器的名字是"Editor for <文件名>"，并且这个文件名也出现在
    // 窗口标题里（IDE 的窗口标题默认带着当前文件名）；还要是可编辑的，并且焦点不在对话框里（对话框开着时 IDE 会把写入推迟到它关掉）
    var isJetBrainsFileEditor: Bool {
        guard role == kAXTextAreaRole, isSettable(kAXValueAttribute),
              let description = copyAXAttribute(element, kAXDescriptionAttribute) as? String else {
            return false
        }
        let application = AXUIElementCreateApplication(pid)
        guard let focusedWindow = asAXElement(copyAXAttribute(application, kAXFocusedWindowAttribute)),
              let mainWindow = asAXElement(copyAXAttribute(application, kAXMainWindowAttribute)), CFEqual(focusedWindow, mainWindow),
              let title = copyAXAttribute(focusedWindow, kAXTitleAttribute) as? String else {
            return false
        }
        let fileNames = description.split(whereSeparator: { $0 == " " || $0 == ":" || $0 == "\"" }).map(String.init)
            .filter { $0.contains(".") && $0.count > 2 }
        return fileNames.contains { title.contains($0) }
    }

    // JetBrains：焦点在编辑器里还是在终端工具窗口里。从父节点开始往上找到窗口为止，途中有容器的名字就是"终端"（各种语言，
    // 或者 "Terminal: Local" 这样的工具窗口标题）就是终端；不看焦点控件自己（编辑器的名字是 "Editor for terminal.py" 这样带文件名的）。
    // 中途读不到（超时、层级太深）时不确定
    fileprivate var ideFocusPlace: IDEFocusPlace {
        var node = asAXElement(copyAXAttribute(element, kAXParentAttribute))
        for _ in 0..<30 {
            guard let current = node, !axBudgetExhausted else {
                return .unknown
            }
            let role = copyAXAttribute(current, kAXRoleAttribute) as? String
            if role == kAXWindowRole {
                return .editor
            }
            if role != kAXTextAreaRole {
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    guard let label = (copyAXAttribute(current, attribute) as? String)?.lowercased() else {
                        continue
                    }
                    if ideTerminalLabels.contains(where: { label == $0 || label.hasPrefix($0 + ":") || label.hasPrefix($0 + " tool window") }) {
                        return .terminal
                    }
                }
            }
            node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
        }
        return .unknown
    }

    // 可编辑的文字控件（⌘X 删除选中内容、模拟键入的前提）：只读的文本视图、Emacs/Vim 这类模态编辑器里键入的字符会被当成命令
    var isEditableTextControl: Bool {
        guard !isSecureTextField, let role, axWritableRoles.contains(role), !isTerminalApp else {
            return false
        }
        return isSettable(kAXSelectedTextAttribute) || isSettable(kAXValueAttribute)
    }

    // Firefox 的 <input>/<textarea>（不是 contenteditable）：单行输入框，或者没有子节点、只有一个文字节点的多行输入区。
    // contenteditable 的子节点是段落、分组
    var isGeckoTextControl: Bool {
        guard let role else {
            return false
        }
        if role == kAXTextFieldRole || role == kAXComboBoxRole {
            return true
        }
        guard role == kAXTextAreaRole, let children = copyAXAttribute(element, kAXChildrenAttribute) as? [AnyObject] else {
            return false
        }
        return children.count <= 1 && children.allSatisfy { child in
            asAXElement(child).flatMap { copyAXAttribute($0, kAXRoleAttribute) as? String } == kAXStaticTextRole
        }
    }

    // 输入法正在组字（有未上屏的拼音）。AppKit、WebKit 提供 AXTextInputMarkedRange，Chromium 没有（这时当作没有）
    var hasMarkedText: Bool {
        guard let value = copyAXAttribute(element, "AXTextInputMarkedRange"), CFGetTypeID(value) == AXValueGetTypeID() else {
            return false
        }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
            return false
        }
        guard range.length > 0 else {
            return false
        }
        // 光标后面的灰色"预测"文字（macOS 14 起）不算
        let caret = selectedRange.map { $0.location + $0.length } ?? Int.max
        return range.location < caret
    }

    // 选中了不止一段（⌘-拖选出的多段、多光标）：选中文字只给第一段，按一次退格却会把每一段都删掉
    var hasMultipleSelections: Bool {
        (copyAXAttribute(element, "AXSelectedTextRanges") as? [Any]).map { $0.count > 1 } ?? false
    }

    // 选了多段时按位置顺序读出每一段（和原生文本视图自己的"拷贝"一样连起来）；有一段读不出来就返回 nil
    var multipleSelectionText: String? {
        guard let values = copyAXAttribute(element, "AXSelectedTextRanges") as? [AnyObject], values.count > 1 else {
            return nil
        }
        var ranges: [CFRange] = []
        for value in values {
            guard CFGetTypeID(value) == AXValueGetTypeID() else {
                return nil
            }
            var range = CFRange()
            guard AXValueGetValue(value as! AXValue, .cfRange, &range) else {
                return nil
            }
            ranges.append(range)
        }
        var pieces: [String] = []
        for var range in ranges.sorted(by: { $0.location < $1.location }) where range.length > 0 {
            guard let rangeValue = AXValueCreate(.cfRange, &range),
                  let piece = copyAXParameterizedAttribute(element, "AXStringForRange", rangeValue) as? String else {
                return nil
            }
            pieces.append(piece)
        }
        guard !pieces.isEmpty else {
            return nil
        }
        // 和文本视图自己的"拷贝"一样：各段之间补一个段落分隔，已经以换行结尾的段不补
        var result = ""
        for (index, piece) in pieces.enumerated() {
            result += piece
            if index < pieces.count - 1, !(piece.hasSuffix("\n") || piece.hasSuffix("\r") || piece.hasSuffix("\u{2029}")) {
                result += "\n"
            }
        }
        return result
    }

    // 焦点所在窗口的标题（终端用它判断正在运行的程序）；读不到为 nil
    var focusedWindowTitle: String? {
        guard let window = asAXElement(copyAXAttribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)) else {
            return nil
        }
        return copyAXAttribute(window, kAXTitleAttribute) as? String
    }

    // 终端前台正在运行什么：以进程树为准（每个标签页的前台进程组里只有 shell，或者只有在等密码的 sudo 这类程序，才算在提示符前）。
    // 窗口标题只在别的标签页运行着程序时，用来确认当前标签页（Terminal、iTerm2 的标题显示它的前台程序）在提示符前。
    // 读不到、认不出都按"别的程序"处理
    fileprivate var terminalForeground: TerminalForeground {
        guard let groups = terminalForegroundGroups(pid: pid, bundleID: bundleIdentifier), !groups.isEmpty else {
            return .other(nil)
        }
        func isPrompt(_ group: [ForegroundProcess]) -> Bool {
            !group.isEmpty && group.allSatisfy(isAtPrompt)
        }
        // 这些组里的 shell；有一组只是在等密码（sudo）时返回空：那个标签页不能多行粘贴，而且不知道焦点在不在它上面
        func shells(in groups: [[ForegroundProcess]]) -> [ForegroundProcess] {
            var shells: [ForegroundProcess] = []
            for group in groups {
                let groupShells = group.filter { !terminalPasswordPrograms.contains($0.name) }
                guard groupShells.count == group.count else {
                    return []
                }
                shells += groupShells
            }
            return shells
        }
        let promptGroups = groups.filter(isPrompt)
        if promptGroups.count == groups.count {
            return .prompt(shells: shells(in: groups))
        }
        let title = focusedWindowTitle
        // 别的标签页在运行程序：看标题里单独成段的当前程序名，并且它正好是某个停在提示符前的标签页里的 shell，才算当前标签页在提示符前。
        // Terminal 在提示符前显示的是登录 shell 的 "-zsh"（"目录 — -zsh — 80×24"），要求带上这个 "-"，免得把叫 zsh 的目录名当成程序；
        // iTerm2 显示 "zsh" 或 "Default (zsh)"
        if let title, let bundleID = bundleIdentifier, jobTitleTerminalBundleIDs.contains(bundleID) {
            let components = title.components(separatedBy: CharacterSet(charactersIn: "—()"))
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let requiresLoginDash = bundleID == "com.apple.Terminal"
            let named = Set(components.compactMap { component -> String? in
                if component.hasPrefix("-") {
                    return String(component.dropFirst())
                }
                return requiresLoginDash ? nil : component
            })
            let matching = promptGroups.filter { group in group.contains { named.contains($0.name) } }
            if !matching.isEmpty {
                return .prompt(shells: shells(in: matching))
            }
        }
        let other = groups.first { !isPrompt($0) }.flatMap(programName)
        return .other(other)
    }

    // 终端里拿着焦点的标签页正在运行 tmux 的旁证（见 typeIntoTerminalByKeys）：Terminal、iTerm2 看窗口标题里有没有单独的 "tmux"；
    // 别的终端看不出标签页，只在 App 只开着一个窗口时才算
    var focusedSurfaceShowsTmux: Bool {
        if let bundleID = bundleIdentifier, jobTitleTerminalBundleIDs.contains(bundleID) {
            guard let title = focusedWindowTitle else {
                return false
            }
            return title.components(separatedBy: CharacterSet(charactersIn: "—()"))
                .contains { $0.trimmingCharacters(in: .whitespaces).lowercased().split(separator: " ").first == "tmux" }
        }
        let windows = (copyAXAttribute(AXUIElementCreateApplication(pid), kAXWindowsAttribute) as? [AnyObject]) ?? []
        return windows.count == 1
    }

    // 确定不是在复制文字：文件管理器里的文件列表、没有选中文字的图片。只对这些放行原生 ⌘C/⌘X——其余情况（列表、大纲里复制出来的
    // 往往也是文字，文件管理器里的文本预览、内置终端，图片上的实况文本，Accessibility 读不出来、判断不了的）一律当作可能是文字
    // 放行之后复制出来的却是文字的地方（见 GlobalMode.noteNonTextPassThrough）记在 misjudgedNonTextContexts 里，以后不再放行
    var isKnownNonTextContext: Bool {
        guard let role else {
            return false
        }
        if let bundleID = bundleIdentifier, Defaults[.misjudgedNonTextContexts].contains(Self.contextKey(bundleID: bundleID, role: role)) {
            return false
        }
        if let bundleID = bundleIdentifier, fileManagerBundleIDs.contains(bundleID) {
            if [kAXOutlineRole, kAXListRole, kAXBrowserRole, kAXTableRole, kAXRowRole].contains(role) {
                return true
            }
            // 分组、滚动区域：可能是图标视图，也可能是 Quick Look、预览栏里的文本预览（底下有文本区域、网页内容或选中的文字）。
            // 看不全（Accessibility 出错、时间用完）就当作可能是文字
            return (role == kAXGroupRole || role == kAXScrollAreaRole) && axSubtreeHasText(element, depth: 3, selectedOnly: false) == false
        }
        // 图片上的实况文本：选中的文字在它的子元素上
        return role == kAXImageRole && hasSelection != true && axSubtreeHasText(element, depth: 2, selectedOnly: true) == false
    }

    static func contextKey(bundleID: String, role: String) -> String {
        "\(bundleID)|\(role)"
    }

    // 有没有选中内容：true 有、false 确定没有、nil 判断不了
    var hasSelection: Bool? {
        if let range = selectedRange {
            return range.length > 0
        }
        if let markerRange = copyAXAttribute(element, "AXSelectedTextMarkerRange"),
           let length = copyAXParameterizedAttribute(element, "AXLengthForTextMarkerRange", markerRange) as? NSNumber {
            return length.intValue > 0
        }
        return nil
    }

    // 焦点是否仍在这个控件上（同一个进程里的同一个元素）
    var isStillFocused: Bool {
        guard let current = focusedTarget() else {
            return false
        }
        return current.pid == pid && CFEqual(current.element, element)
    }
}

func copyAXParameterizedAttribute(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> CFTypeRef? {
    guard !axBudgetExhausted else {
        return nil
    }
    var value: CFTypeRef?
    let result = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value)
    PasteboardQuarantine.shared.checkpoint()
    guard result == .success else {
        return nil
    }
    return value
}

// 同上，读不到时说清是"没有"还是"不知道"（出错、App 没响应、时间用完，或者根本不支持这项查询）
func readAXParameterizedAttribute(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> AXAttributeRead {
    guard !axBudgetExhausted else {
        return .failed
    }
    var value: CFTypeRef?
    let result = AXUIElementCopyParameterizedAttributeValue(element, attribute as CFString, parameter, &value)
    PasteboardQuarantine.shared.checkpoint()
    switch result {
    case .success:
        return value.map { .value($0) } ?? .none
    case .noValue:
        return .none
    default:
        return .failed
    }
}

// 单行输入框粘贴时浏览器会把换行变成空格，这里照做（模拟键入、改写 AXValue 时用）
func normalizedForSingleLine(_ text: String) -> String {
    var result = text
    while let last = result.unicodeScalars.last, last == "\n" || last == "\r" {
        result.unicodeScalars.removeLast()
    }
    return result
        .replacingOccurrences(of: "\r\n", with: " ")
        .replacingOccurrences(of: "\r", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
}

// 4–8 位纯数字（验证码）：分格的验证码输入框是按逐字键入设计的（每输一位跳到下一格），整体写入只会塞进第一格
private func looksLikeOneTimeCode(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return (4...8).contains(trimmed.count) && trimmed.allSatisfy { $0.isASCII && $0.isNumber }
}

// MARK: - 0 暴露粘贴

enum ZeroExposurePasteResult {
    // 已经写进去了（或者写入请求已经发出、结果不确定——这时也不能再走别的路，免得粘贴两遍）
    case inserted
    // 安排了模拟键入，稍后（用户松开修饰键后）完成
    case typing
    // 这里没有 0 暴露的办法（或者用了会改变粘贴的效果）
    case unavailable(UnavailableReason)
}

// 没有 0 暴露办法的原因，用来告诉用户怎么办
enum UnavailableReason: Error {
    case noRoute
    // 只能一行一行地键入（终端、代码编辑器、认不出 ⇧↩ 是不是换行的编辑器）
    case multiLine
    // 当前是拼音等输入法，键入的字符会被拿去组字
    case inputMethod
    // 正运行着（或开着）把按键当命令的程序：终端里的 vim、less，编辑器的 Vim 模式；nil 表示看不出终端里在运行什么
    case modalProgram(String?)
    // 编辑器、shell 会改掉其中的某些字符（自动补全括号引号、历史展开）
    case unsafeCharacters
    // 虚拟机、远程桌面：有的字符没法用一个键（加 ⇧）直接打出来
    case untypeableCharacters
    // 大写锁定开着：虚拟机里打出来的大小写会反
    case capsLock
    // shell 可能开着 vi 键位，命令模式里粘贴进去的字母是命令
    case viMode
    // 打开了 "Don't Type When Keystrokes Are Watched"，而这些程序看得到按键（键入的文字它们都看得到）
    case keystrokesWatched([String])
    // 从网页浏览器复制的文字要粘贴进"终端"：等用户再按一次 ⌘V 确认（见 BrowserToTerminalGuard）
    case needsConfirmation(source: String)
    // 要退回剪贴板方式，而这些 App（虚拟机、远程桌面、模拟器）会把剪贴板同步到另一台电脑上、留在那里：等用户再粘贴一次确认
    // （见 RemoteClipboardGuard）
    case remoteClipboard([String])
    // tmux 设了在粘贴缓冲区时运行的钩子（见 TmuxPaste）
    case tmuxHooks([String])
    // 机密内容要粘贴进地址栏、搜索框：等用户再粘贴一次确认（见 ConcealedDestinationGuard）
    case concealedIntoSearch

    // 允许剪贴板回退时可不可以退回剪贴板：用户为了不让别的程序看到才拒绝键入的，剪贴板上它们（和所有 App）一样看得到
    var allowsClipboardFallback: Bool {
        switch self {
        case .keystrokesWatched, .needsConfirmation, .remoteClipboard, .concealedIntoSearch:
            return false
        default:
            return true
        }
    }
}

// 用户打开了 "Don't Type When Keystrokes Are Watched"、并且现在有第三方程序看得到 Copi 要往 pid 键入的按键时，返回它们的名字。
// location：键入的事件发在哪一层（文字键入发在"已标注"层，虚拟机里按真实的键发在会话层）。
// Secure Input 开着时（密码框）系统不把按键交给任何 event tap，不算
// fresh：不用缓存的 tap 清单（键入途中逐块复查时，最多 20 毫秒前的）
func keystrokeWatchersBlockingTyping(into pid: pid_t, postedAt location: CGEventTapLocation = .cgAnnotatedSessionEventTap,
                                     fresh: Bool = false) -> [String]? {
    guard Defaults[.refuseTypingWhenWatched], !IsSecureEventInputEnabled() else {
        return nil
    }
    // 打开 "Type Privately" 时文字直接发给目标 App：只有专门盯着它的 tap 看得到
    let direct = Defaults[.typePrivately] && location == .cgAnnotatedSessionEventTap
    let watchers = KeystrokeObservers.thirdPartyWatchers(postedAt: location, targetPID: pid, directToTarget: direct, maxAge: fresh ? 0.02 : 1)
    return watchers.isEmpty ? nil : watchers
}

// 在主线程、withAXBudget 之内调用。target 为 nil 表示拿不到焦点控件的信息（例如还没开启无障碍树的 Electron App）：
// 这时不知道焦点是不是输入框，不能贸然模拟键入（在 Finder、图片编辑器、游戏里打字会触发各种快捷操作）。
// keyTime：用户按下粘贴快捷键（或点 Action Bar）的时刻，用来判断之后用户有没有接着操作（见 KeystrokeTyper）。
// concealed：这段文字是不是机密（密码管理器的复制）；nil 时看安全剪贴板
func zeroExposurePaste(_ text: String, into target: FocusedTarget?, keyTime: Date, concealed: Bool? = nil) -> ZeroExposurePasteResult {
    dispatchPrecondition(condition: .onQueue(.main))
    // 允许剪贴板回退时也先走不经过剪贴板的路线：只有这里一条路都没有（返回 .unavailable）时，调用方才退回剪贴板
    guard let target else {
        guard let passwordField = revealPasswordField(around: nil) else {
            // （读不到焦点控件的虚拟机、远程桌面：退回剪贴板之前由 remoteClipboardConfirmationBeforeFallback 先提醒）
            return .unavailable(.noRoute)
        }
        return typePassword(text, into: passwordField, keyTime: keyTime)
    }
    // 机密内容要粘贴进地址栏、搜索框：先提醒
    if ConcealedDestinationGuard.needsConfirmation(text, concealed: concealed ?? (SecureClipboard.shared.text == text && SecureClipboard.shared.isConcealed),
                                                   into: target) {
        return .unavailable(.concealedIntoSearch)
    }
    let bundleID = target.bundleIdentifier ?? ""
    // 虚拟机、远程桌面的画面（不是它们自己界面上的输入框）：只认键位，按真实的按键逐个输入。它们自己的列表、按钮这类界面
    // （虚拟机列表、连接列表）、读不出焦点是什么的时候不键入
    if remoteDesktopBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }), !(target.role.map(axWritableRoles.contains) ?? false) {
        var result = ZeroExposurePasteResult.unavailable(.noRoute)
        if Defaults[.typeIntoVirtualMachines], let role = target.role, !remoteDesktopHostUIRoles.contains(role) {
            result = typeIntoRemoteDesktop(text, target: target, keyTime: keyTime)
        }
        // 要退回剪贴板方式时：文字会经过它们的剪贴板共享进到那台电脑的剪贴板上（还可能进它的剪贴板历史，例如 Windows 的 Win+V），
        // 粘贴完也一直留在那里，Copi 撤不下来。退回之前由 remoteClipboardConfirmationBeforeFallback 先提醒
        return result
    }
    // 密码框：模拟键入。浏览器在密码框里会强制使用 ASCII 输入源，Secure Input 期间系统也不把键盘事件交给任何监听者，
    // 这反而是最不会被看到的情形
    if target.isSecureTextField {
        return typePassword(text, into: target, keyTime: keyTime)
    }
    // VS Code 系编辑器装了 Copi Bridge：先问清是哪个窗口、焦点在它的什么地方。编辑器、小输入框里用编辑器自己的 paste 命令；
    // 终端里由扩展把文字送进去；别的地方（快速打开、查找框……）照常往下走
    if target.isElectronCodeEditorApp, EditorBridge.shared.isConnected(appPID: target.pid),
       let focus = EditorBridge.shared.locateFocus(appPID: target.pid, timeout: min(0.3, axBudgetRemaining ?? 0.3)) {
        switch focus.place {
        case .editor, .simpleEditor:
            return pasteThroughEditorBridge(text, focus: focus, target: target)
        case .terminal:
            return pasteIntoEditorTerminal(text, focus: focus, target: target, keyTime: keyTime)
        case .other:
            break
        }
    }
    // 终端、JetBrains：只键入不会改变效果的文字（终端在 shell 提示符前，多行用 bracketed paste；JetBrains 文件编辑器直接写入）
    if target.isTerminalApp {
        return typeIntoTerminal(text, target: target, keyTime: keyTime)
    }
    if target.isJavaIDE {
        // 文件编辑器：Accessibility 写入（IDE 把它当作一次可撤销的编辑执行），什么文字都能原样插入
        if target.isJetBrainsFileEditor {
            return jetBrainsWrite(text, into: target,
                                  aboveCurrentLine: SecureClipboard.shared.text == text && SecureClipboard.shared.metadata?.pasteOnNewLine == true)
        }
        switch target.ideFocusPlace {
        case .editor:
            return typeIntoCodeEditor(text, target: target, keyTime: keyTime)
        case .terminal:
            return typeIntoIDETerminal(text, target: target, keyTime: keyTime)
        case .unknown:
            return .unavailable(.noRoute)
        }
    }
    let role = target.role
    let names = target.attributeNames
    let engine = target.webEngine(attributeNames: names)
    // 焦点是整个网页、一个分组这类说不清的节点、并且认不出网页引擎（Chrome 的无障碍树还没建好时就是这样），而这个 App 正开着
    // Secure Input：焦点多半在它的密码框里，请它建好无障碍树再确认
    if engine == nil, role == nil || role == "AXWebArea" || role == kAXGroupRole || role == kAXWindowRole,
       let passwordField = revealPasswordField(around: target) {
        return typePassword(text, into: passwordField, keyTime: keyTime)
    }
    guard let engine else {
        if target.isElectronCodeEditorApp {
            return .unavailable(.noRoute)
        }
        // 读不到属性名（目标 App 卡住、超时）而其实是网页：认不出是什么编辑器，按代码编辑器的规则只键入安全的单行文字
        if target.hasWebAreaAncestor {
            return typeIntoCodeEditor(text, target: target, keyTime: keyTime)
        }
        // 原生控件
        switch writeSelectedText(text, to: target) {
        case .inserted, .uncertain:
            return .inserted
        case .notApplicable:
            return typeIfPossible(text, into: target, newlines: newlinePolicy(for: target, role: role, engine: nil), keyTime: keyTime)
        }
    }
    let editorKind = target.webEditorKind(engine: engine)
    switch editorKind {
    case .code?:
        return typeIntoCodeEditor(text, target: target, keyTime: keyTime)
    case .vimCode?:
        return .unavailable(.modalProgram("Vim"))
    case .terminal?:
        return .unavailable(.modalProgram(nil))
    case .wordProcessor?:
        return .unavailable(.noRoute)
    case .spreadsheet?:
        // 单元格里键入（只有找到了单元格编辑框的 class 才会到这里）；换行用 ⌘↩（单元格进入编辑状态之后才行，所以开头的换行去掉）
        var cellText = KeystrokeTyper.normalizedNewlines(text)
        while cellText.hasPrefix("\n") {
            cellText.removeFirst()
        }
        while cellText.hasSuffix("\n") {
            cellText.removeLast()
        }
        return typeIfPossible(cellText, into: target, newlines: .commandReturn, keyTime: keyTime)
    case .unknown?, nil:
        break
    }
    let isAtomic = target.isAtomicSingleLineField || (role == kAXTextAreaRole && target.childCount == 0)
    if looksLikeOneTimeCode(text), target.isAtomicSingleLineField {
        // 逐位键入（每位一个按键，分格验证码组件会自动跳到下一格）
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return typeIfPossible(digits, into: target, newlines: .joinWithSpaces, keyTime: keyTime, perCharacter: true)
    }
    switch engine {
    case .webKit:
        switch webKitTextOperation(text, into: target) {
        case .inserted, .uncertain:
            return .inserted
        case .notApplicable:
            break
        }
    case .chromium:
        if isAtomic {
            switch spliceValue(text, into: target) {
            case .inserted, .uncertain:
                return .inserted
            case .notApplicable:
                break
            }
        } else if target.parameterizedAttributeNames.contains("AXTextOperation") {
            // Chromium 自己也实现了 AXTextOperation，但目前默认关闭；哪天打开了就自动用上（富文本编辑器也能 0 暴露粘贴）
            switch webKitTextOperation(text, into: target) {
            case .inserted, .uncertain:
                return .inserted
            case .notApplicable:
                break
            }
        }
    case .gecko:
        // Firefox 的 <input>/<textarea>：整体改写值（异步生效，写完确认）。富文本编辑区不行，只能键入
        if target.isGeckoTextControl {
            switch spliceValue(text, into: target, byteLimit: geckoValueByteLimit) {
            case .inserted, .uncertain:
                return .inserted
            case .notApplicable:
                break
            }
        }
    }
    if target.isAtomicSingleLineField {
        return typeIfPossible(text, into: target, newlines: .joinWithSpaces, keyTime: keyTime)
    }
    // 认不出是什么编辑器（Firefox、读不到 class）：可能是代码编辑器或电子表格。可编辑的文档区域（contenteditable，代码编辑器多半是这种）
    // 不键入；单独的 <textarea> 按代码编辑器的规则只键入安全的单行文字
    if case .unknown? = editorKind {
        guard target.childCount == 0 else {
            return .unavailable(.noRoute)
        }
        return typeIntoCodeEditor(text, target: target, keyTime: keyTime)
    }
    // 富文本编辑器（Slack、Notion、Gmail……）、多行输入框：用键入（只在 ⇧↩ 确定是换行的地方键入多行文字）
    if role == kAXTextAreaRole || target.isSettable(kAXValueAttribute) {
        return typeIfPossible(text, into: target, newlines: newlinePolicy(for: target, role: role, engine: engine), keyTime: keyTime)
    }
    return .unavailable(.noRoute)
}

private func newlinePolicy(for target: FocusedTarget, role: String?, engine: WebEngine?) -> NewlinePolicy {
    switch role {
    case kAXTextAreaRole?:
        return target.shiftReturnIsSoftNewline(engine: engine) ? .shiftReturn : .refuse
    case kAXTextFieldRole?, kAXComboBoxRole?, "AXSearchField"?:
        return .joinWithSpaces
    default:
        return .refuse
    }
}

// 通过桥接扩展用编辑器自己的 paste 命令粘贴。文字是从这个编辑器复制来的话，把整行复制、多光标各段的信息一起交回去
private func pasteThroughEditorBridge(_ text: String, focus: EditorBridge.Focus, target: FocusedTarget) -> ZeroExposurePasteResult {
    var payload: [String: Any] = ["cmd": "paste", "text": text, "target": focus.place.rawValue]
    // 编辑器附带的复制信息只属于安全剪贴板里的那段文字（粘贴的可能是刚撤下来的临时文字）
    if SecureClipboard.shared.text == text, let metadata = SecureClipboard.shared.metadata {
        payload["isFromEmptySelection"] = metadata.pasteOnNewLine
        if let pieces = metadata.multicursorText {
            payload["multicursorText"] = pieces
        }
    }
    // 等回音也算在这次处理的时间预算里：剩下的时间太少就不发（还什么都没发，拒绝或退回别的办法都不会粘贴两遍）
    let wait = min(0.5, axBudgetRemaining ?? 0.5)
    guard wait >= 0.05 else {
        return .unavailable(.noRoute)
    }
    switch EditorBridge.shared.request(payload, to: focus, timeout: wait) {
    case .response(let response):
        guard response["ok"] as? Bool == true else {
            // 扩展没有执行（来晚了、出错了）
            return .unavailable(.noRoute)
        }
        // 只读的编辑器：编辑器自己的粘贴这时也什么都不做
        if response["result"] as? String != "unchanged" {
            notifyProtected("Pasted safely")
        }
        return .inserted
    case .timedOut:
        // 请求已经发出去了：可能稍后才执行，不能再走别的路，免得粘贴两遍
        notifyPasteUncertain(into: target)
        return .inserted
    case .notSent:
        return .unavailable(.noRoute)
    }
}

// VS Code 系编辑器的集成终端：由扩展问出终端里 shell 的进程（必须是这台 Mac 上、这个编辑器启动的进程），确认它停在提示符前，
// 再让扩展把文字一次送进终端
private func pasteIntoEditorTerminal(_ text: String, focus: EditorBridge.Focus, target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    // 远程窗口的终端跑在别的机器上，看不到里面在运行什么
    guard !focus.isRemote else {
        return .unavailable(.modalProgram(nil))
    }
    guard min(0.3, axBudgetRemaining ?? 0.3) >= 0.05,
          case .response(let info) = EditorBridge.shared.request(["cmd": "terminalProcess"], to: focus, timeout: min(0.3, axBudgetRemaining ?? 0.3)),
          info["ok"] as? Bool == true, info["remote"] == nil || info["remote"] is NSNull,
          let shellPID = (info["pid"] as? NSNumber)?.int32Value, isDescendant(shellPID, of: target.pid) else {
        return .unavailable(.modalProgram(nil))
    }
    // 看前台进程组里真正在运行的 shell（用户可能在终端里又开了一个 bash、sh）
    let group = foregroundGroup(ofProcess: shellPID)
    guard let group, !group.isEmpty, group.allSatisfy(isAtPrompt) else {
        return .unavailable(.modalProgram(group.flatMap(programName)))
    }
    let shells = group.filter { !terminalPasswordPrograms.contains($0.name) }
    // 停在 sudo 这类的密码提示：直接往终端的输入框里键入单行文字，不经过扩展进程（同一进程里的其他扩展看不到密码）
    if shells.count < group.count {
        guard let line = singleLineWithoutTrailingNewline(text) else {
            return .unavailable(.multiLine)
        }
        guard !line.isEmpty, let role = target.role, axWritableRoles.contains(role),
              KeystrokeTyper.canType(line, maxUnitsPerCharacter: typingChunkLimit(pid: target.pid)) else {
            return .unavailable(.noRoute)
        }
        guard InputSourceState.canTypeNow else {
            return .unavailable(.inputMethod)
        }
        if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
            return .unavailable(.keystrokesWatched(watchers))
        }
        KeystrokeTyper.shared.type(line, into: target, keyTime: keyTime)
        return .typing
    }
    let payload: String
    switch terminalPayload(for: text, shells: shells, atPasswordPrompt: false) {
    case .success(let value):
        payload = value
    case .failure(let reason):
        return .unavailable(reason)
    }
    let sendWait = min(0.4, axBudgetRemaining ?? 0.4)
    guard sendWait >= 0.05 else {
        return .unavailable(.noRoute)
    }
    // 用户在这期间接着打字、点了别处（可能切到了别的终端）：不再粘贴
    guard !userActedSince(keyTime) else {
        notifyCopiNotice("Copi didn't paste into \(target.applicationName) because you kept typing or clicked elsewhere. Press ⌘V again.")
        return .inserted
    }
    // 扩展只往刚才问过的那个终端里送（pid 也要对得上）：两次请求之间拿着焦点的终端换了时，它不送
    switch EditorBridge.shared.request(["cmd": "terminalSend", "text": payload, "pid": NSNumber(value: shellPID)], to: focus, timeout: sendWait) {
    case .response(let response) where response["ok"] as? Bool == true:
        notifyProtected("Pasted safely")
        return .inserted
    case .response(let response) where response["error"] as? String == "changed":
        notifyCopiNotice("Copi didn't paste into \(target.applicationName) because a different terminal became active. Press ⌘V again.")
        return .inserted
    case .timedOut:
        notifyPasteUncertain(into: target)
        return .inserted
    default:
        return .unavailable(.noRoute)
    }
}

// JetBrains 的文件编辑器：写 kAXSelectedText。IDE 在自己的事件线程上把它作为一次可撤销的编辑执行，所以写入请求返回时还没生效，
// 稍后确认（字符数对上、插入处的文字对上），确认后再把光标移到插入的文字后面（IDE 会把光标留在前面）。
// 文字里不能有 \r（IDE 会报错、什么都不插入）
// aboveCurrentLine：这是一次整行复制（没有选中内容时复制的光标所在行），和 IDE 自己一样插到当前行的上面，光标留在原来的位置
// （跟着下移一行）
private func jetBrainsWrite(_ text: String, into target: FocusedTarget, aboveCurrentLine: Bool = false) -> ZeroExposurePasteResult {
    guard let lengthBefore = target.numberOfCharacters, let selection = target.selectedRange,
          selection.location >= 0, selection.length >= 0 else {
        return .unavailable(.noRoute)
    }
    let insert = KeystrokeTyper.normalizedNewlines(text)
    guard !insert.isEmpty else {
        return .unavailable(.noRoute)
    }
    let insertedLength = (insert as NSString).length
    var location = selection.location
    var caretAfter = selection.location + insertedLength
    // 先把光标移到当前行的开头（和接下来的写入一样在 IDE 的事件线程上按顺序执行）；读不到行的范围就照常插在光标处
    if aboveCurrentLine, selection.length == 0, insert.hasSuffix("\n"),
       let line = (copyAXAttribute(target.element, kAXInsertionPointLineNumberAttribute) as? NSNumber)?.intValue,
       let value = copyAXParameterizedAttribute(target.element, "AXRangeForLine", NSNumber(value: line)),
       CFGetTypeID(value) == AXValueGetTypeID() {
        var lineRange = CFRange()
        var lineStart = CFRange()
        if AXValueGetValue(value as! AXValue, .cfRange, &lineRange), lineRange.location >= 0, lineRange.location <= selection.location {
            lineStart = CFRange(location: lineRange.location, length: 0)
            if let start = AXValueCreate(.cfRange, &lineStart),
               AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, start) == .success {
                location = lineRange.location
                caretAfter = selection.location + insertedLength
            }
        }
    }
    // 超时（IDE 一时卡住）：写入请求还在 IDE 的队列里，稍后可能照样生效——不能再退回别的办法，否则会粘贴两遍
    let written = AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, insert as CFTypeRef)
    guard written == .success || written == .cannotComplete else {
        return .unavailable(.noRoute)
    }
    confirmJetBrainsWrite(target, insert: insert, at: location, caretAfter: caretAfter,
                          expectedLength: lengthBefore - (location == selection.location ? selection.length : 0) + insertedLength,
                          writtenAt: Date(), deadline: Date().addingTimeInterval(written == .success ? 1.5 : 3))
    return .inserted
}

private func confirmJetBrainsWrite(_ target: FocusedTarget, insert: String, at location: Int, caretAfter: Int, expectedLength: Int,
                                   writtenAt: Date, deadline: Date) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
        var range = CFRange(location: location, length: (insert as NSString).length)
        let landed = target.numberOfCharacters == expectedLength
            && AXValueCreate(.cfRange, &range).flatMap { copyAXParameterizedAttribute(target.element, "AXStringForRange", $0) as? String } == insert
        guard landed else {
            if Date() < deadline {
                confirmJetBrainsWrite(target, insert: insert, at: location, caretAfter: caretAfter, expectedLength: expectedLength,
                                      writtenAt: writtenAt, deadline: deadline)
            } else {
                notifyPasteUncertain(into: target)
            }
            return
        }
        var caret = CFRange(location: caretAfter, length: 0)
        // 写入之后用户又打字、移动了光标的话不动它
        if InputActivity.lastInput < writtenAt, let caretValue = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, caretValue)
        }
        notifyProtected("Pasted safely")
    }
}

// JetBrains 的文件编辑器里剪切：选中的内容已经存进安全剪贴板，再把它写成空（IDE 把它当作一次可撤销的删除）。
// 先确认选区和其中的文字都没变；写入是异步生效的，稍后确认字符数少了这么多
func jetBrainsCut(_ target: FocusedTarget, range: CFRange, text: String) {
    var expectedRange = range
    guard let lengthBefore = target.numberOfCharacters, let selection = target.selectedRange,
          selection.location == range.location, selection.length == range.length,
          AXValueCreate(.cfRange, &expectedRange).flatMap({ copyAXParameterizedAttribute(target.element, "AXStringForRange", $0) as? String }) == text,
          AXUIElementSetAttributeValue(target.element, kAXSelectedTextAttribute as CFString, "" as CFTypeRef) == .success else {
        notifyCopiNotice("Copi copied the selection but couldn't delete it in \(target.applicationName). Delete it yourself if you meant to cut it.")
        return
    }
    let deadline = Date().addingTimeInterval(1.5)
    func confirm() {
        if target.numberOfCharacters == lengthBefore - range.length {
            notifyProtected("Cut safely")
            return
        }
        guard Date() < deadline else {
            notifyCopiNotice("Copi copied the selection, but isn't sure it was deleted from \(target.applicationName). Check before cutting again.")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: confirm)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: confirm)
}

// 虚拟机、远程桌面 App 自己的界面（不是客户机的画面）
private let remoteDesktopHostUIRoles: Set<String> = [
    kAXListRole, kAXTableRole, kAXOutlineRole, kAXRowRole, kAXCellRole, kAXButtonRole, kAXPopUpButtonRole, kAXCheckBoxRole,
    kAXMenuButtonRole, kAXRadioButtonRole, kAXTabGroupRole, kAXToolbarRole, kAXMenuItemRole, kAXMenuBarItemRole,
]

// 虚拟机、远程桌面：它们把按键事件的键位换成客户机的扫描码，不认事件里带的字符。按当前（英文）键盘布局把每个字符换成键位和 ⇧，
// 像真的按键一样逐个按下。只用单行文字（客户机里的 ↩ 会执行、提交），不超过 1000 个字符（每个键要几十毫秒）
private func typeIntoRemoteDesktop(_ text: String, target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    guard let line = singleLineWithoutTrailingNewline(text) else {
        return .unavailable(.multiLine)
    }
    guard !line.isEmpty, (line as NSString).length <= 1000 else {
        return .unavailable(.noRoute)
    }
    guard !CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift) else {
        return .unavailable(.capsLock)
    }
    guard let strokes = KeyPressMap.strokes(for: line) else {
        return .unavailable(.untypeableCharacters)
    }
    guard InputSourceState.canTypeNow else {
        return .unavailable(.inputMethod)
    }
    if let watchers = keystrokeWatchersBlockingTyping(into: target.pid, postedAt: .cgSessionEventTap) {
        return .unavailable(.keystrokesWatched(watchers))
    }
    KeystrokeTyper.shared.pressKeys(strokes, into: target, keyTime: keyTime)
    return .typing
}

// 一次真实的按键：键位、要不要按着 ⇧
struct KeyStroke {
    let keyCode: CGKeyCode
    let shift: Bool
    let character: String
}

// 字符 → 当前键盘布局上的键位（只用不带修饰键和带 ⇧ 两种；⌥ 在客户机里是 Alt/AltGr，死键要组合，都不用）
enum KeyPressMap {
    // 主线程（TIS）。有字符打不出来时返回 nil
    static func strokes(for text: String) -> [KeyStroke]? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataPointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        var layoutID = ""
        if let idPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            layoutID = Unmanaged<CFString>.fromOpaque(idPointer).takeUnretainedValue() as String
        }
        // 客户机的键盘布局看不到：只有 Mac 用的是美式布局时才放心打标点，别的布局只打字母、数字（键位在各种布局里一样）
        let usLayout = layoutID == "com.apple.keylayout.US" || layoutID == "com.apple.keylayout.ABC"
        let layoutData = Unmanaged<CFData>.fromOpaque(dataPointer).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }
        let map = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            buildMap(layout)
        }
        var strokes: [KeyStroke] = []
        for character in text {
            if character == " " {
                strokes.append(KeyStroke(keyCode: CGKeyCode(kVK_Space), shift: false, character: " "))
                continue
            }
            let isPlainAlphanumeric = character.isASCII && (character.isLetter || character.isNumber)
            guard let key = map[character], usLayout || isPlainAlphanumeric else {
                return nil
            }
            strokes.append(KeyStroke(keyCode: key.keyCode, shift: key.shift, character: String(character)))
        }
        return strokes
    }

    private static func buildMap(_ layout: UnsafePointer<UCKeyboardLayout>) -> [Character: (keyCode: CGKeyCode, shift: Bool)] {
        let keyboardType = UInt32(LMGetKbdType())
        let shiftState = UInt32((shiftKey >> 8) & 0xFF)
        // 主键区（字母、数字、标点）；↩、⇥、空格、删除、esc、数字小键盘除外
        let excluded: Set<Int> = [kVK_Return, kVK_Tab, kVK_Space, kVK_Delete, kVK_Escape]
        var map: [Character: (keyCode: CGKeyCode, shift: Bool)] = [:]
        for modifierState in [UInt32(0), shiftState] {
            for keyCode in 0...0x32 where !excluded.contains(keyCode) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), modifierState, keyboardType,
                                            OptionBits(0), &deadKeyState, 4, &length, &chars)
                // 死键（要和下一个键组合）不用
                guard status == noErr, deadKeyState == 0, length == 1, chars[0] >= 0x20, chars[0] != 0x7F,
                      let scalar = Unicode.Scalar(chars[0]) else {
                    continue
                }
                let character = Character(scalar)
                if map[character] == nil {
                    map[character] = (CGKeyCode(keyCode), modifierState != 0)
                }
            }
        }
        return map
    }
}

// 换行怎么处理
enum NewlinePolicy {
    // 单行输入框：像浏览器粘贴时那样把换行变成空格（不能发送 ↩/⇧↩：网页 <input> 里不管带不带 ⇧ 都会提交表单）
    case joinWithSpaces
    // 多行输入框、富文本编辑器：换行用 ⇧↩
    case shiftReturn
    // Google Sheets 的单元格：换行用 ⌘↩
    case commandReturn
    // 不知道 ⇧↩ 在这里是不是换行：有换行就不键入
    case refuse
}

// 只在焦点确实是输入框时模拟键入；当前是拼音等输入法时不键入（字符会被输入法当成拼音组字，
// 而 Copi 在后台切换输入法又不可靠：切回中日韩输入法时菜单栏变了、实际输入却没变）
// 还要求控件可编辑：只读的文本视图、Emacs/Vim 这类模态编辑器里，键入的字符会被当成命令执行。
// 多行文字只在默认（不回退剪贴板）时用 ⇧↩ 键入。
private func typeIfPossible(_ text: String, into target: FocusedTarget, newlines: NewlinePolicy, keyTime: Date, perCharacter: Bool = false) -> ZeroExposurePasteResult {
    guard target.isSecureTextField || target.isEditableTextControl else {
        return .unavailable(.noRoute)
    }
    var policy = newlines
    if case .shiftReturn = policy, multiLineTypingDenyBundleIDPrefixes.contains(where: { (target.bundleIdentifier ?? "").hasPrefix($0) }) {
        policy = .refuse
    }
    let typed: String
    let allowNewlines: Bool
    switch policy {
    case .joinWithSpaces:
        typed = normalizedForSingleLine(text)
        allowNewlines = false
    case .shiftReturn, .commandReturn:
        typed = KeystrokeTyper.normalizedNewlines(text)
        allowNewlines = true
    case .refuse:
        typed = KeystrokeTyper.normalizedNewlines(text)
        allowNewlines = false
    }
    if !allowNewlines, typed.unicodeScalars.contains("\n") {
        return .unavailable(.multiLine)
    }
    guard KeystrokeTyper.canType(typed, allowNewlines: allowNewlines, maxUnitsPerCharacter: typingChunkLimit(pid: target.pid)) else {
        return .unavailable(.noRoute)
    }
    // 密码框：浏览器、系统在焦点进入密码框之后才（异步地）强制切到英文输入源，留给键入前的检查去等
    guard target.isSecureTextField || InputSourceState.canTypeNow else {
        return .unavailable(.inputMethod)
    }
    if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
        return .unavailable(.keystrokesWatched(watchers))
    }
    let newlineKey: KeystrokeTyper.NewlineKey
    if case .commandReturn = policy {
        newlineKey = .commandReturn
    } else {
        newlineKey = .shiftReturn
    }
    KeystrokeTyper.shared.type(typed, into: target, keyTime: keyTime, perCharacter: perCharacter, newlineKey: newlineKey)
    return .typing
}

// 密码框：键入单行文字；看起来是验证码时逐位键入（分格的验证码框也可能是密码框，每格只收一位）
private func typePassword(_ text: String, into target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    if looksLikeOneTimeCode(text) {
        let digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return typeIfPossible(digits, into: target, newlines: .joinWithSpaces, keyTime: keyTime, perCharacter: true)
    }
    return typeIfPossible(text, into: target, newlines: .joinWithSpaces, keyTime: keyTime)
}

// 去掉末尾的换行（终端里真正的粘贴也不会因为末尾的换行而执行命令，键入时去掉它才等价）；中间还有换行就返回 nil
private func singleLineWithoutTrailingNewline(_ text: String) -> String? {
    var line = text
    while let last = line.unicodeScalars.last, last == "\n" || last == "\r" {
        line.unicodeScalars.removeLast()
    }
    return line.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } ? nil : line
}

// 终端：焦点在终端画面上时，iTerm2、Ghostty 允许 Copi 用它们的脚本接口、WezTerm、kitty（打开了远程控制）的话，把文字一次交给终端
// （见 TerminalScript）；否则模拟键入。
// 焦点在同一窗口里的输入框（查找框、iTerm2 的 Composer、Ghostty 的命令面板）时，只往那个输入框里键入单行文字
private func typeIntoTerminal(_ text: String, target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    if let source = BrowserToTerminalGuard.unconfirmedSource(of: text, into: target) {
        return .unavailable(.needsConfirmation(source: source))
    }
    guard target.isTerminalSurface else {
        guard let line = singleLineWithoutTrailingNewline(text) else {
            return .unavailable(.multiLine)
        }
        guard !target.isSecureTextField, KeystrokeTyper.canType(line, maxUnitsPerCharacter: typingChunkLimit(pid: target.pid)) else {
            return .unavailable(.noRoute)
        }
        guard InputSourceState.canTypeNow else {
            return .unavailable(.inputMethod)
        }
        if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
            return .unavailable(.keystrokesWatched(watchers))
        }
        KeystrokeTyper.shared.type(line, into: target, keyTime: keyTime)
        return .typing
    }
    let pasted = TerminalScript.pasteIfPermitted(text, into: target, keyTime: keyTime) {
        // 脚本接口没能送出去（终端版本太旧、关掉了脚本、权限被收回）：照旧模拟键入
        if case .unavailable(let reason) = typeIntoTerminalByKeys(text, target: target, keyTime: keyTime) {
            refuseOrFallBack(reason, text: text, target: target, keyTime: keyTime)
        }
    }
    return pasted ? .typing : typeIntoTerminalByKeys(text, target: target, keyTime: keyTime)
}

// 逐键键入 bracketed paste 时，按键（ESC、文字、↩）原样变成对应字节送给 shell 的终端。Warp 的输入框不是 shell，
// Hyper、Tabby 这类网页终端会拦下 ESC
private let keystrokeBracketedPasteTerminalBundleIDs: Set<String> = [
    "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "com.github.wez.wezterm", "org.alacritty",
]

// 终端里模拟键入：只在 shell 提示符前键入。单行文字直接键入（去掉末尾的换行）；shell 可能开着 vi 键位时也包上 bracketed paste 的标记
// （命令模式里原样键入的字母是命令）。多行文字只在 shell 的行编辑器正在读、并且认得 bracketed paste 时，包成和真正粘贴一样的
// ESC[200~ … ESC[201~ 键入——shell 收到后整段插入编辑缓冲区、不执行（单独键入换行等于按回车执行命令）
private func typeIntoTerminalByKeys(_ text: String, target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    let shells: [ForegroundProcess]
    switch target.terminalForeground {
    case .prompt(let found):
        shells = found
    case .other(let program):
        // 前台是 tmux（终端里所有窗口合计只有这一个标签页、没有分屏时才认得出是它）：交给 tmux 粘贴进它当前的 pane（见 TmuxPaste）。
        // WezTerm 走到这里时是它自己的接口特意没接（复制模式、搜索框、启动器开着，粘贴应该落在那里），不能绕过去交给 tmux；
        // Alacritty 的搜索、提示模式也画在终端画面里，看不出来开着
        // 只有一个 tmux 也不能说明焦点就在它那里（焦点所在的标签页可能已经结束、没有前台进程了）：Terminal、iTerm2 的窗口标题
        // 显示当前标签页的程序，要在标题里看到 tmux；别的终端要求只开着一个窗口
        if program == "tmux", ![TerminalScript.wezterm.bundleIdentifier, "org.alacritty"].contains(target.bundleIdentifier ?? ""),
           target.focusedSurfaceShowsTmux,
           let client = TmuxPaste.soleClient(in: terminalForegroundGroups(of: target)) {
            TmuxPaste.pasteInBackground(text, client: client, target: target, keyTime: keyTime)
            return .typing
        }
        return .unavailable(.modalProgram(program))
    }
    let limit = typingChunkLimit(pid: target.pid)
    let canBracket = { () -> Bool in
        guard let bundleID = target.bundleIdentifier, keystrokeBracketedPasteTerminalBundleIDs.contains(bundleID), !shells.isEmpty else {
            return false
        }
        return shells.allSatisfy { shellAcceptsBracketedPaste(pid: $0.pid, delivery: .keystrokes) && lineEditorIsReading(tty: $0.tty) }
    }
    if let line = singleLineWithoutTrailingNewline(text) {
        guard KeystrokeTyper.canType(line, maxUnitsPerCharacter: limit) else {
            return .unavailable(.noRoute)
        }
        let viMode = shells.contains { shellMayUseViMode(pid: $0.pid) }
        if viMode, !canBracket() {
            return .unavailable(.viMode)
        }
        guard InputSourceState.canTypeNow else {
            return .unavailable(.inputMethod)
        }
        if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
            return .unavailable(.keystrokesWatched(watchers))
        }
        // 能包成 bracketed paste 就包上（和真正的粘贴一样）：键入的途中漏进来的回车（Secure Keyboard Entry 开着时 Copi 拦不到）
        // 只会变成一个换行，不会执行打了一半的命令
        KeystrokeTyper.shared.type(line, into: target, keyTime: keyTime, bracketedPaste: viMode || canBracket())
        return .typing
    }
    var body = KeystrokeTyper.normalizedNewlines(text)
    while body.hasSuffix("\n") {
        body.removeLast()
    }
    guard canBracket() else {
        return .unavailable(.multiLine)
    }
    guard KeystrokeTyper.canType(body, allowNewlines: true, allowTabs: true, maxUnitsPerCharacter: limit) else {
        return .unavailable(.noRoute)
    }
    guard InputSourceState.canTypeNow else {
        return .unavailable(.inputMethod)
    }
    if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
        return .unavailable(.keystrokesWatched(watchers))
    }
    KeystrokeTyper.shared.type(body, into: target, keyTime: keyTime, bracketedPaste: true)
    return .typing
}

// JetBrains 的终端工具窗口：看不出焦点在哪个终端标签页，所以 IDE 里所有终端都停在 shell 提示符前时才键入，并且只键入单行文字
// （多行文字要靠 bracketed paste，IDE 的终端怎么处理按出来的 ESC 没法确认）
private func typeIntoIDETerminal(_ text: String, target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    if case .other(let program) = target.terminalForeground {
        return .unavailable(.modalProgram(program))
    }
    guard let line = singleLineWithoutTrailingNewline(text) else {
        return .unavailable(.multiLine)
    }
    guard let role = target.role, axWritableRoles.contains(role),
          KeystrokeTyper.canType(line, maxUnitsPerCharacter: typingChunkLimit(pid: target.pid)) else {
        return .unavailable(.noRoute)
    }
    guard InputSourceState.canTypeNow else {
        return .unavailable(.inputMethod)
    }
    if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
        return .unavailable(.keystrokesWatched(watchers))
    }
    KeystrokeTyper.shared.type(line, into: target, keyTime: keyTime)
    return .typing
}

// 代码编辑器（VS Code、JetBrains、网页里的 Monaco/CodeMirror）：只键入不会触发自动补全的单行文字
private func typeIntoCodeEditor(_ text: String, target: FocusedTarget, keyTime: Date) -> ZeroExposurePasteResult {
    guard let line = singleLineWithoutTrailingNewline(text) else {
        return .unavailable(.multiLine)
    }
    if hasVimEmulation(for: target) {
        return .unavailable(.modalProgram("Vim"))
    }
    guard isSafeForCodeEditor(line) else {
        return .unavailable(.unsafeCharacters)
    }
    // 编辑器的输入节点（隐藏的 textarea、EditContext、Java 的文本区域）
    guard let role = target.role, axWritableRoles.contains(role),
          KeystrokeTyper.canType(line, maxUnitsPerCharacter: typingChunkLimit(pid: target.pid)) else {
        return .unavailable(.noRoute)
    }
    guard InputSourceState.canTypeNow else {
        return .unavailable(.inputMethod)
    }
    if let watchers = keystrokeWatchersBlockingTyping(into: target.pid) {
        return .unavailable(.keystrokesWatched(watchers))
    }
    KeystrokeTyper.shared.type(line, into: target, keyTime: keyTime)
    return .typing
}

// Chrome 系浏览器、Electron App 的无障碍树没建好时认不出密码框。焦点所在的 App 正开着 Secure Input（多半是焦点在它的密码框里）时，
// 请它建好无障碍树再看焦点是不是真的在密码框里——只凭 Secure Input 的归属记录就打字不可靠（记录可能张冠李戴、残留，
// 见 SecureInputOwner），网页、App 里的单键快捷键会被触发
private func revealPasswordField(around target: FocusedTarget?) -> FocusedTarget? {
    guard let pid = target?.pid ?? NSWorkspace.shared.frontmostApplication?.processIdentifier, pid != getpid(),
          SecureInputOwner.pid == pid, isChromiumApp(pid: pid) else {
        return nil
    }
    let application = AXUIElementCreateApplication(pid)
    requestWebAccessibility(application)
    let deadline = Date().addingTimeInterval(min(0.25, max(0, (axBudgetRemaining ?? 0.35) - 0.1)))
    while true {
        if let element = asAXElement(copyAXAttribute(application, kAXFocusedUIElementAttribute)) {
            let candidate = FocusedTarget(element: element, pid: pid)
            if candidate.isSecureTextField {
                return candidate
            }
        }
        guard Date() < deadline, !axBudgetExhausted else {
            return nil
        }
        sleepAttentively(0.03)
    }
}

// 请 Chrome 系浏览器、Electron App 建好网页部分的无障碍树：问一下 App、焦点窗口和窗口里各个视图（网页视图）的角色就够了。
// 不写 AXManualAccessibility / AXEnhancedUserInterface：Chrome 不认前者；Electron App（VS Code 等）收到它们会进入"屏幕阅读器模式"，
// 一直慢下去（VS Code 还会关掉折叠、小地图）；后者还会干扰窗口动画、和窗口管理工具冲突
func requestWebAccessibility(_ application: AXUIElement) {
    // 主线程上受 Accessibility 时间预算限制（目标 App 卡住时不会拖住 ⌘V）
    _ = copyAXAttribute(application, kAXRoleAttribute)
    guard let window = asAXElement(copyAXAttribute(application, kAXFocusedWindowAttribute)) else {
        return
    }
    _ = copyAXAttribute(window, kAXRoleAttribute)
    guard let children = copyAXAttribute(window, kAXChildrenAttribute) as? [AnyObject] else {
        return
    }
    for child in children.prefix(8) {
        if let element = asAXElement(child) {
            _ = copyAXAttribute(element, kAXRoleAttribute)
        }
    }
}

// element 底下 depth 层以内有没有选中的文字（selectedOnly 为 false 时，有文本区域、网页内容也算）。最多看 60 个元素。
// 看不全时（读不到 element 自己的子元素、Accessibility 的时间预算用完）返回 nil
private func axSubtreeHasText(_ element: AXUIElement, depth: Int, selectedOnly: Bool) -> Bool? {
    var level = [element]
    var visited = 0
    for currentDepth in 0..<depth {
        var next: [AXUIElement] = []
        for parent in level {
            let children: [AnyObject]
            switch readAXAttribute(parent, kAXChildrenAttribute) {
            case .value(let value):
                children = value as? [AnyObject] ?? []
            case .none:
                children = []
            case .failed:
                // 读不到：要紧的是最上面那一层（下面的元素读不到就跳过）
                if currentDepth == 0 || axBudgetExhausted {
                    return nil
                }
                continue
            }
            for child in children {
                guard let child = asAXElement(child) else {
                    continue
                }
                visited += 1
                guard visited <= 60 else {
                    // 没看全：找选中的文字（图片上的实况文本）时当作不知道；文件管理器的图标视图本来就有很多项，当作没有文字
                    return selectedOnly ? nil : false
                }
                if let selected = copyAXAttribute(child, kAXSelectedTextAttribute) as? String, !selected.isEmpty {
                    return true
                }
                if !selectedOnly, let role = copyAXAttribute(child, kAXRoleAttribute) as? String,
                   role == kAXTextAreaRole || role == "AXWebArea" {
                    return true
                }
                next.append(child)
            }
        }
        level = next
    }
    return axBudgetExhausted ? nil : false
}

// 键入进行中（event tap 线程读）：这时用户按下的回车先不给 App——聊天里会把打了一半的消息发出去，shell、虚拟机里会执行打了一半的
// 命令。吞掉它，键入停下（见 GlobalMode.shouldSwallow、KeystrokeTyper.post）
enum TypingInterrupt {
    private static let lock = NSLock()
    private static var active = false
    private static var returnPressed = false
    // 吞掉的那个回车可能还按着：之后它的自动重复也吞掉，直到用户松开它、重新按下回车
    private static var holdingReturn = false
    // ⌘C/⌘V 拦截器没在跑时（手动模式、拦截器没起来）键入期间临时起的、只管回车的 tap
    private static var returnTap: KeyTap?
    // 每次开始键入加一：之前安排的"过一会儿停掉临时 tap"据此知道 tap 又有人在用了
    private static var generation = 0

    // 任意线程（键入队列）
    static func begin() {
        lock.lock()
        active = true
        returnPressed = false
        holdingReturn = false
        generation += 1
        let existing = returnTap
        let needsTap = !GlobalMode.shared.isInterceptingKeys && existing == nil
        lock.unlock()
        // 沿用之前的临时 tap：它可能已经被系统作废了，start() 会重建
        existing?.start()
        if needsTap {
            let tap = KeyTap(events: [.keyDown]) { event in
                event.getIntegerValueField(.eventSourceUserData) != copiSyntheticEventMarker
                    && [Int64(kVK_Return), Int64(kVK_ANSI_KeypadEnter)].contains(event.getIntegerValueField(.keyboardEventKeycode))
                    && swallowReturn(isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            }
            if tap.start() {
                lock.lock()
                returnTap = tap
                lock.unlock()
            }
        }
    }

    static func end() {
        lock.lock()
        active = false
        let scheduled = generation
        let hasTap = returnTap != nil
        lock.unlock()
        // 临时的 tap 再留一会儿：吞掉还按着的回车的自动重复，回车松开了再停
        if hasTap {
            stopTapLater(generation: scheduled, deadline: Date().addingTimeInterval(30))
        }
    }

    private static func stopTapLater(generation scheduled: Int, deadline: Date) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            let returnHeld = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_Return))
                || CGEventSource.keyState(.hidSystemState, key: CGKeyCode(kVK_ANSI_KeypadEnter))
            lock.lock()
            // 又开始键入了：tap 还要用
            guard generation == scheduled, !active else {
                lock.unlock()
                return
            }
            if returnHeld, Date() < deadline {
                lock.unlock()
                stopTapLater(generation: scheduled, deadline: deadline)
                return
            }
            holdingReturn = false
            let tap = returnTap
            returnTap = nil
            lock.unlock()
            tap?.stop()
        }
    }

    // tap 线程：键入进行中时记下并返回 true（吞掉这个回车）；之后还按着的回车的自动重复也吞掉
    static func swallowReturn(isRepeat: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if active {
            returnPressed = true
            holdingReturn = true
            return true
        }
        if holdingReturn {
            if isRepeat {
                return true
            }
            holdingReturn = false
        }
        return false
    }

    static var returnWasPressed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return returnPressed
    }
}

// 从 time 到现在，用户有没有按过（或松开）修饰键（硬件层的记录，不含 Copi 合成的事件）。time 要在修饰键都松开之后
func modifierPressedSince(_ time: Date) -> Bool {
    CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: .flagsChanged) < Date().timeIntervalSince(time)
}

// 从 keyTime（用户按下快捷键的时刻）到现在，用户有没有再按过别的键或点过鼠标。读的是硬件层的输入记录（不含 Copi 合成的事件），
// 不受 App 切换时机影响：⌘Tab 要等松开 ⌘ 才真正切换，光看焦点会来不及发现。
func userActedSince(_ keyTime: Date) -> Bool {
    let keyAge = Date().timeIntervalSince(keyTime)
    // 不算鼠标移动（那会让"用户没有操作"几乎永远不成立）；右键、其他键也算（右键菜单里的"拷贝"）
    let sinceLastAction = [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
        .min() ?? .infinity
    return sinceLastAction < keyAge - 0.03
}

// Safari / WKWebView：WebKit 的 AXTextOperation。同步执行，走真正的编辑命令（派发 beforeinput/input，能 ⌘Z 撤销），
// 对 input、textarea、contenteditable 都有效；密码框的 text marker 被屏蔽，用不了。
// 必须用 TextOperationReplacePreserveCase：旧的 TextOperationReplace 会改动大小写。Safari 18.2 以前不认识这个类型，
// 会当成"选中"处理、原样返回选中的文字，据此判断不支持。
private func webKitTextOperation(_ text: String, into target: FocusedTarget) -> AXWriteResult {
    // WebKit 自己最多等 250ms：等不完它就不发，免得请求已经送达、Copi 却当作没写进去又补一次
    let timeout = min(0.4, axBudgetRemaining ?? 0.4)
    guard timeout >= 0.3, let markerRange = copyAXAttribute(target.element, "AXSelectedTextMarkerRange") else {
        return .notApplicable
    }
    let insert = target.role == kAXTextFieldRole ? normalizedForSingleLine(text) : text
    guard !insert.isEmpty else {
        return .notApplicable
    }
    let selectionBefore = target.selectedRange
    let parameters: NSDictionary = [
        "AXTextOperationMarkerRanges": [markerRange],
        "AXTextOperationType": "TextOperationReplacePreserveCase",
        "AXTextOperationReplacementString": insert,
        "AXTextOperationSmartReplace": false,
    ]
    AXUIElementSetMessagingTimeout(target.element, Float(timeout))
    let startedAt = DispatchTime.now()
    var result: CFTypeRef?
    let error = AXUIElementCopyParameterizedAttributeValue(target.element, "AXTextOperation" as CFString, parameters, &result)
    let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000
    AXUIElementSetMessagingTimeout(target.element, 0.05)
    guard error == .success, let replaced = result as? [String], !replaced.isEmpty else {
        // 请求已经送达、只是迟迟没有结果（WebKit 自己 250ms 超时后返回空，操作稍后照样执行）：不能再走别的路
        if elapsed >= 0.2 || (error == .cannotComplete && elapsed >= timeout * 0.8) {
            notifyPasteUncertain(into: target)
            return .uncertain
        }
        return .notApplicable
    }
    guard replaced == [insert] else {
        return .notApplicable
    }
    // 替换了选中内容时，插入的文字会保持选中状态：把光标移到插入的文字末尾。位置用已知的值算——
    // 这时去读选区，读到的多半还是替换前的
    if let selectionBefore, selectionBefore.length > 0 {
        var caret = CFRange(location: selectionBefore.location + (insert as NSString).length, length: 0)
        if let caretValue = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, caretValue)
        }
    }
    notifyProtected("Pasted safely")
    return .inserted
}

// 上一次改写 AXValue 还没确认生效时，不再拼接新的值（拼接用的旧值已经过时）
private var pendingChromiumWrite = false
// 上一次没能确认生效的写入：同一个输入框里再粘贴时，据此判断页面到底接不接受这种写入
private var unconfirmedChromiumWrite: (element: AXUIElement, oldValue: String, at: Date)?
// 确认不接受 AX 写入的输入框（例如代码编辑器的代理输入框）：之后直接走别的方式
private var chromiumWriteIgnored: (element: AXUIElement, at: Date)?
// Chromium 通过无障碍接口给出的值最多 10000 字节，更长的值读到的是截断的，拼接写回会删掉后面的内容
private let chromiumValueByteLimit = 9_000

// Firefox 的值没有长度上限（读到的不会被截断）
private let geckoValueByteLimit = 4_000_000

// Chrome 系浏览器、Electron、Firefox 里的 <input>/<textarea>：整体改写 AXValue。Chromium 会走页面自己的 SetValue，Firefox 走编辑器的
// "插入文字"（一次可撤销的编辑），都会派发 input 事件，React 等框架都能拿到新值。两者的写入都是异步生效的。
// 只能整值替换，所以先在选区处拼好新值，写完再把光标放回去。
// 不能用于 contenteditable（会变成 setInnerText、或者丢掉富文本格式），也不能用于代码编辑器的代理输入框。
// （Firefox 的 kAXSelectedText 写入有 bug：删除的范围不对，光标处插入会插到开头，所以不用它。）
private func spliceValue(_ text: String, into target: FocusedTarget, byteLimit: Int = chromiumValueByteLimit) -> AXWriteResult {
    if let ignored = chromiumWriteIgnored, CFEqual(ignored.element, target.element), Date().timeIntervalSince(ignored.at) < 600 {
        return .notApplicable
    }
    // 浏览器的无障碍树要过一会儿才跟上页面：刚打过字、改过选区时读到的值和选区可能是旧的，拼出来会抹掉刚打的字
    guard !pendingChromiumWrite, InputActivity.secondsSinceLastInput >= 0.3,
          let role = target.role, target.isSettable(kAXValueAttribute),
          let selection = target.selectedRange, let length = target.numberOfCharacters,
          let oldValue = target.value, oldValue.utf8.count < byteLimit else {
        return .notApplicable
    }
    // 上次在这个输入框里写入后一直没看到变化，这次值还是原样：页面不接受这种写入
    if let last = unconfirmedChromiumWrite, CFEqual(last.element, target.element), Date().timeIntervalSince(last.at) < 10 {
        unconfirmedChromiumWrite = nil
        if oldValue == last.oldValue {
            chromiumWriteIgnored = (target.element, Date())
            return .notApplicable
        }
    }
    let old = oldValue as NSString
    guard old.length == length, selection.location >= 0, selection.length >= 0,
          selection.location + selection.length <= old.length else {
        return .notApplicable
    }
    // 隔一小会儿再读一次，两次一致才写（不一致说明页面还在变）
    sleepAttentively(0.03)
    guard target.value == oldValue, let selectionAgain = target.selectedRange,
          selectionAgain.location == selection.location, selectionAgain.length == selection.length else {
        return .notApplicable
    }
    let insert = role == kAXTextAreaRole
        ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        : normalizedForSingleLine(text)
    let newValue = old.replacingCharacters(in: NSRange(location: selection.location, length: selection.length), with: insert)
    // 选中的内容和要粘贴的一样：什么都不用做
    if newValue == oldValue {
        return .inserted
    }
    let timeout = min(0.3, axBudgetRemaining ?? 0.3)
    guard timeout > 0.05 else {
        return .notApplicable
    }
    AXUIElementSetMessagingTimeout(target.element, Float(timeout))
    let startedAt = DispatchTime.now()
    let result = AXUIElementSetAttributeValue(target.element, kAXValueAttribute as CFString, newValue as CFTypeRef)
    let elapsed = TimeInterval(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000
    AXUIElementSetMessagingTimeout(target.element, 0.05)
    switch result {
    case .success:
        break
    case .cannotComplete where elapsed >= timeout * 0.8:
        // 等到了超时：请求可能稍后才执行，照样确认
        break
    default:
        return .notApplicable
    }
    // 写入是异步生效的：稍后确认、把光标放回插入处。写入一旦发出就不再用别的方式补粘贴——
    // 页面只是慢的话，两种方式都会生效，变成粘贴两遍
    pendingChromiumWrite = true
    let caret = selection.location + (insert as NSString).length
    confirmChromiumValue(target, oldValue: oldValue, newValue: newValue, caret: caret, writtenAt: Date(), deadline: Date().addingTimeInterval(1.5))
    return .inserted
}

private func confirmChromiumValue(_ target: FocusedTarget, oldValue: String, newValue: String, caret: Int, writtenAt: Date, deadline: Date) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
        guard let current = target.value, current != oldValue else {
            if Date() < deadline {
                confirmChromiumValue(target, oldValue: oldValue, newValue: newValue, caret: caret, writtenAt: writtenAt, deadline: deadline)
                return
            }
            pendingChromiumWrite = false
            unconfirmedChromiumWrite = (target.element, oldValue, Date())
            notifyPasteUncertain(into: target)
            return
        }
        pendingChromiumWrite = false
        // SetValue 会把光标放到末尾。只在必要时（插入点不在末尾）、值正是我们写的、写入后用户没有再输入、焦点也还在时才移回去——
        // 设置选区会让 Chrome 把焦点拉回这个输入框，用户已经 Tab 到别处（例如密码框）时会把后面的输入抢过来
        if caret != (current as NSString).length, current == newValue,
           InputActivity.lastInput < writtenAt, target.isStillFocused {
            var range = CFRange(location: caret, length: 0)
            if let rangeValue = AXValueCreate(.cfRange, &range) {
                AXUIElementSetAttributeValue(target.element, kAXSelectedTextRangeAttribute as CFString, rangeValue)
            }
        }
        notifyProtected("Pasted safely")
    }
}

func notifyPasteUncertain(into target: FocusedTarget) {
    notifyCopiNotice("Copi couldn't confirm the paste into \(target.applicationName). Check whether the text arrived before pasting again.")
}

// MARK: - 0 暴露复制

// 在主线程、withAXBudget 之内调用。读不到时返回 nil。
// 读出的选中文字。droppedAttachments：选区里夹着图片等附件（辅助功能给的是占位符 U+FFFC），只保管了其中的文字——
// 附件不经过系统剪贴板就带不走
struct CopiedSelection {
    let text: String
    let droppedAttachments: Bool
}

func zeroExposureCopy(from target: FocusedTarget) -> String? {
    zeroExposureCopySelection(from: target)?.text
}

func zeroExposureCopySelection(from target: FocusedTarget) -> CopiedSelection? {
    guard !target.isSecureTextField else {
        return nil
    }
    let names = target.attributeNames
    let text: String?
    if let engine = target.webEngine(attributeNames: names) {
        text = readWebSelection(target, engine: engine)
    } else {
        // 原生控件（也包括终端）：直接读选中文字；万一是没带网页属性的网页节点，按网页处理
        guard let selected = target.selectedText else {
            return nil
        }
        text = target.hasWebAreaAncestor ? nil : selected
    }
    guard let text else {
        return nil
    }
    return copiedSelection(fromRaw: text)
}

// 选区里有图片等附件时，AX 拿到的只是占位符 U+FFFC：去掉占位符，只要还剩下文字就保管文字
func copiedSelection(fromRaw text: String) -> CopiedSelection? {
    guard !text.isEmpty else {
        return nil
    }
    guard text.contains("\u{FFFC}") else {
        return CopiedSelection(text: text, droppedAttachments: false)
    }
    let plain = text.replacingOccurrences(of: "\u{FFFC}", with: "")
    guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    return CopiedSelection(text: plain, droppedAttachments: true)
}

private func readWebSelection(_ target: FocusedTarget, engine: WebEngine) -> String? {
    // 刚刚改过选区（拖选、⇧ 方向键、⌘A）时，浏览器的无障碍树要过一会儿才同步，太快去读会读到上一次的选区
    InputActivity.waitForSettledInput()
    // 代码编辑器、网页终端、Google Docs 只渲染可见部分，读出来的选区会被截断；认不出是什么的多行编辑区（Firefox）同理
    switch target.webEditorKind(engine: engine) {
    case .code?, .vimCode?, .terminal?, .wordProcessor?, .spreadsheet?:
        return nil
    case .unknown?:
        if target.role == kAXTextAreaRole {
            return nil
        }
    case nil:
        break
    }
    // 原子输入框里的选区：直接读选中文字（contenteditable 有子节点，不走这里——Chromium 会把它的段落粘成一行）
    if let role = target.role, axWritableRoles.contains(role), target.childCount == 0 {
        // Chromium 读出来的值最多 10000 字节，太长时不可信
        if engine == .chromium, let value = target.value, value.utf8.count >= 9000 {
            return nil
        }
        return target.selectedText
    }
    guard let markerRange = copyAXAttribute(target.element, "AXSelectedTextMarkerRange") else {
        return nil
    }
    switch engine {
    case .webKit:
        // WebKit 按复制时同样的方式遍历文字，段落之间的换行都在
        return copyAXParameterizedAttribute(target.element, "AXStringForTextMarkerRange", markerRange) as? String
    case .chromium:
        return paragraphPreservingString(target.element, markerRange: markerRange)
    case .gecko:
        return geckoSelectionString(target.element, markerRange: markerRange)
    }
}

// 逐段读网页选区（Chromium、Firefox）时最多走多少段：只防万一原地打转。真正的上限是调用方的 Accessibility 时间预算——
// 用完之后每一步都读不出来，照样返回 nil。之前固定是 200 段：一篇长文章、⌘A 全选的网页往往有几百段，预算还剩很多时就被拒绝复制了
private let maxSelectionParagraphs = 20_000

// Firefox：选区文字不带段落分隔（"<p>A</p><p>B</p>" 读出来是 "AB"），只有 <br> 是换行。它没有 AXNextParagraphEnd…，
// 用 AXParagraphTextMarkerRangeForTextMarker 一段一段往后走，再用换行拼起来。逐段读出的文字拼在一起必须正好等于整段读出的文字，
// 对不上（或者哪一段读不出来）就不猜，返回 nil——宁可这次复制不了，也不能把段落粘在一起的文字当成复制结果。
// Firefox 给出的选区是最近一次选区变化事件里记下的，所以要在用户选择之前就打开它的无障碍树（见 WebAccessibilityWarmer）。
private func geckoSelectionString(_ element: AXUIElement, markerRange rawRange: CFTypeRef) -> String? {
    guard CFGetTypeID(rawRange) == AXTextMarkerRangeGetTypeID() else {
        return nil
    }
    let selection = rawRange as! AXTextMarkerRange
    var whole = copyAXParameterizedAttribute(element, "AXStringForTextMarkerRange", selection) as? String
    if whole?.isEmpty ?? true, (textLength(element, selection) ?? 0) > 0, (axBudgetRemaining ?? 0) > 0.15 {
        // 第一次读文字时 Firefox 可能还在异步准备文字缓存，稍等再读一次
        sleepAttentively(0.08)
        whole = copyAXParameterizedAttribute(element, "AXStringForTextMarkerRange", selection) as? String
    }
    guard let whole, !whole.isEmpty else {
        return nil
    }
    let end = AXTextMarkerRangeCopyEndMarker(selection)
    var cursor = AXTextMarkerRangeCopyStartMarker(selection)
    guard let endIndex = markerIndex(element, end), var cursorIndex = markerIndex(element, cursor), cursorIndex < endIndex else {
        return nil
    }
    var paragraphs: [String] = []
    for _ in 0..<maxSelectionParagraphs {
        guard let paragraphRaw = copyAXParameterizedAttribute(element, "AXParagraphTextMarkerRangeForTextMarker", cursor),
              CFGetTypeID(paragraphRaw) == AXTextMarkerRangeGetTypeID() else {
            return nil
        }
        let paragraphEnd = AXTextMarkerRangeCopyEndMarker(paragraphRaw as! AXTextMarkerRange)
        guard let paragraphEndIndex = markerIndex(element, paragraphEnd) else {
            return nil
        }
        let reachedEnd = paragraphEndIndex >= endIndex
        // 每一步都必须往后走，免得在段落边界上原地打转
        guard reachedEnd || paragraphEndIndex > cursorIndex,
              let part = copyAXParameterizedAttribute(element, "AXStringForTextMarkerRange",
                                                      AXTextMarkerRangeCreate(kCFAllocatorDefault, cursor, reachedEnd ? end : paragraphEnd)) as? String else {
            return nil
        }
        paragraphs.append(part)
        if reachedEnd {
            guard paragraphs.joined() == whole else {
                return nil
            }
            let nonEmpty = paragraphs.filter { !$0.isEmpty }
            var result = ""
            for (index, paragraph) in nonEmpty.enumerated() {
                result += paragraph
                // 段落末尾已经是 <br> 带来的换行时不再补
                if index < nonEmpty.count - 1, !paragraph.hasSuffix("\n") {
                    result += "\n"
                }
            }
            return result
        }
        cursor = paragraphEnd
        cursorIndex = paragraphEndIndex
    }
    // 段落太多
    return nil
}

private func markerIndex(_ element: AXUIElement, _ marker: AXTextMarker) -> Int? {
    (copyAXParameterizedAttribute(element, "AXIndexForTextMarker", marker) as? NSNumber)?.intValue
}

// Chromium 整段读出的选区文字不带段落分隔（AXRange::GetText 默认 kWithoutParagraphBreaks："A\nB" 读出来是 "AB"），
// 这里一段一段读出来再用换行拼起来。下一段从上一段的结尾直接开始读：之前从段落结尾往后再挪一个字符
// （AXNextTextMarkerForTextMarker）当作跳过段落之间的换行，可整段文字里并没有换行，挪过去的是下一段的第一个字——每段丢一个字；
// 选区末尾是图标、按钮这类嵌入对象时还会挪到一个无效的位置上，整次复制被拒绝。
// 逐段读出的文字连在一起必须正好等于整段读出的文字，对不上就不猜，返回 nil
private func paragraphPreservingString(_ element: AXUIElement, markerRange rawRange: CFTypeRef) -> String? {
    guard CFGetTypeID(rawRange) == AXTextMarkerRangeGetTypeID() else {
        return nil
    }
    let selection = rawRange as! AXTextMarkerRange
    // Chromium 的选区是"起点到焦点"，从后往前选时顺序是反的，先整理成正序
    let unordered = [AXTextMarkerRangeCopyStartMarker(selection), AXTextMarkerRangeCopyEndMarker(selection)] as CFArray
    guard let orderedRaw = copyAXParameterizedAttribute(element, "AXTextMarkerRangeForUnorderedTextMarkers", unordered),
          CFGetTypeID(orderedRaw) == AXTextMarkerRangeGetTypeID() else {
        return nil
    }
    let ordered = orderedRaw as! AXTextMarkerRange
    let first = AXTextMarkerRangeCopyStartMarker(ordered)
    let last = AXTextMarkerRangeCopyEndMarker(ordered)
    guard let total = textLength(element, ordered), total > 0 else {
        return nil
    }
    var paragraphs: [String] = []
    var cursor = first
    var consumed = 0
    var reachedEnd = false
    for _ in 0..<maxSelectionParagraphs {
        // 下一个段落结尾。确定没有了（已经是网页里最后一段）时，剩下的部分就是最后一段；出错、超时就不猜
        var paragraphEnd: AXTextMarker?
        switch readAXParameterizedAttribute(element, "AXNextParagraphEndTextMarkerForTextMarker", cursor) {
        case .value(let value) where CFGetTypeID(value) == AXTextMarkerGetTypeID():
            paragraphEnd = (value as! AXTextMarker)
        case .none:
            paragraphEnd = nil
        default:
            return nil
        }
        // 只量这一段的长度（不从选区开头重新量），累计起来判断有没有到选区末尾
        var paragraphLength: Int?
        if let end = paragraphEnd {
            guard let length = textLength(element, AXTextMarkerRangeCreate(kCFAllocatorDefault, cursor, end)) else {
                return nil
            }
            paragraphLength = length
            // 一个字都没走过：可能是 Chromium 走到网页末尾时给的空位置（问它什么都问不出来），这也是没有下一个段落结尾
            if length == 0 {
                switch readAXParameterizedAttribute(element, "AXIndexForTextMarker", end) {
                case .value:
                    break
                case .none:
                    paragraphEnd = nil
                    paragraphLength = nil
                case .failed:
                    return nil
                }
            }
        }
        reachedEnd = paragraphLength.map { consumed + $0 >= total } ?? true
        let stop = reachedEnd ? last : paragraphEnd!
        guard let paragraph = copyAXParameterizedAttribute(element, "AXStringForTextMarkerRange",
                                                           AXTextMarkerRangeCreate(kCFAllocatorDefault, cursor, stop)) as? String else {
            return nil
        }
        paragraphs.append(paragraph)
        if reachedEnd {
            break
        }
        // 没有往前走（不该发生）：不原地打转
        guard let paragraphLength, paragraphLength > 0, let paragraphEnd else {
            return nil
        }
        consumed += paragraphLength
        cursor = paragraphEnd
    }
    // 走了这么多段还没到选区末尾，或者逐段读出的文字和整段的对不上：交给回退路径
    guard reachedEnd,
          let whole = copyAXParameterizedAttribute(element, "AXStringForTextMarkerRange", ordered) as? String,
          paragraphs.joined() == whole else {
        return nil
    }
    // 段落末尾（或开头）已经是 <br> 带来的换行时不再补；空段落不留空行
    let nonEmpty = paragraphs.filter { !$0.isEmpty }
    var result = ""
    for (index, paragraph) in nonEmpty.enumerated() {
        result += paragraph
        if index < nonEmpty.count - 1, !paragraph.hasSuffix("\n"), !nonEmpty[index + 1].hasPrefix("\n") {
            result += "\n"
        }
    }
    return result
}

private func textLength(_ element: AXUIElement, _ range: AXTextMarkerRange) -> Int? {
    (copyAXParameterizedAttribute(element, "AXLengthForTextMarkerRange", range) as? NSNumber)?.intValue
}

// 最近一次键盘输入、可能改变选区的操作（鼠标松开、⇧ 方向键、⌘A……）的时间：浏览器的无障碍树要过一会儿才跟上
enum InputActivity {
    private static let lock = NSLock()
    private static var lastInputAt = Date.distantPast

    // 任意线程可用
    static func noteInput() {
        lock.lock()
        lastInputAt = Date()
        lock.unlock()
    }

    static var secondsSinceLastInput: TimeInterval {
        Date().timeIntervalSince(lastInput)
    }

    static var lastInput: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastInputAt
    }

    // 主线程：距离上次输入不到 0.15 秒时等一等
    static func waitForSettledInput() {
        let settle: TimeInterval = 0.15
        let elapsed = secondsSinceLastInput
        if elapsed < settle {
            sleepAttentively(min(settle - elapsed, axBudgetRemaining ?? settle))
        }
    }
}

// MARK: - 模拟键入

// 把文字"打"进当前焦点：每个按键事件带上要输入的字符（和密码管理器的自动填充一样），全程不碰剪贴板。
// 绑定到用户按下粘贴快捷键时的那个输入框：开始前和每打一块之前都确认焦点还在那里、用户也没有再按别的键或点鼠标，
// 否则就停下——免得把内容（往往是密码）打进别的 App 或别的输入框。
final class KeystrokeTyper {
    static let shared = KeystrokeTyper()

    // 太长的文字打起来又慢又容易出错（也容易和用户自己的按键交错）
    static let maxLength = 4000
    // 每个事件最多带 20 个 UTF-16 单元，多了会被系统悄悄截掉
    static let chunkLimit = 20

    // 换行按哪个键
    enum NewlineKey {
        // 多行输入框、聊天框（单独的 ↩ 往往是发送）
        case shiftReturn
        // Google Sheets 的单元格
        case commandReturn
        // 终端（bracketed paste 里面）
        case plainReturn
    }

    private enum Action {
        case type(String, NewlineKey)
        // 终端里的多行粘贴：ESC[200~ + 文字（换行按 ↩、Tab 按 ⇥）+ ESC[201~
        case typeBracketedPaste(String)
        // 虚拟机、远程桌面：真实的按键（键位 + ⇧）
        case pressKeys([KeyStroke])
        // ⌘X：选中的文字已经存进安全剪贴板，再按一次退格把它删掉
        case deleteSelection
    }

    private struct Job {
        let action: Action
        let target: FocusedTarget
        let keyTime: Date
        // 逐字符发送（分格验证码：每输一位，焦点会自动跳到同一进程里的下一个输入框）
        let perCharacter: Bool
        // 每个按键事件最多带几个 UTF-16 单元（见 typingChunkLimit）
        let maxUnitsPerEvent: Int

        var isCut: Bool {
            if case .deleteSelection = action {
                return true
            }
            return false
        }
    }

    private enum Chunk {
        case text(units: [UniChar], characterCount: Int)
        // 换行用 ⇧↩：聊天框里单独的 ↩ 是发送，⇧↩ 在各种编辑器、多行输入框里都是换行
        case newline
        // Google Sheets 单元格里的换行 ⌘↩
        case commandReturn
        // 终端 bracketed paste 里用的 ↩、⇥、esc
        case plainReturn
        case tab
        case escape
        case deleteBackward

        var characterCount: Int {
            switch self {
            case .text(_, let count):
                return count
            case .newline, .commandReturn, .plainReturn, .tab:
                return 1
            case .escape, .deleteBackward:
                return 0
            }
        }
    }

    private let queue = DispatchQueue(label: "Copi.KeystrokeTyper", qos: .userInteractive)
    // 只在 queue 上用：这次键入因为途中有程序开始看按键而停下时，那些程序的名字
    private var watchersStoppedTyping: [String]?
    // 只在 queue 上用：这次键入开始的时刻（修饰键已经都松开了）
    private var typingStartedAt = Date.distantPast
    private var pending: [Job] = []
    private var isTyping = false

    // 统一换行：\r\n、\r 都当作一个换行
    static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    // 能用键入完成的文字：不含制表符等控制字符（Tab 会切换焦点），换行只在 allowNewlines 时可以有；
    // 也不含单个字符就超过一个按键事件能带的 UTF-16 单元数的组合（会被截断，见 typingChunkLimit）
    static func canType(_ text: String, allowNewlines: Bool = false, allowTabs: Bool = false, maxUnitsPerCharacter: Int = chunkLimit) -> Bool {
        guard !text.isEmpty, text.utf16.count <= maxLength else {
            return false
        }
        if text.unicodeScalars.contains(where: {
            $0.properties.generalCategory == .control && !(allowNewlines && $0 == "\n") && !(allowTabs && $0 == "\t")
        }) {
            return false
        }
        return !text.contains { $0.utf16.count > maxUnitsPerCharacter }
    }

    // 主线程调用。先等用户松开修饰键（刚按下的 ⌘V 的 ⌘ 往往还按着，会把字符变成快捷键）。
    func type(_ text: String, into target: FocusedTarget, keyTime: Date, perCharacter: Bool = false, bracketedPaste: Bool = false,
              newlineKey: NewlineKey = .shiftReturn) {
        enqueue(Job(action: bracketedPaste ? .typeBracketedPaste(text) : .type(text, newlineKey), target: target, keyTime: keyTime,
                    perCharacter: perCharacter, maxUnitsPerEvent: typingChunkLimit(pid: target.pid)))
    }

    // 主线程调用：在虚拟机、远程桌面里逐个按键
    func pressKeys(_ strokes: [KeyStroke], into target: FocusedTarget, keyTime: Date) {
        enqueue(Job(action: .pressKeys(strokes), target: target, keyTime: keyTime, perCharacter: false, maxUnitsPerEvent: Self.chunkLimit))
    }

    // 主线程调用：删除焦点控件里选中的内容（⌘X）
    func deleteSelection(in target: FocusedTarget, keyTime: Date) {
        enqueue(Job(action: .deleteSelection, target: target, keyTime: keyTime, perCharacter: false, maxUnitsPerEvent: Self.chunkLimit))
    }

    private func enqueue(_ job: Job) {
        dispatchPrecondition(condition: .onQueue(.main))
        pending.append(job)
        // 放到下一轮再开始：调用方可能还在 Accessibility 的时间预算里，焦点检查不该受它限制
        DispatchQueue.main.async { [self] in
            startNextIfIdle()
        }
    }

    private func startNextIfIdle() {
        guard !isTyping, !pending.isEmpty else {
            return
        }
        isTyping = true
        let job = pending.removeFirst()
        waitForModifiersReleased(deadline: Date().addingTimeInterval(0.8)) { [self] released in
            guard released else {
                let appName = job.target.applicationName
                notifyCopiNotice(job.isCut
                    ? "Copi copied the text but didn't delete it from \(appName) because keys were still held down."
                    : "Copi didn't type the paste into \(appName) because keys were still held down. Press ⌘V again.")
                finishJob()
                return
            }
            // 稍等一下再检查：⌘Tab 这类操作在松开 ⌘ 的那一刻才生效。输入源刚切换过（包括焦点进入密码框时系统强制切到英文）
            // 要等它在目标 App 里生效
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                // 拼音等输入法开着（密码框除外，系统会自己切到英文）：临时切到英文键盘布局再打，打完切回去。
                // 拼音正在组字（有未上屏的拼音）时不切：切走会留下一个关不掉的候选窗、输入框也会卡住
                // 终端的"安全键盘输入"不限定输入源（只有密码框会被系统强制切到英文），照常切换
                if !job.isCut, !job.target.isSecureTextField, SecureInputOwner.pid != job.target.pid || job.target.isTerminalApp,
                   !InputSourceState.isASCIIKeyboardLayoutActive, InputSourceSwitcher.shared.isEnabled {
                    if job.target.hasMarkedText {
                        notifyCopiNotice("Finish or cancel what you're typing with the input method in \(job.target.applicationName), then press ⌘V again.")
                        finishJob()
                        return
                    }
                    InputSourceSwitcher.shared.switchToASCII { [self] switched in
                        guard let switched else {
                            run(job, inputSourceReady: false)
                            return
                        }
                        run(job, inputSourceReady: true, switched: switched)
                    }
                    return
                }
                waitForASCIIInputSource(unless: job.isCut, deadline: Date().addingTimeInterval(0.5)) { [self] ready in
                    run(job, inputSourceReady: ready)
                }
            }
        }
    }

    // 主线程：最后确认一遍，然后在后台队列上发出按键。switched：为这次键入临时切换了输入源，打完（或放弃时）要切回去
    private func run(_ job: Job, inputSourceReady: Bool, switched: InputSourceSwitcher.Switch? = nil) {
        let appName = job.target.applicationName
        // 打字前的字符数：切回输入法之前据此确认目标 App 已经处理完打进去的字
        let lengthBefore = switched == nil ? nil : job.target.numberOfCharacters
        let finish = { [self] (typedChunks: Int) in
            guard let switched else {
                finishJob()
                return
            }
            // 等目标 App 处理完排队的按键再切回去，否则最后几个字会被输入法拿去组字。虚拟机、远程桌面直接选回去：它们捕获键盘时
            // 系统快捷键不起作用，模拟的 ⌃空格 会被转发进客户机；它们也不经过这台 Mac 的输入法
            let pressesKeys: Bool = {
                if case .pressKeys = job.action {
                    return true
                }
                return false
            }()
            InputSourceSwitcher.shared.restore(switched, directly: pressesKeys, consumed: { done in
                Self.waitUntilConsumed(job.target, lengthBefore: lengthBefore, typedChunks: typedChunks, then: done)
            }) { [self] in
                finishJob()
            }
        }
        guard inputSourceReady else {
            notifyCopiNotice("Copi didn't type the paste into \(appName) because it couldn't switch away from the current input method. Switch to ABC or U.S. and press ⌘V again.")
            finish(0)
            return
        }
        guard !userActedSince(job.keyTime), Self.focusMatches(job) else {
            notifyCopiNotice(job.isCut
                ? "Copi copied the text but didn't delete it from \(appName) because the focus or your input changed."
                : "Copi didn't type the paste into \(appName) because the focus or your input changed. Press ⌘V again.")
            finish(0)
            return
        }
        let chunks: [Chunk]
        switch job.action {
        case .type(let text, let newlineKey):
            chunks = job.perCharacter
                ? text.map { .text(units: Array(String($0).utf16), characterCount: 1) }
                : Self.chunks(of: text, limit: job.maxUnitsPerEvent, newlineKey: newlineKey)
        case .typeBracketedPaste(let text):
            chunks = [.escape] + Self.chunks(of: "[200~", limit: job.maxUnitsPerEvent)
                + Self.chunks(of: text, limit: job.maxUnitsPerEvent, newlineKey: .plainReturn)
                + Self.bracketedPasteEnd(limit: job.maxUnitsPerEvent)
        case .deleteSelection:
            chunks = [.deleteBackward]
        case .pressKeys(let strokes):
            chunks = strokes.map { .text(units: Array($0.character.utf16), characterCount: 1) }
        }
        // 临时切到英文之后、开始打字之前（等它稳定的那一小会儿）用户又切回了输入法：这时的切换通知已经处理过，
        // 下面的检查发现不了，所以在这里再确认一次
        if switched != nil, !InputSourceState.isASCIIKeyboardLayoutActive, !job.isCut {
            notifyCopiNotice("Copi didn't type the paste into \(appName) because the input method changed. Press ⌘V again.")
            finish(0)
            return
        }
        let inputSourceGeneration = InputSourceState.changeGeneration
        queue.async { [self] in
            var unclosedBracket = false
            let completed: Int
            TypingInterrupt.begin()
            defer { TypingInterrupt.end() }
            typingStartedAt = Date()
            if case .pressKeys(let strokes) = job.action {
                completed = pressKeys(strokes, for: job)
            } else if case .typeBracketedPaste = job.action {
                completed = post(chunks, for: job, inputSourceGeneration: inputSourceGeneration,
                                 closing: Self.bracketedPasteEnd(limit: job.maxUnitsPerEvent).count, unclosed: &unclosedBracket)
            } else {
                completed = post(chunks, for: job, inputSourceGeneration: inputSourceGeneration)
            }
            let needsClosing = unclosedBracket
            // 没打完：是不是因为途中有程序开始看按键（见 post）、用户按了回车
            let watchers = completed < chunks.count ? watchersStoppedTyping : nil
            watchersStoppedTyping = nil
            let returnPressed = TypingInterrupt.returnWasPressed
            DispatchQueue.main.async {
                if returnPressed, completed < chunks.count {
                    notifyCopiNotice("Copi stopped typing into \(appName) because you pressed Return before it finished, and didn't send that Return. Check the field before sending.")
                } else if returnPressed, !job.isCut {
                    notifyCopiNotice("Copi held back a Return you pressed while it was finishing typing into \(appName). Press Return again if you meant to send it.")
                } else if let watchers {
                    let names = ListFormatter.localizedString(byJoining: Array(watchers.prefix(3)))
                    notifyCopiNotice(completed == 0
                        ? "Copi didn't type the paste into \(appName) because \(names) can now see keystrokes."
                        : "Copi stopped typing the paste into \(appName) because \(names) started watching keystrokes. Check the field before pasting again.")
                } else if job.isCut {
                    if completed == chunks.count {
                        notifyProtected("Cut safely")
                    } else {
                        notifyCopiNotice("Copi copied the text but didn't delete it from \(appName) because the focus moved.")
                    }
                } else if completed == chunks.count {
                    notifyProtected("Pasted safely")
                } else if completed == 0 {
                    notifyCopiNotice("Copi didn't type the paste into \(appName) because the focus moved or you kept typing. Press ⌘V again.")
                } else {
                    // 不说打了几个字：通知会留在通知中心里，密码的长度也不该透露
                    notifyCopiNotice("Copi typed only part of the paste into \(appName) before the focus or input method changed. Check the field before pasting again.")
                }
                if needsClosing {
                    self.closeBracketedPaste(job) {
                        finish(completed)
                    }
                } else {
                    finish(completed)
                }
            }
        }
    }

    // 主线程：bracketed paste 键入到一半时用户切换了输入法。先临时切到英文，再补发结束标记（否则 shell 一直停在粘贴状态，
    // 之后的按键都当成粘贴的内容），然后切回用户刚选的输入法
    private func closeBracketedPaste(_ job: Job, then done: @escaping () -> Void) {
        let appName = job.target.applicationName
        // 用户关掉了临时切换输入源（或者没有英文键盘布局）：不切，只提示
        guard InputSourceSwitcher.shared.isEnabled else {
            notifyCopiNotice("The input method changed while Copi was typing into \(appName). If the shell stops responding, press Control-C.")
            done()
            return
        }
        InputSourceSwitcher.shared.switchToASCII { [self] switched in
            guard let switched else {
                notifyCopiNotice("The input method changed while Copi was typing into \(appName). If the shell stops responding, press Control-C.")
                done()
                return
            }
            queue.async { [self] in
                if Self.focusMatches(job) {
                    let source = CGEventSource(stateID: .privateState)
                    for chunk in Self.bracketedPasteEnd(limit: job.maxUnitsPerEvent) {
                        emit(chunk, source: source, to: job.target.pid)
                        usleep(2_000)
                    }
                }
                DispatchQueue.main.async {
                    InputSourceSwitcher.shared.restore(switched, consumed: { finished in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            finished(())
                        }
                    }, then: done)
                }
            }
        }
    }

    // 主线程：等目标 App 处理完打进去的字——字符数变了并且稳定 50 毫秒；读不到字符数（终端、密码框）时按发出的按键数估一个时间
    private static func waitUntilConsumed(_ target: FocusedTarget, lengthBefore: Int?, typedChunks: Int, then done: @escaping (()) -> Void) {
        let fallback = typedChunks == 0 ? 0 : min(1.0, max(0.3, 0.15 + Double(typedChunks) * 0.004))
        guard typedChunks > 0, let lengthBefore else {
            DispatchQueue.main.asyncAfter(deadline: .now() + fallback) {
                done(())
            }
            return
        }
        let deadline = Date().addingTimeInterval(fallback)
        var lastLength = lengthBefore
        var stableSince = Date()
        func poll() {
            let length = target.numberOfCharacters ?? lengthBefore
            if length != lastLength {
                lastLength = length
                stableSince = Date()
            }
            if (length != lengthBefore && Date().timeIntervalSince(stableSince) >= 0.05) || Date() >= deadline {
                done(())
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015, execute: poll)
        }
        poll()
    }

    // 主线程：等当前输入源变成英文键盘布局，到期还不是就放弃（skip 为 true 时不用等，例如 ⌘X 只按退格）
    private func waitForASCIIInputSource(unless skip: Bool, deadline: Date, then action: @escaping (Bool) -> Void) {
        if skip || InputSourceState.isSettledASCIIKeyboardLayout {
            action(true)
            return
        }
        if Date() >= deadline {
            action(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [self] in
            waitForASCIIInputSource(unless: skip, deadline: deadline, then: action)
        }
    }

    private func finishJob() {
        isTyping = false
        startNextIfIdle()
    }

    // 等修饰键全部松开；到期还按着就放弃（用户多半在按别的组合键，例如 ⌘Tab 切换器还开着）
    private func waitForModifiersReleased(deadline: Date, then action: @escaping (Bool) -> Void) {
        let held = CGEventSource.flagsState(.combinedSessionState).intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate])
        if held.isEmpty {
            action(true)
            return
        }
        if Date() >= deadline {
            action(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [self] in
            waitForModifiersReleased(deadline: deadline, then: action)
        }
    }

    // bracketed paste 的结束标记：ESC 用真正的 esc 键（文字事件里的 ESC 会被有的终端改写或丢掉）
    private static func bracketedPasteEnd(limit: Int) -> [Chunk] {
        [.escape] + chunks(of: "[201~", limit: limit)
    }

    // 按字符（不拆开 emoji、组合字符）切成每块不超过 limit 个 UTF-16 单元（一个字符本身超过时单独成块），换行单独成块
    // newlineKey：换行按哪个键。终端里（bracketed paste 里面）换行按 ↩、Tab 按 ⇥，shell 把它们原样插入
    private static func chunks(of text: String, limit: Int, newlineKey: NewlineKey = .shiftReturn) -> [Chunk] {
        let terminal = newlineKey == .plainReturn
        var chunks: [Chunk] = []
        var current: [UniChar] = []
        var characters = 0
        func flush() {
            if !current.isEmpty {
                chunks.append(.text(units: current, characterCount: characters))
                current = []
                characters = 0
            }
        }
        for character in text {
            if character == "\n" {
                flush()
                switch newlineKey {
                case .shiftReturn:
                    chunks.append(.newline)
                case .commandReturn:
                    chunks.append(.commandReturn)
                case .plainReturn:
                    chunks.append(.plainReturn)
                }
                continue
            }
            if terminal, character == "\t" {
                flush()
                chunks.append(.tab)
                continue
            }
            let units = Array(String(character).utf16)
            if current.count + units.count > limit {
                flush()
            }
            current.append(contentsOf: units)
            characters += 1
        }
        flush()
        return chunks
    }

    // 在后台队列上依次发出按键事件，块与块之间稍作停顿，免得目标 App 的事件队列来不及处理而丢字。
    // 每块之前都确认焦点还在目标上、用户没有接着操作；返回实际发出去的块数。
    // closing：结尾的这几块（bracketed paste 的 ESC[201~）。中途放弃时如果焦点还在终端上，照样补发它们结束粘贴——
    // 否则 shell 会一直把之后的按键当成粘贴的内容。输入源已经不是英文时不能直接补发（文字会进输入法），
    // 把 unclosed 设为 true，由调用方先切到英文再补发
    private func post(_ chunks: [Chunk], for job: Job, inputSourceGeneration: Int, closing: Int = 0) -> Int {
        var unclosed = false
        return post(chunks, for: job, inputSourceGeneration: inputSourceGeneration, closing: closing, unclosed: &unclosed)
    }

    private func post(_ chunks: [Chunk], for job: Job, inputSourceGeneration: Int, closing: Int, unclosed: inout Bool) -> Int {
        let source = CGEventSource(stateID: .privateState)
        var completed = 0
        for (index, chunk) in chunks.enumerated() {
            // 中途切换了输入法（快捷键、工具切换、焦点进出密码框）：接下来的字符可能被输入法拿去。
            // 打开了 "Don't Type When Keystrokes Are Watched"、途中有程序装上了能看到按键的 tap：停下（tap 清单缓存 1 秒）
            let watchers = job.isCut ? nil : keystrokeWatchersBlockingTyping(into: job.target.pid, fresh: true)
            if watchers != nil {
                watchersStoppedTyping = watchers
            }
            // 用户接着操作了（包括只按修饰键：连按两下 ⌥ 呼出的输入框、⌘ 切换器）、按了回车。焦点检查要和目标 App 来回通信、
            // 可能要好一阵：发出去之前最后再看一眼
            let interrupted = { userActedSince(job.keyTime) || modifierPressedSince(self.typingStartedAt) || TypingInterrupt.returnWasPressed }
            if interrupted() || !Self.focusMatches(job) || InputSourceState.changeGeneration != inputSourceGeneration
                || watchers != nil || sessionIsLockedNow() || interrupted() {
                if closing > 0, index > 0, index < chunks.count, Self.focusMatches(job) {
                    let ascii = InputSourceState.changeGeneration == inputSourceGeneration
                        || DispatchQueue.main.sync { InputSourceState.isASCIIKeyboardLayoutActive }
                    if ascii {
                        for tail in chunks[max(index, chunks.count - closing)...] {
                            emit(tail, source: source, to: job.target.pid)
                            usleep(2_000)
                        }
                    } else {
                        unclosed = true
                    }
                }
                return completed
            }
            emit(chunk, source: source, to: job.target.pid)
            completed += 1
            InputActivity.noteInput()
            usleep(job.perCharacter ? 20_000 : 2_000)
        }
        return completed
    }

    // pid：键入的目标 App。打开 "Type Privately" 时直接发给它（CGEventPostToPid：只经过专门盯着这个 App 的 tap，全系统的键盘 tap
    // 看不到）；否则发在带注解的会话层（之后的 tap 都看得到）
    private func emit(_ chunk: Chunk, source: CGEventSource?, to pid: pid_t) {
        for keyDown in [true, false] {
            let keyCode: CGKeyCode
            switch chunk {
            case .text:
                keyCode = 0
            case .newline, .commandReturn, .plainReturn:
                keyCode = CGKeyCode(kVK_Return)
            case .tab:
                keyCode = CGKeyCode(kVK_Tab)
            case .escape:
                keyCode = CGKeyCode(kVK_Escape)
            case .deleteBackward:
                keyCode = CGKeyCode(kVK_Delete)
            }
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
                continue
            }
            switch chunk {
            case .text(let units, _):
                // 清掉所有修饰键：残留的 ⇧/⌘ 会让字符变样或变成快捷键
                event.flags = []
                units.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
            case .newline:
                event.flags = .maskShift
            case .commandReturn:
                event.flags = .maskCommand
            case .plainReturn, .tab, .escape, .deleteBackward:
                event.flags = []
            }
            // 不打标记：发在带注解的会话层或者直接发给目标 App，Copi 的按键拦截器（会话层）都看不到它，用不着
            if Defaults[.typePrivately] {
                event.postToPid(pid)
            } else {
                event.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    // 后台队列：在虚拟机、远程桌面里逐个按键。它们按 flagsChanged 事件判断 ⇧ 有没有按着（只在按键事件上带 ⇧ 标记不够），
    // 所以真的按下、松开 ⇧ 键，并且 ⇧ 前后、按键之间稍作停顿（太快会丢键或者被当成按住不放、自动重复）。返回按下的键数
    private func pressKeys(_ strokes: [KeyStroke], for job: Job) -> Int {
        let source = CGEventSource(stateID: .privateState)
        // 左 ⇧ 的设备位（NX_DEVICELSHIFTKEYMASK）：有的客户端按它判断是按下还是松开
        let shiftFlags = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x2)
        func emit(_ event: CGEvent?) {
            guard let event else {
                return
            }
            event.setIntegerValueField(.eventSourceUserData, value: copiSyntheticEventMarker)
            // 发到会话层（不是带注解的那一层）：虚拟机可能在会话层截取键盘
            event.post(tap: .cgSessionEventTap)
        }
        var shiftDown = false
        func setShift(_ down: Bool) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Shift), keyDown: down)
            event?.type = .flagsChanged
            event?.flags = down ? shiftFlags : []
            emit(event)
            shiftDown = down
        }
        // 不管怎么结束都要松开 ⇧，否则客户机里 ⇧ 会一直按着
        defer {
            if shiftDown {
                usleep(30_000)
                setShift(false)
            }
        }
        var completed = 0
        for stroke in strokes {
            let watchers = keystrokeWatchersBlockingTyping(into: job.target.pid, postedAt: .cgSessionEventTap, fresh: true)
            if watchers != nil {
                watchersStoppedTyping = watchers
            }
            if userActedSince(job.keyTime) || modifierPressedSince(typingStartedAt) || !Self.focusMatches(job) || watchers != nil
                || TypingInterrupt.returnWasPressed || sessionIsLockedNow() {
                return completed
            }
            if stroke.shift != shiftDown {
                usleep(50_000)
                setShift(stroke.shift)
                usleep(50_000)
                // 按 ⇧ 前后各等了 50 毫秒：这期间用户可能点到了别处
                if userActedSince(job.keyTime) || modifierPressedSince(typingStartedAt) || TypingInterrupt.returnWasPressed
                    || !Self.focusMatches(job) {
                    return completed
                }
            }
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: stroke.keyCode, keyDown: keyDown)
                event?.flags = shiftDown ? shiftFlags : []
                // 同时带上字符：用 Unicode 方式转发键盘的客户端（Windows App 的 Unicode 模式等）认这个
                var units = Array(stroke.character.utf16)
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
                emit(event)
                usleep(keyDown ? 12_000 : 30_000)
            }
            completed += 1
            InputActivity.noteInput()
        }
        return completed
    }

    // 系统报告的键盘焦点是否仍是这个输入框（任意线程可用）。不用 NSWorkspace：Spotlight 这类浮动面板拿着焦点时，
    // 前台 App 是下面那个。只在有明确证据（换了进程、换了元素）时才算不是；读不到时稍后重试一次。
    private static func focusMatches(_ job: Job) -> Bool {
        for attempt in 0..<2 {
            if attempt > 0 {
                usleep(30_000)
            }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                continue
            }
            let focused = value as! AXUIElement
            var focusedPID: pid_t = 0
            guard AXUIElementGetPid(focused, &focusedPID) == .success, focusedPID == job.target.pid else {
                return false
            }
            if CFEqual(focused, job.target.element) {
                return true
            }
            // 分格验证码：焦点自动跳到了同一进程里的下一个单行输入框
            if job.perCharacter {
                var role: CFTypeRef?
                return AXUIElementCopyAttributeValue(focused, kAXRoleAttribute as CFString, &role) == .success
                    && (role as? String) == kAXTextFieldRole
            }
            return false
        }
        return false
    }

}

// 当前输入源是不是 ASCII 键盘布局（ABC、U.S. 等）。是拼音、日文这类输入法时，模拟键入的字符会被输入法拿去组字，
// 而且会先经过输入法进程——这本身就是一种暴露。不在后台临时切换输入法：切回中日韩输入法时菜单栏变了、App 实际的输入却常常没变，
// 切过去也要过一会儿才在目标 App 里生效，期间键入的字符照样进了输入法。
// TIS 接口只能在主线程调用。
enum InputSourceState {
    // 最近一次切换输入源的时间：刚切换时系统记录的输入源已经变了，目标 App 却可能还在用原来的
    private static var lastChangeAt = Date.distantPast
    private static let generationLock = NSLock()
    private static var generation = 0

    static func noteChange() {
        dispatchPrecondition(condition: .onQueue(.main))
        lastChangeAt = Date()
        generationLock.lock()
        generation += 1
        generationLock.unlock()
    }

    // 每切换一次输入源加一（任意线程可读）：键入途中据此发现输入源变了
    static var changeGeneration: Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return generation
    }

    // 刚切换完、还没在目标 App 里生效的也算（键入前由 isSettledASCIIKeyboardLayout 再等一等）
    static var isASCIIKeyboardLayoutActive: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let typePointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType),
              let asciiPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsASCIICapable) else {
            return false
        }
        let type = Unmanaged<CFString>.fromOpaque(typePointer).takeUnretainedValue() as String
        let isASCIICapable = CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(asciiPointer).takeUnretainedValue())
        return type == (kTISTypeKeyboardLayout as String) && isASCIICapable
    }

    // 现在能不能键入：是英文键盘布局，或者可以临时切过去（见 InputSourceSwitcher）
    static var canTypeNow: Bool {
        isASCIIKeyboardLayoutActive || InputSourceSwitcher.shared.isEnabled
    }

    // 是英文键盘布局，并且已经切换过来一会儿了
    static var isSettledASCIIKeyboardLayout: Bool {
        Date().timeIntervalSince(lastChangeAt) > 0.25 && isASCIIKeyboardLayoutActive
    }

    // 当前输入源的名字（例如"简体拼音"），用在提示里
    static var currentName: String? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let namePointer = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(namePointer).takeUnretainedValue() as String
    }
}

// MARK: - 临时切换到英文输入源

// 拼音等输入法开着时，模拟键入的字符会被输入法拿去组字（也会先经过输入法进程）。键入前临时切到英文键盘布局（ABC 等），打完切回去：
//  - 切过去：从后台程序选中英文布局一向可靠，但要过一会儿才在目标 App 里生效——等系统报告切换完成后再稍等一下才打字；
//  - 切回来：从后台程序直接选中中日韩输入法有个老问题（菜单栏变了、App 实际的输入却没变，直到切换焦点）。所以优先模拟系统的
//    "选择上一个输入源"快捷键（默认 ⌃空格），和用户自己按快捷键走同一条路；它关掉了就按"下一个输入源"快捷键轮过去，
//    两个都关掉了才直接选中（并提示用户）。每一步都确认结果。
// TIS 接口只能在主线程调用。
final class InputSourceSwitcher {
    static let shared = InputSourceSwitcher()

    struct Switch {
        let original: TISInputSource
        let originalID: String
        let targetID: String
        // 原来的是中日韩这类输入法（不是键盘布局）：只能用快捷键切回去
        let originalIsInputMethod: Bool
    }

    // 系统报告切换完成并稳定之后，再等这么久才开始打字
    private let settleDelay: TimeInterval = 0.2
    // 发快捷键用的后台队列（按键之间要停顿，不能卡主线程）
    private let hotKeyQueue = DispatchQueue(label: "Copi.InputSourceHotKey", qos: .userInteractive)

    // 主线程：开着这个功能，并且有可以切过去的英文键盘布局。切回中日韩输入法优先用系统的输入源快捷键，都关掉了也能切（见 restore）
    var isEnabled: Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        return Defaults[.switchInputSourceForTyping] && asciiTarget() != nil
    }

    // 为什么不能切（给提示用）；能切时为 nil
    var unavailableReason: String? {
        dispatchPrecondition(condition: .onQueue(.main))
        guard Defaults[.switchInputSourceForTyping] else {
            return "Switch to ABC or U.S. and press ⌘V again, or turn on \"Switch to ABC While Typing\" in Copi."
        }
        guard asciiTarget() != nil else {
            return "Add the ABC or U.S. keyboard in System Settings › Keyboard › Input Sources so Copi can switch to it."
        }
        return nil
    }

    // 主线程：切到英文键盘布局，等它生效后回调；切不过去时回调 nil
    func switchToASCII(then completion: @escaping (Switch?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        let isInputMethod = Self.currentIsInputMethod
        guard let original = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), let originalID = Self.sourceID(of: original),
              let target = asciiTarget(), let targetID = Self.sourceID(of: target) else {
            completion(nil)
            return
        }
        let generationBefore = InputSourceState.changeGeneration
        guard TISSelectInputSource(target) == noErr else {
            completion(nil)
            return
        }
        let switched = Switch(original: original, originalID: originalID, targetID: targetID, originalIsInputMethod: isInputMethod)
        // 等系统报告的输入源变成目标、并稳定 30 毫秒，也等 Copi 自己收到切换通知（不然键入途中才到的通知会被当成又切换了）
        let deadline = Date().addingTimeInterval(0.3)
        var stableSince: Date?
        func poll() {
            if Self.currentSourceID() == targetID {
                stableSince = stableSince ?? Date()
            } else {
                stableSince = nil
            }
            let stable = stableSince.map { Date().timeIntervalSince($0) >= 0.03 } ?? false
            if stable, InputSourceState.changeGeneration != generationBefore {
                DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                    completion(switched)
                }
                return
            }
            guard Date() < deadline else {
                // 系统报告已经切过去了、只是没收到通知：照样可以打
                if stable {
                    DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                        completion(switched)
                    }
                } else {
                    restore(switched, consumed: { $0(()) }) {
                        completion(nil)
                    }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        poll()
    }

    // 主线程：等目标 App 处理完打进去的字（consumed 回调 done 的时候），再切回原来的输入源
    func restore(_ switched: Switch, directly: Bool = false, consumed: @escaping (@escaping (()) -> Void) -> Void,
                 then completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        consumed { [self] _ in
            // 用户这期间自己换了输入源：不动
            guard Self.currentSourceID() == switched.targetID else {
                completion()
                return
            }
            guard switched.originalIsInputMethod, !directly else {
                // 原来是别的键盘布局（俄文等）：直接选回去就行
                TISSelectInputSource(switched.original)
                completion()
                return
            }
            restoreWithHotKey(switched, attempt: 0, completion: completion)
        }
    }

    // 模拟"选择上一个输入源"快捷键切回去，确认系统报告的输入源变回原来的并稳定 80 毫秒；没变就再按一次；
    // 变成了别的输入源（"上一个"不是它）就先选回原来的、再选英文、再按快捷键；最后才直接选中（App 里可能还是英文）。
    // 这个快捷键关掉了（常和编辑器的 ⌃空格 冲突）就用"下一个输入源"快捷键一个个切过去
    private func restoreWithHotKey(_ switched: Switch, attempt: Int, completion: @escaping () -> Void) {
        // 用户还按着修饰键（粘贴后紧接着按 ⌘S、⇧↩……）：等松开再按快捷键，否则组合出来的是别的快捷键
        let hadToWait = Self.modifiersHeld
        waitForModifiersReleased(deadline: Date().addingTimeInterval(2)) { [self] released in
            // 等的时候用户自己换了输入源（⌃空格 本身就要按着 ⌃）：不再动
            if hadToWait, Self.currentSourceID() != switched.targetID {
                completion()
                return
            }
            guard released else {
                selectDirectly(switched, completion: completion)
                return
            }
            pressPreviousSourceHotKey(switched, attempt: attempt, completion: completion)
        }
    }

    private func pressPreviousSourceHotKey(_ switched: Switch, attempt: Int, completion: @escaping () -> Void) {
        guard let hotKey = previousSourceHotKey() else {
            if let next = nextSourceHotKey() {
                restoreByCycling(switched, hotKey: next, pressesLeft: min(8, Self.selectableSourceCount()), completion: completion)
            } else {
                selectDirectly(switched, completion: completion)
            }
            return
        }
        hotKeyQueue.async { [self] in
            postHotKey(hotKey)
            DispatchQueue.main.async { [self] in
                waitForSource(switched.originalID, stableFor: 0.08, timeout: 0.36) { [self] restored in
                    if restored {
                        completion()
                        return
                    }
                    let current = Self.currentSourceID()
                    if attempt == 0, current == switched.targetID {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            self.restoreWithHotKey(switched, attempt: 1, completion: completion)
                        }
                    } else if attempt <= 1, current != switched.targetID, let target = asciiTarget() {
                        TISSelectInputSource(switched.original)
                        TISSelectInputSource(target)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.restoreWithHotKey(switched, attempt: 2, completion: completion)
                        }
                    } else {
                        TISSelectInputSource(switched.original)
                        notifyCopiNotice("Copi couldn't switch your input method back after typing. If typing stays in English, press your input-source shortcut.")
                        completion()
                    }
                }
            }
        }
    }

    // 按"下一个输入源"快捷键，每按一次确认输入源变了并稳定下来，直到回到原来的那个（最多把菜单里的输入源轮一遍）
    private func restoreByCycling(_ switched: Switch, hotKey: (keyCode: CGKeyCode, flags: CGEventFlags), pressesLeft: Int,
                                  completion: @escaping () -> Void) {
        guard pressesLeft > 0 else {
            selectDirectly(switched, completion: completion)
            return
        }
        guard !Self.modifiersHeld else {
            let expected = Self.currentSourceID()
            waitForModifiersReleased(deadline: Date().addingTimeInterval(2)) { [self] released in
                // 等的时候用户自己换了输入源：不再动
                if Self.currentSourceID() != expected {
                    completion()
                    return
                }
                if released {
                    restoreByCycling(switched, hotKey: hotKey, pressesLeft: pressesLeft, completion: completion)
                } else {
                    selectDirectly(switched, completion: completion)
                }
            }
            return
        }
        let before = Self.currentSourceID()
        hotKeyQueue.async { [self] in
            postHotKey(hotKey)
            DispatchQueue.main.async { [self] in
                waitForChange(from: before, stableFor: 0.08, timeout: 0.36) { [self] in
                    if Self.currentSourceID() == switched.originalID {
                        completion()
                    } else {
                        restoreByCycling(switched, hotKey: hotKey, pressesLeft: pressesLeft - 1, completion: completion)
                    }
                }
            }
        }
    }

    // 快捷键用不了（都关掉了、修饰键一直按着、轮了一圈也没回到原来的）：直接选中原来的输入法。系统菜单栏会变回去，
    // 但这个窗口里可能还是英文，直到焦点变化——告诉用户
    private func selectDirectly(_ switched: Switch, completion: @escaping () -> Void) {
        TISSelectInputSource(switched.original)
        if previousSourceHotKey() == nil, nextSourceHotKey() == nil {
            notifyCopiNotice("Copi switched your input method back after typing, but macOS may keep typing English in this window until you click elsewhere. Turn on \"Select the previous input source\" in System Settings › Keyboard › Keyboard Shortcuts › Input Sources to avoid this.")
        } else {
            notifyCopiNotice("Copi couldn't switch your input method back after typing. If typing stays in English, press your input-source shortcut.")
        }
        completion()
    }

    // 主线程：等修饰键全部松开；到期还按着时回调 false
    private func waitForModifiersReleased(deadline: Date, then action: @escaping (Bool) -> Void) {
        if !Self.modifiersHeld {
            action(true)
            return
        }
        guard Date() < deadline else {
            action(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [self] in
            waitForModifiersReleased(deadline: deadline, then: action)
        }
    }

    // 等系统报告的输入源变成别的并稳定下来（或者超时）
    private func waitForChange(from id: String?, stableFor: TimeInterval, timeout: TimeInterval, then completion: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var stableSince: Date?
        var last = id
        func poll() {
            let current = Self.currentSourceID()
            if current != id, current == last {
                stableSince = stableSince ?? Date()
                if Date().timeIntervalSince(stableSince!) >= stableFor {
                    completion()
                    return
                }
            } else {
                stableSince = nil
            }
            last = current
            guard Date() < deadline else {
                completion()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        poll()
    }

    // 输入法菜单里能选的输入源有几个（"下一个输入源"最多按这么多次就转一圈）
    private static func selectableSourceCount() -> Int {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsEnabled: true,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource]
        return max(2, list?.count ?? 2)
    }

    private func waitForSource(_ id: String, stableFor: TimeInterval, timeout: TimeInterval, then completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        var stableSince: Date?
        func poll() {
            if Self.currentSourceID() == id {
                stableSince = stableSince ?? Date()
                if Date().timeIntervalSince(stableSince!) >= stableFor {
                    completion(true)
                    return
                }
            } else {
                stableSince = nil
            }
            guard Date() < deadline else {
                completion(false)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
        }
        poll()
    }

    // 可以选中的英文键盘布局：优先系统记住的那个英文布局（大写锁定键切换的也是它），其次 ABC、U.S.
    private func asciiTarget() -> TISInputSource? {
        let filter: [CFString: Any] = [
            kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceType: kTISTypeKeyboardLayout as Any,
            kTISPropertyInputSourceIsASCIICapable: true,
            kTISPropertyInputSourceIsEnabled: true,
            kTISPropertyInputSourceIsSelectCapable: true,
        ]
        guard let list = TISCreateInputSourceList(filter as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource],
              !list.isEmpty else {
            return nil
        }
        var preferredIDs = ["com.apple.keylayout.ABC", "com.apple.keylayout.US"]
        if let remembered = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(), let id = Self.sourceID(of: remembered) {
            preferredIDs.insert(id, at: 0)
        }
        for id in preferredIDs {
            if let match = list.first(where: { Self.sourceID(of: $0) == id }) {
                return match
            }
        }
        return list.first
    }

    private static func sourceID(of source: TISInputSource) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }

    private static func currentSourceID() -> String? {
        TISCopyCurrentKeyboardInputSource().map { sourceID(of: $0.takeRetainedValue()) } ?? nil
    }

    // 当前是输入法（拼音、日文……），不是键盘布局
    private static var currentIsInputMethod: Bool {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let typePointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else {
            return false
        }
        let type = Unmanaged<CFString>.fromOpaque(typePointer).takeUnretainedValue() as String
        return type != (kTISTypeKeyboardLayout as String)
    }

    private static var modifiersHeld: Bool {
        !CGEventSource.flagsState(.hidSystemState).intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand, .maskSecondaryFn]).isEmpty
    }

    // 系统设置里"选择上一个输入源"快捷键（AppleSymbolicHotKeys 里的 60 号）
    private func previousSourceHotKey() -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        inputSourceHotKey("60")
    }

    // "选择输入法菜单中的下一个输入源"（61 号）
    private func nextSourceHotKey() -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        inputSourceHotKey("61")
    }

    // 关掉了、没有设置过、带着不认识的修饰键时为 nil
    private func inputSourceHotKey(_ id: String) -> (keyCode: CGKeyCode, flags: CGEventFlags)? {
        guard let hotKeys = UserDefaults.standard.persistentDomain(forName: "com.apple.symbolichotkeys")?["AppleSymbolicHotKeys"] as? [String: Any],
              let entry = hotKeys[id] as? [String: Any], (entry["enabled"] as? NSNumber)?.boolValue == true,
              let value = entry["value"] as? [String: Any], let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else {
            return nil
        }
        // parameters：[字符, 键码, 修饰键]，修饰键的各位和 CGEventFlags 一样（⇧ 0x20000、⌃ 0x40000、⌥ 0x80000、⌘ 0x100000、fn 0x800000）
        let keyCode = parameters[1].intValue
        let rawModifiers = parameters[2].uint64Value
        let known: UInt64 = 0x20000 | 0x40000 | 0x80000 | 0x100000 | 0x800000
        let flags = CGEventFlags(rawValue: rawModifiers)
        guard keyCode >= 0, keyCode < 128, rawModifiers & ~known == 0,
              !flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty else {
            return nil
        }
        return (CGKeyCode(keyCode), flags)
    }

    // 像用户按下快捷键一样，在硬件层发出：逐个按下修饰键（flagsChanged），按下、松开主键，再倒序松开修饰键；按键之间稍作停顿。
    // 只发系统快捷键能匹配上的层级（HID），发到更上层的话 ⌃空格 会直接交给 App（VS Code 的补全、终端里的 ^@）
    private func postHotKey(_ hotKey: (keyCode: CGKeyCode, flags: CGEventFlags)) {
        let source = CGEventSource(stateID: .hidSystemState)
        let modifierKeys: [(CGEventFlags, CGKeyCode)] = [
            (.maskControl, CGKeyCode(kVK_Control)), (.maskAlternate, CGKeyCode(kVK_Option)), (.maskShift, CGKeyCode(kVK_Shift)),
            (.maskCommand, CGKeyCode(kVK_Command)), (.maskSecondaryFn, CGKeyCode(kVK_Function)),
        ].filter { hotKey.flags.contains($0.0) }
        func post(_ event: CGEvent?) {
            guard let event else {
                return
            }
            event.setIntegerValueField(.eventSourceUserData, value: copiSyntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
        var flags = CGEventFlags()
        for (flag, keyCode) in modifierKeys {
            flags.insert(flag)
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
            event?.type = .flagsChanged
            event?.flags = flags
            post(event)
            usleep(8_000)
        }
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: hotKey.keyCode, keyDown: keyDown)
            event?.flags = flags
            post(event)
            usleep(keyDown ? 15_000 : 8_000)
        }
        for (flag, keyCode) in modifierKeys.reversed() {
            flags.remove(flag)
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
            event?.type = .flagsChanged
            event?.flags = flags
            post(event)
            usleep(5_000)
        }
    }
}

// MARK: - 打开 Chrome / Electron / Firefox 的无障碍树

// Chromium 和 Firefox 只在有辅助程序问起时才构建网页的无障碍树（读一次 App 的角色就会开启，之后整个进程都保持开启），
// 而且是异步构建的——等用户按 ⌘C/⌘V 时才问就来不及了。所以在 App 被激活时就提前问一次。
// 只读角色，不写 AXEnhancedUserInterface / AXManualAccessibility：那两个会让 VS Code 之类进入"屏幕阅读器模式"、拖慢窗口动画。
final class WebAccessibilityWarmer {
    static let shared = WebAccessibilityWarmer()

    private let queue = DispatchQueue(label: "Copi.AccessibilityWarmer", qos: .utility)
    private var warmedPIDs = Set<pid_t>()
    private var observer: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?

    func start() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard observer == nil else {
            return
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                WebAccessibilityWarmer.shared.warm(app)
                // iTerm2、Ghostty：提前在后台查好 Copi 能不能用它们的脚本接口（粘贴时只读缓存）
                if TerminalScript(bundleIdentifier: app.bundleIdentifier) != nil {
                    TerminalScript.refreshPermission(pid: app.processIdentifier)
                }
            }
        }
        // 进程号会被复用：App 退出后把它的记录清掉
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { notification in
            if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                WebAccessibilityWarmer.shared.warmedPIDs.remove(app.processIdentifier)
                forgetAppEngineCache(pid: app.processIdentifier)
                TerminalScript.forget(pid: app.processIdentifier)
            }
        }
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            warm(frontmost)
        }
    }

    private func warm(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard Defaults[.isOn], Defaults[.enableWebAccessibility], AXIsProcessTrusted(), pid != getpid(), !warmedPIDs.contains(pid) else {
            return
        }
        warmedPIDs.insert(pid)
        queue.async {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.1)
            // 有的 Chrome 版本只在网页视图自己被问起角色时才打开网页部分的无障碍树
            requestWebAccessibility(application)
            var role: CFTypeRef?
            var focused: CFTypeRef?
            if AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
               let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let focusedElement = focused as! AXUIElement
                AXUIElementSetMessagingTimeout(focusedElement, 0.1)
                AXUIElementCopyAttributeValue(focusedElement, kAXRoleAttribute as CFString, &role)
            }
        }
    }
}

// MARK: - 通知

private let noticeLock = NSLock()
private var lastNoticeDates: [String: Date] = [:]

// 拒绝复制/粘贴的通知上带一个按钮："这个 App 照常使用系统剪贴板"（见 AppDelegate 里的处理）
enum CopiNotificationAction {
    static let refusedCategory = "copi.refused"
    static let useNormalClipboard = "copi.useNormalClipboard"
    static let bundleIDKey = "bundleID"
    static let appNameKey = "appName"

    static func register() {
        let action = UNNotificationAction(identifier: useNormalClipboard, title: "Use Normal Clipboard in This App", options: [])
        let category = UNNotificationCategory(identifier: refusedCategory, actions: [action], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

// 被拒绝的那个 App
struct RefusedApp {
    let bundleID: String?
    let name: String
    let pid: pid_t?
    // 焦点在终端画面上（终端的脚本接口只用在这里）
    let onTerminalSurface: Bool

    // 焦点所在的 App（拿不到焦点控件时退回系统报告的焦点 App）
    init(target: FocusedTarget?) {
        if let target {
            bundleID = target.bundleIdentifier
            name = target.applicationName
            pid = target.pid
            onTerminalSurface = target.isTerminalApp && target.role == kAXTextAreaRole && target.isTerminalSurface
        } else {
            let focused = focusedApplication()
            bundleID = focused?.bundleIdentifier
            name = focused?.localizedName ?? "this app"
            pid = focused?.processIdentifier
            onTerminalSurface = false
        }
    }

    // 怎样才能在这里不经过剪贴板复制粘贴：VS Code 系编辑器还没装（或还没连上、装的是旧版本）Copi 的桥接扩展时，提示去装；
    // iTerm2、Ghostty 还没允许 Copi 用脚本接口、而允许之后这次粘贴就能成功时，提示去允许（只对粘贴；复制用不上它）
    func hint(forPasteRefusal reason: UnavailableReason?) -> String {
        guard let pid else {
            return ""
        }
        if let bundleID, remoteDesktopBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) }) {
            switch reason {
            case .noRoute?, .remoteClipboard?:
                return Defaults[.typeIntoVirtualMachines] ? "" : " Turn on Type Into Virtual Machines in Copi's menu to paste single lines there by pressing keys."
            default:
                return ""
            }
        }
        if let terminal = TerminalScript(bundleIdentifier: bundleID) {
            guard let reason, onTerminalSurface,
                  TerminalScript.cachedPermission(pid: pid).map({ $0 != .allowed && $0 != .unsupported }) == true else {
                return ""
            }
            switch reason {
            case .inputMethod, .multiLine, .noRoute:
                if terminal == .kitty {
                    return " Turn on kitty's remote control for Copi (see Terminal Access in Copi's menu) to paste there directly, including multiple lines."
                }
                return terminal.usesAppleEvents
                    ? " Allow \(terminal.displayName) under Terminal Access in Copi's menu to paste there directly, including multiple lines."
                    : ""
            default:
                return ""
            }
        }
        guard isVSCodeFamilyApp(pid: pid), !EditorBridge.shared.isConnected(appPID: pid) else {
            return ""
        }
        if EditorBridge.shared.hasOutdatedConnection(appPID: pid) {
            return " Reinstall Copi Bridge for \(name) in Copi's menu to update it."
        }
        return " Install Copi Bridge for \(name) in Copi's menu to copy and paste there without the clipboard."
    }
}

func notifyCopiNotice(_ body: String, offering app: RefusedApp? = nil) {
    let now = Date()
    noticeLock.lock()
    if let last = lastNoticeDates[body], now.timeIntervalSince(last) < 3 {
        noticeLock.unlock()
        return
    }
    lastNoticeDates[body] = now
    noticeLock.unlock()
    let content = UNMutableNotificationContent()
    content.title = "Copi"
    content.body = body
    if let app, let bundleID = app.bundleID, !bundleID.isEmpty {
        content.categoryIdentifier = CopiNotificationAction.refusedCategory
        content.userInfo = [CopiNotificationAction.bundleIDKey: bundleID, CopiNotificationAction.appNameKey: app.name]
    }
    UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "copi.notice.\(body.hashValue)", content: content, trigger: nil))
}

// 主线程：异步的路线（终端的脚本接口）最后没能粘贴。允许剪贴板回退、焦点还在那里、用户也没有接着操作时，退回剪贴板方式；否则拒绝
func refuseOrFallBack(_ reason: UnavailableReason, text: String, target: FocusedTarget, keyTime: Date) {
    dispatchPrecondition(condition: .onQueue(.main))
    if !ZeroExposurePolicy.isStrict, reason.allowsClipboardFallback, !userActedSince(keyTime), focusedApplication()?.processIdentifier == target.pid {
        // 有会把本机剪贴板同步出去的 App 在运行：先提醒
        if let syncReason = remoteClipboardConfirmationBeforeFallback(text, targetPID: target.pid) {
            notifyPasteRefused(syncReason, app: RefusedApp(target: target))
            return
        }
        TransientPaste.shared.stage(text, restorePrevious: false, for: target.pid)
        postPasteKeystroke()
        return
    }
    notifyPasteRefused(reason, app: RefusedApp(target: target))
}

// macOS 26.4 起，"终端"在粘贴从网页浏览器复制来的内容时会先警告（防止网页骗用户粘贴、运行恶意命令）。它看的是系统剪贴板上内容的
// 写入者；Copi 不经过剪贴板粘贴，这道检查就被绕过了。所以在同样的场合由 Copi 拦一下：第一次 ⌘V 只提醒，8 秒内再按一次才粘贴
// 网页浏览器
let browserBundleIDPrefixes = [
    "com.apple.Safari", "com.google.Chrome", "org.chromium.", "org.mozilla.", "com.microsoft.edgemac", "com.brave.Browser",
    "company.thebrowser.", "com.operasoftware.", "com.vivaldi.", "com.kagi.kagimacOS", "com.duckduckgo.", "app.zen-browser.",
    "net.waterfox.", "io.gitlab.librewolf", "org.torproject.", "net.mullvad.", "one.ablaze.floorp", "ru.yandex.desktop.yandex-browser",
    "com.openai.atlas", "ai.perplexity.comet", "com.pushplaylabs.sidekick", "com.wavebox.",
]

// 从密码管理器复制的机密内容（密码、恢复码）要粘贴进地址栏、Spotlight、搜索框：这些地方边输入边把文字发给搜索服务（搜索建议），
// 粘贴下去就已经发出去了。多半是焦点没在用户以为的地方（例如还在地址栏里）：第一次只提醒，8 秒内再粘贴一次才粘贴
enum ConcealedDestinationGuard {
    // 主线程
    static var confirmation = PasteConfirmation()
    private static let launcherBundleIDs: Set<String> = ["com.apple.Spotlight", "com.raycast.macos", "com.runningwithcrayons.Alfred"]

    // 主线程：要提醒时返回 true（这一次不粘贴）
    static func needsConfirmation(_ text: String, concealed: Bool, into target: FocusedTarget) -> Bool {
        guard concealed, !target.isSecureTextField, !ZeroExposurePolicy.isPasswordManager(target.bundleIdentifier) else {
            return false
        }
        // 网址（密码管理器里复制的网站地址）照常粘贴
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            return false
        }
        let bundleID = target.bundleIdentifier ?? ""
        let role = target.role
        // 列出来的浏览器；没列出来、但用 Chromium、Gecko 内核的也可能是浏览器（新出的、改名的），只是 Electron App、Thunderbird
        // 这类不是：它们的输入框都在网页内容里，看不出层级时会被当成地址栏
        let isThunderbird = bundleID.hasPrefix("org.mozilla.thunderbird")
        let listed = !isThunderbird && browserBundleIDPrefixes.contains(where: { bundleID.hasPrefix($0) })
        let byEngine = !listed && !isThunderbird
            && ((isChromiumApp(pid: target.pid) && !isElectronApp(pid: target.pid)) || isGeckoApp(pid: target.pid, bundleIdentifier: target.bundleIdentifier))
        let fieldRole = role == kAXTextFieldRole || role == kAXComboBoxRole
        // 地址栏：浏览器自己界面上的输入框（不在网页内容里）。只按内核认出来的浏览器要一直找到窗口都没有网页内容才算
        let isAddressBar = fieldRole && ((listed && !target.hasWebAreaAncestor) || (byEngine && reachesWindowOutsideWebArea(target.element)))
        let isSearchField = copyAXAttribute(target.element, kAXSubroleAttribute) as? String == "AXSearchField"
        guard isAddressBar || isSearchField || launcherBundleIDs.contains(bundleID) else {
            return false
        }
        return confirmation.needsConfirmation(key: "\(target.pid)\u{0}\(text)")
    }
}

// 从 element 往上一直找到窗口，路上没有网页内容（找不到窗口、读不到上一层都不算）
private func reachesWindowOutsideWebArea(_ element: AXUIElement) -> Bool {
    var node: AXUIElement? = element
    for _ in 0..<64 {
        guard let current = node, let role = copyAXAttribute(current, kAXRoleAttribute) as? String else {
            return false
        }
        if role == "AXWebArea" {
            return false
        }
        if role == kAXWindowRole {
            return true
        }
        node = asAXElement(copyAXAttribute(current, kAXParentAttribute))
    }
    return false
}

// Electron App（带 Electron Framework）
private func isElectronApp(pid: pid_t) -> Bool {
    guard let url = NSRunningApplication(processIdentifier: pid)?.bundleURL else {
        return false
    }
    return FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
}

enum BrowserToTerminalGuard {
    // 主线程
    static var confirmation = PasteConfirmation()

    // 主线程：要提醒时返回来源 App 的名字（这一次不粘贴）；用户已经确认过、或者不需要提醒时返回 nil
    static func unconfirmedSource(of text: String, into target: FocusedTarget) -> String? {
        guard target.bundleIdentifier == "com.apple.Terminal",
              ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)),
              SecureClipboard.shared.text == text, let source = SecureClipboard.shared.source,
              browserBundleIDPrefixes.contains(where: { source.hasPrefix($0) }),
              confirmation.needsConfirmation(key: text) else {
            return nil
        }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source)
        return url.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") } ?? "a web browser"
    }
}

// 用户亲手发起的粘贴（⌘V 按下的那一下、菜单里的粘贴、Copi 的粘贴快捷键、Action Bar）最近一次的时刻。按住 ⌘V 不放产生的自动重复
// 不算：它不能当作"再粘贴一次"的确认。event tap 线程和主线程都会写
enum PastePress {
    private static let lock = NSLock()
    private static var lastDeliberate = Date.distantPast

    static func noteDeliberate(at time: Date) {
        lock.lock()
        lastDeliberate = max(lastDeliberate, time)
        lock.unlock()
    }

    static var lastDeliberateAt: Date {
        lock.lock()
        defer { lock.unlock() }
        return lastDeliberate
    }
}

// "8 秒内再粘贴一次确认"的提醒（主线程）。提醒之后用户亲手再粘贴一次才算确认；确认之后到期之前一直有效——同一次粘贴可能还要
// 过另一道提醒，不能因为那一道这次没过，这一道就又要从头来（异步的路线晚一点才回来，也一样）
struct PasteConfirmation {
    private var pending: (key: String, armedAt: Date, until: Date)?

    // 返回 true 表示这一次只提醒、不粘贴
    mutating func needsConfirmation(key: String) -> Bool {
        let now = Date()
        if let current = pending, current.key == key, now < current.until {
            guard PastePress.lastDeliberateAt > current.armedAt else {
                return true
            }
            // 确认过了：再保持 8 秒（另一道提醒这次没过时，用户读完它再粘贴，这一道不能已经过期又要从头来）
            pending = (key, current.armedAt, max(current.until, now.addingTimeInterval(8)))
            return false
        }
        pending = (key, now, now.addingTimeInterval(8))
        return true
    }
}

// 会把本机剪贴板同步出去的 App 在运行时，退回剪贴板方式之前的提醒（见 remoteClipboardConfirmationBeforeFallback）
enum RemoteClipboardGuard {
    // 主线程
    static var confirmation = PasteConfirmation()
}

// 粘贴进放行的 App 被拒绝时补一句（放行只让那个 App 自己复制的文字留在系统剪贴板上）
let normalClipboardPasteNote = " Text copied in other apps stays off the clipboard, even in apps that use the normal clipboard."

// suffix：追加在说明后面的话。粘贴被拒绝时不提供"这个 App 照常使用系统剪贴板"的按钮：放行只影响在那个 App 里的复制，帮不了这次粘贴
func notifyPasteRefused(_ reason: UnavailableReason, app: RefusedApp, suffix: String = "") {
    let name = app.name
    let body: String
    switch reason {
    case .noRoute:
        body = "\(name) has no way to paste without the system clipboard, so Copi pasted nothing."
    case .multiLine:
        body = "Copi can only paste single lines into \(name) without the system clipboard, so it pasted nothing."
    case .inputMethod:
        // 只有当前确实是输入法时才说出它的名字（刚切到 ABC 的那一瞬间不会走到这里）
        let inputMethod = InputSourceState.currentName.map { "\($0) is" } ?? "An input method is"
        let advice = InputSourceSwitcher.shared.unavailableReason ?? "Switch to ABC or U.S. and press ⌘V again."
        body = "Copi pastes into \(name) by typing, and \(inputMethod) active, which would change the text. " + advice
    case .modalProgram(let program?):
        body = "\(name) is running \(program), which could treat pasted text as commands, so Copi pasted nothing."
    case .modalProgram(nil):
        body = "Copi can't tell what is running in \(name), which could treat pasted text as commands, so it pasted nothing. Copi types into terminals only at a shell prompt."
    case .unsafeCharacters:
        body = "\(name) would auto-complete brackets, quotes or punctuation in this text, so Copi pasted nothing. Without the clipboard Copi can only paste letters, digits and simple symbols there."
    case .untypeableCharacters:
        body = "Copi pastes into \(name) by pressing keys, and some characters in this text have no single key on your keyboard layout, so it pasted nothing."
    case .capsLock:
        body = "Turn off Caps Lock and press ⌘V again: Copi pastes into \(name) by pressing keys, and Caps Lock would change the letters."
    case .viMode:
        body = "The shell in \(name) may be using vi key bindings, where pasted letters could act as commands, so Copi pasted nothing."
    case .concealedIntoSearch:
        body = "This looks like a password or secret from a password manager, and the focus in \(name) is in an address bar or search field, which can send what you paste to a search service right away. Paste again within 8 seconds to paste it there anyway."
    case .tmuxHooks(let hooks):
        body = "tmux has hooks that run when text is pasted (\(hooks.joined(separator: ", "))), which could save or send the text elsewhere, so Copi pasted nothing. Check `tmux show-hooks -g` and `tmux show-hooks -t <session>` if you didn't set them up."
    case .remoteClipboard(let apps):
        let names = ListFormatter.localizedString(byJoining: Array(apps.prefix(3)))
        body = "Copi would paste into \(name) through the clipboard, and \(names) can copy it to another computer's clipboard (and its clipboard history), where it stays after the paste. Paste again within 8 seconds to paste anyway."
    case .needsConfirmation(let source):
        body = "This text was copied from \(source). Commands copied from websites can harm your Mac, so check it first: paste again within 8 seconds to paste it into \(name)."
    case .keystrokesWatched(let watchers):
        let names = ListFormatter.localizedString(byJoining: Array(watchers.prefix(3)))
        body = "Copi would paste into \(name) by typing, and \(names) can see keystrokes, so it pasted nothing. Turn off Don't Type When Keystrokes Are Watched in Copi's menu to type anyway."
    }
    notifyCopiNotice(body + suffix + app.hint(forPasteRefusal: reason))
}

// 为什么拒绝了一次复制
enum CopyRefusal {
    // 选中了内容，但不借助系统剪贴板读不出来
    case unreadable
    // Copi 正忙（主线程卡住、上一次粘贴还没完成），这次按键作废了
    case busy
    // 没看到选中的文字（有的 App 这时会复制别的东西）
    case emptySelection
    // 选了不止一段，读得到的只有第一段
    case multipleSelections
}

func notifyCopyRefused(app: RefusedApp, cut: Bool, reason: CopyRefusal) {
    let verb = cut ? "cut" : "copied"
    let body: String
    switch reason {
    case .unreadable:
        body = "Copi can't read a selection in \(app.name) without the system clipboard, so nothing was \(verb)."
    case .busy:
        body = "Copi was busy and skipped this \(cut ? "⌘X" : "⌘C"), so nothing was \(verb). Try again in a moment."
    case .emptySelection:
        body = "Copi didn't see any selected text in \(app.name), so nothing was \(verb)."
    case .multipleSelections:
        body = "Copi can't \(cut ? "cut" : "copy") several selections at once without the system clipboard, so nothing was \(verb). Do them one at a time."
    }
    let suffix = " Copi also cleared its clipboard so a paste won't insert something older."
    if case .busy = reason {
        notifyCopiNotice(body + suffix)
    } else {
        notifyCopiNotice(body + suffix + app.hint(forPasteRefusal: nil), offering: app)
    }
}
