<div align="center">
  <img src="Resources/Screenshots/app-icon-rounded.png" width="128" alt="Dukou icon" />
  <h1>Dukou (渡口)</h1>
  <p><strong>Send chat history straight from WeChat's forward menu to wherever you need it.</strong></p>
  <p>A native, lightweight, entirely local WeChat chat-history hand-off for macOS.</p>
  <p><a href="README.md">简体中文</a> · English</p>
  <p>
    <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple" alt="macOS 14+" />
    <img src="https://img.shields.io/badge/Swift-6.2-F05138?style=flat-square&logo=swift&logoColor=white" alt="Swift 6.2" />
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
| **Send to Custom** | Your own list of apps: one app just goes, two or more get a small picker card |

One step further, Quick WeChat forward (experimental) exports, verifies and pastes the latest messages of a named group semi-automatically, by group name and message count, with no manual selection.

> [!NOTE]
> There is no release yet; build from source.

## Features

- **The extension has no interface.** Pick an entry and nothing appears on screen; the files just land. The copy finishes before the system reclaims its temporary file, so a batch either arrives whole or not at all.
- **Entries you can switch off.** Each entry is a separate system extension, toggled from Settings → Entries rather than three panes deep in System Settings.
- **A Dropover-style shelf.** A floating square that never takes focus, docked to the corner you chose. Drag out and get accepted, and it is consumed; drag everything out and it disappears. Nothing is deleted; the files move to History.
- **History that cleans itself.** Every batch records its entry, its outcome and its size. Anything not on the shelf is moved to the Trash after the retention window (7 days by default), and can be put back on the shelf at any time.
- **Send to any app.** The Send to Custom list is kept in Settings, and the same list backs the Send to ▸ menus on the shelf and in History. Terminal-like apps can receive quoted file paths instead of files.
- **Attached prompt.** When sending to Codex, Claude, a custom app or through the quick WeChat forward, a prompt of your own is pasted first, then the files (for terminal-like apps it is folded in ahead of the paths). One summary prompt comes built in; keep up to three and switch between them.
- **Failures always have a way out.** App not installed, permission missing, app never came forward: the files are already on the clipboard, and the message offers to put them on the shelf. Success shows nothing.
- **Quick WeChat forward (experimental).** Name a group and a message count; Dukou drives WeChat through Accessibility to select and merge-forward the messages, verifies the exported ZIP, and pastes it into the app you are using.
- **Safe updates.** Sparkle checks for EdDSA-signed releases and downloads only the one you confirm, from GitHub Releases.
- **Simplified Chinese and English** throughout, share-menu entries included.

## What it does not do

- It does not unpack, read, preview or index anything. The ZIP is an opaque file from start to finish.
- It does not use the network, except to check for updates. The five extensions are sandboxed with no network permission, and `Scripts/check-release-config.sh` keeps asserting that; the app's only request is Sparkle reading the signed appcast.
- It does not use private APIs. Activation goes through `NSWorkspace`; the automated ⌘V is a `CGEvent` behind the system's own permission.

## Getting started

### Requirements

- macOS 14 or later
- Xcode 26 (Swift 6.2) to build; [mise](https://mise.jdx.dev) is optional
- ChatGPT.app or Claude.app for the Send to Codex / Claude entries

### Build and install

```bash
git clone https://github.com/qzz0518/Dukou.git
cd Dukou
mise run reinstall   # assemble and sign dist/Dukou.app, install into ~/Applications
```

Without mise:

```bash
CONFIG=release Scripts/make-app.sh
Scripts/install-dev-build.sh
```

The build script picks a stable Developer ID or Apple Development identity from the keychain when there is one. That matters for Accessibility: TCC remembers the grant by code signature, and an ad-hoc signature has to be granted again after every rebuild.

### First run

1. Open Dukou. A four-step guide walks you through switching on the entries you want. A freshly installed share extension is **registered but disabled** until you switch it on.
2. Grant Accessibility if you want automated pasting. Skipping is fine; Dukou guides you again the first time a forward fails.
3. In WeChat, select messages → forward to other apps → pick the entry.

## Privacy

| Data | What Dukou does with it |
|---|---|
| The ZIP WeChat exports | Copied into the App Group container as is; never unpacked or read |
| Clipboard | File URLs only, or the quoted paths a terminal asked for |
| Network | Software updates only: Sparkle reads a signed appcast on GitHub Pages and downloads only the release you confirm, from GitHub Releases |
| Sandbox | All five extensions are sandboxed. The app is not: switching entries calls `pluginkit`, and `pkd` refuses a sandboxed client |

## Development

| Command | Purpose |
|---|---|
| `mise run build` | Build all three targets |
| `mise run test` | Run the tests |
| `mise run i18n` | Check the Chinese and English resources against the source |
| `mise run release-config` | Check bundle ids, the App Group, entitlements and the five entries |
| `mise run bundle` | Assemble and sign `dist/Dukou.app` for the host architecture |
| `mise run bundle-universal` | The same as Universal 2 |
| `mise run install` / `reinstall` | Install into `~/Applications`; `reinstall` rebuilds first |
| `mise run icon` | Generate the PNG, ICNS and README icon from `Resources/AppIcon-artwork.png` |
| `mise run dmg-background` | Draw the Finder background the DMG opens with |
| `mise run release-dry-run` | Build a Developer ID-signed Universal 2 DMG without notarizing it |
| `mise run release` | Build, sign, notarize, staple and generate the signed appcast from a clean tag |
| `mise run verify` | Build, test, check and bundle in one step |

```text
Sources/
├── DukouCore/    Inbox protocol, manifests, intents, batch state; shared by app and extension
├── DukouShare/   The share extension: import and commit, no interface
└── DukouApp/     Resident app, shelf, auto-paste, permission guide, settings, WeChat automation, Sparkle updates
Tests/            Inbox, batch state, forward targets and WeChat transcript parsing
```

The five `.appex` bundles run one executable and tell themselves apart by `DKShareAction`. The extension copies the files into `Inbox/Staging` in the App Group, writes the manifest and the intent, then renames the whole directory into `Inbox/Ready` in one step. The app watches that directory and consumes the intent, deleting it as it reads, so a forward runs exactly once.

## Contributing

- [Report an issue](https://github.com/qzz0518/Dukou/issues)
- [Follow @zerah_eth on X](https://x.com/zerah_eth)

## License

[MIT](LICENSE)
