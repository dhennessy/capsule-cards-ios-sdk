import Foundation

public enum CapsuleCardsError: Error {
    case invalidResponse
    case requestError(Int, String)  // HTTP 4xx / 5xx
}

extension CapsuleCardsError: LocalizedError {
    struct ErrorBody: Decodable {
        let detail: String
    }
    
    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response received from server"
        case .requestError(let statusCode, let body):
            if let data = body.data(using: .utf8), let errorBody = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                return errorBody.detail
            } else {
                return "HTTP Error \(statusCode)"
            }
        }
    }
}
