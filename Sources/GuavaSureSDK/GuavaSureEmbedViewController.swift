import AVFoundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Main embed view controller - mirrors `guavasure_flutter` / Android SDK.
@MainActor
public final class GuavaSureEmbedViewController: UIViewController {
    private var webView: WKWebView!
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let bridgeDispatcher = BridgeDispatcher()
    private let paymentLauncher = PaymentLauncher()
    private var bridgeScriptHandler: BridgeScriptMessageHandler?

    private var config: GuavaSureEmbedConfig?
    private var callbacks = GuavaSureEmbedCallbacks()
    private var allowedOrigins: Set<String> = []
    private var bridgeOriginTrusted = false
    private var adoptedWarmupSession: GuavaSureEmbedWarmupSession?
    private var awaitingBrowserPayment = false
    private var paymentOpenedAt: Date?
    private var collectPaymentInFlight = false
    private var progressObservation: NSKeyValueObservation?
    private var preferredStatusBar: UIStatusBarStyle = .default
    private var activeFilePickerDelegate: FilePickerDelegate?
    private var activeDocumentPickerDelegate: DocumentPickerDelegate?
    private var activeCameraDelegate: CameraCaptureDelegate?

    public init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || isMovingFromParent, webView != nil {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: BridgeConstants.channelName
            )
            bridgeScriptHandler = nil
        }
    }

    deinit {
        progressObservation?.invalidate()
    }

    public override var preferredStatusBarStyle: UIStatusBarStyle {
        preferredStatusBar
    }

    public func configure(config: GuavaSureEmbedConfig, callbacks: GuavaSureEmbedCallbacks = GuavaSureEmbedCallbacks()) {
        self.config = config
        self.callbacks = callbacks
        allowedOrigins = EmbedOriginPolicy.resolveAllowedOrigins(config: config)
    }

    /// Optional preload before presenting this controller. Use the same config as [configure].
    public static func warmup(config: GuavaSureEmbedConfig) {
        GuavaSureEmbedWarmup.warmup(config: config)
    }

    /// Clears any warmup session (for example on partner logout).
    public static func cancelWarmup() {
        GuavaSureEmbedWarmup.cancel()
    }

    public func loadEmbed() {
        Task {
            do {
                guard let config else { return }
                if let warmed = GuavaSureEmbedWarmup.claimIfMatching(config: config) {
                    warmed.onLoadError = { [weak self] message in
                        self?.callbacks.onLoadError?(message)
                    }
                    adoptWarmupSession(warmed)
                    return
                }
                loadViewIfNeeded()
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

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        if webView == nil {
            webView = makeWebView()
        } else if bridgeScriptHandler == nil {
            let handler = BridgeScriptMessageHandler(owner: self)
            bridgeScriptHandler = handler
            webView.configuration.userContentController.add(handler, name: BridgeConstants.channelName)
        }
        setupWebView()
        setupBridge()
        layoutViews()
        adoptedWarmupSession = nil
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        handleResumeFromBrowserPayment()
    }

    private func setupWebView() {
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true

        progressObservation = webView.observe(\.estimatedProgress) { [weak self] webView, _ in
            guard let self else { return }
            self.progressView.isHidden = webView.estimatedProgress >= 1.0
            self.progressView.setProgress(Float(webView.estimatedProgress), animated: true)
        }
    }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        BridgeInjection.install(into: configuration.userContentController)
        let handler = BridgeScriptMessageHandler(owner: self)
        bridgeScriptHandler = handler
        configuration.userContentController.add(handler, name: BridgeConstants.channelName)

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = Self.safariMobileUserAgent
        return webView
    }

    private func setupBridge() {
        bridgeDispatcher.callbacks.onOpenPayment = { [weak self] request in
            guard let self else { return }
            self.callbacks.onPaymentLinkOpened?()
            self.paymentLauncher.launch(from: self, request: request) { result in
                Task { @MainActor in
                    switch result {
                    case .nativeSuccess:
                        break
                    case .browserOpened:
                        self.awaitingBrowserPayment = true
                        self.paymentOpenedAt = Date()
                    case .nativeFailure(_, let cancelled):
                        if cancelled {
                            await ChunkedJsDelivery.signalNativePaymentEnded(
                                webView: self.webView,
                                cancelled: true
                            )
                        }
                    case .failed:
                        await ChunkedJsDelivery.signalNativePaymentEnded(
                            webView: self.webView,
                            cancelled: true
                        )
                    }
                }
            }
        }

        bridgeDispatcher.callbacks.onCollectPayment = { [weak self] request in
            self?.handleCollectPayment(request)
        }

        bridgeDispatcher.callbacks.onPickFile = { [weak self] requestId, accept in
            self?.presentFilePicker(requestId: requestId, accept: accept)
        }

        bridgeDispatcher.callbacks.onCameraPermission = { [weak self] requestId in
            self?.handleCameraPermission(requestId: requestId)
        }

        bridgeDispatcher.callbacks.onCapturePhoto = { [weak self] requestId in
            self?.handleCapturePhoto(requestId: requestId)
        }

        bridgeDispatcher.callbacks.onOpenCameraSettings = { [weak self] in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }

        bridgeDispatcher.callbacks.onLogout = { [weak self] in
            GuavaSureEmbedWarmup.cancel()
            Task { await self?.callbacks.onLogout?() }
        }

        bridgeDispatcher.callbacks.onGoBack = { [weak self] in
            self?.callbacks.onGoBack?()
        }

        bridgeDispatcher.callbacks.onChromeColor = { [weak self] background, status in
            self?.applyChromeColor(background: background, statusBarStyle: status)
        }
    }

    func handleBridgeMessage(_ message: WKScriptMessage) {
        guard message.name == BridgeConstants.channelName,
              message.frameInfo.isMainFrame,
              isBridgeOriginTrusted,
              let body = bridgeMessageBody(message) else {
            return
        }
        bridgeDispatcher.dispatch(body)
    }

    private var isBridgeOriginTrusted: Bool {
        guard let url = webView.url else { return bridgeOriginTrusted }
        return EmbedOriginPolicy.isAllowed(url, allowedOrigins: allowedOrigins)
    }

    private func bridgeMessageBody(_ message: WKScriptMessage) -> String? {
        if let body = message.body as? String { return body }
        if let body = message.body as? NSString { return body as String }
        return nil
    }

    private func adoptWarmupSession(_ warmed: GuavaSureEmbedWarmupSession) {
        progressObservation?.invalidate()

        if isViewLoaded {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: BridgeConstants.channelName
            )
            webView.removeFromSuperview()
        }

        webView = warmed.webView
        bridgeOriginTrusted = warmed.bridgeOriginTrusted
        adoptedWarmupSession = warmed

        if isViewLoaded {
            layoutWebViewInHierarchy()
            setupWebView()
            let handler = BridgeScriptMessageHandler(owner: self)
            bridgeScriptHandler = handler
            webView.configuration.userContentController.add(handler, name: BridgeConstants.channelName)
            adoptedWarmupSession = nil
        }

        for message in warmed.queuedMessages {
            bridgeDispatcher.dispatch(message)
        }
        warmed.queuedMessages.removeAll()

        if warmed.loadFinished {
            BridgeInjection.reinject(into: webView)
            progressView.isHidden = true
        }
    }

    private func layoutWebViewInHierarchy() {
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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
        let wantsPdf = accept.lowercased().contains("pdf")
        if wantsPdf {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.pdf, UTType.image])
            picker.allowsMultipleSelection = false
            let delegate = DocumentPickerDelegate(requestId: requestId, webView: webView) { [weak self] in
                self?.activeDocumentPickerDelegate = nil
            }
            activeDocumentPickerDelegate = delegate
            picker.delegate = delegate
            present(picker, animated: true)
            return
        }

        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .images
        configuration.selectionLimit = 1
        let picker = PHPickerViewController(configuration: configuration)
        let delegate = FilePickerDelegate(requestId: requestId, webView: webView) { [weak self] in
            self?.activeFilePickerDelegate = nil
        }
        activeFilePickerDelegate = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    private func handleCameraPermission(requestId: String) {
        guard config?.enableCameraCapture == true else {
            resolveCameraPermission(requestId: requestId, outcome: "permission_denied")
            return
        }

        resolveCameraPermissionAfterStatusCheck(requestId: requestId)
    }

    private func resolveCameraPermissionAfterStatusCheck(requestId: String) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            resolveCameraPermission(requestId: requestId, outcome: "granted")
        case .denied, .restricted:
            resolveCameraPermission(requestId: requestId, outcome: "permission_permanently_denied")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    self.resolveCameraPermission(
                        requestId: requestId,
                        outcome: granted ? "granted" : "permission_denied"
                    )
                }
            }
        @unknown default:
            resolveCameraPermission(requestId: requestId, outcome: "permission_denied")
        }
    }

    private func handleCapturePhoto(requestId: String) {
        guard config?.enableCameraCapture == true else {
            resolveCameraCapture(requestId: requestId, payload: nil, error: "permission_denied")
            return
        }

        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            resolveCameraCapture(requestId: requestId, payload: nil, error: "error")
            return
        }

        let authStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if authStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.presentCameraPicker(requestId: requestId)
                    } else {
                        self.resolveCameraCapture(requestId: requestId, payload: nil, error: "permission_denied")
                    }
                }
            }
            return
        }

        guard authStatus == .authorized else {
            let error = authStatus == .denied || authStatus == .restricted
                ? "permission_permanently_denied"
                : "permission_denied"
            resolveCameraCapture(requestId: requestId, payload: nil, error: error)
            return
        }

        presentCameraPicker(requestId: requestId)
    }

    private func presentCameraPicker(requestId: String) {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        let captureRequestId = requestId
        let delegate = CameraCaptureDelegate { [weak self] image in
            guard let self else { return }
            self.activeCameraDelegate = nil
            guard let image,
                  let data = image.jpegData(compressionQuality: 0.85) else {
                self.resolveCameraCapture(requestId: captureRequestId, payload: nil, error: "error")
                return
            }
            if data.count > BridgeConstants.maxFileBytes {
                self.resolveCameraCapture(requestId: captureRequestId, payload: nil, error: "error")
                return
            }
            let payload: [String: String] = [
                "name": "capture.jpg",
                "mimeType": "image/jpeg",
                "base64": data.base64EncodedString(),
            ]
            self.resolveCameraCapture(requestId: captureRequestId, payload: payload, error: nil)
        }
        activeCameraDelegate = delegate
        picker.delegate = delegate
        present(picker, animated: true)
    }

    private func resolveCameraPermission(requestId: String, outcome: String) {
        let encodedId = JsStringEncoding.quote(requestId)
        let payload = (try? JSONSerialization.data(withJSONObject: ["outcome": outcome]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"outcome\":\"permission_denied\"}"
        evaluateJavaScript("window.__guavasureResolveCameraPermission(\(encodedId), \(payload));")
    }

    private func resolveCameraCapture(
        requestId: String,
        payload: [String: String]?,
        error: String?
    ) {
        let encodedId = JsStringEncoding.quote(requestId)
        if let payload,
           let data = try? JSONSerialization.data(withJSONObject: payload),
           let json = String(data: data, encoding: .utf8) {
            evaluateJavaScript("window.__guavasureResolveCameraCapture(\(encodedId), \(json));")
        } else {
            let errorPayload = (try? JSONSerialization.data(withJSONObject: ["error": error ?? "error"]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"error\":\"error\"}"
            evaluateJavaScript("window.__guavasureResolveCameraCapture(\(encodedId), \(errorPayload));")
        }
    }

    private func evaluateJavaScript(_ script: String) {
        guard !script.isEmpty else { return }
        webView.evaluateJavaScript(script)
    }

    private func applyChromeColor(background: String, statusBarStyle: String) {
        guard let color = UIColor(hex: background) else { return }
        view.backgroundColor = color
        preferredStatusBar = statusBarStyle.lowercased() == "light" ? .lightContent : .default
        setNeedsStatusBarAppearanceUpdate()
    }

    private static let safariMobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
}

extension GuavaSureEmbedViewController: WKNavigationDelegate, WKUIDelegate {
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
        BridgeInjection.reinject(into: webView)
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
    private let onComplete: () -> Void

    init(requestId: String, webView: WKWebView, onComplete: @escaping () -> Void) {
        self.requestId = requestId
        self.webView = webView
        self.onComplete = onComplete
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        defer { onComplete() }
        guard let provider = results.first?.itemProvider,
              provider.canLoadObject(ofClass: UIImage.self) else {
            Task { await resolve(nil) }
            return
        }

        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let self else { return }
            guard let image = object as? UIImage,
                  let data = image.jpegData(compressionQuality: 0.85) else {
                Task { await self.resolve(nil) }
                return
            }
            if data.count > BridgeConstants.maxFileBytes {
                Task { await self.resolve(nil) }
                return
            }
            let payload: [String: String] = [
                "name": "upload.jpg",
                "mimeType": "image/jpeg",
                "base64": data.base64EncodedString(),
            ]
            Task { await self.resolve(payload) }
        }
    }

    @MainActor
    private func resolve(_ payload: [String: String]?) async {
        guard let webView else { return }
        await ChunkedJsDelivery.resolveFilePick(webView: webView, requestId: requestId, payload: payload)
    }
}

private final class DocumentPickerDelegate: NSObject, UIDocumentPickerDelegate {
    let requestId: String
    weak var webView: WKWebView?
    private let onComplete: () -> Void

    init(requestId: String, webView: WKWebView, onComplete: @escaping () -> Void) {
        self.requestId = requestId
        self.webView = webView
        self.onComplete = onComplete
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        defer { onComplete() }
        guard let url = urls.first else {
            Task { await resolve(nil) }
            return
        }

        Task {
            let payload = await readPayload(from: url)
            await resolve(payload)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        defer { onComplete() }
        Task { await resolve(nil) }
    }

    @MainActor
    private func resolve(_ payload: [String: String]?) async {
        guard let webView else { return }
        await ChunkedJsDelivery.resolveFilePick(webView: webView, requestId: requestId, payload: payload)
    }

    private func readPayload(from url: URL) async -> [String: String]? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.count > BridgeConstants.maxFileBytes { return nil }

        let mimeType = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        return [
            "name": url.lastPathComponent,
            "mimeType": mimeType,
            "base64": data.base64EncodedString(),
        ]
    }
}

private final class CameraCaptureDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    private let onComplete: (UIImage?) -> Void

    init(onComplete: @escaping (UIImage?) -> Void) {
        self.onComplete = onComplete
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
        onComplete(nil)
    }

    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        onComplete(info[.originalImage] as? UIImage)
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
