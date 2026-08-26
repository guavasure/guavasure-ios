import Foundation

enum GuavaSureUrlBuilder {
    static func buildEmbedUrl(config: GuavaSureEmbedConfig, partnerAuthToken: String?) -> String {
        if let override = config.embedUrlOverride, !override.isEmpty {
            return override
        }

        var params: [String: String] = [
            "partner": config.partnerId,
            "platform": config.platform,
        ]
        if config.environment == .sandbox {
            params["env"] = "sandbox"
        }
        if let token = partnerAuthToken, !token.isEmpty {
            params["partner-auth-token"] = token
        }
        if let externalId = config.partnerExternalId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !externalId.isEmpty {
            params["partner-external-id"] = externalId
        }
        if config.enableCameraCapture {
            params["enable-camera-capture"] = "true"
        }

        if let host = config.localDevHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            var components = URLComponents()
            components.scheme = config.localDevScheme
            components.host = host
            components.port = config.localDevPort
            components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
            return components.url?.absoluteString ?? config.embedBaseUrl
        }

        guard var components = URLComponents(string: config.embedBaseUrl) else {
            return config.embedBaseUrl
        }
        var items = components.queryItems ?? []
        for (key, value) in params {
            items.removeAll { $0.name == key }
            items.append(URLQueryItem(name: key, value: value))
        }
        components.queryItems = items
        return components.url?.absoluteString ?? config.embedBaseUrl
    }
}
