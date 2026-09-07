## 更新日志

1. **右键那一下没生效不再让整轮转发失败**。滚动刚停下时右键，微信有时会把菜单弹出来，但这一下并没有真的选中消息；而 Qt 的菜单项不提供 AXPress，只能合成点击，弹窗坐标还在动的时候点下去就会落空。现在「右键 → 多选 → 合并转发」整段都会重试，最多四次，消息气泡的左右两个落点轮着来，每次重试都按当前的行位置重新定位锚点；菜单项也要连续两次扫描位置一致，才会被点。

## Changelog

1. **A right-click that does not take no longer ends the run.** Just after a scroll settles, WeChat sometimes shows the context menu without the click having actually landed on the message; and because Qt's menu items expose no AXPress, the press has to be a synthetic click, which misses while the popup's coordinates are still moving. The whole right-click → 多选 → 合并转发 transition now retries — up to four times, alternating between the two click points on the bubble and re-locating the anchor row from the current geometry each time — and a menu item is only clicked once two consecutive scans agree on where it is.
