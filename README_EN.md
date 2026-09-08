<div align="center">
  <img src="Resources/Screenshots/app-icon-rounded.png" width="128" alt="Dukou icon" />
  <h1>Dukou (渡口)</h1>
  <p><strong>Send chat history straight from WeChat's forward menu to wherever you need it.</strong></p>
  <p>A native, lightweight, entirely local WeChat chat-history hand-off for macOS.</p>
  <p><a href="README.md">简体中文</a> · English</p>
  <p>
    <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple" alt="macOS 14+" />
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License" /></a>
    <a href="https://x.com/zerah_eth"><img src="https://img.shields.io/badge/follow-%40zerah__eth-111111?style=flat-square&logo=x&logoColor=white" alt="Follow @zerah_eth on X" /></a>
  </p>
</div>

<p align="center">
  <img src="Resources/Screenshots/wechat-forward.png" width="720" alt="WeChat 4.1.13's forward-to-other-apps menu, with Dukou's five entries listed beside the system share services" />
</p>

<p align="center">
  <img src="Resources/Screenshots/overview.png" width="1100" alt="Dukou overview: entry switches, quick WeChat forward, the shelf and history" />
</p>

## Background

Since WeChat 4.1.13 for macOS, a multi-selection of chat history can be merge-forwarded to third-party apps: WeChat itself packs the text, images and videos into one ZIP with a time-ordered TXT transcript. That is exactly what an AI agent needs to read a complete stream of a conversation, and it involves no database and no keys: the content only ever travels as the file WeChat exported.

The catch is that the "forward to other apps" list only shows apps that ship a share extension. Finder is not there, nor Terminal, nor Codex or Claude. Dukou puts them there. The forward menu gains five entries, and each one goes straight where it says:

| Entry | What it does |
|---|---|
| **Stash in Dukou** | Lands on the shelf in a corner of the screen; drag from the icon into any app |
| **Send to Codex** | Brings ChatGPT forward and pastes into its input |
| **Send to Claude** | Brings Claude forward and pastes into its input |
| **Copy to Clipboard** | Just puts it on the clipboard; the ⌘V is yours |
| **Send to Custom** | Your own list of apps: one app just goes, two or more get a small picker card next to the pointer |

One step further, Quick WeChat forward and Quick Moments forward (experimental) do the selecting, exporting and pasting for you — just name what you want and how much of it.

## Features

- **The extension has no interface.** Pick an entry and nothing appears on screen; the files just land. A batch either arrives whole or not at all.
- **Entries you can switch off.** Each entry is a separate system extension, toggled from Settings → Entries rather than three panes deep in System Settings.
- **A Dropover-style shelf.** A floating square that never takes focus, docked to the corner you chose. Drag out and get accepted, and it is consumed; drag everything out and it disappears. Nothing is deleted; the files move to History.
- **History that cleans itself.** Every batch records its entry, its outcome and its size. Anything not on the shelf is moved to the Trash after the retention window (7 days by default), and can be put back on the shelf at any time.
- **Send to any app.** The Send to Custom list is kept in Settings, and the same list backs the Send to ▸ menus on the shelf and in History. Terminal-like apps can receive quoted file paths instead of files.
- **Attached prompt.** When sending to Codex, Claude, a custom app or through a quick forward, a prompt of your own is pasted first, then the files (for terminal-like apps it is folded in ahead of the paths). One summary prompt comes built in; keep up to three and switch between them.
- **Failures always have a way out.** App not installed, permission missing, app never came forward: the files are already on the clipboard, and the message offers to put them on the shelf. Success shows nothing.
- **Quick WeChat forward (experimental).** Name a group and a message count, and Dukou does the selecting and merge-forwarding in WeChat, then pastes the ZIP into the app you are using or saves it to a folder you pick. No cap on the count; about 5 seconds per 100 messages, exported in batches past 100, and batches can be combined into a single ZIP. Files are named by group, time range and count, and a folder destination opens after saving. A status capsule in the corner reports progress; ESC or Cancel stops it at any time.
- **Quick Moments forward (experimental).** Choose how many recent posts to export, with photos and videos as separate options. Authors, the times WeChat shows and the full text go into a chronological TXT, with the media in a `media/` folder inside the same ZIP, and the result pastes into an app or saves to a folder just the same. Photos and videos have to be opened and downloaded one by one, which is slow, so leave the computer alone while it runs; ESC stops it, and anything that could not be read is marked in the TXT.
- **Safe updates.** Sparkle checks for signed releases and downloads only the one you confirm, from GitHub Releases.
- **Simplified Chinese and English** throughout, share-menu entries included.

## What it does not do

- It does not read WeChat databases, and it builds no chat preview or index. The chat history is the ZIP WeChat exported; Dukou reads only its dates and counts, to name the file. Moments are read only when you start a Moments forward, and what it reads goes into a ZIP of its own.
- It does not use the network, except to check for updates. The five entry extensions are sandboxed with no network permission, and the app's only request is fetching update information.
- It does not use private APIs. Bringing an app forward and pressing ⌘V for you both go through documented system interfaces, behind a permission you grant.

## Getting started

### Requirements

- macOS 14 or later
- ChatGPT.app or Claude.app for the Send to Codex / Claude entries

### Homebrew

```bash
brew install --cask qzz0518/tap/dukou
```

Update later with `brew upgrade --cask dukou`, or let the app offer the update itself through Sparkle.

### DMG

Download the latest `Dukou-*.dmg` from [Releases](https://github.com/qzz0518/Dukou/releases), open it and drag Dukou into Applications. Homebrew and Releases serve the same Developer ID-signed, Apple-notarized Universal 2 DMG.

### First run

1. Open Dukou. A four-step guide walks you through switching on the entries you want. A freshly installed share extension is **registered but disabled** until you switch it on.
2. Grant Accessibility if you want automated pasting. Skipping is fine; Dukou guides you again the first time a forward fails.
3. In WeChat, select messages → forward to other apps → pick the entry.

## Privacy

| Data | What Dukou does with it |
|---|---|
| The ZIP WeChat exports | Kept as is in Dukou's own container; a quick forward reads its dates and counts for naming, and can combine batches into one ZIP |
| Moments text and media | Read only when you start a Moments forward, then packaged as a TXT and media ZIP under the same retention as chat history. The clipboard is borrowed while media is collected and restored if nothing newer was copied |
| Clipboard | Files, the attached prompt, or the quoted paths a terminal asked for |
| Network | Software updates only: signed update information is fetched periodically, and only the release you confirm is downloaded, from GitHub Releases |
| Sandbox | All five extensions run sandboxed |

## Contributing

- [Report an issue](https://github.com/qzz0518/Dukou/issues)
- [Follow @zerah_eth on X](https://x.com/zerah_eth)

## License

[MIT](LICENSE)
