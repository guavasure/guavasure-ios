import UIKit
import WebKit

extension GuavaSureTheme {
    /// Shown until the embed paints, so dark-mode apps don't flash white. The chrome bridge then
    /// switches to the page's real background.
    var initialBackgroundColor: UIColor {
        switch self {
        case .light: return .white
        case .dark: return UIColor(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255, alpha: 1)
        }
    }

    static func applyInitialBackground(_ theme: GuavaSureTheme?, to webView: WKWebView) {
        guard let theme else { return }
        webView.isOpaque = false
        webView.backgroundColor = theme.initialBackgroundColor
        webView.scrollView.backgroundColor = theme.initialBackgroundColor
    }
}
