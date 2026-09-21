import SwiftUI

/// About 偏好 Tab
/// v0.2.0 全新:
///   - 大标题"Fraunces" 字 + 版本 SF Mono 副标(电影感开场)
///   - 简介:Apple Silicon 原生 + dejavu 团队出品
///   - 版权 + GitHub 链接(纯占位 URL,主人公开仓库)
/// 留白多,少元素。
struct AboutSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                heroCard
                descriptionCard
                linksCard
                copyrightCard
            }
            .padding(28)
        }
        .background(Color.themeBgDark.opacity(0.4))
    }

    // MARK: - Hero

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(appName)
                .font(.fraunces(size: 42, weight: .regular, italic: true))
                .foregroundStyle(Color.themeFgDark)
            Text(versionLine)
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.themeFgDarkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .glass(cornerRadius: 18)
    }

    // MARK: - 简介

    private var descriptionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Apple Silicon native")
                .font(.fraunces(size: 17, weight: .regular, italic: true))
                .foregroundStyle(Color.themeFgDark)
            Text(description)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
            Button {
                OnboardingStore.reset()
            } label: {
                Text(L10n.t("settings.about.replayOnboarding", zh: "重看引导", en: "Replay intro", language: AppSettings.shared.language))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.dsNormal)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .glass(cornerRadius: 16)
    }

    // MARK: - 链接

    private var linksCard: some View {
        HStack(spacing: 12) {
            linkRow(systemImage: "link", label: "GitHub", url: "https://github.com/Dejavu835/diskmon")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .glass(cornerRadius: 16)
    }

    private func linkRow(systemImage: String, label: String, url: String) -> some View {
        Link(destination: URL(string: url) ?? URL(string: "https://github.com/Dejavu835/diskmon")!) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(Color.themeFgDark)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
        }
    }

    // MARK: - 版权

    private var copyrightCard: some View {
        HStack(alignment: .center) {
            Text(String(
                localized: "about.copyright",
                defaultValue: "© 2026 déjà vu_tao（mian）, Cursor Agent, MiniMax Agent, gorkbuild"
            ))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Color.themeFgDarkMuted)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glass(cornerRadius: 14)
    }

    // MARK: - 派生

    private var appName: String {
        String(localized: "app.name", defaultValue: "DiskMon")
    }

    private var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "4.0.1"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "4.0.1"
        return "v\(version) (\(build))"
    }

    private var description: String {
        """
        A native menu bar companion for keeping an eye on your external disks.
        Built by déjà vu_tao（mian）, Cursor Agent, MiniMax Agent, and gorkbuild — \
        temperature, SMART health, and lifetime, presented in a calm, restrained interface.
        """
    }
}
