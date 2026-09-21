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
        }
    }
}
