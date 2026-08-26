# GuavaSure iOS SDK

Swift Package that embeds the hosted GuavaSure insurance flow in `WKWebView` and implements `GuavasureBridge` for native Razorpay Checkout, file pick, camera capture, and partner auth.

**Full integration guide:** [partners.guavasure.com — iOS SDK](https://partners.guavasure.com/integration/docs/integrations/ios-sdk)

## Features

Same bridge protocol as the Android SDK and [`guavasure_flutter`](https://pub.dev/packages/guavasure_flutter):

- `GuavasureBridge` WKWebView channel
- Native Razorpay Checkout (via `razorpay-pod`)
- SFSafariViewController payment link fallback
- No embed reload on Safari return (embed polls in background)
- File pick, logout, go-back callbacks
- Optional partner-collected payment handler

## Quick start

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/guavasure/guavasure-ios.git", from: "1.0.1"),
],
```

Repository: [github.com/guavasure/guavasure-ios](https://github.com/guavasure/guavasure-ios)

### Usage

```swift
import GuavaSureSDK

let embed = GuavaSureEmbedViewController()
embed.configure(
    config: GuavaSureEmbedConfig(
        partnerId: "YOUR_PARTNER_ID",
        environment: .sandbox,
        partnerAuthTokenProvider: {
            try await yourBackend.mintCustomerAuthToken(userId: userId)
        }
    ),
    callbacks: GuavaSureEmbedCallbacks(
        onLogout: { await dismissEmbed() },
        onGoBack: { navigationController?.popViewController(animated: true) }
    )
)
navigationController?.pushViewController(embed, animated: true)
embed.loadEmbed()
```

### Info.plist

```xml
<key>NSCameraUsageDescription</key>
<string>Used to capture pet photos for insurance claims.</string>
```

## Embed URL

```
https://embed.guavasure.com?partner=...&env=sandbox&platform=app-webview&partner-auth-token=...
```

## Payment behavior

| Path                            | On success                              |
| ------------------------------- | --------------------------------------- |
| Native Razorpay SDK             | Embed keeps polling and advances flow   |
| SFSafariViewController fallback | No reload — embed polling advances flow |

## Requirements

- iOS 15+
- Swift 5.9+
- Xcode 15+

## Related

- [Android SDK](https://partners.guavasure.com/integration/docs/integrations/android-sdk)
- [Flutter plugin](https://pub.dev/packages/guavasure_flutter)
- [Mobile WebView protocol](https://partners.guavasure.com/integration/docs/integrations/mobile-webview)
