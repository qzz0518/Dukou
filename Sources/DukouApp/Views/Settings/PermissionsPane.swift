import DukouCore
import SwiftUI

struct PermissionsPane: View {
    @ObservedObject var authorization: AccessibilityAuthorization

    var body: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            SettingsSection(title: L10n.text("系统权限"), systemImage: "checkmark.shield") {
                PermissionRow(
                    title: L10n.text("辅助功能"),
                    detail: L10n.text("用于操作微信，以及激活目标应用并粘贴；只暂存或复制不需要。"),
                    granted: authorization.isTrusted
                ) {
                    Button(L10n.text("引导授权")) { authorization.guideIfNeeded() }
                        .buttonStyle(SettingsActionButtonStyle())
                }
            }

            Notice(L10n.text("辅助功能不会弹系统授权框，需要把 Dukou 拖进列表；授权后立即生效，不必重启。"))
        }
    }
}
