import AppKit
import SwiftUI
import WebKit

/// Gemini 的「搜索建议」组件（`searchEntryPoint.renderedContent`）。按 Google 的条款，必须在回答下方原样展示（SPEC §5）。
///
/// - 内容是 Google 给的 HTML 和 CSS，自己带深浅色样式，所以用 WKWebView 原样渲染，背景透明。
/// - 高度跟随内容：页面加载完后读 `scrollHeight`，不在消息里出现第二个滚动区域。
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

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.scrollHeight") { [weak self] result, _ in
                guard let value = (result as? NSNumber)?.doubleValue, value > 0 else { return }
                MainActor.assumeIsolated {
                    self?.height.wrappedValue = CGFloat(value)
                }
            }
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
