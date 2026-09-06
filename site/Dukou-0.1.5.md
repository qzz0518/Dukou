## 更新日志

1. **加载历史更快**：以前每翻一页历史都要跑回最新消息确认一次；现在通过焦点位置的变化直接判断加载了多少，全程只在最后回来一次。
2. **修复：最后一条是时间戳或「拍了拍」时会卡住**。这类提示不是消息，以前会被误判成没能回到最新消息而中止。
3. **修复：以下消息类型会导致转发中止**——合并转发的聊天记录卡片、带名字的动画表情、视频通话记录、红包、视频。这些消息在微信导出的文本里和界面上写法不同，以前会被当成对不上。

## Changelog

1. **History loads faster**: each page of history used to be confirmed by travelling back to the newest message. The pass now reads how much arrived from where the keyboard focus moved, and returns to the bottom only once at the end.
2. **Fixed: a run could stall when the last row was a timestamp or a 拍了拍 notice**. Neither is a message, and the list was judged not to have reached the bottom when it already had.
3. **Fixed: these message kinds stopped a forward** — merged chat-record cards, labeled animated stickers, video calls, red packets and videos. WeChat's exported text describes them differently from the interface, and the mismatch used to abort the run.
