import SwiftUI
import WebKit

/// HTML is rendered only after a deny-all resource rule has been installed.
/// This view never enables captured scripts or uses the persistent cookie store.
struct IsolatedHTMLPreview: View {
    let data: Data
    var body: some View {
        if ProcessInfo.processInfo.environment["PM_SETTINGS_SNAPSHOT"] != nil {
            Text(Strings.Detail.bodyToolsPreviewDisabled).foregroundStyle(.secondary)
        } else if data.count > 2_097_152 {
            Text(Strings.Detail.bodyToolsPreviewTooLarge).foregroundStyle(.secondary)
        } else {
            IsolatedHTMLDocument(html: String(decoding: data, as: UTF8.self))
        }
    }
}

private struct IsolatedHTMLDocument: NSViewRepresentable {
    let html: String
    func makeNSView(context: Context) -> HTMLPreviewContainer { HTMLPreviewContainer() }
    func updateNSView(_ view: HTMLPreviewContainer, context: Context) { view.load(html) }
    static func dismantleNSView(_ view: HTMLPreviewContainer, coordinator: ()) { view.close() }
}

@MainActor
private final class HTMLPreviewContainer: NSView, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView?
    private var source: String?
    private var generation = 0
    private var initialDocument = false
    override func layout() { super.layout(); webView?.frame = bounds }

    func close() {
        generation += 1
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView?.uiDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        source = nil
    }

    func load(_ html: String) {
        guard source != html else { return }
        close()
        source = html
        let expected = generation
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "ProxyMirrorIsolatedHTML", encodedContentRuleList: rules) { [weak self] rule, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected, let rule else { return }
                let configuration = WKWebViewConfiguration()
                configuration.websiteDataStore = .nonPersistent()
                configuration.defaultWebpagePreferences.allowsContentJavaScript = false
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
                configuration.userContentController.add(rule)
                let view = WKWebView(frame: self.bounds, configuration: configuration)
                view.navigationDelegate = self
                view.uiDelegate = self
                self.webView = view
                self.addSubview(view)
                self.initialDocument = true
                // CSP also disables refresh, forms, frames, objects and inline event code.
                let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'; frame-src 'none'; object-src 'none'\">"
                view.loadHTMLString(policy + html, baseURL: nil)
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The one local document load is necessary to display loadHTMLString.
        // Every link, redirect, frame navigation and subsequent request is denied.
        if initialDocument, navigationAction.navigationType == .other,
           navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.request.url?.absoluteString == "about:blank" {
            initialDocument = false
            decisionHandler(.allow)
        } else { decisionHandler(.cancel) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
}
