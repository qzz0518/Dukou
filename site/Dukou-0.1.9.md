<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
## 更新日志

1. **新增「快捷朋友圈转发」（实验）**。填要导出的条数，图片和视频可以分别选。Dukou 把作者、微信显示的时间和完整正文按时间线整理成 TXT，媒体放进同一个 ZIP 的 `media/` 文件夹，粘给应用或存进文件夹。读不到作者时会停下来，不猜——记错人比少一条更糟；没能加载的内容会写进 TXT，而不是悄悄丢掉。图片和视频要逐个打开再下载，速度很慢，这段时间请不要碰电脑，按 ESC 可以中断。采集媒体时会临时借用剪贴板，结束后如果你已经复制了新东西，就不再覆盖。
2. **两种快捷转发都能直接存进文件夹**。以前只能粘给应用，导出本身是目的时（留档、转给别人、喂给读目录的工具）没法用。现在目标是应用或文件夹，同一个选择器里挑；存完自动打开目录，重名不覆盖而是改名。
3. **消息条数不再有上限，可以合并成一个 ZIP**。每 100 条一批连续导出，界面按每 100 条约 5 秒预估耗时；可以把多批解压后重新打包成一个 ZIP，向应用转发超过 500 条时会主动建议——那正是一次粘贴很多文件开始出问题的地方。合并或交付中断时原始 ZIP 仍留在记录里。
4. **文件名统一**。聊天记录和朋友圈都按「来源 + 内容时间范围 + 条数」命名。只有起止都拿得到时才用内容时间；否则按导出时间标注——朋友圈只有「3 小时前」这种相对时间时，能诚实说的只有这个。
5. **README 精简**。删掉了构建命令、目录结构这些开发内容，剩下的说明也改成不写代码的人能看懂的话。

## Changelog

1. **Quick Moments forward (experimental).** Choose how many recent posts to export, with photos and videos as separate options. Authors, the times WeChat displays and the full text go into a chronological TXT, with the media in a `media/` folder inside one ZIP, pasted into an app or saved to a folder. A post whose author cannot be read stops the run rather than being guessed at — a wrong attribution is worse than a missing post — and anything that could not be loaded is written into the text instead of quietly dropped. Photos and videos have to be opened and downloaded one at a time, which is slow, so leave the computer alone while it runs; ESC stops it. The clipboard is borrowed during collection and is not restored over anything you copied in the meantime.
2. **Either quick forward can now land in a folder.** Pasting into an app was the only ending, which ruled out the case where the export itself is the point — an archive you keep, hand to someone, or feed to something that reads a directory. A destination is now an app or a folder, picked the same way; folders open after saving, and a name collision is worked around rather than overwritten.
3. **No cap on the message count, and batches can be merged.** Batches of 100 export back to back and the pane estimates five seconds per hundred. A run can extract those batches and repack them as a single ZIP, which is offered past 500 messages — the point where handing an app many files starts failing on its own. The original ZIPs stay in history if merging or delivery stops.
4. **One naming scheme.** Chat and Moments exports are both named by source, the span the content covers and the count. Only a range with both endpoints describes content; anything else is dated by export time, which is all a Moments post with a relative timestamp can honestly claim.
5. **A shorter README.** The build commands and source tree are gone, and what remains is written for people who do not read Swift.
