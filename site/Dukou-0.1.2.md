## 更新日志

1. **快捷微信转发能送到不在最前面的应用**：以前目标 App 只要被挡住或最小化就一定失败。现在 Dukou 会先把它带到前台，最小化的窗口也还原回来，再粘贴。
2. **执行期间有一枚状态条**：浮在屏幕角落，说明进行到哪一步、提醒完成前别碰鼠标和键盘，随时可以点「取消」。失败也说在这里，并带一个直接跳回设置的按钮——出错时设置窗口通常已经被微信盖住了。
3. **等待时间少了三分之一**：滚动改成按可见列表的高度一步跨过去，并按微信跟得上的节奏自己调速。120 条消息从 17.3 秒降到 11.2 秒，300 条全程约 30 秒。
4. **「发送到自定义」的选择卡片改在鼠标旁边弹出**：以前固定在暂存架的角落——多显示器上那往往是另一块屏幕。现在它跟着你点击的位置出现，就在同一块屏幕上。
5. **DMG 安装背景重画**：六枚渡口气泡贴纸围着中间的拖拽通道，每个指针都朝向 Applications 文件夹。

## Changelog

1. **Quick WeChat forward reaches apps that are not in front**: it used to fail whenever the destination was behind another window or minimised. Dukou now brings the app forward, restoring a minimised window, before it pastes.
2. **A status capsule while it runs**: it floats in the corner, names the step it is on, asks you to keep your hands off the mouse and keyboard, and cancels on one click. A failure is said there too, with a button back to Settings — by then Settings is usually buried behind WeChat.
3. **A third less waiting**: the scroll now steps by the height of the visible list instead of crawling, and paces itself to what WeChat can keep up with. 120 messages went from 17.3 s to 11.2 s; 300 take about 30 s.
4. **The Send to Custom picker opens next to the pointer**: it used to sit in the shelf's corner, which on a multi-display Mac was often the wrong screen. It now appears beside the click that raised it, on that screen.
5. **A redrawn DMG background**: six Dukou bubble stickers ring the drag lane in the middle, every pointer aimed at the Applications folder.
