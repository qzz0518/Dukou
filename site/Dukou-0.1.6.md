## 更新日志

1. **不再因为「没见过的消息类型」中断转发**。以前会把微信导出的每条记录和界面上的消息逐条比对，可这个比对得先认识消息类型——红包、视频号、合并的聊天记录卡片、带名字的表情、视频通话，每一种都要单独写规则，而且都是先失败过一次才补上的。没补到的类型就直接中止，哪怕微信已经正确导出了。现在直接交付微信导出的原始 ZIP。
2. **仍然校验文件完整**：每个条目照常做 CRC 校验，空的或读不完整的会拒绝并保留文件。
3. **条数改为显示「约 N 条」**：条数来自解析聊天记录文本，属于估算，界面上不再说得像精确值。

## Changelog

1. **An unrecognised message kind no longer aborts a forward.** Each exported record used to be compared against the message it was supposed to be, and that comparison had to know the kind first — red packets, Channels cards, merged chat-record cards, labeled stickers, video calls each needed their own rule, every one of them written after a run had already failed on it. Any kind not yet accounted for stopped the forward, for messages WeChat had exported perfectly well. The native ZIP is now delivered as-is.
2. **The archive is still checked for integrity**: every entry goes through the same CRC check, and an empty or unreadable one is refused with the file kept.
3. **The count is now shown as "about N"**: it comes from parsing the transcript, so it is an estimate and no longer presented as exact.
