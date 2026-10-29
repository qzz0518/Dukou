# The Share-menu entries Dukou ships.
#
# macOS builds that menu from signed extension bundles: one entry is one
# `.appex`, and the list is therefore fixed when the app is built. What the user
# chooses is which of these to keep — in Dukou's own 设置 → 入口, which writes the
# same pkd election System Settings → General → Login Items & Extensions →
# Sharing does.
#
# All of them run the same executable and tell themselves apart by DKShareAction,
# so adding an entry costs a row here and a pair of InfoPlist.strings — not a
# second copy of the import code.
#
# Apps are not rows here. 「发给 Codex」, 「发给 Claude」 and every app the user
# adds are generated on the user's Mac, one small app each, so the Share menu can
# show the app's own icon (DirectShareEntries). They are copies of the template
# make-app.sh builds into Contents/Helpers.
#
# slot | appex name | bundle id suffix | DKShareAction | default display name
SHARE_SLOTS=(
	"Shelf|DukouShare|Share|shelf|暂存到渡口"
	"Clipboard|DukouShareClipboard|ShareClipboard|clipboard|复制到剪贴板"
)
