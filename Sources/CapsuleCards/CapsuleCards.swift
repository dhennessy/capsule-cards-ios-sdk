import Foundation
import os

/// Shares your app's model values as links, and turns incoming links back into those values.
///
/// ```swift
/// CapsuleCards.configure(publishableKey: "cc_pk_live_…")
///
/// let link = try await CapsuleCards.shared.share(recipe)
/// ShareLink(item: link.url)
///
/// .onOpenURL { url in
///     Task {
///         if let recipe = try await CapsuleCards.shared.capsule(from: url, as: Recipe.self) { … }
///     }
/// }
/// ```
public final class CapsuleCards: Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var configured: CapsuleCards?

    private static let logger = Logger(subsystem: "cards.capsule.sdk", category: "CapsuleCards")
    private static let editTokenHeader = "X-Capsule-Edit-Token"

    private let publishableKey: String
    private let apiURL: URL
    private let session: URLSession
    private let editTokens: any EditTokenStore

    /// Sets up the shared instance. Call this once, when your app launches.
    public static func configure(publishableKey: String) {
        let instance = CapsuleCards(publishableKey: publishableKey)
        lock.withLock { configured = instance }
    }

    public static var shared: CapsuleCards {
        guard let instance = lock.withLock({ configured }) else {
            preconditionFailure("Call CapsuleCards.configure(publishableKey:) before using CapsuleCards.shared.")
        }
        return instance
    }

    public convenience init(publishableKey: String) {
        self.init(publishableKey: publishableKey, session: .shared, editTokens: KeychainEditTokenStore())
    }

    init(
        publishableKey: String,
        apiURL: URL = URL(string: "https://api.capsule.cards/v1/capsules")!,
        session: URLSession,
        editTokens: any EditTokenStore
    ) {
        // A secret key has full access to the app's capsules, and anyone can extract it from an app binary.
        precondition(!publishableKey.hasPrefix("cc_sk_"), "Never put a secret key in your app. Use a publishable key.")
        self.publishableKey = publishableKey
        self.apiURL = apiURL
        self.session = session
        self.editTokens = editTokens
    }

    // MARK: Sharing

    /// Creates a capsule from the value and returns its link, ready for the share sheet.
    public func share<Value: Shareable>(_ value: Value) async throws -> CapsuleLink {
        let (fields, images) = try Self.fields(for: value)
        var body = fields
        body["share_type"] = Value.shareType
        if !images.isEmpty {
            body["attachments"] = try Self.attachmentFields(for: images, preview: value.preview.image)
        }
        let data = try await send("POST", to: apiURL, body: body)
        let created = try Self.decode(CapsuleResponse.self, from: data)
        guard let link = CapsuleLink(url: created.url) else {
            throw CapsuleCardsError.invalidResponse
        }
        if let token = created.editToken {
            do {
                try editTokens.save(token, for: link.publicID)
            } catch {
                // The capsule exists and the link works, so still return it. It just can't be edited from here.
                Self.logger.error("Couldn't save the edit token for \(link.publicID): \(error)")
            }
        }
        do {
            try await upload(created.attachments, images: images, to: link, editToken: created.editToken)
        } catch {
            // A link that's missing its image shouldn't be left behind.
            try? await delete(link)
            throw error
        }
        return link
    }

    /// Updates a capsule in place. Its card and payload change at the same URL, within about a minute.
    public func update<Value: Shareable>(_ link: CapsuleLink, with value: Value) async throws {
        let token = try editToken(for: link)
        let (fields, images) = try Self.fields(for: value)
        var body = fields
        body["attachments"] = try Self.attachmentFields(for: images, preview: value.preview.image)
        let url = apiURL.appendingPathComponent(link.publicID)
        let data = try await send("PATCH", to: url, body: body, editToken: token)
        let updated = try Self.decode(CapsuleResponse.self, from: data)
        try await upload(updated.attachments, images: images, to: link, editToken: token)
    }

    /// Deletes a capsule. Its link stays live and shows a "no longer available" page.
    public func delete(_ link: CapsuleLink) async throws {
        let token = try editToken(for: link)
        do {
            try await send("DELETE", to: apiURL.appendingPathComponent(link.publicID), editToken: token)
        } catch CapsuleCardsError.capsuleDeleted {
            // Already gone, which is what the caller wanted.
        }
        try editTokens.remove(for: link.publicID)
    }

    // MARK: Receiving

    /// Turns an incoming link into a value of your type.
    ///
    /// Returns `nil` if the URL isn't a capsule link, or if the capsule is of a different share type, so you can
    /// try each of your types in turn.
    public func capsule<Value: Shareable>(from url: URL, as type: Value.Type) async throws -> Value? {
        guard let link = CapsuleLink(url: url), let readURL = Self.readURL(for: link) else {
            return nil
        }
        let data = try await send("GET", to: readURL)
        guard
            let capsule = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let shareType = capsule["share_type"] as? String,
            let payload = capsule["payload"] as? [String: Any],
            let attachmentList = capsule["attachments"]
        else {
            throw CapsuleCardsError.invalidResponse
        }
        guard shareType == Value.shareType else {
            return nil
        }
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        if let stored = capsule["schema_version"] as? Int, stored < Value.schemaVersion {
            return try Value.migrate(payloadData, from: stored)
        }
        let attachments = try Self.decode(
            [ReceivedAttachment].self, from: JSONSerialization.data(withJSONObject: attachmentList))
        let decoder = Self.payloadDecoder()
        decoder.userInfo[.receivedAttachments] = Dictionary(
            attachments.map { ($0.filename, $0) }, uniquingKeysWith: { first, _ in first })
        return try decoder.decode(Value.self, from: payloadData)
    }

    // MARK: Implementation

    private struct CapsuleResponse: Decodable {
        let url: URL
        let editToken: String?
        let attachments: [AttachmentResponse]

        enum CodingKeys: String, CodingKey {
            case url
            case editToken = "edit_token"
            case attachments
        }
    }

    private struct AttachmentResponse: Decodable {
        let uuid: String
        let filename: String
        let upload: Upload?
    }

    private struct Upload: Decodable {
        let url: URL
        let method: String
        let headers: [String: String]
    }

    /// Uploads each file the service is waiting for, straight to storage, and marks it complete.
    private func upload(
        _ attachments: [AttachmentResponse],
        images: [CapsuleImage],
        to link: CapsuleLink,
        editToken: String?
    ) async throws {
        for attachment in attachments {
            guard let upload = attachment.upload else {
                continue
            }
            guard let data = images.first(where: { $0.filename == attachment.filename })?.uploadableData else {
                throw CapsuleCardsError.attachmentUnavailable
            }
            var request = URLRequest(url: upload.url)
            request.httpMethod = upload.method
            for (name, value) in upload.headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
            let (body, response) = try await session.upload(for: request, from: data)
            try Self.validate(response, data: body)
            let complete = apiURL.appendingPathComponent(
                "\(link.publicID)/attachments/\(attachment.uuid)/complete")
            try await send("POST", to: complete, editToken: editToken)
        }
    }

    private static func attachmentFields(for images: [CapsuleImage], preview: CapsuleImage?) throws -> [[String: Any]] {
        try images.map { image in
            guard let size = image.size else {
                throw CapsuleCardsError.attachmentUnavailable
            }
            return [
                "filename": image.filename,
                "content_type": image.contentType,
                "size": size,
                "is_preview": image.filename == preview?.filename,
            ]
        }
    }

    /// Reads go to the link's own hostname, which is served from the edge rather than the API.
    private static func readURL(for link: CapsuleLink) -> URL? {
        var components = URLComponents(url: link.url, resolvingAgainstBaseURL: false)
        components?.path = "/v1/capsules/\(link.publicID)"
        components?.query = nil
        components?.fragment = nil
        return components?.url
    }

    private func editToken(for link: CapsuleLink) throws -> String {
        guard let token = try editTokens.token(for: link.publicID) else {
            throw CapsuleCardsError.missingEditToken
        }
        return token
    }

    private static func fields<Value: Shareable>(for value: Value) throws -> ([String: Any], [CapsuleImage]) {
        let collector = AttachmentCollector()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.userInfo[.attachmentCollector] = collector
        guard let payload = try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any] else {
            throw CapsuleCardsError.invalidPayload
        }
        let preview = value.preview
        if let image = preview.image {
            collector.add(image)
        }
        var fields: [String: Any] = [
            "title": preview.title,
            // Empty rather than absent, so that an update can clear a field.
            "description": preview.description ?? "",
            "og_type": preview.type ?? "",
            "payload": payload,
        ]
        // An uploaded preview sets the image URL when it completes, and an update mustn't clear that.
        if preview.image == nil {
            fields["image_url"] = preview.imageURL?.absoluteString ?? ""
        }
        if Value.schemaVersion > 0 {
            fields["schema_version"] = Value.schemaVersion
        }
        return (fields, collector.images)
    }

    private static func payloadDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CapsuleCardsError.invalidResponse
        }
    }

    @discardableResult
    private func send(
        _ method: String,
        to url: URL,
        body: [String: Any]? = nil,
        editToken: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        if let editToken {
            request.setValue(editToken, forHTTPHeaderField: Self.editTokenHeader)
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return data
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CapsuleCardsError.invalidResponse
        }
        switch http.statusCode {
        case 200...299:
            return
        case 404:
            throw CapsuleCardsError.capsuleNotFound
        case 410:
            throw CapsuleCardsError.capsuleDeleted
        default:
            throw CapsuleCardsError.requestError(http.statusCode, String(decoding: data, as: UTF8.self))
        }
    }
}
