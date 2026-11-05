import Foundation

public enum CapsuleCardsError: Error, Equatable {
    /// The server's response wasn't what the SDK expected.
    case invalidResponse
    /// The server rejected the request, with its HTTP status and response body.
    case requestError(Int, String)
    /// The capsule doesn't exist, or belongs to another app.
    case capsuleNotFound
    /// The capsule was deleted. Its link stays live and shows a "no longer available" page.
    case capsuleDeleted
    /// This device has no edit token for the capsule, so it can't change it. This happens after a reinstall,
    /// or on a device other than the one that shared the capsule.
    case missingEditToken
    /// The value didn't encode to a JSON object, which is what a capsule's payload must be.
    case invalidPayload
    /// An image's file isn't available, because it hasn't finished uploading or couldn't be downloaded.
    case attachmentUnavailable
    /// The capsule was written with an older schema version and the type doesn't implement `migrate`.
    case migrationRequired(fromVersion: Int)
}

extension CapsuleCardsError: LocalizedError {
    private struct ErrorBody: Decodable {
        let detail: String
    }

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response received from server"
        case .requestError(let statusCode, let body):
            if let data = body.data(using: .utf8), let errorBody = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                return errorBody.detail
            }
            return "HTTP Error \(statusCode)"
        case .capsuleNotFound:
            return "This capsule could not be found"
        case .capsuleDeleted:
            return "This capsule is no longer available"
        case .missingEditToken:
            return "This device can't change this capsule"
        case .invalidPayload:
            return "The value couldn't be encoded as a JSON object"
        case .attachmentUnavailable:
            return "This image isn't available"
        case .migrationRequired(let version):
            return "This capsule uses schema version \(version), which this app can't read"
        }
    }
}
