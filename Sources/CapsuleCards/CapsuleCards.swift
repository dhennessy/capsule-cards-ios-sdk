import Foundation
import UniformTypeIdentifiers

public struct Attachment: Codable {
    public let capsuleUUID: String
    public let contentType: String?
    public let createdAt: Date
    public let filename: String?
    public let updatedAt: Date
    public let url: URL?
    public let uuid: String

    enum CodingKeys: String, CodingKey {
        case capsuleUUID = "capsule_uuid"
        case contentType = "content_type"
        case createdAt = "created_at"
        case filename
        case updatedAt = "updated_at"
        case url
        case uuid
    }
}

fileprivate struct AttachmentCreateRequest: Encodable {
    public let contentType: String?
    public let filename: String?
    public let url: URL?

    enum CodingKeys: String, CodingKey {
        case contentType = "content_type"
        case filename
        case url
    }
}

fileprivate struct AttachmentUploadParams: Codable {
    public let fields: [String: String]
    public let url: URL
}

public struct Capsule: Codable {
    public let createdAt: Date
    public let description: String?
    public let imageURL: URL?
    public let publicURL: URL
    public let templateUUID: String
    public let title: String
    public let type: String?
    public let updatedAt: Date
    public let uuid: String

    enum CodingKeys: String, CodingKey {
        case createdAt = "created_at"
        case description
        case imageURL = "image_url"
        case publicURL = "public_url"
        case templateUUID = "template_uuid"
        case title
        case type
        case updatedAt = "updated_at"
        case uuid
    }
}

fileprivate struct CapsuleCreateRequest: Encodable {
    let title: String
    let description: String?
    let imageURL: URL?
    let type: String?
    let templateUUID: String

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case imageURL = "image_url"
        case type
        case templateUUID = "template_uuid"
    }
}

fileprivate struct CapsuleUpdateRequest: Encodable {
    let title: String?
    let description: String?
    let imageURL: URL?
    let type: String?

    enum CodingKeys: String, CodingKey {
        case title
        case description
        case imageURL = "image_url"
        case type
    }
}


fileprivate struct MultipartFormDataBuilder {
    let boundary: String
    private let body = NSMutableData()

    func addField(name: String, value: String) {
        var fieldString = "--\(boundary)\r\n"
        fieldString += "Content-Disposition: form-data; name=\"\(name)\"\r\n"
        fieldString += "\r\n"
        fieldString += "\(value)\r\n"
        body.append(fieldString.data(using: .utf8)!)
    }
    
    func addFile(name: String, filename: String, data: Data, contentType: String) {
        var fieldString = "--\(boundary)\r\n"
        fieldString += "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n"
        fieldString += "Content-Type: \(contentType)\r\n"
        fieldString += "\r\n"
        body.append(fieldString.data(using: .utf8)!)
        body.append(data)
        body.append("\r\n".data(using: .utf8)!)
    }
    
    func addFinalBoundary() {
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
    }
    
    var data: Data {
        body as Data
    }
}

public struct Client {
    let baseURL: URL
    let session: URLSession
    public var apiKey: String
    
    public init(apiKey: String, baseURL: URL = URL(string: "https://api.capsule.cards/v1/capsules/")!, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }
    
    public func createCapsule(title: String, templateUUID: String, description: String? = nil, imageURL: URL? = nil, type: String? = nil) async throws -> Capsule {
        let body = CapsuleCreateRequest(title: title, description: description, imageURL: imageURL, type: type, templateUUID: templateUUID)
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted]
        let jsonData = try jsonEncoder.encode(body)
        
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        let (data, response) = try await session.data(for: request)
        
        try validateHttpResponse(data: data, response: response)
        return try getJSONDecoder().decode(Capsule.self, from: data)
    }
    
    public func getCapsule(uuid: String) async throws -> Capsule {
        let url = baseURL.appendingPathComponent("\(uuid)/")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validateHttpResponse(data: data, response: response)
        return try getJSONDecoder().decode(Capsule.self, from: data)
    }
    
    public func updateCapsule(uuid: String, title: String? = nil, description: String? = nil, imageURL: URL? = nil, type: String? = nil) async throws -> Capsule {
        let body = CapsuleUpdateRequest(title: title, description: description, imageURL: imageURL, type: type)
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted]
        let jsonData = try jsonEncoder.encode(body)

        let url = baseURL.appendingPathComponent("\(uuid)")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        let (data, response) = try await session.data(for: request)
        
        try validateHttpResponse(data: data, response: response)
        return try getJSONDecoder().decode(Capsule.self, from: data)
    }

    public func getAttachment(capsuleUUID: String, uuid: String) async throws -> Attachment {
        let url = baseURL.appendingPathComponent("\(capsuleUUID)/attachments/\(uuid)")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try validateHttpResponse(data: data, response: response)
        return try getJSONDecoder().decode(Attachment.self, from: data)
    }
    
    public func createAttachment(capsuleUUID: String, filename: String, contentType: String? = nil) async throws -> Attachment {
        let body = AttachmentCreateRequest(contentType: contentType, filename: filename, url: nil)
        let jsonEncoder = JSONEncoder()
        jsonEncoder.outputFormatting = [.prettyPrinted]
        let jsonData = try jsonEncoder.encode(body)

        let url = baseURL.appendingPathComponent("\(capsuleUUID)/attachments")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        let (data, response) = try await session.data(for: request)

        try validateHttpResponse(data: data, response: response)
        return try getJSONDecoder().decode(Attachment.self, from: data)
    }

    fileprivate func getAttachmentUploadParams(capsuleUUID: String, attachmentUUID: String) async throws -> AttachmentUploadParams {
        let url = baseURL.appendingPathComponent("\(capsuleUUID)/attachments/\(attachmentUUID)/upload")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)

        try validateHttpResponse(data: data, response: response)
        return try getJSONDecoder().decode(AttachmentUploadParams.self, from: data)
    }
    
    fileprivate func uploadImageData(to url: URL, fields: [String: String], data: Data, filename: String, contentType: String?) async throws {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let builder = MultipartFormDataBuilder(boundary: boundary)
        for (key, value) in fields {
            builder.addField(name: key, value: value)
        }
        builder.addFile(name: filename, filename: filename, data: data, contentType: contentType ?? "application/octet-stream")
        builder.addFinalBoundary()
        request.httpBody = builder.data
        let (data, response) = try await session.data(for: request)
        
        try validateHttpResponse(data: data, response: response)
    }
    
    public func createAttachment(capsuleUUID: String, filename: String, contentType: String? = nil, data: Data) async throws -> Attachment {
        var attachment = try await createAttachment(capsuleUUID: capsuleUUID, filename: filename, contentType: contentType)
        let uploadParams = try await getAttachmentUploadParams(capsuleUUID: capsuleUUID, attachmentUUID: attachment.uuid)
        try await uploadImageData(to: uploadParams.url, fields: uploadParams.fields, data: data, filename: filename, contentType: contentType)
        attachment = try await getAttachment(capsuleUUID: capsuleUUID, uuid: attachment.uuid)

        return attachment
    }
    
    // MARK: Implementation helpers
    
    private func validateHttpResponse(data: Data, response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CapsuleCardsError.invalidResponse
        }
        
        switch http.statusCode {
        case 200...299:
            return
            
        case 400...599:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CapsuleCardsError.requestError(http.statusCode, body)
            
        default:
            throw CapsuleCardsError.invalidResponse
        }
    }
    
    private func getJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                return date
            } else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date string \(dateString)")
            }
        }
        return decoder
    }
}
