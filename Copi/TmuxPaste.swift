//
//  TmuxPaste.swift
//  Copi
//
//  终端里前台是 tmux 时：把文字交给 tmux，用它自己的 paste-buffer 粘贴进当前的 pane。tmux 直接写进 pane 的终端
//  （不经过剪贴板、不产生按键事件，能看到按键的程序看不到），并且和真正的粘贴一样：pane 里的程序打开了 bracketed paste 模式
//  才加标记（tmux 自己就是这个程序的终端，知道得最准），换行变成回车。
//   - 用 tmux 客户端自己的程序文件和它连着的 socket（从它的启动参数 -S / -L、环境变量 TMUX_TMPDIR 推出来），版本对得上；
//   - 先问 tmux 这个客户端当前的 pane 和它的终端设备（list-clients），再按 pane 里的前台程序决定能不能粘贴、送什么，
//     和别的终端一样（shell 提示符前、Vim 里单行……）；
//   - 文字只经过管道：load-buffer - 从标准输入读进一个随机名字的缓冲区，紧接着 paste-buffer -d 粘贴并删掉它。文字不出现在任何
//     进程的启动参数里，也不出现在 tmux 记录的命令里（show-messages）。设了会在这期间运行的钩子时不用这条路。
//  需要 tmux 3.1 以上（source-file 从标准输入读）。ssh 到别的机器上的 tmux 看不到，照旧拒绝。
//

import Foundation

enum TmuxPaste {
    enum Outcome {
        case sent
        // 肯定没粘贴（tmux 不对劲、连不上……）
        case failed
        // 交给 tmux 之后没等到它回话：可能已经（或稍后）粘贴了
        case unsure
        // 按规则不能粘贴（pane 里运行着把字母当命令的程序……）
        case refused(UnavailableReason)
        // 用户在这期间接着操作了
        case stale
    }

    // 前台进程组是不是一个 tmux 客户端
    static func isClient(_ group: [ForegroundProcess]) -> Bool {
        !group.isEmpty && group.allSatisfy { $0.name == "tmux" }
    }

    // 看不出焦点在终端的哪个标签页时：所有标签页的前台进程组只有一个、并且是 tmux 客户端，才知道粘贴给谁
    static func soleClient(in groups: [[ForegroundProcess]]?) -> ForegroundProcess? {
        guard let groups, groups.count == 1, isClient(groups[0]) else {
            return nil
        }
        return groups[0].first
    }

    // 主线程：在后台交给 tmux，结果用通知告诉用户
    static func pasteInBackground(_ text: String, client: ForegroundProcess, target: FocusedTarget, keyTime: Date) {
        DispatchQueue.global(qos: .userInitiated).async {
            report(paste(text, client: client, keyTime: keyTime), text: text, target: target, keyTime: keyTime)
        }
    }

    // 任意线程：在主线程上告诉用户结果；没能粘贴时照常拒绝（或者允许剪贴板回退时退回剪贴板）
    static func report(_ outcome: Outcome, text: String, target: FocusedTarget, keyTime: Date) {
        DispatchQueue.main.async {
            switch outcome {
            case .sent:
                notifyProtected("Pasted safely")
            case .stale:
                notifyCopiNotice("Copi didn't paste into \(RefusedApp(target: target).name) because you kept typing or clicked elsewhere. Press ⌘V again.")
            case .refused(let reason):
                refuseOrFallBack(reason, text: text, target: target, keyTime: keyTime)
            case .failed:
                refuseOrFallBack(.modalProgram("tmux"), text: text, target: target, keyTime: keyTime)
            case .unsure:
                // 可能已经粘贴了：不能再退回别的方式粘贴一遍
                notifyCopiNotice("Copi isn't sure the paste reached \(RefusedApp(target: target).name). Check the terminal before pasting again.")
            }
        }
    }

    // 后台线程：client 是终端里拿着焦点的那个标签页前台的 tmux 客户端
    static func paste(_ text: String, client: ForegroundProcess, keyTime: Date) -> Outcome {
        guard let binary = processExecutablePath(pid: client.pid), let socket = socketPath(ofClient: client.pid),
              let version = version(of: binary), !version.lexicographicallyPrecedes([3, 1]) else {
            return .failed
        }
        // 这个客户端当前的 pane：编号、终端设备、是不是在复制模式里（这时粘贴会落到程序里，不是用户以为的地方）、是不是关了输入；
        // 客户端是不是只读的（attach -r：它自己的粘贴到不了 pane）；pane 里的程序有没有打开 bracketed paste 模式（tmux 3.7 起才有，
        // 更早的版本是空的）
        guard case .output(let output) = run(binary, ["-S", socket, "list-clients", "-F",
                                                       "#{client_pid}\t#{pane_id}\t#{pane_tty}\t#{pane_in_mode}\t#{pane_input_off}\t#{client_readonly}\t#{bracket_paste_flag}"]),
              let row = output.split(separator: "\n").map({ $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) })
                .first(where: { $0.count == 7 && $0[0] == String(client.pid) }),
              row[1].hasPrefix("%"), row[2].hasPrefix("/dev/") else {
            return .failed
        }
        guard row[3] == "0", row[4] == "0", row[5] != "1", let group = foregroundGroup(ofTerminalDevice: row[2]) else {
            return .refused(.modalProgram("tmux"))
        }
        // 套着的 tmux（pane 里又开了一个）：不往里送
        if isClient(group) {
            return .refused(.modalProgram("tmux"))
        }
        let bracketFlag = row[6]
        // pane 里运行的不是 shell（Vim 之类）：只有 tmux 确认它打开了 bracketed paste 模式时才送。在 tmux 里 Vim 不一定会打开
        // （TERM 是 tmux/screen，macOS 自带的 terminfo 里没有相应的能力），没打开时粘贴的字母就是命令
        if !group.allSatisfy(isAtPrompt), bracketFlag != "1" {
            return .refused(.modalProgram(programName(in: group)))
        }
        let body: String
        switch TerminalScript.pasteLikePayload(for: text, foreground: group) {
        case .success(let value):
            body = value
        case .failure(let reason):
            return .refused(reason)
        }
        // tmux 确定没打开 bracketed paste 模式时，多行文字的换行就是回车
        if bracketFlag == "0", body.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return .refused(.multiLine)
        }
        // （tmux 3.7 以前的 paste-buffer 原样送出缓冲区：文字里夹着的 ESC[201~ 会提前结束 bracketed paste。pasteLikePayload 已经把
        // 换行、制表符以外的控制字符换成了可见的符号）
        let payload = body
        guard !payload.utf8.contains(0) else {
            return .refused(.noRoute)
        }
        // tmux 的钩子在存缓冲区、粘贴的命令之后当场运行（在删掉缓冲区之前），可以把缓冲区存到文件里、交给别的程序。
        // 设了这些钩子（多半是用户自己的配置，但也可能是别的程序加的）就不经过缓冲区
        let hooks = bufferHooks(binary: binary, socket: socket)
        guard let hooks else {
            return .failed
        }
        guard hooks.isEmpty else {
            return .refused(.tmuxHooks(hooks))
        }
        guard !userActedSince(keyTime) else {
            return .stale
        }
        let buffer = "copi-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        // 文字从标准输入读进缓冲区（load-buffer -），不放在命令里：tmux 3.2 起把执行过的每条命令连同参数记进服务器的消息记录，
        // 任何能连上它的程序都能用 show-messages 读出来，一直留到被后面的 1000 条命令挤掉。粘贴之后 -d 马上删掉缓冲区
        switch run(binary, ["-S", socket, "load-buffer", "-b", buffer, "-", ";", "paste-buffer", "-p", "-d", "-b", buffer, "-t", row[1]],
                   input: Data(payload.utf8)) {
        case .output:
            return .sent
        case .failed:
            // 读进来了却没粘贴成功时缓冲区还在：删掉（不存在时报错，不管它）
            _ = run(binary, ["-S", socket, "delete-buffer", "-b", buffer])
            return .failed
        case .timedOut:
            _ = run(binary, ["-S", socket, "delete-buffer", "-b", buffer])
            return .unsure
        }
    }

    // 会在 Copi 的缓冲区还在的时候运行的钩子：设了的名字；问不到时为 nil。这几个钩子都是会话一级的（-w、-p 设的也存在会话上），
    // load-buffer 不带目标，它的钩子在"最近活动的会话"上找，不一定是 pane 所在的那个：全局的和每个会话的都要看
    private static func bufferHooks(binary: String, socket: String) -> [String]? {
        let watched: Set<String> = ["after-load-buffer", "after-paste-buffer", "after-delete-buffer", "after-set-buffer", "command-error"]
        guard case .output(let sessions) = run(binary, ["-S", socket, "list-sessions", "-F", "#{session_id}"]) else {
            return nil
        }
        var arguments = ["-S", socket, "show-hooks", "-g"]
        for session in sessions.split(separator: "\n") where session.hasPrefix("$") {
            arguments += [";", "show-hooks", "-t", String(session)]
        }
        guard case .output(let output) = run(binary, arguments) else {
            return nil
        }
        // 每行 "名字[序号] 命令"；没设的只有名字
        var found: Set<String> = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespaces).isEmpty else {
                continue
            }
            let name = String(parts[0].prefix { $0 != "[" })
            if watched.contains(name) {
                found.insert(name)
            }
        }
        return found.sorted()
    }

    // 客户端连着的 socket：启动参数里的 -S 路径，或者 -L 名字（默认 "default"）放在 TMUX_TMPDIR（默认 /tmp）下的 tmux-<uid> 里。
    // 只认当前用户自己的 socket
    private static func socketPath(ofClient pid: pid_t) -> String? {
        guard let arguments = processArguments(pid: pid) else {
            return nil
        }
        var label = "default"
        var explicitPath: String?
        var index = 1
        // 全局选项在命令之前；带参数的有 -c -f -L -S -T
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("-"), argument.count > 1, argument != "--" else {
                break
            }
            let flags = Array(argument.dropFirst())
            var consumedNext = false
            for (position, flag) in flags.enumerated() where "cfLST".contains(flag) {
                let attached = String(flags[(position + 1)...])
                let value = attached.isEmpty ? (index + 1 < arguments.count ? arguments[index + 1] : nil) : attached
                consumedNext = attached.isEmpty
                if flag == "S" {
                    explicitPath = value
                } else if flag == "L", let value {
                    label = value
                }
                break
            }
            index += consumedNext ? 2 : 1
        }
        let path: String
        if let explicitPath {
            path = explicitPath
        } else {
            let base = processEnvironment(pid: pid)?["TMUX_TMPDIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "/tmp"
            let resolved = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
            path = "\(resolved)/tmux-\(getuid())/\(label)"
        }
        var info = stat()
        guard path.hasPrefix("/"), lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == getuid() else {
            return nil
        }
        return path
    }

    // "tmux 3.4"、"tmux 3.3a"、"tmux next-3.6" → [3, 4]
    private static func version(of binary: String) -> [Int]? {
        guard case .output(let output) = run(binary, ["-V"]),
              let range = output.range(of: #"(\d+)\.(\d+)"#, options: .regularExpression) else {
            return nil
        }
        return output[range].split(separator: ".").compactMap { Int($0) }
    }

    private enum RunResult {
        case output(String)
        case failed
        // 1.5 秒还没完，结束了它（tmux 被结束时退出码也是 0，要单独认出来）
        case timedOut
    }

    // 运行 tmux（干净的环境，不继承 TMUX 之类）。程序文件来自 tmux 客户端进程，可能被换掉：用 HelperProcess，不带着 Copi 的权限运行
    private static func run(_ binary: String, _ arguments: [String], input: Data? = nil) -> RunResult {
        switch HelperProcess.run(binary, arguments, environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8"],
                                 input: input, timeout: 1.5) {
        case .output(let data):
            return .output(String(decoding: data, as: UTF8.self))
        case .failed:
            return .failed
        case .timedOut:
            return .timedOut
        }
    }
}

// 进程的启动参数（argv，只能读同一用户的进程）；读不到时为 nil
func processArguments(pid: pid_t) -> [String]? {
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
    // 布局：argc、程序路径、补齐用的 0、各个参数（都以 0 结尾）、环境变量
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
    var arguments: [String] = []
    while arguments.count < argumentCount, index < size {
        let start = index
        while index < size, buffer[index] != 0 {
            index += 1
        }
        arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
        index += 1
    }
    return arguments.count == argumentCount ? arguments : nil
}
