import AppKit
import SwiftUI

/// 让所在的窗口在 app 失去激活时不被 AppKit 自动隐藏（#46）。
///
/// 用在设置窗口和 Main Window 上：用户点了别的 app 之后，它们应该像普通窗口一样留在原处。
/// Quick Panel 不用它，失焦就隐藏是 Quick Panel 自己的行为（`windowDidResignKey`）。
struct StaysVisibleWhenInactive: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowConfiguringView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowConfiguringView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.hidesOnDeactivate = false
        }
    }
}
