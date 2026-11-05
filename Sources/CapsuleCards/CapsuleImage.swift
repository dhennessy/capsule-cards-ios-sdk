import Foundation

/// An image that travels with a capsule, for use as a property of your `Shareable` type.
///
/// The bytes are uploaded to storage when you share. Only a small reference goes in the payload, so a recipient
/// gets a `CapsuleImage` that downloads the file when you call `data()`.
public struct CapsuleImage: Codable, Hashable, Sendable {
    /// Unique within the capsule. A value keeps its filename, so updating a capsule doesn't upload it again.
    public let filename: String
    public let contentType: String
    /// Where the image can be downloaded. `nil` until the capsule has been received from the service.
    public let url: URL?

    let size: Int?
    private let bytes: Data?

    /// An image to share, from JPEG data.
    public init(jpeg data: Data) {
        filename = "\(UUID().uuidString.lowercased()).jpg"
        contentType = "image/jpeg"
        url = nil
        size = data.count
        bytes = data
    }

    init(filename: String, contentType: String, size: Int?, url: URL?) {
        self.filename = filename
        self.contentType = contentType
        self.size = size
        self.url = url
        bytes = nil
    }

    var uploadableData: Data? { bytes }

    /// The image's bytes, downloading them if needed.
    public func data(session: URLSession = .shared) async throws -> Data {
        if let bytes {
            return bytes
        }
        guard let url else {
            throw CapsuleCardsError.attachmentUnavailable
        }
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CapsuleCardsError.attachmentUnavailable
        }
        return data
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case attachment
    }

    public func encode(to encoder: any Encoder) throws {
        (encoder.userInfo[.attachmentCollector] as? AttachmentCollector)?.add(self)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(filename, forKey: .attachment)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let filename = try container.decode(String.self, forKey: .attachment)
        let attachments = decoder.userInfo[.receivedAttachments] as? [String: ReceivedAttachment]
        let attachment = attachments?[filename]
        self.init(
            filename: filename,
            contentType: attachment?.contentType ?? "application/octet-stream",
            size: attachment?.size,
            url: attachment?.url)
    }
}

/// An attachment as the service describes it when a capsule is read.
struct ReceivedAttachment: Decodable, Sendable {
    let filename: String
    let contentType: String
    let size: Int?
    let url: URL

    enum CodingKeys: String, CodingKey {
        case filename
        case contentType = "content_type"
        case size
        case url
    }
}

/// Gathers the images a value contains while it's being encoded, wherever they are in the value.
final class AttachmentCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String: CapsuleImage] = [:]

    func add(_ image: CapsuleImage) {
        lock.withLock { collected[image.filename] = image }
    }

    var images: [CapsuleImage] {
        lock.withLock { collected.values.sorted { $0.filename < $1.filename } }
    }
}

extension CodingUserInfoKey {
    static let attachmentCollector = CodingUserInfoKey(rawValue: "cards.capsule.attachmentCollector")!
    static let receivedAttachments = CodingUserInfoKey(rawValue: "cards.capsule.receivedAttachments")!
}
