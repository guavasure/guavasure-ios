import Foundation
import WebKit

enum ChunkedJsDelivery {
    static func resolveFilePick(
        webView: WKWebView,
        requestId: String,
        payload: [String: String]?
    ) async {
        let encodedId = jsQuote(requestId)
        guard let payload else {
            await evaluate(webView, "window.__guavasureResolveFilePick(\(encodedId), null);")
            return
        }

        guard let base64 = payload["base64"] else {
            await evaluate(webView, "window.__guavasureResolveFilePick(\(encodedId), null);")
            return
        }

        if base64.count <= BridgeConstants.base64ChunkSize,
           let json = jsonString(payload) {
            await evaluate(webView, "window.__guavasureResolveFilePick(\(encodedId), \(json));")
            return
        }

        let meta: [String: String] = [
            "name": payload["name"] ?? "upload",
            "mimeType": payload["mimeType"] ?? "application/octet-stream",
        ]
        guard let metaJson = jsonString(meta) else {
            await evaluate(webView, "window.__guavasureResolveFilePick(\(encodedId), null);")
            return
        }

        await evaluate(
            webView,
            """
            (function () {
              window.__guavasurePickBuffers = window.__guavasurePickBuffers || {};
              window.__guavasurePickBuffers[\(encodedId)] = '';
            })();
            """
        )

        var offset = base64.startIndex
        while offset < base64.endIndex {
            let end = base64.index(
                offset,
                offsetBy: BridgeConstants.base64ChunkSize,
                limitedBy: base64.endIndex
            ) ?? base64.endIndex
            let chunk = String(base64[offset..<end])
            let encodedChunk = jsQuote(chunk)
            await evaluate(
                webView,
                """
                (function () {
                  window.__guavasurePickBuffers[\(encodedId)] += \(encodedChunk);
                })();
                """
            )
            offset = end
        }

        await evaluate(
            webView,
            """
            (function () {
              var requestId = \(encodedId);
              var meta = \(metaJson);
              var base64 = window.__guavasurePickBuffers[requestId] || '';
              delete window.__guavasurePickBuffers[requestId];
              window.__guavasureResolveFilePick(requestId, {
                name: meta.name,
                mimeType: meta.mimeType,
                base64: base64,
              });
            })();
            """
        )
    }

    static func signalNativePaymentEnded(webView: WKWebView, cancelled: Bool) async {
        await evaluate(
            webView,
            """
            (function () {
              if (typeof window.__guavasureAbortExternalPayment === 'function') {
                window.__guavasureAbortExternalPayment(\(cancelled ? "true" : "false"));
              }
            })();
            """
        )
    }

    private static func evaluate(_ webView: WKWebView, _ script: String) async {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { _, _ in
                continuation.resume()
            }
        }
    }

    private static func jsQuote(_ value: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    private static func jsonString(_ object: [String: String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }
}
