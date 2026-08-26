import Foundation

enum BridgeConstants {
    static let channelName = "GuavasureBridge"
    static let openPayment = "open-payment"
    static let guavasurePayment = "guavasure:payment"
    static let collectPayment = "COLLECT_PAYMENT"
    static let paymentConfirmed = "PAYMENT_CONFIRMED"
    static let paymentCancelled = "PAYMENT_CANCELLED"
    static let pickFile = "pick-file"
    static let logout = "logout"
    static let goBack = "go-back"
    static let chromeColor = "chrome-color"
    static let capturePhoto = "capture-photo"
    static let cameraPermission = "camera-permission"
    static let openCameraSettings = "open-camera-settings"
    static let base64ChunkSize = 16_000
    static let maxFileBytes = 10 * 1024 * 1024
}

struct OpenPaymentRequest {
    let url: String
    let quoteId: String?
    let orderId: String?
    let subscriptionId: String?
    let key: String?
    let amountPaise: Int?
    let currency: String?
    let name: String?
    let description: String?
    let prefillName: String?
    let prefillEmail: String?
    let prefillContact: String?

    var canOpenNativeCheckout: Bool {
        guard let key, !key.isEmpty else { return false }
        return !(orderId?.isEmpty ?? true) || !(subscriptionId?.isEmpty ?? true)
    }
}

final class BridgeDispatcher {
    struct Callbacks {
        var onOpenPayment: (OpenPaymentRequest) -> Void = { _ in }
        var onCollectPayment: (CollectPaymentRequest) -> Void = { _ in }
        var onPickFile: (String, String) -> Void = { _, _ in }
        var onCameraPermission: (String) -> Void = { _ in }
        var onCapturePhoto: (String) -> Void = { _ in }
        var onOpenCameraSettings: () -> Void = {}
        var onLogout: () -> Void = {}
        var onGoBack: () -> Void = {}
        var onChromeColor: (String, String) -> Void = { _, _ in }
    }

    var callbacks = Callbacks()

    func dispatch(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare(BridgeConstants.logout) == .orderedSame {
            callbacks.onLogout()
            return
        }
        if trimmed.caseInsensitiveCompare(BridgeConstants.goBack) == .orderedSame {
            callbacks.onGoBack()
            return
        }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        let type = (json["type"] as? String) ?? ""
        let event = (json["event"] as? String) ?? ""

        switch type {
        case BridgeConstants.logout:
            callbacks.onLogout()
        case BridgeConstants.goBack:
            callbacks.onGoBack()
        case BridgeConstants.chromeColor:
            if let background = json["background"] as? String, !background.isEmpty {
                let status = (json["statusBarStyle"] as? String) ?? "dark"
                callbacks.onChromeColor(background, status)
            }
        case BridgeConstants.openCameraSettings:
            callbacks.onOpenCameraSettings()
        case BridgeConstants.cameraPermission:
            if let requestId = json["requestId"] as? String, !requestId.isEmpty {
                callbacks.onCameraPermission(requestId)
            }
        case BridgeConstants.capturePhoto:
            if let requestId = json["requestId"] as? String, !requestId.isEmpty {
                callbacks.onCapturePhoto(requestId)
            }
        case BridgeConstants.pickFile:
            if let requestId = json["requestId"] as? String, !requestId.isEmpty {
                let accept = (json["accept"] as? String) ?? "image/*"
                callbacks.onPickFile(requestId, accept)
            }
        case BridgeConstants.openPayment:
            let url = (json["url"] as? String) ?? ""
            let request = parseOpenPayment(json, url: url)
            if !url.isEmpty || request.canOpenNativeCheckout {
                callbacks.onOpenPayment(request)
            }
        case BridgeConstants.guavasurePayment where event == BridgeConstants.collectPayment:
            guard let payload = json["data"] as? [String: Any],
                  let intentId = payload["intentId"] as? String,
                  let quoteId = payload["quoteId"] as? String,
                  let amount = payload["amount"] as? NSNumber,
                  let currency = payload["currency"] as? String,
                  let planLabel = payload["planLabel"] as? String else {
                return
            }
            callbacks.onCollectPayment(
                CollectPaymentRequest(
                    intentId: intentId,
                    quoteId: quoteId,
                    amount: amount,
                    currency: currency,
                    planLabel: planLabel
                )
            )
        default:
            if event.caseInsensitiveCompare(BridgeConstants.logout) == .orderedSame {
                callbacks.onLogout()
            } else if event.caseInsensitiveCompare(BridgeConstants.goBack) == .orderedSame {
                callbacks.onGoBack()
            }
        }
    }

    private func parseOpenPayment(_ json: [String: Any], url: String) -> OpenPaymentRequest {
        let prefill = json["prefill"] as? [String: Any]
        return OpenPaymentRequest(
            url: url,
            quoteId: json["quoteId"] as? String,
            orderId: json["orderId"] as? String,
            subscriptionId: json["subscriptionId"] as? String,
            key: json["key"] as? String,
            amountPaise: intValue(json["amountPaise"]),
            currency: json["currency"] as? String,
            name: json["name"] as? String,
            description: json["description"] as? String,
            prefillName: prefill?["name"] as? String,
            prefillEmail: prefill?["email"] as? String,
            prefillContact: prefill?["contact"] as? String
        )
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        case let double as Double:
            return Int(double)
        default:
            return nil
        }
    }

    func buildPaymentConfirmedScript(intentId: String, quoteId: String) -> String {
        buildPartnerPaymentScript(event: BridgeConstants.paymentConfirmed, intentId: intentId, quoteId: quoteId)
    }

    func buildPaymentCancelledScript(intentId: String, quoteId: String) -> String {
        buildPartnerPaymentScript(event: BridgeConstants.paymentCancelled, intentId: intentId, quoteId: quoteId)
    }

    private func buildPartnerPaymentScript(event: String, intentId: String, quoteId: String) -> String {
        let payload: [String: Any] = [
            "type": BridgeConstants.guavasurePayment,
            "event": event,
            "data": ["intentId": intentId, "quoteId": quoteId],
            "timestamp": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else {
            return ""
        }
        return """
        (function() {
          var msg = \(json);
          window.dispatchEvent(new MessageEvent('message', { data: msg }));
        })();
        """
    }
}
