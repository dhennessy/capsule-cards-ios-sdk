# CapsuleCards

Share your app's content as a link that opens straight in your app, and as a web page for everyone else.

```swift
import CapsuleCards

struct Recipe: Shareable {
    static let shareType = "recipe"

    var name: String
    var servings: Int

    var preview: CapsulePreview {
        CapsulePreview(title: name, description: "Serves \(servings)")
    }
}

// Once, when your app launches
CapsuleCards.configure(publishableKey: "cc_pk_live_…")

// Share
let link = try await CapsuleCards.shared.share(recipe)
ShareLink(item: link.url)

// Update or delete, from the device that shared it
try await CapsuleCards.shared.update(link, with: editedRecipe)
try await CapsuleCards.shared.delete(link)

// Receive
.onOpenURL { url in
    Task {
        if let recipe = try await CapsuleCards.shared.capsule(from: url, as: Recipe.self) {
            // Import the recipe
        }
    }
}
```

Add `applinks:<your-slug>.capsule.cards` to your app's Associated Domains so links open your app.

`capsule(from:as:)` returns `nil` for a URL that isn't a capsule link, or a capsule of a different share type, so
an app with several share types can try each in turn.

Updates can take about a minute to appear, because the service caches capsules at the edge. Links can only be
updated or deleted from the device that shared them, because each capsule's edit token stays in that device's
Keychain.

The SDK uses App Attest automatically on supported devices. Add the App Attest capability to your app, then choose
`Report` or `Enforce` for the app in the dashboard. Attestation can't run in the Simulator, so use `Off` or `Report`
during development.

Use only your publishable key in your app. The SDK stops with an error if you give it a secret key.
