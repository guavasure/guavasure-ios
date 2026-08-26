import Foundation

enum JsStringEncoding {
    /// Produces a JSON-encoded string literal safe for embedding in `evaluateJavaScript`.
    static func quote(_ value: String) -> String {
        if let data = try? JSONEncoder().encode(value),
           let encoded = String(data: data, encoding: .utf8) {
            return encoded
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
