import SwiftUI
import WebKit
import AppKit

/// Owns the one web view Pacely uses, so it keeps running (for reminders) even when the window is closed.
@MainActor
final class WebHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private(set) var webView: WKWebView?
    private var loadedMode = ""

    /// Finds the app's built-in copy of the Pacely web app.
    static var bundledIndex: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html")
            ?? Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "static")
            ?? Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web")
    }

    /// (Re)creates the web view for the current mode and loads Pacely.
    func load(mode: String) {
        let config = WKWebViewConfiguration()
        let ucc = config.userContentController
        ucc.add(WeakHandler(self), name: "pacely")
        var boot = "window.PACELY_PLATFORM='mac';window.PACELY_MODE='\(mode)';"
        if mode == "local" {
            ucc.addScriptMessageHandler(FetchBridge(), contentWorld: .page, name: "pacelyFetch")
            boot += "window.PACELY_LOCAL_DATA=\(LocalStore.read() ?? "null");"
        }
        ucc.addUserScript(WKUserScript(source: boot, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.websiteDataStore = .default()

        let old = webView
        let wv = WKWebView(frame: old?.frame ?? .zero, configuration: config)
        wv.navigationDelegate = self
        wv.uiDelegate = self
        wv.setValue(false, forKey: "drawsBackground")
        wv.autoresizingMask = [.width, .height]
        if let parent = old?.superview {
            old?.removeFromSuperview()
            wv.frame = parent.bounds
            parent.addSubview(wv)
        }
        webView = wv
        loadedMode = mode

        if mode == "local" {
            guard let index = WebHost.bundledIndex else {
                wv.loadHTMLString("<h2 style='font-family:-apple-system;padding:40px'>Pacely's built-in files are missing. Rebuild the app.</h2>", baseURL: nil)
                return
            }
            wv.loadFileURL(index, allowingReadAccessTo: index.deletingLastPathComponent())
        } else {
            let token = Store.token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = API.url("/auth?t=" + token) { wv.load(URLRequest(url: url)) }
        }
    }

    /// Runs JavaScript in the page and returns its text result.
    func js(_ code: String, _ args: [String: Any] = [:]) async throws -> String {
        guard let wv = webView else { throw APIError.message("Pacely isn't open yet.") }
        let r = try await wv.callAsyncJavaScript(code, arguments: args, in: nil, contentWorld: .page)
        return (r as? String) ?? ""
    }

    // MARK: messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if body["type"] as? String == "saveLocal", let text = body["data"] as? String {
            if loadedMode == "local" { LocalStore.write(text) }
            return
        }
        MacModel.shared.handle(body)
    }

    // MARK: navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = navigationAction.request.url else { decisionHandler(.allow); return }
        if u.path == "/api/export" {
            decisionHandler(.cancel)
            MacModel.shared.exportDatabase()
            return
        }
        if let scheme = u.scheme?.lowercased(), !["http", "https", "about", "data", "blob", "file"].contains(scheme) {
            NSWorkspace.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        let myHost = URL(string: Store.server)?.host
        if navigationAction.navigationType == .linkActivated, let host = u.host, host != myHost {
            NSWorkspace.shared.open(u)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await MacModel.shared.refresh() }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = false
        panel.begin { result in completionHandler(result == .OK ? panel.urls : nil) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let html = """
        <html><body style='font-family:-apple-system;padding:80px 30px;text-align:center;color:#666'>
        <div style='font-size:48px'>📡</div><h2>Can’t reach your Pacely server</h2>
        <p>Check your internet connection, then choose Refresh from the Pacely menu bar icon.</p></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }
}

/// Lets on-Mac Pacely download calendar links and talk to AI helpers, which a web page alone isn't allowed to do.
/// Only switched on when plans are kept on this Mac (the page is then Pacely's own built-in copy).
final class FetchBridge: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let b = message.body as? [String: Any], let s = b["url"] as? String, let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            replyHandler(nil, "That link isn't a web address.")
            return
        }
        var r = URLRequest(url: url)
        r.httpMethod = b["method"] as? String ?? "GET"
        r.timeoutInterval = 300
        (b["headers"] as? [String: String])?.forEach { r.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let body = b["body"] as? String { r.httpBody = body.data(using: .utf8) }
        URLSession.shared.dataTask(with: r) { data, resp, err in
            DispatchQueue.main.async {
                if let err = err { replyHandler(nil, err.localizedDescription); return }
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                replyHandler(["status": status, "text": String(data: data ?? Data(), encoding: .utf8) ?? ""], nil)
            }
        }.resume()
    }
}

final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Shows the shared web view inside the main window.
struct MacWebView: NSViewRepresentable {
    @ObservedObject var model: MacModel

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if model.host.webView?.superview !== nsView { attach(to: nsView) }
    }

    private func attach(to container: NSView) {
        guard let wv = model.host.webView else { return }
        wv.removeFromSuperview()
        wv.frame = container.bounds
        wv.autoresizingMask = [.width, .height]
        container.addSubview(wv)
    }
}
