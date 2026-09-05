<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
## 更新日志

1. **五条转发入口**：微信「转发到其他应用」里出现 暂存到渡口 / 发给 Codex / 发给 Claude / 复制到剪贴板 / 发送到自定义，在设置里逐条开关。
2. **无界面的分享扩展**：点完入口不出现任何面板，文件在系统回收临时文件前落盘，整批原子提交。
3. **Dropover 式暂存架**：常驻所选屏幕角落，拖出去就送达，全拖完自动消失；文件留在「记录」里，到期自动清理。
4. **发到任何 App**：自定义应用清单，一个直接发、多个弹卡片选；终端类应用可只粘贴带引号的文件路径。
5. **附加 Prompt**：转发时先粘一条写好的 Prompt 再粘文件，最多保存 3 条随时切换。
6. **快捷微信转发（实验）**：填群名和条数，通过辅助功能在微信里多选、合并转发，校验导出的 ZIP 后粘贴到目标 App。
7. **安全分发**：Universal 2 应用与 DMG 均已完成 Developer ID 签名、Apple 公证和票据装订，并提供 Sparkle EdDSA 签名更新源。

## Changelog

1. **Five forward-menu entries**: Stash in Dukou / Send to Codex / Send to Claude / Copy to Clipboard / Send to Custom appear in WeChat's "forward to other apps" menu, each switchable in Settings.
2. **A share extension with no interface**: nothing appears on screen; the files land before the system reclaims its temporary copy, committed as one atomic batch.
3. **A Dropover-style shelf**: docked to the corner you chose, consumed when dragged out, gone when empty; files stay in History and age out on schedule.
4. **Send to any app**: your own list of targets — one goes straight through, several get a picker; terminal-like apps can receive quoted paths instead of files.
5. **Attached prompt**: a prompt of your own is pasted ahead of the files; keep up to three and switch between them.
6. **Quick WeChat forward (experimental)**: name a group and a message count; Dukou drives WeChat through Accessibility, verifies the exported ZIP and pastes it into the target app.
7. **Secure distribution**: the Universal 2 app and DMG are Developer ID-signed, Apple-notarized and stapled, with an EdDSA-signed Sparkle update feed.
