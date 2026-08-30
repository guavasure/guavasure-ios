import Foundation
import WebKit

enum GuavaSureEmbedWarmupKey {
    static func build(config: GuavaSureEmbedConfig) -> String {
        let override = config.embedUrlOverride?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let localHost = config.localDevHost?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let origin: String
        if !override.isEmpty {
            origin = override
        } else if !localHost.isEmpty {
            origin = "\(config.localDevScheme)://\(localHost):\(config.localDevPort)"
        } else {
            origin = config.embedBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let externalId = config.partnerExternalId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let authToken = config.partnerAuthToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let env = config.environment == .sandbox ? "sandbox" : "production"
        let camera = config.enableCameraCapture ? "1" : "0"
        return [
            config.partnerId,
            env,
            origin,
            config.platform,
            externalId,
            authToken,
            camera,
        ].joined(separator: "|")
    }
}

final class GuavaSureEmbedWarmupSession: NSObject {
    let config: GuavaSureEmbedConfig
    let matchKey: String
    var webView: WKWebView
    let allowedOrigins: Set<String>
    var loadFinished = false
    var bridgeOriginTrusted = false
    var queuedMessages: [String] = []
    var claimed = false
    var loadFailed = false
    var onLoadError: ((String) -> Void)?
    weak var scriptHandler: WarmupBridgeScriptMessageHandler?
    var navigationDelegate: WKNavigationDelegate?

    init(
        config: GuavaSureEmbedConfig,
        matchKey: String,
        webView: WKWebView,
        allowedOrigins: Set<String>
    ) {
        self.config = config
        self.matchKey = matchKey
        self.webView = webView
        self.allowedOrigins = allowedOrigins
    }
}

final class WarmupBridgeScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var session: GuavaSureEmbedWarmupSession?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == BridgeConstants.channelName,
              message.frameInfo.isMainFrame,
              let session,
              session.bridgeOriginTrusted else {
            return
        }

        if let body = message.body as? String {
            session.queuedMessages.append(body)
        } else if let body = message.body as? NSString {
            session.queuedMessages.append(body as String)
        }
    }
}

private final class WarmupNavigationDelegate: NSObject, WKNavigationDelegate {
    private weak var session: GuavaSureEmbedWarmupSession?

    init(session: GuavaSureEmbedWarmupSession) {
        self.session = session
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let session else { return }
        updateBridgeTrust(session: session, url: webView.url)
        session.loadFinished = false
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let session else { return }
        updateBridgeTrust(session: session, url: webView.url)
        session.loadFinished = true
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let session else {
            decisionHandler(.cancel)
            return
        }
        guard navigationAction.targetFrame?.isMainFrame == true,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let scheme = url.scheme?.lowercased() ?? ""
        if scheme != "http" && scheme != "https" {
            decisionHandler(.cancel)
            return
        }

        if EmbedOriginPolicy.isAllowed(url, allowedOrigins: session.allowedOrigins) {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        recordLoadFailure(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        recordLoadFailure(error.localizedDescription)
    }

    private func recordLoadFailure(_ message: String) {
        guard let session else { return }
        session.loadFailed = true
        if session.claimed {
            session.onLoadError?(message)
        }
    }

    private func updateBridgeTrust(session: GuavaSureEmbedWarmupSession, url: URL?) {
        guard let url else {
            session.bridgeOriginTrusted = false
            return
        }
        session.bridgeOriginTrusted = EmbedOriginPolicy.isAllowed(url, allowedOrigins: session.allowedOrigins)
        if !session.bridgeOriginTrusted {
            session.queuedMessages.removeAll()
        }
    }
}

enum GuavaSureEmbedWarmup {
    private static var session: GuavaSureEmbedWarmupSession?

    static func warmup(config: GuavaSureEmbedConfig) {
        cancel()

        let matchKey = GuavaSureEmbedWarmupKey.build(config: config)
        let allowedOrigins = EmbedOriginPolicy.resolveAllowedOrigins(config: config)

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        BridgeInjection.install(into: configuration.userContentController)

        let handler = WarmupBridgeScriptMessageHandler()
        configuration.userContentController.add(handler, name: BridgeConstants.channelName)

        let warmupSession = GuavaSureEmbedWarmupSession(
            config: config,
            matchKey: matchKey,
            webView: WKWebView(frame: .zero, configuration: configuration),
            allowedOrigins: allowedOrigins
        )
        warmupSession.webView.customUserAgent = safariMobileUserAgent
        handler.session = warmupSession
        warmupSession.scriptHandler = handler

        let navDelegate = WarmupNavigationDelegate(session: warmupSession)
        warmupSession.navigationDelegate = navDelegate
        warmupSession.webView.navigationDelegate = navDelegate

        session = warmupSession

        Task {
            do {
                let token = try await resolvePartnerAuthToken(config: config)
                guard warmupSession.claimed || session === warmupSession else { return }
                let urlString = GuavaSureUrlBuilder.buildEmbedUrl(
                    config: config,
                    partnerAuthToken: token
                )
                guard let url = URL(string: urlString) else {
                    recordSessionFailure(warmupSession, message: "Invalid embed URL")
                    return
                }
                warmupSession.webView.load(URLRequest(url: url))
            } catch {
                recordSessionFailure(warmupSession, message: error.localizedDescription)
            }
        }
    }

    static func claimIfMatching(config: GuavaSureEmbedConfig) -> GuavaSureEmbedWarmupSession? {
        guard let current = session, !current.claimed else { return nil }
        guard current.matchKey == GuavaSureEmbedWarmupKey.build(config: config) else { return nil }
        if current.loadFailed {
            cancel()
            return nil
        }
        current.claimed = true
        session = nil
        if current.scriptHandler != nil {
            current.webView.configuration.userContentController.removeScriptMessageHandler(
                forName: BridgeConstants.channelName
            )
        }
        return current
    }

    static func cancel() {
        if let current = session {
            current.webView.configuration.userContentController.removeScriptMessageHandler(
                forName: BridgeConstants.channelName
            )
        }
        session = nil
    }

    private static func recordSessionFailure(_ warmupSession: GuavaSureEmbedWarmupSession, message: String) {
        warmupSession.loadFailed = true
        if warmupSession.claimed {
            warmupSession.onLoadError?(message)
        } else if session === warmupSession {
            cancel()
        }
    }

    private static func resolvePartnerAuthToken(config: GuavaSureEmbedConfig) async throws -> String? {
        if let provider = config.partnerAuthTokenProvider {
            return try await provider()
        }
        return config.partnerAuthToken
    }

    private static let safariMobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}
