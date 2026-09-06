<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
## 更新日志

1. **快捷微信转发快了一大截：500 条消息全程约 20 秒**（上个版本 300 条约 30 秒）。以前是用滚轮一屏一屏往上翻，每翻一次都得停下来看看落到哪了；现在直接用微信消息列表自带的键盘导航——Home 一下就跨过整段已加载的记录，方向键一次稳稳走一条消息。按键只发给微信，不经过全局输入。
2. **超高的消息也能正确选中**：比一屏还高的图片或长文本，以前滚轮跨不过去，现在一个方向键就过。
3. **视频号卡片能通过校验**：这类消息的作者名辅助功能能读到、视频链接读不到，以前会被当成对不上而中止。

## Changelog

1. **Quick WeChat forward is much faster: about 20 seconds for 500 messages** (the previous release took about 30 seconds for 300). It used to scroll the wheel a screen at a time and stop after each one to work out where it had landed. It now uses the message list's own keyboard navigation — Home crosses the entire loaded history in one step, and an arrow key moves exactly one message. The keys go to WeChat directly rather than through the global event stream.
2. **Messages taller than the window are handled correctly**: an image or a long text bubble taller than a screen could not be stepped over by the wheel. One arrow key crosses it.
3. **Channels cards pass verification**: accessibility exposes such a card's author but not its video URL, so these messages used to be read as a mismatch and stop the run.
