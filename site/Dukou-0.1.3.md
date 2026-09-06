<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
## 更新日志

1. **一次几百条的微信转发不再中途失败**：微信的聊天记录是用到才从磁盘读的，越往上翻越慢——实测已加载的部分每秒能过 64 条，没加载的只有 8 条。以前每一批 100 条都要重新撞上这道坎，第三、四批往往直接超时告败。现在超过 100 条会先把整段历史一次性拉到内存里再开始选，而且它会读微信自己的账：已经加载够了就直接跳过，一秒都不多花。
2. **修好一处一直存在的问题**：回到最新消息用的是一个过大的滚动手势，微信会把它压成每次约 50 点。它一直「有效」只是因为列表通常本来就停在最新消息处——你要是先往上翻过一段再执行，它就回不去了。
3. **「转发到其他应用」在各种电脑上都能找到**：这一行上方会为装了的企业微信、WorkBuddy 各留一条推广位，所以它的位置有三种可能。以前按固定位置去点，装了一个推广位的机器碰巧对得上，macOS 26 上没有推广位时那一下会点进联系人列表里。现在按结构定位——推广位和标签行没有名字、每个联系人都有名字，那一行就在第一个有名字的行上面。macOS 15 与 macOS 26 均已验证，不需要屏幕录制权限。
4. **按 Esc 立即中断转发**：执行期间鼠标被自动化占着，「取消」得瞄准了点；Esc 在哪儿都能按。
5. **条数只能输入数字**：这个框在失焦前是自由文本，输入法给的「②00」能原样停在里面。现在非数字当场被拒，各种写法的数字（②00、２００）都会折成 200。

## Changelog

1. **Forwarding several hundred WeChat messages no longer gives up halfway**: WeChat reads a conversation off disk as you scroll into it — measured at about 64 rows per second over history it already holds and about 8 over history it does not. Every batch of 100 used to hit that boundary again, and the third or fourth would simply time out. A request past 100 now loads the whole stretch once before selecting anything, and it reads WeChat's own count first: if the history is already in memory, the pass costs nothing.
2. **A long-standing bug fixed**: returning to the newest message used one enormous scroll gesture, which WeChat clamps to about 50 points. It only ever appeared to work because the list is normally already at the newest message — scroll up first and it could not get back.
3. **Forward to Other Apps is found on every Mac**: WeChat stacks a promotion above that row for each companion app installed (企业微信, WorkBuddy), so it sits in one of three places. Clicking a fixed position happened to match a machine with exactly one promotion; on macOS 26 with none, the click landed in the recipient list. It is now located by structure — promotions and the tab row have no name, every contact does — and verified on both macOS 15 and macOS 26, with no screen-recording permission involved.
4. **Escape stops a forward immediately**: the automation owns the pointer while it runs, so Cancel has to be aimed at. Escape does not.
5. **The message count takes only digits**: the field was free text until it lost focus, so an input method could leave "②00" sitting in it. Non-digits are now refused as typed, and digits in any form (②00, ２００) fold to 200.
