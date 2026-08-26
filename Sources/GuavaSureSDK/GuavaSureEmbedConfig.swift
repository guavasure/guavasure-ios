import Foundation

public enum GuavaSureEnvironment: String, Sendable {
    case production
    case sandbox
}

public struct GuavaSureEmbedConfig: Sendable {
    public let partnerId: String
    public let environment: GuavaSureEnvironment
    public let partnerAuthToken: String?
    public let partnerAuthTokenProvider: (@Sendable () async throws -> String?)?
    public let partnerExternalId: String?
    public let embedBaseUrl: String
    public let embedUrlOverride: String?
    public let platform: String
    public let localDevHost: String?
    public let localDevPort: Int
    public let localDevScheme: String
    /// Opt-in native camera bridge. SDK never prompts — partner must grant `CAMERA` first.
    public let enableCameraCapture: Bool

    public static let defaultEmbedBaseUrl = "https://embed.guavasure.com"
    public static let appWebviewPlatform = "app-webview"

    public init(
        partnerId: String,
        environment: GuavaSureEnvironment = .production,
        partnerAuthToken: String? = nil,
        partnerAuthTokenProvider: (@Sendable () async throws -> String?)? = nil,
        partnerExternalId: String? = nil,
        embedBaseUrl: String = Self.defaultEmbedBaseUrl,
        embedUrlOverride: String? = nil,
        platform: String = Self.appWebviewPlatform,
        localDevHost: String? = nil,
        localDevPort: Int = 5173,
        localDevScheme: String = "http",
        enableCameraCapture: Bool = false
    ) {
        self.partnerId = partnerId
        self.environment = environment
        self.partnerAuthToken = partnerAuthToken
        self.partnerAuthTokenProvider = partnerAuthTokenProvider
        self.partnerExternalId = partnerExternalId
        self.embedBaseUrl = embedBaseUrl
        self.embedUrlOverride = embedUrlOverride
        self.platform = platform
        self.localDevHost = localDevHost
        self.localDevPort = localDevPort
        self.localDevScheme = localDevScheme
        self.enableCameraCapture = enableCameraCapture
    }
}

public struct CollectPaymentRequest: Sendable {
    public let intentId: String
    public let quoteId: String
    public let amount: NSNumber
    public let currency: String
    public let planLabel: String
}

public enum PartnerPaymentResult: Sendable {
    case confirmed
    case cancelled
}

public typealias PartnerPaymentHandler = @Sendable (CollectPaymentRequest) async throws -> PartnerPaymentResult

public struct GuavaSureEmbedCallbacks {
    public var partnerPaymentHandler: PartnerPaymentHandler?
    public var onPaymentLinkOpened: (() -> Void)?
    public var onLogout: (() async -> Void)?
    public var onGoBack: (() -> Void)?
    public var onLoadError: ((String) -> Void)?

    public init(
        partnerPaymentHandler: PartnerPaymentHandler? = nil,
        onPaymentLinkOpened: (() -> Void)? = nil,
        onLogout: (() async -> Void)? = nil,
        onGoBack: (() -> Void)? = nil,
        onLoadError: ((String) -> Void)? = nil
    ) {
        self.partnerPaymentHandler = partnerPaymentHandler
        self.onPaymentLinkOpened = onPaymentLinkOpened
        self.onLogout = onLogout
        self.onGoBack = onGoBack
        self.onLoadError = onLoadError
    }
}
