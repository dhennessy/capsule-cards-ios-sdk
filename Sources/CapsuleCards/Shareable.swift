import Foundation

/// A model value your app can share as a capsule.
///
/// ```swift
/// struct Recipe: Shareable {
///     static let shareType = "recipe"
///
///     var name: String
///     var servings: Int
///
///     var preview: CapsulePreview {
///         CapsulePreview(title: name, description: "Serves \(servings)")
///     }
/// }
/// ```
public protocol Shareable: Codable {
    /// The share type's key from the dashboard. Defaults to the default share type.
    static var shareType: String { get }

    /// The schema version this type writes. Defaults to `0`, for a share type with no schema.
    static var schemaVersion: Int { get }

    /// How the capsule appears in link previews and on its web page.
    var preview: CapsulePreview { get }

    /// Reads a payload written with an older schema version. Capsules are never rewritten, so links
    /// shared long ago still arrive with the version they were written with.
    static func migrate(_ payload: Data, from version: Int) throws -> Self
}

extension Shareable {
    public static var shareType: String { "default" }
    public static var schemaVersion: Int { 0 }

    public static func migrate(_ payload: Data, from version: Int) throws -> Self {
        throw CapsuleCardsError.migrationRequired(fromVersion: version)
    }
}

/// The Open Graph fields of a capsule.
public struct CapsulePreview: Hashable, Sendable {
    public var title: String
    public var description: String?
    public var imageURL: URL?
    /// The Open Graph type, such as `article`. Defaults to `website` on the card.
    public var type: String?

    public init(title: String, description: String? = nil, imageURL: URL? = nil, type: String? = nil) {
        self.title = title
        self.description = description
        self.imageURL = imageURL
        self.type = type
    }
}

/// A capsule's public link. It's `Codable`, so you can store it to update or delete the capsule later.
public struct CapsuleLink: Codable, Hashable, Sendable {
    private static let publicIDLength = 10

    public let publicID: String
    public let url: URL

    /// Reads a capsule link, returning `nil` for anything else: capsule links are https URLs of the form
    /// `https://<hostname>/<public_id>`.
    public init?(url: URL) {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            return nil
        }
        let publicID = String(url.path.dropFirst())
        guard url.path.hasPrefix("/"), Self.isPublicID(publicID) else {
            return nil
        }
        self.publicID = publicID
        self.url = url
    }

    private static func isPublicID(_ value: String) -> Bool {
        value.count == publicIDLength && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
