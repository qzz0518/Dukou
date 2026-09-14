<div align="center">
  <img src="Resources/Screenshots/app-icon-rounded.png" width="128" alt="Dukou 图标" />
  <h1>Dukou（渡口）</h1>
  <p><strong>在微信的转发菜单里，直接把聊天记录送到你要用的地方。</strong></p>
  <p>原生、轻量、完全本地的 macOS 微信聊天记录转发工具。</p>
  <p>也是合规的微信聊天记录与朋友圈备份工具：只用微信自带的转发和导出，不读数据库、不解密、不注入。</p>
  <p>简体中文 · <a href="README_EN.md">English</a></p>
  <p>
    <img src="https://img.shields.io/badge/macOS-14%2B-black?style=flat-square&logo=apple" alt="macOS 14+" />
    <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License" /></a>
    <a href="https://x.com/zerah_eth"><img src="https://img.shields.io/badge/follow-%40zerah__eth-111111?style=flat-square&logo=x&logoColor=white" alt="在 X 关注 @zerah_eth" /></a>
  </p>
</div>

<p align="center">
  <img src="Resources/Screenshots/wechat-forward.png" width="720" alt="微信 4.1.13 的「转发到其他应用」菜单：Dukou 的五条入口和系统自带的共享服务排在一起" />
</p>

<p align="center">
  <img src="Resources/Screenshots/overview.png" width="1100" alt="Dukou 总览：入口开关、快捷微信转发、暂存架与记录" />
</p>

## 背景

macOS 微信 4.1.13 起，多选的聊天记录可以「合并转发」给第三方应用：微信自己把文字、图片和视频打成一个 ZIP，附一份按时间排好的 TXT。这正好是 AI agent 读一段完整信息流需要的东西，而且不碰数据库、不用密钥解密，聊天内容只走微信自己导出的文件。

问题是「转发到其他应用」的列表里只有装了共享扩展的 App：Finder、终端、Codex、Claude 都不在。Dukou 把它们补进去，转发菜单里多出五条入口，点哪条就直接到哪：

| 入口 | 做什么 |
|---|---|
| **暂存到渡口** | 放到屏幕角落的暂存架，从图标拖进任何 App |
| **发给 Codex** | 激活 ChatGPT 并粘贴到输入框 |
| **发给 Claude** | 激活 Claude 并粘贴到输入框 |
| **复制到剪贴板** | 只放进剪贴板，⌘V 由你决定 |
| **发送到自定义** | 你自己的应用清单：一个直接发过去，多个才在鼠标旁边弹一张小卡片让你选 |

再往前一步，「快捷微信转发」和「快捷朋友圈转发」（实验）按你填的群名和条数自动完成多选、导出和粘贴，不用自己动手。

## 功能

- **扩展没有界面**：点完入口不出现任何面板，文件直接落盘。
- **入口可开关**：每条入口是独立的系统扩展，在「设置 → 入口」里逐条开关。
- **暂存架**：不抢焦点的浮动方块，常驻屏幕角落；拖出去被接受就消化，文件转进「记录」。
- **记录到期自清**：超过保留时长（默认 7 天）自动移到废纸篓，随时能放回暂存架。
- **发到任何 App**：「发送到自定义」的清单自己维护，终端类应用可以只粘贴文件路径。
- **附加 Prompt**：发给 Codex / Claude / 自定义应用时先粘一条 Prompt，最多保存 3 条。
- **失败有兜底**：目标没装、没给权限、没到前台，文件一定已在剪贴板，并可放到暂存架。
- **快捷微信转发（实验）**：填群名和条数，Dukou 在微信里多选、合并转发，ZIP 粘给当前 App 或存进文件夹；超过 100 条自动分批，可合并成一个 ZIP，按 ESC 中断。
- **HTML 聊天预览**：ZIP 里附一个 `index.html`，解压后离线翻阅聊天气泡，可搜索、按日期查看、看图片和音视频。
- **快捷朋友圈转发（实验）**：按条数导出朋友圈，正文按时间线整理成 TXT，图片和视频放进同一个 ZIP；逐条下载较慢，按 ESC 中断。
- **备份到本地**：快捷转发选「存到文件夹」就是一次备份，群聊和朋友圈都按名称、时间范围和条数命名。
- **安全更新**：Sparkle 检查签名过的新版本，只从 GitHub Release 下载。
- **中英双语**：界面、菜单项和提示都有简体中文与 English。

## 它不做什么

- 不读微信数据库，不解密、不注入、不改微信。聊天内容只来自微信自己导出的 ZIP。
- 除了检查更新不联网。五个扩展都在沙盒里，没有网络权限。
- 不用私有 API。切换应用和代按 ⌘V 都走系统公开接口，且要你先授权。

## 快速开始

### 系统要求

- macOS 14 或更高版本
- 「发给 Codex / Claude」需要装有 ChatGPT.app 或 Claude.app

### Homebrew

```bash
brew install --cask qzz0518/tap/dukou
```

后续更新用 `brew upgrade --cask dukou`，或者等 App 自己通过 Sparkle 提示。

### DMG 安装

前往 [Releases](https://github.com/qzz0518/Dukou/releases) 下载最新的 `Dukou-*.dmg`，打开后将 Dukou 拖入 Applications。Homebrew 与 Releases 是同一份经过 Developer ID 签名和 Apple 公证的 Universal 2 DMG。

### 第一次使用

1. 打开 Dukou，四步向导会带你打开需要的入口。新装的共享扩展默认**未启用**，不打开就不会出现在转发菜单里。
2. 想用自动粘贴，给「辅助功能」授权。跳过也行，第一次转发失败时 Dukou 会再引导一次。
3. 微信里多选聊天记录 → 转发到其他应用 → 选你要的那一条。

## 已知问题

**部分微信账号上，「快捷微信转发」和「快捷朋友圈转发」读不到微信界面，提示「没有找到唯一匹配的群聊」。** 手动多选后从转发菜单送到 Dukou 不受影响。

- 现象：辅助功能已授权，但微信只向系统暴露窗口外壳（窗口、三个红绿灯按钮、菜单栏），聊天列表、会话标题和消息都不可见。重装、重新授权、换 macOS 或微信版本都没有用。
- 原因：微信 4.1 起由微信自己决定是否暴露界面控件，这个状态跟着微信账号走，不在 Dukou 和系统这一侧。同一台 Mac、同一版微信，有的账号有控件树，有的没有；Windows 版微信的自动化社区也记录了同样的按账号差异（[pywechat #256](https://github.com/Hello-Mr-Crab/pywechat/issues/256)、[#276](https://github.com/Hello-Mr-Crab/pywechat/issues/276)）。
- 进展：正在寻找不依赖控件树的实现方式。

## 隐私

| 数据 | Dukou 的处理方式 |
|---|---|
| 微信导出的 ZIP | 原样保存在 Dukou 的容器里，只读取时间和条数用于命名 |
| 朋友圈文字与媒体 | 只在你发起朋友圈转发时读取，打包成 ZIP，保留规则同聊天记录 |
| 剪贴板 | 只写入文件、附加的 Prompt，或终端要的路径 |
| 网络 | 只有软件更新，且只从 GitHub Release 下载 |
| 沙盒 | 五个扩展全部在沙盒里运行 |

## 参与项目

- [报告问题](https://github.com/qzz0518/Dukou/issues)
- [在 X 关注 @zerah_eth](https://x.com/zerah_eth)

## 许可证

[MIT](LICENSE)
