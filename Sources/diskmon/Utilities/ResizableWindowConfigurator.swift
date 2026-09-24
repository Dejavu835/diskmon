import SwiftUI
import AppKit

/// SwiftUI `Settings` / 部分 WindowGroup 会丢掉 `.resizable`。
/// 挂到根 View 上,把当前 NSWindow 改回可缩放并设 minSize。
struct ResizableWindowConfigurator: NSViewRepresentable {
    var minSize: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        DispatchQueue.main.async { Self.apply(to: view.window, minSize: minSize) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { Self.apply(to: nsView.window, minSize: minSize) }
    }

    private static func apply(to window: NSWindow?, minSize: CGSize) {
        guard let window else { return }
        window.styleMask.insert(.resizable)
        window.minSize = NSSize(width: minSize.width, height: minSize.height)
        window.contentMinSize = NSSize(width: minSize.width, height: minSize.height)
        window.maxSize = NSSize(width: 12_000, height: 12_000)
        window.contentMaxSize = NSSize(width: 12_000, height: 12_000)
        if let panel = window as? NSPanel {
            panel.styleMask.insert(.resizable)
            panel.isFloatingPanel = false
        }
    }
}
