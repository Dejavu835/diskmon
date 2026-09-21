import SwiftUI

/// 设置页通用玻璃行:标题/帮助在上,控件在下。窄窗口不裁中文说明。
struct SettingsRow<Content: View>: View {
    let title: String
    var help: String? = nil
    let systemImage: String
    var helpColor: Color = .secondary
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.fraunces(size: 16, weight: .regular, italic: true))
                        .foregroundStyle(Color.themeFgDark)
                        .fixedSize(horizontal: false, vertical: true)
                    if let help, !help.isEmpty {
                        Text(help)
                            .font(.system(size: 11))
                            .foregroundStyle(helpColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(2)
                    }
                }
                Spacer(minLength: 0)
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 16)
    }
}
