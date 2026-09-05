# The Share-menu entries Dukou ships.
#
# macOS builds that menu from signed extension bundles: one entry is one
# `.appex`, and the list is therefore fixed when the app is built. What the user
# chooses is which of these to keep — in Dukou's own 设置 → 入口, which writes the
# same pkd election System Settings → General → Login Items & Extensions →
# Sharing does.
#
# All five run the same executable and tell themselves apart by DKShareAction,
# so adding an entry costs a row here and a pair of InfoPlist.strings — not a
# second copy of the import code.
#
# There is no sixth row per app the user installs: an entry is a signed bundle
# inside Dukou.app and cannot be created at runtime. 「发送到自定义」 is the
# answer to that — one entry that asks which app, from a list the settings
# window writes into the app group.
#
# slot | appex name | bundle id suffix | DKShareAction | default display name
SHARE_SLOTS=(
	"Shelf|DukouShare|Share|shelf|暂存到渡口"
	"Codex|DukouShareCodex|ShareCodex|codex|发给 Codex"
	"Claude|DukouShareClaude|ShareClaude|claude|发给 Claude"
	"Clipboard|DukouShareClipboard|ShareClipboard|clipboard|复制到剪贴板"
	"Custom|DukouShareCustom|ShareCustom|custom|发送到自定义"
)
