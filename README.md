<div align="center">
    <img src="Stuff/AppIcon-readme.png" width="200" height="200">

# Copi
**A Secure Alternative to the Mac System Clipboard**

**English** · [简体中文](./README.zh-CN.md)

<!-- SHIELD GROUP -->
[![](https://img.shields.io/badge/SwiftUI-brightgreen)]() [![](https://img.shields.io/badge/macOS-blue)]()

</div>

> [!NOTE]
> **This is a fork of [s1ntoneli/Copi](https://github.com/s1ntoneli/Copi)** by Sintone (MIT License). It keeps copied text off the system clipboard by default (Copi refuses rather than put it there), moves text that other apps put on the clipboard into Copi within milliseconds, pastes into terminals and editors through their own interfaces, and adds the protections described below. It has no network or update code. Apps on the original's Releases page don't include these changes.

[Copi](https://copi.cleanclip.cc) is an open-source, lightweight, and secure clipboard alternative for macOS. It takes over copying and pasting text, keeping what you copy where no other application can read it, effectively protecting your privacy data. It carries plain text only (formatting is dropped).

## Download
This fork has no prebuilt app: open `Copi.xcodeproj` in Xcode, choose your own signing team and build the Copi scheme. The original Copi is on [its Releases page](https://github.com/s1ntoneli/Copi/releases).


## Why Copi?

1. Defend against clipboard hijacking attacks
2. Prevent clipboard content leakage

## Who Needs It?

If you:
1. Own digital currencies
2. Frequently copy sensitive information
3. Don't trust the system clipboard

## How to Use?

### 1. Action Bar Mode
Once the Action Bar is enabled, when you select text, quick buttons for secure copying and pasting will appear above the selected text. Click with the mouse to use Copi's clipboard for text operations. Long-press (or drag in) the text field you're typing in to show the paste option; Paste only goes into that field, and the bar closes if another app comes to the front.

<img src="Stuff/actionbar2.png" alt="Quick action buttons for text" width=400/>

### 2. Shortcut Mode
You can set dedicated shortcuts for secure copying and pasting. They work while "Override ⌘C/⌘V" (below) is off.

<img src="Stuff/shortcuts.png" alt="You can set dedicated shortcuts for secure copying and pasting" width=400/>

### 3. Override System Copy and Paste Shortcuts
On by default. ⌘C, ⌘X and ⌘V go through Copi's secure channels. They carry plain text only: formatting is dropped, and copying images or app objects (a mail message, a shape) is refused unless the app is in **Apps Using the Normal Clipboard**. ⇧⌘V and ⌥⇧⌘V paste Copi's text where the app's own menus use them for a Paste variant; in browsers ⇧⌘V does too (a web app's paste without formatting), unless a clipboard manager that opens its history with ⇧⌘V (Paste, Pastebot, Flycut, Clipy, CleanClip) is running. Elsewhere these keys go to the app or to whatever program uses them. In Copi's own windows ⌘C/⌘V work as usual. If you turn it off, ⌘C/⌘V use the system clipboard as usual and only the Action Bar and the Safe Copy/Paste shortcuts are protected.

<img src="Stuff/override-shortcuts.png" alt="After overriding, all text copying and pasting will automatically go through Copi's secure channels" width=400/>

## Why Trust You?
Open source.

## How to Ensure Data Security?

Copi keeps copied text in its own memory (never in a pasteboard other apps can read) and, by default, **never puts it on the system clipboard** — so other apps, clipboard managers, Universal Clipboard and Spotlight's clipboard history can't see it. It moves text in and out of apps directly:

- **Native text fields**: reads and writes the selection through Accessibility. With several selections (⌘-drag), copies them all.
- **Safari / web views**: inserts through WebKit's text-editing accessibility API; reads page selections through text markers.
- **Chrome-based browsers and Electron apps**: writes plain inputs through Accessibility and reads selections through text markers (needs "Accessibility for Chrome & Electron Apps", on by default; Copi only asks these apps to build their accessibility tree and never turns on their screen-reader mode).
- **Password fields, single-line fields and rich-text editors (Slack, Notion, Gmail…)**: types the text, like a password manager's auto-type. Multi-line text is typed (line breaks as ⇧↩) only in native (AppKit) text views and in known chat, mail and code-hosting apps and sites where ⇧↩ is a line break (in other toolkits ⇧↩ can mean something else: in Jupyter QtConsole and Spyder it runs the code); in Google Sheets cells line breaks are typed as ⌘↩; elsewhere (notebooks, search boxes) only single lines are typed.
- **Input methods (Pinyin, Japanese, Korean…)**: while it types, Copi switches to ABC (or U.S.) and switches back afterwards, using the system's input-source shortcuts so the app really goes back to your input method. It never switches while you are still composing (Chrome-based browsers and Electron apps don't report composing, so finish composing there before pasting). Turn off **Switch to ABC While Typing** to switch yourself instead.
- **VS Code, Cursor, Windsurf, VSCodium and other VS Code-based editors**: install **Copi Bridge** from **Editor Bridge** in Copi's menu (if the editor's row says **Outdated**, click **Reinstall**, then restart the editor). Copy, cut and paste in the editor, paste in the commit message box and chat input, and copy and paste in the integrated terminal then go through the editor's own commands, so multi-cursor, whole-line copy and formatting work as usual, with no clipboard. Without the bridge, only single-line text made of letters, digits and simple symbols is typed.
- **JetBrains IDEs**: in the file editor, pastes any text through Accessibility (one undoable edit), copies the selection or, with nothing selected, the whole line, and cuts selections. In the IDE's terminal, types single lines when every terminal is at a shell prompt.
- **Terminals**: in **iTerm2** and **Ghostty** (after you allow Copi under **Terminal Access** in its menu), in **WezTerm** (no setup needed) and in **kitty** (after you turn on its remote control, see below), the text goes straight to the terminal through the terminal's own interface: no keystrokes for other apps to see, no input-method switching, and multi-line text arrives as a bracketed paste (inserted, not run) in zsh, bash 4.4+ (5.1+ in Ghostty, WezTerm and kitty) and fish. When that interface can't be used for a paste (Ghostty's Quick Terminal or an older Ghostty, WezTerm's copy mode, kitty older than 0.32.2 or without its socket, a window Copi can't match), Copi types the text as in other terminals. In Ghostty, WezTerm and kitty, single lines also work inside Vim. In other terminals Copi types at a shell prompt (or a `sudo` password prompt, which Copi confirms from the terminal's settings: a `sudo` already running a command is not a prompt), judged from the terminal's processes; multi-line text is typed as a bracketed paste in zsh and bash 4.4+ (Terminal, kitty, WezTerm, Alacritty). Multi-line text is only sent while the shell is waiting for a command (not to a script's `read` prompt), and shells using vi key bindings get bracketed pastes only. If **tmux** is in front (in any terminal except Alacritty), Copi hands the text to tmux itself, which pastes it into the current pane like a real paste (bracketed when the program there asked for it); the same prompt rules apply to what runs inside the pane. Inside tmux, programs other than a shell (such as Vim) get text only with tmux 3.7 or later, which tells Copi whether the program turned on bracketed paste. This works when Copi can tell which terminal tab is focused (iTerm2, Ghostty and WezTerm with the routes above; in Terminal when the window title shows tmux and it is Terminal's only tab; in other terminals only with a single window, a single tab and no splits) and needs tmux 3.1 or later. The text reaches tmux through a pipe, never as part of a command, so it doesn't end up in tmux's message log (`tmux show-messages`), and its buffer is deleted right after the paste. Copi doesn't use tmux's paste buffer when any session has hooks that run on it (such as `after-load-buffer` or `after-paste-buffer`), since they could save the text somewhere. (Copi builds before this one passed the text as a command argument, which tmux kept in its message log until the tmux server restarts; restart tmux if you pasted secrets with them.) If less, ssh or anything Copi can't identify is running, it refuses, as it does for WezTerm panes in an ssh or tmux domain. A search field or composer in the terminal window gets single lines typed into it.
- **Web code editors (Monaco, CodeMirror…)**: types single-line text made of letters, digits and simple symbols (API keys and tokens usually are); anything that would trigger auto-closing brackets or completions is refused, as is any editor in Vim mode.
- **Firefox**: writes text fields through Accessibility, types into the editors of known chat and mail sites, and copies page text paragraph by paragraph.
- **Virtual machines and remote desktops**: presses the real keys for single-line text (characters on your keyboard layout; Caps Lock must be off). Copi can't see what is running in the guest (in vim or less, letters are commands), so this is off until you turn on **Type Into Virtual Machines**. Pasting there through the clipboard (with **Allow Clipboard Fallback**) would leave the text on the guest's clipboard, and in its clipboard history, after the paste, so Copi asks first: paste again within 8 seconds to paste anyway (holding ⌘V down doesn't count). This covers Parallels, VMware, UTM, VirtualBox, VirtualBuddy, Microsoft Remote Desktop / Windows App, Screen Sharing, Citrix, Horizon, RealVNC, TeamViewer, AnyDesk, Jump Desktop, Parsec, RustDesk, Moonlight, Amazon WorkSpaces, Royal TSX, Screens, the iOS Simulator and iPhone Mirroring.
- **⌘X**: in editable fields Copi reads the selection, keeps it, and then deletes it. Where it can read but not delete, it copies and tells you.

Where nothing works without the clipboard (for example Google Docs, which draws its text itself and auto-corrects typing), Copi refuses and tells you. You can:

- add an app to **Apps Using the Normal Clipboard** (or click the button on a copy-refusal notification): text copied in that app stays on the system clipboard as usual. Only that app's own copies do; text you copied elsewhere is still pasted into it without the clipboard, and anything other programs put on the clipboard while it is in front is still moved into Copi. A copy counts as that app's own when it follows within a second a ⌘C/⌘X Copi let through to it, a click in one of its windows, a copy or cut shortcut like ⌃C, ⌃X, ⇧⌘C or ⇧Delete, Copy or Cut chosen in its menus, or Return in a terminal or password manager; a copy marked as a password counts only after a ⌘C/⌘X Copi let through, or when the app declares it wrote it. Or
- turn on **Allow Clipboard Fallback (Less Secure)**, which briefly puts the text on the clipboard instead (marked so clipboard managers don't record it, not synced to your other devices, and removed within about a second after the app reads it, or after 3 seconds if nothing does; a program watching the clipboard can read it during that time). For copies Copi can't read directly, the app copies as usual: the text sits on the system clipboard, unmarked (clipboard managers, Spotlight's clipboard history, Handoff and virtual machines' clipboard sharing may see it), for the few milliseconds until Copi moves it off. Virtual machines, remote desktops and simulators running on this Mac can still copy it to their own clipboard, so while one of them is running Copi asks first: paste again within 8 seconds to go ahead.

**kitty**: its remote control is off by default. Click **Set Up…** next to kitty under **Terminal Access**: Copi puts a small check script (`copi_rc_auth.py`) in kitty's config folder and shows three lines to add to `kitty.conf`:

```
allow_remote_control password
remote_control_password "" copi_rc_auth.py
listen_on unix:kitty-copi
```

Restart kitty afterwards. Without a password, the script only lets apps on this Mac send text to the focused kitty window through the socket: nothing can read from kitty this way, and programs running inside kitty (including over ssh) can't use it without a password. That is, programs that reach kitty through the terminal itself (escape codes, including over ssh) can't use it; any program running as you on this Mac, including ones running inside kitty, can still send text to the focused kitty window, and a request carrying a password kitty doesn't know makes kitty ask you whether to allow it (Copi never sends one, so say no). Leave it off if that worries you.

Other protections:

- Copi's clipboard is hidden in the menu until you click **Show**, and is cleared when the Mac locks or sleeps. **Clear Copi Clipboard After** can also clear it 1, 5, 15 or 60 minutes after you copy.
- **Copy, Cut and Paste in menus and right-click menus** go through Copi too: it catches the click, or the Return key when you choose them with the arrow keys, before the menu item runs, closes the menu and handles it like ⌘C/⌘X/⌘V. Copi learns each app's own names for these items (for example 复制 in Chinese apps) as soon as the app comes to the front. Copy chosen in a right-click menu on something other than the field you're typing in (a chat bubble, a list row) runs the app's own Copy, which goes through the system clipboard like a Copy button. (An app's own Copy button still goes through the system clipboard, and Copi moves the text off within milliseconds; while a menu is open Copi checks the clipboard every few milliseconds, so items chosen with Space, VoiceOver or Voice Control are moved off quickly too.)
- **Dragging selected text** would put it on the drag pasteboard, where any app can read it, so Copi stops the drag before it starts when it can tell you're dragging selected text, and otherwise clears the text from the drag pasteboard as soon as the drag starts (**Block Dragging Text**, on by default; a selection that also carries a link or picture is cleared half a second after the drop). Use ⌘X or ⌘C and then ⌘V to move text. Files and images still drag as usual. With the option off, dragged text is removed from the drag pasteboard half a second after the drop. Drags that carry text along with files or file promises (a mail message, a note) are cleared 30 seconds after the drop, giving the receiving app time to fetch the files; plain Finder file drags are left alone.
- **Find pasteboard**: ⌘E ("Use Selection for Find") and find bars put the search text on the system's find pasteboard, which any app can read. Copi notices within 20 ms (a few ms after shortcuts) and clears it 50 ms after it's written. The app you searched in keeps its own search; another app's ⌘G can't continue it. Ghostty's copy-on-select (on by default) keeps every selection in a named pasteboard any app can read; Copi clears it 10 seconds after you select (middle-click paste works within that time). GNU Emacs keeps every active region in the named pasteboards "Selection" and "Secondary" the same way; Copi clears those 10 seconds after they last change (middle-click and secondary paste work within that time).
- **Text with images**: when a copy mixes text with images or attachments, Copi keeps the text off the clipboard and drops the images (they can't be kept without the clipboard), and tells you. ⌘X on such a selection copies the text but doesn't delete it.
- With Override ⌘C/⌘V on, text that another app writes to the clipboard within 3 seconds of a protected copy, before you press a key or click, is blocked (a common clipboard-hijacking trick).
- From macOS 26.4, Terminal warns before pasting something copied in a web browser (websites trick people into pasting harmful commands). Copi pastes without the clipboard, which would skip that check, so it asks instead: the first ⌘V of text copied in a browser shows a notice, and a second ⌘V within 8 seconds pastes it.
- The system clipboard's contents in Copi's menu are hidden until you click **Show**, like Copi's own clipboard. Either one hides itself again after 30 seconds. On macOS 13 and 14 Copi's menu doesn't show up in screen sharing or recordings (macOS 15 and later no longer honor that).
- While Copi is typing a paste, a Return you press is held back and the typing stops (otherwise a chat app would send half the message, or a shell would run half the command); typing also stops if you switch apps, click, or press a modifier key. (While Secure Input is on, for example in a password field or a terminal with Secure Keyboard Entry, macOS hides keys from Copi, so it can't hold the Return back; in terminals where the line is typed as a bracketed paste (zsh and bash 4.4+ in Terminal, iTerm2, Ghostty, kitty, WezTerm and Alacritty) the Return can't run it; in other shells, such as fish or macOS's /bin/bash, it can.) In terminals, single lines are typed as a bracketed paste where the shell supports it, so a stray Return can't run them.
- Copi never pastes, types or copies while the screen is locked, whatever **Clear Copi Clipboard When Mac Locks** is set to.
- If you paste a password-manager copy into a browser's address bar, Spotlight, Raycast, Alfred or a search field (which may send what you type to a search service at once), Copi asks first: paste again within 8 seconds to go ahead. Web addresses paste normally.
- Copi sees keys after tools that remap them (BetterTouchTool, Hammerspoon, Keyboard Maestro), so a ⌃C or mouse button they turn into ⌘C is protected like ⌘C.
- Copies that carry only rich text, a web page fragment or a link (no plain text) are moved off the clipboard too: Copi keeps their text (formatting is dropped; for HTML it reads the tags in one quick pass, so nothing from the page is loaded and no input can stall Copi). Copies that also carry images, files or an app's own data stay as they are.
- An app sometimes writes a copy in steps (first an image or a marker, the text last). If Copi looks in between, it keeps watching that copy for half a second and moves the text once it appears. Text Copi can't read at all (an app that never delivers it, or macOS's **Paste from Other Apps** set to deny Copi) is removed from the clipboard rather than left there, and Copi tells you (with **Allow Clipboard Fallback** on, it is left for the app's own paste).
- When Copi lets a ⌘C through because it looks like copying a file or picture (Finder's file list, an image) and text arrives instead, Copi moves it, tells you, and refuses ⌘C in that spot from then on (Copi's menu lists how many such spots it has learned, with a Reset button). Text shown in Finder's Quick Look or preview pane and Live Text selected in an image are never let through.
- Text copied with ⌘C inside a password manager (a revealed password, a recovery code) is kept concealed in Copi like its own Copy button's copies: hidden in the menu and cleared after 90 seconds.
- **Type Privately (Beta)**: where Copi pastes by typing, it can send the keys straight to the app instead of through the system-wide keyboard stream, so programs watching every keystroke don't see them (only ones watching that particular app do). Off by default, because some apps may ignore keys sent this way. It doesn't apply to virtual machines and remote desktops, which only take keys pressed through the system-wide keyboard stream.
- The menu bar icon shows a warning sign whenever protection is off, paused (for example after Accessibility permission was removed) or limited (macOS's **Paste from Other Apps** doesn't let Copi read other apps' copies), and Copi's menu says why, so you know even with notifications turned off.
- Copi's settings live in ordinary preferences that any program running as you can change. If one turns protection down (turns Copi off, adds an app to **Apps Using the Normal Clipboard**, allows clipboard fallback, turns on typing into virtual machines, sets Safe Paste to a key without ⌘/⌥/⌃…) and it wasn't you changing that very setting in Copi's menu, Copi tells you and shows the warning icon until you dismiss it in its menu, also when they were changed while Copi wasn't running (a program that also rewrites Copi's saved copy of its settings can hide that). If another program quits Copi, it reopens (with **Restart Copi If It Stops Unexpectedly**) and tells you which program did; if Copi stops responding (stuck, or paused by another program), it is restarted within about 20 seconds. A program running as you that is set on stopping Copi can still do it (for example by killing it and its restart helper together); if it is killed, the menu bar icon disappears and Copi tells you the next time it starts; a paused Copi keeps showing its icon, and a program that also rewrites Copi's preferences can suppress that notice.
- Command-line tools Copi runs for terminals and editors (tmux, WezTerm's `wezterm cli`, an editor's CLI) run without Copi's permissions, so a replaced tool can't use them, and Copi only talks to a WezTerm or kitty socket owned by the very process it is pasting into. In VS Code's integrated terminal, Copi Bridge only sends the text to the terminal Copi checked; if another terminal became active in between, it doesn't paste.

What Copi can't do:

- Copies an app makes by itself (a password manager's Copy button, a website's copy button, copy-on-select, `pbcopy`) reach the system clipboard first. Copi checks every 20 ms, every 4 ms after any click or shortcut, and every 3 ms all the time with **Constant Fast Check** (uses more energy), and moves them off within a few milliseconds (within about 5 ms with **Instant Clipboard Detection (Beta)**, which listens for macOS's internal clipboard-change notice or, where that isn't available, keeps an invisible placeholder on the clipboard; Copi waits those few ms so a password manager can finish marking its copy). While Copi is busy handling a ⌘C or ⌘V, it keeps checking between its own steps; only a single step that waits for an unresponsive app (up to about 0.4 s), or reading a copy the source app is still producing (a large Office range), delays it. Terminals that copy every selection (iTerm2's Copy to pasteboard on selection, WezTerm's default) put text there the same way; Copi's notice says where to turn that off. Copies an app marks as passwords (most password-manager apps do), and copies made while a password manager is in front, stay concealed in Copi and are cleared after 90 seconds; copies from password-manager browser extensions or command-line tools usually aren't marked and are kept like other copies (set **Clear Copi Clipboard After** to limit how long). Copies marked as temporary by text expanders and similar tools that carry images or only non-text data stay on the clipboard for up to 3 seconds, so the tool's own paste works. Still, an app that watches the clipboard constantly could catch them in that moment; for passwords, use your password manager's autofill (for example 1Password's ⌘\ or a browser extension), which never touches the clipboard.
- macOS itself can see what passes through the clipboard: Spotlight's clipboard history (macOS 26 and later) may record a copy an app made by itself in the few milliseconds before Copi moves it, and Handoff tells your nearby devices that something was copied. **macOS Features That See the Clipboard** in Copi's menu shows whether they are on and opens their settings. Text Copi keeps never goes there, and everything Copi itself puts on the clipboard is marked to stay out of Spotlight's history.
- Software that already has Accessibility, Input Monitoring or Screen Recording permission can read text fields and keystrokes directly. Copi can't protect against it. Where Copi pastes by typing, such software sees the typed text; **Programs That Can See Keystrokes** in Copi's menu lists the ones holding keyboard event taps right now (apps that read the keyboard hardware directly or use Accessibility aren't listed; check System Settings › Privacy & Security). Turn on **Don't Type When Keystrokes Are Watched** to have Copi refuse instead of typing while a program that would see its typed keys is running (one that watches all apps at the level Copi types at, or the app you're pasting into; paused ones included; macOS's own don't count). Programs listed that only see the keyboard hardware don't stop typing, and nothing is checked while Secure Input is on, when macOS hides keys from all of them. Copi checks again before every few keys and stops if one starts watching partway (it may still see those few keys).
- Terminals and editors keep their own copies of what you paste in some cases: tmux keeps what you copy in copy-mode in its own buffers (any program that can reach tmux can read them, like the screen itself); iTerm2's Broadcast Input sends a paste to every session in the broadcast; terminals and editors with debug logging turned on may log pasted text. Copi doesn't touch these.
- Copi only protects while it runs: if it is quit, copies go to the system clipboard as usual. If it crashes or is force quit, it opens again within a couple of seconds (**Restart Copi If It Stops Unexpectedly**, on by default; use **Quit Copi** in its menu to stop it) and tells you; turn on **Launch at Login** so it also runs after you log in.

<img src="Stuff/safecopy.png" alt="How is data security ensured?" width=800/>

## Roadmap
- [x] Traceless copying
- [x] Action Bar
- [x] Dedicated Copy Shortcut
- [x] Override System Copy and Paste Shortcuts
- [ ] Automatic Obfuscated Paste
    - [ ] Predefined Regex
    - [ ] User-defined Regex
    - [ ] User-defined Fixed String
    - [ ] From Password Manager
- [ ] History
- [x] Cut (Command+X)

## Screenshots
<img src="Stuff/screenshot.png" alt="" width=400/>


## Share with More People 🔥

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

## Contributing

Contributions are welcome! 👏

For major changes, please open an issue first to discuss what you would like to change.

Please make sure to update tests as appropriate.


## License

[MIT](./LICENSE). The original Copi is © 2024 Sintone; this fork's changes are © 2026 Zongwei Tang.


## Apps by the original author
Support the original author: [☕️ Donation](https://www.gitfish.dev/repo/s1ntoneli/Copi)

* [CleanClip](https://cleanclip.cc): The cleanest clipboard manager on macOS.
* [Macaify](https://macaify.com): Fast use of ChatGPT on macOS.
* [Copi](https://copi.cleanclip.cc): A secure alternative to the Mac system clipboard.

## Star History (original repository)

[![Star History Chart](https://api.star-history.com/svg?repos=s1ntoneli/Copi&type=Date)](https://star-history.com/#s1ntoneli/Copi&Date)

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


[![Powered by DartNode](https://dartnode.com/branding/DN-Open-Source-sm.png)](https://dartnode.com "Powered by DartNode - Free VPS for Open Source")
