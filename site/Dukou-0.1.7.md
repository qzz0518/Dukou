<!-- sparkle-sign-warning:
IMPORTANT: This file was signed by Sparkle. Any modifications to this file requires updating signatures in appcasts that reference this file! This will involve re-running generate_appcast or sign_update.
-->
## 更新日志

1. **转发途中群里来新消息不再中断**。以前的定位逻辑假设聊天列表只在被滚动时才会变：新消息一到，可见的消息行增减、位置反向移动，就会被判成「跟不上了」而停下——活跃的群里这不是偶发，是常态。现在改成按两次快照之间仍然相同的那段消息来重新定位，重复内容分不清时就取离原位置最近的那个。

## Changelog

1. **A message arriving mid-run no longer stops the forward.** The tracker assumed the list only moves when it is scrolled: an arrival adds or pushes out visible rows and can reverse the direction things moved in, and any of that used to end the run — in an active group that is the normal case, not an edge one. It now re-locates itself by the longest stretch of messages the two snapshots still share, falling back to whichever position is nearest the previous one when repeated rows make that ambiguous.
