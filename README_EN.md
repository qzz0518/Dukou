<div align="center">
  <img src="Resources/Screenshots/app-icon-rounded.png" width="128" alt="Dukou icon" />
  <h1>Dukou (渡口)</h1>
  <p><strong>Send chat history straight from WeChat's forward menu to wherever you need it.</strong></p>
  <p>A native, lightweight, entirely local WeChat chat-history hand-off for macOS.</p>
  <p>It is also a compliant backup tool for WeChat chats and Moments: WeChat's own forward and export only — no database reads, no decryption, no injection.</p>
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

- **No interface in the extension.** Pick an entry and the files just land; nothing appears on screen.
- **Entries you can switch off.** Each entry is a separate system extension, toggled in Settings → Entries.
- **A shelf.** A floating square in a screen corner that never takes focus; drag out and it is consumed, the files move to History.
- **History that cleans itself.** Batches older than the retention window (7 days by default) go to the Trash and can be put back on the shelf.
- **Send to any app.** Keep your own list under Send to Custom; terminal-like apps can receive file paths instead.
- **Attached prompt.** A prompt of your own is pasted before the files when sending to Codex, Claude or a custom app; keep up to three.
- **Failures have a way out.** App missing, permission missing or app not in front: the files are already on the clipboard and can go to the shelf.
- **Quick WeChat forward (experimental).** Name a group and a count; Dukou selects and merge-forwards in WeChat, then pastes the ZIP into the current app or saves it to a folder. Batches past 100 can be combined into one ZIP; ESC stops it.
- **HTML chat preview.** An `index.html` inside the ZIP for browsing the chat offline: search, filter by date, view images, play audio and video.
- **Quick Moments forward (experimental).** Export a number of recent posts as a time-ordered TXT with the photos and videos in the same ZIP. Downloading is slow; ESC stops it.
- **Backups on your own disk.** Save a quick forward to a folder and you have a backup, named by chat, time range and count.
- **Safe updates.** Sparkle checks for signed releases and downloads only from GitHub Releases.
- **Simplified Chinese and English** throughout.

## What it does not do

- No database reads, no decryption, no injection, no changes to WeChat. Chat content comes only from the ZIP WeChat itself exports.
- No network, except checking for updates. All five extensions are sandboxed without network permission.
- No private APIs. Switching apps and pressing ⌘V for you go through public system interfaces, behind a permission you grant.

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

## Known issue

**On some WeChat accounts, Quick WeChat forward and Quick Moments forward cannot read WeChat's interface and report "A unique matching group was not found".** Manual multi-select and forwarding to Dukou's entries are unaffected.

- Symptom: Accessibility is granted, yet WeChat exposes only the window shell (the window, its three traffic-light buttons and the menu bar). The session list, chat title and messages are absent. Reinstalling, re-granting the permission, or changing macOS or WeChat builds does not help.
- Cause: since WeChat 4.1, WeChat itself decides whether to expose its controls, and that state follows the WeChat account rather than Dukou or the system. On the same Mac with the same WeChat build, some accounts have a control tree and some do not; the Windows WeChat automation community has documented the same per-account split ([pywechat #256](https://github.com/Hello-Mr-Crab/pywechat/issues/256), [#276](https://github.com/Hello-Mr-Crab/pywechat/issues/276)).
- Status: looking for an approach that does not depend on the control tree.

## Privacy

| Data | What Dukou does with it |
|---|---|
| The ZIP WeChat exports | Kept as is in Dukou's own container; only dates and counts are read, for naming |
| Moments text and media | Read only when you start a Moments forward, packed into a ZIP under the same retention as chats |
| Clipboard | Files, the attached prompt, or the paths a terminal asked for |
| Network | Software updates only, downloaded only from GitHub Releases |
| Sandbox | All five extensions run sandboxed |

## Contributing

- [Report an issue](https://github.com/qzz0518/Dukou/issues)
- [Follow @zerah_eth on X](https://x.com/zerah_eth)

## License

[MIT](LICENSE)
