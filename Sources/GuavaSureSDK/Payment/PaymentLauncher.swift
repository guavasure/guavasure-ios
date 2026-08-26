import Foundation
import Razorpay
import SafariServices
import UIKit

enum PaymentLaunchResult {
    case nativeSuccess(paymentId: String)
    case nativeFailure(message: String, cancelled: Bool)
    case browserOpened
    case failed
}

@MainActor
final class PaymentLauncher: NSObject {
    private var razorpay: RazorpayCheckout?
    private var nativeCompletion: ((PaymentLaunchResult) -> Void)?

    func launch(
        from viewController: UIViewController,
        request: OpenPaymentRequest,
        completion: @escaping (PaymentLaunchResult) -> Void
    ) {
        let presenter = Self.resolvePresenter(from: viewController)

        if request.canOpenNativeCheckout, let key = request.key {
            launchNative(from: presenter, request: request, key: key) { result in
                switch result {
                case .nativeSuccess, .nativeFailure(_, cancelled: true):
                    completion(result)
                case .nativeFailure:
                    self.launchBrowser(from: presenter, request: request, completion: completion)
                case .browserOpened, .failed:
                    completion(result)
                }
            }
            return
        }

        launchBrowser(from: presenter, request: request, completion: completion)
    }

    private func launchBrowser(
        from viewController: UIViewController,
        request: OpenPaymentRequest,
        completion: @escaping (PaymentLaunchResult) -> Void
    ) {
        guard PaymentUrlPolicy.isAllowed(request.url), let url = URL(string: request.url) else {
            completion(.failed)
            return
        }

        let safari = SFSafariViewController(url: url)
        safari.delegate = self
        viewController.present(safari, animated: true)
        completion(.browserOpened)
    }

    private func launchNative(
        from viewController: UIViewController,
        request: OpenPaymentRequest,
        key: String,
        completion: @escaping (PaymentLaunchResult) -> Void
    ) {
        if nativeCompletion != nil {
            completion(.nativeFailure(message: "Payment already in progress", cancelled: true))
            return
        }

        nativeCompletion = completion
        let razorpay = RazorpayCheckout.initWithKey(key, andDelegateWithData: self)
        self.razorpay = razorpay

        var options: [String: Any] = [
            "key": key,
            "name": request.name ?? "GuavaSure",
            "currency": request.currency ?? "INR",
            "theme": ["color": "#E85A4F"],
        ]
        if let description = request.description { options["description"] = description }
        if let orderId = request.orderId { options["order_id"] = orderId }
        if let subscriptionId = request.subscriptionId { options["subscription_id"] = subscriptionId }
        if let amount = request.amountPaise, amount > 0 { options["amount"] = amount }

        var prefill: [String: String] = [:]
        if let name = request.prefillName { prefill["name"] = name }
        if let email = request.prefillEmail { prefill["email"] = email }
        if let contact = request.prefillContact { prefill["contact"] = contact }
        if !prefill.isEmpty { options["prefill"] = prefill }

        // Child embed VCs must pass an ancestor in the window hierarchy (see razorpay-pod example).
        DispatchQueue.main.async {
            razorpay.open(options, displayController: viewController)
        }
    }

    private func finishNative(_ result: PaymentLaunchResult) {
        nativeCompletion?(result)
        nativeCompletion = nil
        razorpay = nil
    }

    private static func resolvePresenter(from viewController: UIViewController) -> UIViewController {
        var current = viewController
        while let parent = current.parent {
            current = parent
        }
        if let navigationController = current.navigationController {
            current = navigationController
        } else if let tabBarController = current.tabBarController {
            current = tabBarController
        }
        while let presented = current.presentedViewController {
            current = presented
        }
        return current
    }
}

extension PaymentLauncher: RazorpayPaymentCompletionProtocolWithData {
    nonisolated func onPaymentSuccess(_ payment_id: String, andData response: [AnyHashable: Any]?) {
        Task { @MainActor in
            finishNative(.nativeSuccess(paymentId: payment_id))
        }
    }

    nonisolated func onPaymentError(_ code: Int32, description str: String, andData response: [AnyHashable: Any]?) {
        Task { @MainActor in
            let cancelled = code == 2 &&
                str.localizedCaseInsensitiveContains("cancel")
            finishNative(.nativeFailure(message: str, cancelled: cancelled))
        }
    }
}

extension PaymentLauncher: SFSafariViewControllerDelegate {}
