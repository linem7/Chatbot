import AppKit
import SwiftUI
import WebKit

/// Gemini 的「搜索建议」组件（`searchEntryPoint.renderedContent`）。按 Google 的条款，必须在回答下方原样展示（SPEC §5）。
///
/// - 内容是 Google 给的 HTML 和 CSS，自己带深浅色样式，所以用 WKWebView 原样渲染，背景透明。
/// - 高度跟随内容：页面里的 ResizeObserver 在 body 尺寸变化时把高度报回来（Main Window 宽度可变，
///   变宽变窄都会重新计算），不在消息里出现第二个滚动区域。
/// - 点里面的链接（搜索建议的 chip）用默认浏览器打开，不在 WebView 里跳转。
struct SearchSuggestionView: View {
    let html: String
    @State private var height: CGFloat = 44

    var body: some View {
        SuggestionWebView(html: html, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SuggestionWebView: NSViewRepresentable {
    let html: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(height: $height)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // body 的尺寸一变（包括宽度变化导致的换行），就把内容高度报给原生侧
        configuration.userContentController.add(context.coordinator, name: Coordinator.heightMessage)
        configuration.userContentController.addUserScript(WKUserScript(
            source: """
                new ResizeObserver(() => {
                  window.webkit.messageHandlers.\(Coordinator.heightMessage).postMessage(Math.ceil(document.body.getBoundingClientRect().height));
                }).observe(document.body);
                """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        ))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        // 背景透明，跟着消息区的材质
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        context.coordinator.load(html, in: webView)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.height = $height
        context.coordinator.load(html, in: webView)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // userContentController 会强引用 message handler，拆掉时解开
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.heightMessage)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let heightMessage = "suggestionHeight"
        var height: Binding<CGFloat>
        private var loadedHTML: String?

        init(height: Binding<CGFloat>) {
            self.height = height
        }

        func load(_ html: String, in webView: WKWebView) {
            guard html != loadedHTML else { return }
            loadedHTML = html
            // 去掉 body 的默认外边距，高度才准
            let page = "<!doctype html><html><head><meta charset=\"utf-8\">"
                + "<style>html,body{margin:0;padding:0;background:transparent;}</style></head><body>\(html)</body></html>"
            webView.loadHTMLString(page, baseURL: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = (message.body as? NSNumber)?.doubleValue else { return }
            setHeight(value)
        }

        /// 加载完再量一次，防止 ResizeObserver 的第一次回调来得太早。
        /// 用 body 的实际高度，不用 documentElement.scrollHeight：后者不会小于视口高度，变宽之后缩不回来。
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("Math.ceil(document.body.getBoundingClientRect().height)") { [weak self] result, _ in
                guard let value = (result as? NSNumber)?.doubleValue else { return }
                MainActor.assumeIsolated { self?.setHeight(value) }
            }
        }

        private func setHeight(_ value: Double) {
            let newHeight = CGFloat(value)
            guard newHeight > 0, abs(newHeight - height.wrappedValue) >= 1 else { return }
            height.wrappedValue = newHeight
        }

        /// 链接一律交给默认浏览器；只允许加载我们自己给的这一页。
        /// 用 async 版本：回调版本的闭包标注（@MainActor、@Sendable）和 SDK 对不上时，方法不会被当成代理方法调用。
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                return .cancel
            }
            return .allow
        }

        /// target="_blank" 的链接（Google 的 chip 就是这样）：同样交给默认浏览器。
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
            return nil
        }
    }
}
