import Foundation

enum EmbedOriginPolicy {
    static func resolveAllowedOrigins(config: GuavaSureEmbedConfig) -> Set<String> {
        if let override = config.embedUrlOverride, !override.isEmpty,
           let origin = normalizeOrigin(URL(string: override)) {
            return [origin]
        }
        if let host = config.localDevHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            var components = URLComponents()
            components.scheme = config.localDevScheme
            components.host = host
            components.port = config.localDevPort
            if let origin = normalizeOrigin(components.url) {
                return [origin]
            }
        }
        if let origin = normalizeOrigin(URL(string: config.embedBaseUrl)) {
            return [origin]
        }
        return []
    }

    static func isAllowed(_ url: URL, allowedOrigins: Set<String>) -> Bool {
        guard let origin = normalizeOrigin(url) else { return false }
        return allowedOrigins.contains(origin)
    }

    private static func normalizeOrigin(_ url: URL?) -> String? {
        guard let url, let host = url.host?.lowercased(), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        let port = url.port ?? defaultPort(scheme)
        if isDefaultPort(scheme: scheme, port: port) {
            return "\(scheme)://\(host)"
        }
        return "\(scheme)://\(host):\(port)"
    }

    private static func defaultPort(scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }

    private static func isDefaultPort(scheme: String, port: Int) -> Bool {
        port == defaultPort(scheme: scheme)
    }
}

enum PaymentUrlPolicy {
    static func isAllowed(_ url: String) -> Bool {
        guard let components = URLComponents(string: url),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased() else {
            return false
        }
        if host == "rzp.io" || host == "razorpay.me" { return true }
        if host == "razorpay.com" || host.hasSuffix(".razorpay.com") { return true }
        return false
    }
}
