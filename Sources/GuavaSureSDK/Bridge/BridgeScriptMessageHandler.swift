import WebKit

final class BridgeScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var owner: GuavaSureEmbedViewController?

    init(owner: GuavaSureEmbedViewController) {
        self.owner = owner
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        owner?.handleBridgeMessage(message)
    }
}
