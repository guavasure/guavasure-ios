import WebKit

/// Injects `window.GuavasureBridge.postMessage` for WKWebView.
///
/// Android exposes this via `@JavascriptInterface`; Flutter via `addJavaScriptChannel`.
/// WKWebView only provides `webkit.messageHandlers` unless we polyfill the same API
/// the hosted embed expects.
enum BridgeInjection {
    static let userScriptSource = """
    (function () {
      if (window.GuavasureBridge) return;
      var handler =
        window.webkit &&
        window.webkit.messageHandlers &&
        window.webkit.messageHandlers.\(BridgeConstants.channelName);
      if (!handler) return;
      window.GuavasureBridge = {
        postMessage: function (message) {
          handler.postMessage(message);
        },
      };
    })();
    """

    static func install(into controller: WKUserContentController) {
        for injectionTime: WKUserScriptInjectionTime in [.atDocumentStart, .atDocumentEnd] {
            let script = WKUserScript(
                source: userScriptSource,
                injectionTime: injectionTime,
                forMainFrameOnly: true
            )
            controller.addUserScript(script)
        }
    }

    static func reinject(into webView: WKWebView) {
        webView.evaluateJavaScript(userScriptSource, completionHandler: nil)
    }
}
