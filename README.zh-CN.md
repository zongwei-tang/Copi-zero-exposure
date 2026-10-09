<div align="center">
    <img src="Stuff/AppIcon-readme.png" width="200" height="200">

# Copi
**macOS 系统剪贴板的安全替代品**

[English](./README.md) · **简体中文**
  
<!-- SHIELD GROUP -->
[![](https://img.shields.io/badge/SwiftUI-brightgreen)]() [![](https://img.shields.io/badge/macOS-blue)]()

</div>

> [!NOTE]
> **这是 [s1ntoneli/Copi](https://github.com/s1ntoneli/Copi)（作者 Sintone，MIT 许可）的 fork。** 默认绝不把复制的文字放到系统剪贴板上（做不到就拒绝），别的 App 放到剪贴板上的文字几毫秒内收进 Copi，往终端、编辑器里粘贴走它们自己的接口，还加了下文说的各项保护。没有联网和自动更新的代码。原项目 Releases 页面上的 App 不包含这些改动。

[Copi](https://copi.cleanclip.cc) 是一款开源、轻量且安全的 macOS 系统剪贴板替代工具。它接管文字的复制粘贴，复制的内容放在任何其他应用程序都读不到的地方，有效保护您的隐私数据。只保管纯文字（格式会丢掉）。


## 为何需要 Copi?

1. 防御剪贴板替换攻击
2. 防止剪贴板内容泄漏

## 谁要用？

如果你：
1. 是数字货币拥有者
2. 经常复制敏感信息
3. 不信任系统剪贴板

## 如何使用？

### 1. 快捷操作栏模式
开启 Action Bar 显示后，选中文字时，文字上方会显示用于安全复制、粘贴的快捷按钮。鼠标点击即可使用 Copi 剪贴板进行文字操作。在正在输入的文字框里长按（或拖动）可以显示粘贴选项；Paste 只粘贴进这个文字框，别的 App 到了前台时按钮栏会收起来。

<img src="Stuff/actionbar2.png" alt="文字的快速操作按钮" width=400/>

### 2. 快捷键模式
可以设定单独的快捷键进行安全复制、安全粘贴。只在关掉"覆盖 ⌘C/⌘V"（见下）时可用。

<img src="Stuff/shortcuts.png" alt="可以设定单独的快捷键进行安全复制、安全粘贴" width=400/>

### 3. 覆盖系统复制粘贴快捷键
默认开启。⌘C、⌘X、⌘V 都经过 Copi 的安全渠道。它们只传纯文字：格式会丢掉，复制图片或 App 里的对象（一封邮件、一个形状）会被拒绝，除非这个 App 在 **Apps Using the Normal Clipboard** 里。⇧⌘V、⌥⇧⌘V 在 App 自己的菜单把它们当作某种"粘贴"时粘贴 Copi 里的文字；浏览器里的 ⇧⌘V（网页里的"无格式粘贴"）也一样，除非正运行着用 ⇧⌘V 呼出历史的剪贴板管理工具（Paste、Pastebot、Flycut、Clipy、CleanClip）。别处这两个键照常交给 App 或者用它们的程序。在 Copi 自己的窗口里 ⌘C/⌘V 照常工作。关掉之后 ⌘C/⌘V 照常使用系统剪贴板，只有快捷操作栏和 Safe Copy/Paste 快捷键受保护。

<img src="Stuff/override-shortcuts.png" alt="覆盖后所有对文字的复制粘贴自动从 Copi 的安全渠道进行复制、粘贴" width=400/>

## 为何相信你？
开源。

## 如何确保数据安全?

Copi 把复制的文字保存在自己的内存里（不放进任何其他 App 能读取的剪贴板），并且默认**绝不把它放上系统剪贴板**——其他 App、剪贴板管理工具、通用剪贴板（Universal Clipboard）和 Spotlight 的剪贴板历史都看不到。文字直接在 Copi 和目标 App 之间传递：

- **原生输入框**：通过辅助功能直接读写选中的文字。选了多段（⌘ 拖选）时全部复制。
- **Safari / 网页视图**：通过 WebKit 的文本编辑辅助接口插入文字，通过 text marker 读取网页选区。
- **Chrome 系浏览器和 Electron App**：通过辅助功能改写普通输入框，通过 text marker 读取选区（需要开启"Accessibility for Chrome & Electron Apps"，默认开启；Copi 只请这些 App 建好无障碍树，不会让它们进入屏幕阅读器模式）。
- **密码框、单行输入框和富文本编辑器（Slack、Notion、Gmail……）**：像密码管理器的自动填充一样把文字"打"进去。多行文字（换行用 ⇧↩）只键入到原生（AppKit）的多行文本框（别的界面库里 ⇧↩ 可能是别的意思：Jupyter QtConsole、Spyder 里是运行代码），以及确定 ⇧↩ 是换行的聊天、邮件、代码托管 App 和网页里；Google Sheets 的单元格里换行用 ⌘↩；别处（Notebook、搜索框）只键入单行文字。
- **输入法（拼音、日文、韩文……）**：键入时 Copi 临时切到 ABC（或美国）键盘，打完再切回来，并且用系统的输入源快捷键切回，保证 App 里真的回到你的输入法。你正在组字（有未上屏的拼音）时不会切换（Chrome 系浏览器和 Electron App 不报告组字状态，在它们里面请先上屏再粘贴）。不想让 Copi 切换的话，关掉 **Switch to ABC While Typing**。
- **VS Code、Cursor、Windsurf、VSCodium 等 VS Code 系编辑器**：在 Copi 菜单的 **Editor Bridge** 里装上 **Copi Bridge**（编辑器那一行显示 **Outdated** 时点 **Reinstall**，然后重启编辑器）。之后编辑器里的复制、剪切、粘贴，提交信息框、聊天输入框里的粘贴，以及集成终端里的复制、粘贴，都走编辑器自己的命令，多光标、整行复制、格式化都和平常一样，全程不经过剪贴板。没装时只键入由字母、数字和简单符号组成的单行文字。
- **JetBrains 系 IDE**：文件编辑器里通过辅助功能粘贴任意文字（一次可撤销的编辑），复制选中的内容（没有选中时复制整行），也能剪切选中的内容；IDE 的终端里，所有终端都停在 shell 提示符前时键入单行文字。
- **终端**：**iTerm2**、**Ghostty**（在 Copi 菜单的 **Terminal Access** 里允许之后）、**WezTerm**（不用设置）和 **kitty**（打开它的远程控制之后，见下文）里，文字通过终端自己的接口直接交给终端：没有可被别的 App 看到的按键，不用切换输入法，多行文字在 zsh、bash 4.4 以上（Ghostty、WezTerm、kitty 里要 5.1 以上）和 fish 里以 bracketed paste 的方式整段插入、不执行。这些接口这次用不了时（Ghostty 的快捷终端或较旧的 Ghostty、WezTerm 的复制模式、kitty 低于 0.32.2 或没有 socket、认不出窗口），Copi 和在别的终端里一样键入。Ghostty、WezTerm、kitty 里在 Vim 中也能粘贴单行文字。其他终端里，根据终端里的进程判断，只在 shell 提示符（或 `sudo` 的密码提示：Copi 会从终端的设置确认它真的在等密码，已经在运行命令的 `sudo` 不算）前键入；多行文字在 zsh、bash 4.4 以上里以 bracketed paste 的方式键入（Terminal、kitty、WezTerm、Alacritty）。多行文字只在 shell 正等着输入命令时才送（脚本里的 `read` 提示不算）；用 vi 键位的 shell 只用 bracketed paste 的方式粘贴。前台是 **tmux** 时（Alacritty 以外的任何终端里），Copi 把文字交给 tmux，由它像真正的粘贴一样送进当前的 pane（里面的程序打开了 bracketed paste 模式就加标记），pane 里运行的程序同样按上面的规则判断。tmux 里运行的不是 shell 时（例如 Vim），要 tmux 3.7 以上才粘贴（它会告诉 Copi 那个程序有没有打开 bracketed paste 模式）。需要 Copi 能认出焦点在终端的哪个标签页（iTerm2、Ghostty、WezTerm 走上面的接口时；Terminal 里窗口标题显示着 tmux 并且只有这一个标签页时；别的终端只在只开着一个窗口、一个标签页、没有分屏时），以及 tmux 3.1 以上。文字经过管道交给 tmux，不作为命令的参数，所以不会进 tmux 的消息记录（`tmux show-messages`），粘贴完缓冲区马上删掉。任何一个会话设了在粘贴缓冲区时运行的钩子（例如 `after-load-buffer`、`after-paste-buffer`）时，Copi 不经过它的缓冲区：钩子可以把文字存到别处。（这一版之前的 Copi 把文字作为命令参数交给 tmux，tmux 会把它留在消息记录里直到 tmux 服务器重启；用旧版粘贴过机密内容的话，请重启 tmux。）正在运行 less、ssh 或者认不出的程序时拒绝，WezTerm 里 ssh、tmux 域的 pane 也拒绝。终端窗口里的查找框、Composer 只键入单行文字。
- **网页里的代码编辑器（Monaco、CodeMirror……）**：键入只含字母、数字和简单符号的单行文字（API key、token 大多如此）；会触发自动补全括号、补全候选的内容会被拒绝，开着 Vim 模式的编辑器也拒绝。
- **Firefox**：通过辅助功能改写输入框，往已知的聊天、邮件网站的编辑器里键入，按段落读取网页文字来复制。
- **虚拟机和远程桌面**：像真的按键一样逐个按下单行文字（键盘布局上有的字符；大写锁定要关掉）。Copi 看不到客户机里在运行什么（vim、less 里字母是命令），所以默认不这样做，要你自己打开 **Type Into Virtual Machines**。经过剪贴板粘贴（打开了 **Allow Clipboard Fallback** 时）会让文字在粘贴之后一直留在客户机的剪贴板上（以及它的剪贴板历史里），所以 Copi 先问你：8 秒内再粘贴一次才粘贴（按住 ⌘V 不放不算）。覆盖 Parallels、VMware、UTM、VirtualBox、VirtualBuddy、Microsoft Remote Desktop / Windows App、屏幕共享、Citrix、Horizon、RealVNC、TeamViewer、AnyDesk、Jump Desktop、Parsec、RustDesk、Moonlight、Amazon WorkSpaces、Royal TSX、Screens、iOS 模拟器和 iPhone 镜像。
- **⌘X**：在可编辑的输入框里读出并保存选中的文字，再把它删掉；能读不能删的地方只复制并告诉你。

实在没有不经过剪贴板的办法时（例如 Google Docs：文字是它自己画出来的，键入还会被自动更正），Copi 拒绝并通知你。你可以：

- 把 App 加入 **Apps Using the Normal Clipboard（照常使用系统剪贴板的 App）**（或者直接点复制被拒绝的通知上的按钮）：在这个 App 里复制的文字照常留在系统剪贴板上。只有它自己复制的才这样；在别处复制的文字粘贴进它时照样不经过剪贴板，它在前台时别的程序写进剪贴板的内容也照样收进 Copi。紧跟在这些操作之后一秒内的复制才算它自己的：Copi 放行给它的 ⌘C/⌘X、在它的窗口里的点击、⌃C、⌃X、⇧⌘C、⇧Delete 这类复制、剪切快捷键、在它的菜单里选的"拷贝""剪切"、终端和密码管理器里的回车；标为密码的复制只有紧跟在放行的 ⌘C/⌘X 之后、或者它声明是自己写的才算。或者
- 打开 **Allow Clipboard Fallback（允许剪贴板回退，较不安全）**，粘贴时改为把文字短暂放到系统剪贴板上（带有剪贴板管理工具不会记录的标记、不同步到你的其他设备、App 读走后约一秒内撤下，没人读的话 3 秒后撤下；这期间盯着剪贴板的程序读得到）。Copi 读不出来的复制则由 App 照常复制：文字不带标记地放在系统剪贴板上（剪贴板管理工具、Spotlight 的剪贴板历史、接力和虚拟机的剪贴板共享都可能看到），直到几毫秒后 Copi 把它转走。本机运行的虚拟机、远程桌面、模拟器仍可能把它同步到它们自己的剪贴板上，所以有这样的 App 在运行时 Copi 先问你：8 秒内再粘贴一次才继续。

**kitty**：它的远程控制默认关着。在 **Terminal Access** 里 kitty 旁边点 **Set Up…**：Copi 在 kitty 的配置目录里放一个小的检查脚本（`copi_rc_auth.py`），并告诉你往 `kitty.conf` 里加这三行：

```
allow_remote_control password
remote_control_password "" copi_rc_auth.py
listen_on unix:kitty-copi
```

然后重启 kitty。不带密码的请求，这个脚本只允许本机的 App 通过 socket 往拿着焦点的 kitty 窗口里送文字：谁都不能这样读取 kitty 里的内容，kitty 里运行的程序（包括 ssh 到的远程主机）不带密码也用不了它。也就是说，经过终端本身（转义序列，包括 ssh）来的请求用不了它；但以你的身份在这台 Mac 上运行的任何程序，包括 kitty 里运行的程序，都能往拿着焦点的 kitty 窗口里送文字；带着 kitty 不认识的密码的请求会让 kitty 弹窗问你要不要允许（Copi 从不带密码，遇到时请拒绝）。介意的话就别打开。

其他保护：

- 菜单里的 Copi 剪贴板内容默认隐藏，点 **Show** 才显示；锁屏、睡眠时自动清空。**Clear Copi Clipboard After** 还可以在复制 1、5、15 或 60 分钟后清空它。
- **菜单和右键菜单里的"拷贝""剪切""粘贴"**也经过 Copi：在菜单项执行之前接住这次点击（或者用方向键选中后按的回车）、关掉菜单，像 ⌘C/⌘X/⌘V 一样处理。Copi 在 App 到前台时就读好它给这几项起的名字（例如中文 App 里的"复制"）。在不是你正在输入的地方（聊天气泡、列表里的一行）右键选"拷贝"，执行的是 App 自己的拷贝，和点"复制"按钮一样会经过系统剪贴板。（点 App 界面上自己的"复制"按钮，文字仍会先进系统剪贴板，Copi 在几毫秒内把它转走；菜单开着时 Copi 每几毫秒查一次剪贴板，用空格、VoiceOver、语音控制选的菜单项写进来的内容也会很快被转走。）
- **拖动选中的文字**会把文字放进拖放剪贴板，任何 App 都能读，所以 Copi 认得出你在拖动选中的文字时，在拖动开始之前就把它拦下，认不出时在拖动一开始就把文字从拖放剪贴板上清掉（**Block Dragging Text**，默认开；同时带着链接或图片的选区在放下半秒后清掉）。移动文字请用 ⌘X 或 ⌘C 再 ⌘V。文件、图片照常拖放。关掉这个选项后，拖放的文字在放下半秒后从拖放剪贴板上清掉。同时带着文件或文件承诺的拖动（一封邮件、一条笔记）在放下 30 秒后清掉，给接收的 App 留出取文件的时间；访达里单纯的文件拖动不动。
- **查找剪贴板**：⌘E（"用所选内容查找"）和各 App 的查找栏会把要找的文字放进系统的查找剪贴板，任何 App 都能读。Copi 在 20 毫秒内发现（按组合键之后几毫秒），写入 50 毫秒后清掉。你在哪个 App 里查找，它自己的查找不受影响；别的 App 不能再用 ⌘G 接着找。Ghostty 的"选中即复制"（默认开）把每次选中的文字放进一个任何 App 都能读的命名剪贴板；Copi 在选中 10 秒后清掉它（这期间鼠标中键粘贴照常可用）。GNU Emacs 也把每个选中的区域放进名为 "Selection"、"Secondary" 的命名剪贴板，Copi 在它们最后一次变化 10 秒后清掉（这期间鼠标中键粘贴、secondary 粘贴照常可用）。
- **夹着图片的文字**：复制的内容里文字和图片、附件混在一起时，Copi 只把文字收走、不留在剪贴板上，图片丢掉（不经过剪贴板带不走），并告诉你。对这样的选区按 ⌘X 只复制文字、不删除。
- 开着 Override ⌘C/⌘V 时，一次受保护的复制之后 3 秒内、你还没按键或点击时，别的程序写进剪贴板的文字会被拦下（常见的剪贴板劫持手法）。
- 从 macOS 26.4 起，"终端"粘贴从网页浏览器复制来的内容之前会先警告（网页常骗人粘贴、运行有害的命令）。Copi 不经过剪贴板粘贴，会绕过这道检查，所以由 Copi 来问：从浏览器复制的文字第一次按 ⌘V 只提醒，8 秒内再按一次 ⌘V 才粘贴。
- 菜单里系统剪贴板上的内容也默认隐藏，点 **Show** 才显示，和 Copi 剪贴板一样。两者显示 30 秒后都会自动重新隐藏。在 macOS 13、14 上，Copi 的菜单不会出现在屏幕共享、录屏里（macOS 15 起系统不再遵守这个设置）。
- Copi 模拟键入时你按下的回车会被拦下、键入停下（否则聊天 App 会把打了一半的消息发出去，shell 会执行打了一半的命令）；切换 App、点击、按修饰键也会让键入停下。（Secure Input 开着时，例如在密码框里、开着 Secure Keyboard Entry 的终端里，macOS 不把按键交给 Copi，它拦不住这个回车；终端里以 bracketed paste 方式键入的那一行（Terminal、iTerm2、Ghostty、kitty、WezTerm、Alacritty 里的 zsh 和 bash 4.4 以上），回车不会执行它；别的 shell（例如 fish、macOS 自带的 /bin/bash）里会执行。）终端里，shell 支持的话单行文字也以 bracketed paste 的方式键入，漏进来的回车不会执行它。
- 锁屏时 Copi 绝不粘贴、键入、复制，不管 **Clear Copi Clipboard When Mac Locks** 怎么设。
- 把从密码管理器复制的内容粘贴进浏览器地址栏、Spotlight、Raycast、Alfred 或搜索框（它们可能边输入边把文字发给搜索服务）时，Copi 先问你：8 秒内再粘贴一次才粘贴。网址照常粘贴。
- Copi 看到的是改键工具（BetterTouchTool、Hammerspoon、Keyboard Maestro）改过之后的按键：它们把 ⌃C、鼠标侧键改成的 ⌘C 和 ⌘C 一样受保护。
- 只有富文本、网页片段或者链接（没有纯文本）的复制也会被转走：Copi 保管其中的文字（格式丢掉；HTML 只用一遍快速扫描去掉标签，不加载网页里的任何东西，什么样的输入都卡不住 Copi）。同时带着图片、文件或者 App 自己格式的数据的复制原样不动。
- App 有时分几步写入一次复制（先写图片或标记，文字最后写）。Copi 恰好在中间看到时，会在半秒内继续盯着这一版，文字一出现就转走。完全读不出来的文字（提供数据的 App 一直不给、或者 macOS 的 **Paste from Other Apps** 拒绝了 Copi）会从剪贴板上清掉而不是留在那里，并告诉你（开着 **Allow Clipboard Fallback** 时留给 App 自己粘贴）。
- Copi 把一次 ⌘C 当作复制文件或图片放行（访达的文件列表、一张图片），结果复制出来的却是文字时，Copi 把它转走、告诉你，并且以后在那个地方拒绝 ⌘C（Copi 的菜单里写着它记下了几个这样的地方，可以一键重置）。访达的快速查看、预览栏里显示的文字，图片里用实况文本选中的文字，都不会被放行。
- 在密码管理器里用 ⌘C 复制的文字（显示出来的密码、恢复码）在 Copi 里和它自己的"复制"按钮一样按机密处理：菜单里不显示，90 秒后清除。
- **Type Privately (Beta)**：Copi 用键入的方式粘贴时，把按键直接发给目标 App，不经过全系统的键盘事件流，盯着所有按键的程序看不到（只有专门盯着这个 App 的看得到）。默认关：有的 App 可能不认这样发来的按键。对虚拟机和远程桌面不起作用：它们只认经过全系统键盘事件流的按键。
- 保护关闭、暂停（例如辅助功能权限被撤掉）或受限（macOS 的 **Paste from Other Apps** 不让 Copi 读别的 App 的复制）时，菜单栏图标会变成警告标志，Copi 的菜单里写着原因，关掉了通知也看得到。
- Copi 的设置存在普通的偏好设置里，以你的身份运行的任何程序都能改。有程序调低了保护（关掉 Copi、把 App 加进 **Apps Using the Normal Clipboard**、允许剪贴板回退、打开往虚拟机里键入、把 Safe Paste 设成不带 ⌘/⌥/⌃ 的键……），而那一项不是你刚在 Copi 的菜单里自己改的，Copi 会告诉你，并且菜单栏图标一直显示警告，直到你在菜单里看过并关掉提示，Copi 没在运行时被改的也一样（同时改写 Copi 保存的设置副本的程序能把这一点也藏起来）。别的程序退出 Copi 时，它会重新打开（**Restart Copi If It Stops Unexpectedly** 开着时）并告诉你是哪个程序干的；Copi 没有响应时（卡住，或者被别的程序暂停），大约 20 秒内会被重新启动。一个以你的身份运行、存心要停掉 Copi 的程序仍然做得到（例如把它和负责重启的进程一起结束）；被结束时菜单栏图标会消失，Copi 下次启动时会告诉你；被暂停的 Copi 图标还在，同时改写 Copi 偏好设置的程序也能让这条提醒不出现。
- Copi 为终端、编辑器运行的命令行工具（tmux、WezTerm 的 `wezterm cli`、编辑器的命令行工具）不带 Copi 的权限运行，被换掉的工具借不到这些权限；Copi 只和正在粘贴的那个进程自己的 WezTerm、kitty socket 通信。VS Code 的集成终端里，Copi Bridge 只把文字送进 Copi 检查过的那个终端；中间换了别的终端拿焦点，就不粘贴。

Copi 做不到的：

- App 自己写进剪贴板的复制（密码管理器的"复制"按钮、网页上的复制按钮、选中即复制、`pbcopy`）会先进入系统剪贴板。Copi 平时每 20 毫秒检查一次，点击、按组合键之后每 4 毫秒，打开 **Constant Fast Check** 后一直每 3 毫秒（更费电），几毫秒内就把它转走（打开 **Instant Clipboard Detection (Beta)** 后约 5 毫秒：Copi 收听 macOS 内部的剪贴板变化通知，没有这个通知时在剪贴板上放一个看不见的占位项；多等这几毫秒是让密码管理器来得及给它的复制加上标记）。Copi 正在处理 ⌘C/⌘V 时也会在每一步之间检查；只有某一步在等一个没有响应的 App（最多约 0.4 秒），或者在读一份源 App 还在生成的复制（很大的 Office 区域）时会晚一些。每次选中都复制的终端（iTerm2 的 Copy to pasteboard on selection、WezTerm 的默认设置）也是这样把文字放上剪贴板的；Copi 的提示会告诉你去哪里关掉。App 标为密码的复制（大多数密码管理器 App 会这样标），以及在密码管理器里复制的内容，在 Copi 里按机密处理，90 秒后清除；密码管理器的浏览器扩展、命令行工具的复制通常没有标记，和普通复制一样保管（可以用 **Clear Copi Clipboard After** 限制保留多久）。文本扩展这类工具标为临时的、带着图片或者只有非文字内容的复制，最多会在剪贴板上停留 3 秒，好让工具自己的粘贴能用。但一直盯着剪贴板的程序仍可能在这一瞬间读到；密码请用密码管理器的自动填充（例如 1Password 的 ⌘\ 或浏览器扩展），它不经过剪贴板。
- macOS 自己也看得到经过剪贴板的内容：Spotlight 的剪贴板历史（macOS 26 起）可能把 App 自己写进剪贴板、Copi 还没来得及转走的那几毫秒里的内容记下来；接力（Handoff）会告诉你附近的设备"刚复制了东西"。Copi 菜单里的 **macOS Features That See the Clipboard** 显示它们开着没有，并能打开对应的设置。Copi 保管的文字从不经过这些地方，Copi 自己放到剪贴板上的东西也都标记了不进 Spotlight 的历史。
- 已经拿到辅助功能、输入监控或屏幕录制权限的软件本来就能直接读取输入框和按键，Copi 无法防护。Copi 用键入的方式粘贴时，这类软件能看到打出来的文字；Copi 菜单里的 **Programs That Can See Keystrokes** 列出现在装着键盘 event tap 的程序（直接读键盘硬件、用辅助功能读取的不在其中，请到系统设置 › 隐私与安全性里看）。打开 **Don't Type When Keystrokes Are Watched** 后，有看得到 Copi 键入的按键的程序（在 Copi 键入的那一层盯着所有 App 的，或者专门盯着你要粘贴的那个 App 的；暂停着的也算；macOS 自带的不算）在运行时，Copi 拒绝而不是键入。列表里只看得到键盘硬件的程序不影响键入；Secure Input 开着时 macOS 不把按键交给任何程序，这时不检查。键入时每几个键就再查一次，途中有程序开始看按键时会停下（它仍可能看到那几个键）。
- 有些情况下终端、编辑器会自己留着粘贴进去的内容：tmux 在复制模式里复制的文字存在它自己的缓冲区里（能连上 tmux 的程序都读得到，和屏幕上的内容一样）；iTerm2 的 Broadcast Input 会把一次粘贴发给所有参与广播的会话；开着调试日志的终端、编辑器可能把粘贴的文字记进日志。这些 Copi 不管。
- Copi 只在运行时生效：退出后，复制会照常进入系统剪贴板。崩溃或被强制退出时，它会在一两秒内重新打开并告诉你（**Restart Copi If It Stops Unexpectedly**，默认开；要停掉它请用菜单里的 **Quit Copi**）；打开 **Launch at Login**，登录后也会自动运行。

<img src="Stuff/safecopy.png" alt="如何确保数据安全" width=800/>

## 计划
- [x] 无痕复制
- [x] 快捷操作栏
- [x] 单独的复制快捷键
- [x] 覆盖系统复制粘贴快捷键
- [ ] 数据自动打码粘贴
    - [ ] 预制正则
    - [ ] 用户自定义正则
    - [ ] 用户自定义固定字符
    - [ ] 密码管理器来源

## 下载
这个 fork 没有编译好的 App：用 Xcode 打开 `Copi.xcodeproj`，选你自己的签名团队，编译 Copi scheme。原版 Copi 在[原项目的 Releases 页面](https://github.com/s1ntoneli/Copi/releases)。

## 截图
<img src="Stuff/screenshot.png" alt="" width=400/>

## Star 历史（原仓库）

[![Star History Chart](https://api.star-history.com/svg?repos=s1ntoneli/Copi&type=Date)](https://star-history.com/#s1ntoneli/Copi&Date)

## 分享给更多人 🔥

<div class="share">

[![][share-x-shield]][share-x-link]&nbsp;
[![][share-facebook-shield]][share-facebook-link]&nbsp;
[![][share-telegram-shield]][share-telegram-link]&nbsp;
[![][share-whatsapp-shield]][share-whatsapp-link]&nbsp;
[![][share-reddit-shield]][share-reddit-link]&nbsp;
[![][share-linkedin-shield]][share-linkedin-link]

<!-- [![][share-weibo-shield]][share-weibo-link]<br/> -->
<!-- [![][share-mastodon-shield]][share-mastodon-link]<br/> -->
</div>

## 贡献

欢迎提交 PR 👏。

对于重大更改，请先打开一个 issue 来讨论您想要更改的内容。

请确保适当地更新测试。

## 许可证

[MIT](./LICENSE)。原版 Copi © 2024 Sintone；这个 fork 的改动 © 2026 Zongwei Tang。

## 原作者的其他 App
支持原作者：[☕️ Sponsor](https://macaify.lemonsqueezy.com/buy/188835a0-ca78-444d-b1ca-399218cb1b6a?logo=0&discount=0)

* [CleanClip](https://cleanclip.cc): 可能是 macOS 上最干净的剪贴板管理工具!
* [Macaify](https://macaify.com): 在任意 App 中使用 ChatGPT
* [Copi](https://copi.cleanclip.cc): macOS 系统剪贴板的安全替代品

[share-x-link]: https://twitter.com/intent/tweet?url=https%3A%2F%2Fcopi.cleanclip.cc&text=Copi%20-%20An%20open%20source%20secure%20alternatives%20to%20the%20macOS%20system%20clipboard.%20Protect%20your%20data%20a%20step%20ahead%2C%20no%20more%20worries%20about%20clipboard%20data%20leakage
[share-x-shield]: https://img.shields.io/badge/-share%20on%20x-black?labelColor=black&logo=x&logoColor=white
[share-facebook-link]: https://www.facebook.com/sharer/sharer.php?u=https%3A%2F%2Fcopi.cleanclip.cc%20Protect%20your%20data%20a%20step%20ahead%2C%20no%20more%20worries%20about%20clipboard%20data%20leakage.
[share-facebook-shield]: https://img.shields.io/badge/-share%20on%20facebook-black?labelColor=black&logo=facebook&logoColor=white
[share-linkedin-link]: http://www.linkedin.com/shareArticle?mini=true&url=https%3A%2F%2Fcopi.cleanclip.cc&title=Copi%20-%20An%20open%20source%20secure%20alternatives%20to%20the%20macOS%20system%20clipboard.%20Protect%20your%20data%20a%20step%20ahead%2C%20no%20more%20worries%20about%20clipboard%20data%20leakage
[share-linkedin-shield]: https://img.shields.io/badge/-share%20on%20linkedin-black?labelColor=black&logo=linkedin&logoColor=white

<!-- [share-mastodon-link]:
[share-mastodon-shield]: https://img.shields.io/badge/-share%20on%20mastodon-black?labelColor=black&logo=mastodon&logoColor=white&style=flat-square -->

[share-reddit-link]: http://www.reddit.com/submit?url=https%3A%2F%2Fcopi.cleanclip.cc&title=Copi%20-%20An%20open%20source%20secure%20alternatives%20to%20the%20macOS%20system%20clipboard.%20Protect%20your%20data%20a%20step%20ahead%2C%20no%20more%20worries%20about%20clipboard%20data%20leakage
[share-reddit-shield]: https://img.shields.io/badge/-share%20on%20reddit-black?labelColor=black&logo=reddit&logoColor=white
[share-telegram-link]: https://t.me/share/url?url=https://copi.cleanclip.cc&text=Copi%20-%20An%20open%20source%20secure%20alternatives%20to%20the%20macOS%20system%20clipboard.%20Protect%20your%20data%20a%20step%20ahead%2C%20no%20more%20worries%20about%20clipboard%20data%20leakage.
[share-telegram-shield]: https://img.shields.io/badge/-share%20on%20telegram-black?labelColor=black&logo=telegram&logoColor=white

<!-- [share-weibo-link]:
[share-weibo-shield]: https://img.shields.io/badge/-share%20on%20weibo-black?labelColor=black&logo=sinaweibo&logoColor=white&style=flat-square -->

[share-whatsapp-link]: https://api.whatsapp.com/send?text=https://copi.cleanclip.cc
[share-whatsapp-shield]: https://img.shields.io/badge/-share%20on%20whatsapp-black?labelColor=black&logo=whatsapp&logoColor=white
