import Foundation

public enum GuavaSureEnvironment: String, Sendable {
    case production
    case sandbox
}

/// Embed colour scheme, sent as the `theme` URL param.
///
/// `.dark` uses the partner's dark theme when GuavaSure has enabled one for the partner and it is
/// switched on in the Partner Dashboard; otherwise the embed stays light.
public enum GuavaSureTheme: String, Sendable {
    case light
    case dark
}

public struct GuavaSureEmbedConfig: Sendable {
    public let partnerId: String
    public let environment: GuavaSureEnvironment
    /// Static JWT fallback. Prefer `partnerAuthTokenProvider`.
    @available(*, deprecated, message: "Use partnerAuthTokenProvider instead. Static tokens are one-use and short-lived; the SDK will not mint a fresh JWT on warmup or reload.")
    public var partnerAuthToken: String? { fallbackPartnerAuthToken }
    /// Fallback JWT when `partnerAuthTokenProvider` is nil.
    let fallbackPartnerAuthToken: String?
    public let partnerAuthTokenProvider: (@Sendable () async throws -> String?)?
    public let partnerExternalId: String?
    public let embedBaseUrl: String
    public let embedUrlOverride: String?
    public let platform: String
    public let localDevHost: String?
    public let localDevPort: Int
    public let localDevScheme: String
    /// Opt-in native camera bridge. When enabled, the SDK requests camera access when needed.
    public let enableCameraCapture: Bool
    /// Alternate partner customization from Embed → Theme configs (`theme-config-id` URL param).
    public let themeConfigId: String?
    /// When true, the embed URL includes `claim-mode=true` so home is a claims-focused Policy Details screen.
    public let claimMode: Bool
    /// Whether `partnerExternalId` locks the embed to that pet. When false, the embed URL includes
    /// `partner-pet-lock=false`: the pet is selected initially, other pets stay visible and the
    /// customer can switch. Ignored when `partnerExternalId` is unset.
    public let lockPet: Bool
    /// Embed colour scheme (`theme` URL param). Pass `.dark` when your app is in dark mode.
    /// Nil sends no param and the embed shows the light theme.
    public let theme: GuavaSureTheme?

    public static let defaultEmbedBaseUrl = "https://embed.guavasure.com"
    public static let appWebviewPlatform = "app-webview"

    /// - Parameter partnerAuthToken: Deprecated. Use `partnerAuthTokenProvider` instead.
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
        enableCameraCapture: Bool = false,
        themeConfigId: String? = nil,
        claimMode: Bool = false,
        lockPet: Bool = true,
        theme: GuavaSureTheme? = nil
    ) {
        self.partnerId = partnerId
        self.environment = environment
        self.fallbackPartnerAuthToken = partnerAuthToken
        self.partnerAuthTokenProvider = partnerAuthTokenProvider
        self.partnerExternalId = partnerExternalId
        self.embedBaseUrl = embedBaseUrl
        self.embedUrlOverride = embedUrlOverride
        self.platform = platform
        self.localDevHost = localDevHost
        self.localDevPort = localDevPort
        self.localDevScheme = localDevScheme
        self.enableCameraCapture = enableCameraCapture
        self.themeConfigId = themeConfigId
        self.claimMode = claimMode
        self.lockPet = lockPet
        self.theme = theme
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
