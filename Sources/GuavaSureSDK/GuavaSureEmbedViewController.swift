import PhotosUI
import UIKit
import WebKit

/// Main embed view controller — mirrors `guavasure_flutter` / Android SDK.
@MainActor
public final class GuavaSureEmbedViewController: UIViewController {
    private let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let bridgeDispatcher = BridgeDispatcher()
    private let paymentLauncher = PaymentLauncher()

    private var config: GuavaSureEmbedConfig?
    private var callbacks = GuavaSureEmbedCallbacks()
    private var allowedOrigins: Set<String> = []
    private var bridgeOriginTrusted = false
    private var awaitingBrowserPayment = false
    private var paymentOpenedAt: Date?
    private var collectPaymentInFlight = false
    private var progressObservation: NSKeyValueObservation?

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func configure(config: GuavaSureEmbedConfig, callbacks: GuavaSureEmbedCallbacks = GuavaSureEmbedCallbacks()) {
        self.config = config
        self.callbacks = callbacks
        allowedOrigins = EmbedOriginPolicy.resolveAllowedOrigins(config: config)
    }

    public func loadEmbed() {
        Task {
            do {
                guard let config else { return }
                let token = try await resolvePartnerAuthToken(config: config)
                let urlString = GuavaSureUrlBuilder.buildEmbedUrl(config: config, partnerAuthToken: token)
                guard let url = URL(string: urlString) else { return }
                webView.load(URLRequest(url: url))
            } catch {
                callbacks.onLoadError?(error.localizedDescription)
            }
        }
    }

    public func reloadEmbedHome() {
        Task {
            guard let config else { return }
            let token = try? await resolvePartnerAuthToken(config: config)
            let urlString = GuavaSureUrlBuilder.buildEmbedUrl(config: config, partnerAuthToken: token)
            guard let url = URL(string: urlString) else { return }
            webView.load(URLRequest(url: url))
        }
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupWebView()
        setupBridge()
        layoutViews()
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleResumeFromBrowserPayment()
    }

    private func setupWebView() {
        let configuration = webView.configuration
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.userContentController.add(self, name: BridgeConstants.channelName)
        webView.customUserAgent = Self.safariMobileUserAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        progressObservation = webView.observe(\.estimatedProgress) { [weak self] webView, _ in
            guard let self else { return }
            self.progressView.isHidden = webView.estimatedProgress >= 1.0
            self.progressView.setProgress(Float(webView.estimatedProgress), animated: true)
        }
    }

    private func setupBridge() {
        bridgeDispatcher.callbacks.onOpenPayment = { [weak self] request in
            guard let self else { return }
            self.callbacks.onPaymentLinkOpened?()
            self.paymentLauncher.launch(from: self, request: request) { result in
                switch result {
                case .nativeSuccess:
                    self.reloadEmbedHome()
                case .browserOpened:
                    self.awaitingBrowserPayment = true
                    self.paymentOpenedAt = Date()
                case .nativeFailure, .failed:
                    break
                }
            }
        }

        bridgeDispatcher.callbacks.onCollectPayment = { [weak self] request in
            self?.handleCollectPayment(request)
        }

        bridgeDispatcher.callbacks.onPickFile = { [weak self] requestId, accept in
            self?.presentFilePicker(requestId: requestId, accept: accept)
        }

        bridgeDispatcher.callbacks.onLogout = { [weak self] in
            Task { await self?.callbacks.onLogout?() }
        }

        bridgeDispatcher.callbacks.onGoBack = { [weak self] in
            self?.callbacks.onGoBack?()
        }

        bridgeDispatcher.callbacks.onChromeColor = { [weak self] background, status in
            self?.applyChromeColor(background: background, statusBarStyle: status)
        }
    }

    private func layoutViews() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        progressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        view.addSubview(progressView)

        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func resolvePartnerAuthToken(config: GuavaSureEmbedConfig) async throws -> String? {
        if let provider = config.partnerAuthTokenProvider {
            return try await provider()
        }
        return config.partnerAuthToken
    }

    private func handleResumeFromBrowserPayment() {
        guard awaitingBrowserPayment, let openedAt = paymentOpenedAt else { return }
        if Date().timeIntervalSince(openedAt) < 2 { return }
        awaitingBrowserPayment = false
    }

    private func handleCollectPayment(_ request: CollectPaymentRequest) {
        guard !collectPaymentInFlight else { return }
        guard let handler = callbacks.partnerPaymentHandler else {
            evaluateJavaScript(bridgeDispatcher.buildPaymentCancelledScript(
                intentId: request.intentId,
                quoteId: request.quoteId
            ))
            return
        }

        collectPaymentInFlight = true
        Task {
            defer { collectPaymentInFlight = false }
            do {
                let result = try await handler(request)
                let script: String
                switch result {
                case .confirmed:
                    script = bridgeDispatcher.buildPaymentConfirmedScript(
                        intentId: request.intentId,
                        quoteId: request.quoteId
                    )
                case .cancelled:
                    script = bridgeDispatcher.buildPaymentCancelledScript(
                        intentId: request.intentId,
                        quoteId: request.quoteId
                    )
                }
                evaluateJavaScript(script)
            } catch {
                evaluateJavaScript(bridgeDispatcher.buildPaymentCancelledScript(
                    intentId: request.intentId,
                    quoteId: request.quoteId
                ))
            }
        }
    }

    private func presentFilePicker(requestId: String, accept: String) {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = accept.contains("pdf") ? .any(of: [.images]) : .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = FilePickerDelegate(
            requestId: requestId,
            webView: webView
        )
        present(picker, animated: true)
    }

    private func evaluateJavaScript(_ script: String) {
        guard !script.isEmpty else { return }
        webView.evaluateJavaScript(script)
    }

    private func applyChromeColor(background: String, statusBarStyle: String) {
        guard let color = UIColor(hex: background) else { return }
        view.backgroundColor = color
        setNeedsStatusBarAppearanceUpdate()
    }

    private static let safariMobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}

extension GuavaSureEmbedViewController: WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == BridgeConstants.channelName,
              bridgeOriginTrusted,
              let body = message.body as? String else {
            return
        }
        bridgeDispatcher.dispatch(body)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
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

        if EmbedOriginPolicy.isAllowed(url, allowedOrigins: allowedOrigins) {
            decisionHandler(.allow)
            return
        }

        UIApplication.shared.open(url)
        decisionHandler(.cancel)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        updateBridgeTrust(url: webView.url)
        progressView.isHidden = false
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateBridgeTrust(url: webView.url)
        progressView.isHidden = true
    }

    private func updateBridgeTrust(url: URL?) {
        guard let url else {
            bridgeOriginTrusted = false
            return
        }
        bridgeOriginTrusted = EmbedOriginPolicy.isAllowed(url, allowedOrigins: allowedOrigins)
    }
}

private final class FilePickerDelegate: NSObject, PHPickerViewControllerDelegate {
    let requestId: String
    weak var webView: WKWebView?

    init(requestId: String, webView: WKWebView) {
        self.requestId = requestId
        self.webView = webView
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else {
            resolve(nil)
            return
        }

        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let self, let image = object as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.85) else {
                self?.resolve(nil)
                return
            }
            if data.count > BridgeConstants.maxFileBytes {
                self.resolve(nil)
                return
            }
            let base64 = data.base64EncodedString()
            let payload: [String: String] = [
                "name": "upload.jpg",
                "mimeType": "image/jpeg",
                "base64": base64,
            ]
            self.resolve(payload)
        }
    }

    private func resolve(_ payload: [String: String]?) {
        let encodedId = NSString(string: requestId).debugDescription
            .replacingOccurrences(of: "\"", with: "")
        DispatchQueue.main.async { [weak self] in
            guard let webView = self?.webView, let requestId = self?.requestId else { return }
            if let payload,
               let data = try? JSONSerialization.data(withJSONObject: payload),
               let json = String(data: data, encoding: .utf8) {
                let id = (try? JSONSerialization.jsonObject(with: Data("\"\(requestId)\"".utf8))) as? String
                let quotedId = id.map { "\"\($0)\"" } ?? "\"\(requestId)\""
                webView.evaluateJavaScript("window.__guavasureResolveFilePick(\(quotedId), \(json));")
            } else {
                webView.evaluateJavaScript("window.__guavasureResolveFilePick(\"\(requestId)\", null);")
            }
        }
    }
}

private extension UIColor {
    convenience init?(hex: String) {
        var cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("#") { cleaned.removeFirst() }
        guard cleaned.count == 6, let value = Int(cleaned, radix: 16) else { return nil }
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b, alpha: 1)
    }
}
