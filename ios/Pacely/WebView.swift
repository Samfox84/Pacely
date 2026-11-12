import SwiftUI
import WebKit
import UIKit

/// Shows your Pacely server full screen and listens for messages from it.
struct PacelyWebView: UIViewRepresentable {
    let url: URL
    let onMessage: ([String: Any]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMessage: onMessage)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(WeakMessageHandler(context.coordinator), name: "pacely")
        config.userContentController.addUserScript(WKUserScript(source: "window.PACELY_PLATFORM='ios';",
                                                                 injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.allowsInlineMediaPlayback = true
        config.websiteDataStore = .default()

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.isOpaque = false
        wv.backgroundColor = .systemBackground
        wv.scrollView.backgroundColor = .systemBackground
        wv.allowsBackForwardNavigationGestures = false
        wv.allowsLinkPreview = false
        // Feel like an app, not a web page: no pinch-zoom
        wv.scrollView.minimumZoomScale = 1
        wv.scrollView.maximumZoomScale = 1
        wv.scrollView.bouncesZoom = false
        wv.scrollView.pinchGestureRecognizer?.isEnabled = false

        let refresh = UIRefreshControl()
        refresh.addTarget(context.coordinator, action: #selector(Coordinator.pullToRefresh(_:)), for: .valueChanged)
        wv.scrollView.refreshControl = refresh

        context.coordinator.webView = wv
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let onMessage: ([String: Any]) -> Void
        weak var webView: WKWebView?

        init(onMessage: @escaping ([String: Any]) -> Void) {
            self.onMessage = onMessage
            super.init()
            NotificationCenter.default.addObserver(forName: .pacelyRunJS, object: nil, queue: .main) { [weak self] n in
                guard let js = n.object as? String else { return }
                // Give the page a moment if Pacely was just opened
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.webView?.evaluateJavaScript(js, completionHandler: nil) }
            }
        }

        @objc func pullToRefresh(_ sender: UIRefreshControl) {
            webView?.reload()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any] {
                onMessage(body)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let u = navigationAction.request.url else { decisionHandler(.allow); return }
            // Backup download: fetch it with the app key and offer the share sheet
            if u.path == "/api/export" {
                decisionHandler(.cancel)
                Task { await Self.shareExport() }
                return
            }
            // Calendar subscribe links (webcal:), phone numbers and other apps open outside Pacely
            if let scheme = u.scheme?.lowercased(), !["http", "https", "about", "data", "blob", "file"].contains(scheme) {
                UIApplication.shared.open(u)
                decisionHandler(.cancel)
                return
            }
            // Links to other websites open in Safari
            let myHost = URL(string: Store.server)?.host
            if navigationAction.navigationType == .linkActivated, let host = u.host, host != myHost {
                UIApplication.shared.open(u)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.scrollView.refreshControl?.endRefreshing()
            webView.scrollView.pinchGestureRecognizer?.isEnabled = false
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            webView.scrollView.refreshControl?.endRefreshing()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            webView.scrollView.refreshControl?.endRefreshing()
            let html = """
            <html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head>
            <body style='font-family:-apple-system;padding:60px 24px;text-align:center;color:#555'>
            <div style='font-size:48px'>📡</div><h2>Can’t reach Pacely</h2>
            <p>Check your internet connection, then pull down to try again.</p></body></html>
            """
            webView.loadHTMLString(html, baseURL: URL(string: Store.server))
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            webView.reload()
        }

        @MainActor
        static func shareExport() async {
            do {
                let data = try await API.request("/api/export")
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd"
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("pacely-backup-\(f.string(from: Date())).json")
                try data.write(to: file)
                let vc = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
                var top = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
                while let presented = top?.presentedViewController { top = presented }
                if let pop = vc.popoverPresentationController, let view = top?.view {
                    pop.sourceView = view
                    pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
                }
                top?.present(vc, animated: true)
            } catch {
                print("Export failed", error)
            }
        }
    }
}

extension Notification.Name {
    static let pacelyRunJS = Notification.Name("pacelyRunJS")
}

/// Stops the web view keeping the coordinator alive forever.
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
