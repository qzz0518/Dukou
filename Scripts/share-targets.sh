# Third-party apps that Dukou can expose as individual Share-menu entries.
#
# A Share extension must be signed as part of an installed app. Runtime-created
# extensions cannot be given the release app's Team identity, so these target
# hosts are assembled and signed at build time. The settings switch only copies
# or removes the matching pre-signed host.
#
# key | target bundle id | display name | icon resource
DIRECT_SHARE_TARGETS=(
	"Today|ai.today.macos.app.cn|Today|Today.icns"
	"Doubao|com.bot.pc.doubao|豆包|Doubao.icns"
)
