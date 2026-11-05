import Foundation
import Testing

@testable import CapsuleCards

struct Snapshot: Shareable, Equatable {
    var caption: String
    var photo: CapsuleImage
    var preview: CapsulePreview { CapsulePreview(title: caption, image: photo) }
}

private let uploadJSON = #"{"url":"https://bucket.example/put?sig=1","method":"PUT","headers":{"Content-Type":"image/jpeg","x-amz-acl":"public-read"}}"#

private func capsuleResponse(filename: String, upload: String = uploadJSON, token: String = #""token-1""#) -> String {
    #"{"public_id":"aB3dE5gH7j","url":"https://mealmate.capsule.cards/aB3dE5gH7j","edit_token":\#(token),"attachments":[{"uuid":"att-1","filename":"\#(filename)","upload":\#(upload)}]}"#
}

extension CapsuleCardsTests {
    private func routeUploads(filename: String, upload: String = uploadJSON, failUpload: Bool = false) {
        StubProtocol.handler = { request in
            switch (request.httpMethod, request.url?.host, request.url?.path) {
            case ("POST", _, "/v1/capsules"), ("PATCH", _, "/v1/capsules/aB3dE5gH7j"):
                return .init(status: 201, body: capsuleResponse(filename: filename, upload: upload))
            case ("PUT", "bucket.example", _):
                return .init(status: failUpload ? 403 : 200, body: "")
            case ("DELETE", _, _):
                return .init(status: 204, body: "")
            default:
                return .init(body: "{}")
            }
        }
    }

    private func requests(_ method: String) -> [(request: URLRequest, body: Data?)] {
        StubProtocol.requests.filter { $0.request.httpMethod == method }
    }

    @Test func shareUploadsTheImageThenCompletesIt() async throws {
        let image = CapsuleImage(jpeg: Data([1, 2, 3]))
        routeUploads(filename: image.filename)
        _ = try await sdk.share(Snapshot(caption: "Hi", photo: image))

        let create = try JSONSerialization.jsonObject(with: try #require(requests("POST").first?.body)) as? [String: Any]
        let attachments = try #require(create?["attachments"] as? [[String: Any]])
        #expect(attachments.count == 1)
        #expect(attachments[0]["filename"] as? String == image.filename)
        #expect(attachments[0]["content_type"] as? String == "image/jpeg")
        #expect(attachments[0]["size"] as? Int == 3)
        #expect(attachments[0]["is_preview"] as? Bool == true)
        #expect(create?["image_url"] == nil)
        let payload = try #require(create?["payload"] as? [String: Any])
        #expect(payload["photo"] as? [String: String] == ["attachment": image.filename])

        let put = try #require(requests("PUT").first)
        #expect(put.request.url?.absoluteString == "https://bucket.example/put?sig=1")
        #expect(put.request.value(forHTTPHeaderField: "x-amz-acl") == "public-read")
        #expect(put.request.value(forHTTPHeaderField: "Content-Type") == "image/jpeg")
        #expect(put.request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(put.body == Data([1, 2, 3]))

        let complete = try #require(requests("POST").last?.request)
        #expect(complete.url?.path == "/v1/capsules/aB3dE5gH7j/attachments/att-1/complete")
        #expect(complete.value(forHTTPHeaderField: "X-Capsule-Edit-Token") == "token-1")
    }

    @Test func aFailedUploadDeletesTheCapsuleAndThrows() async throws {
        let image = CapsuleImage(jpeg: Data([1]))
        routeUploads(filename: image.filename, failUpload: true)
        await #expect(throws: CapsuleCardsError.self) {
            _ = try await self.sdk.share(Snapshot(caption: "Hi", photo: image))
        }
        #expect(requests("DELETE").count == 1)
        #expect(try tokens.token(for: "aB3dE5gH7j") == nil)
    }

    @Test func updateDoesNotUploadAnImageTheServiceAlreadyHas() async throws {
        let image = CapsuleImage(jpeg: Data([1, 2]))
        try tokens.save("token-1", for: "aB3dE5gH7j")
        routeUploads(filename: image.filename, upload: "null")
        try await sdk.update(link(), with: Snapshot(caption: "Changed", photo: image))
        #expect(requests("PUT").isEmpty)
        let body = try JSONSerialization.jsonObject(with: try #require(requests("PATCH").first?.body)) as? [String: Any]
        #expect((body?["attachments"] as? [[String: Any]])?.count == 1)
        // Sending this would wipe the image from the card, because nothing completes to set it again.
        #expect(body?["image_url"] == nil)
    }

    @Test func updateWithoutImagesSendsAnEmptyList() async throws {
        try tokens.save("token-1", for: "aB3dE5gH7j")
        StubProtocol.reply = .init(body: updated)
        try await sdk.update(link(), with: Note(text: "Changed"))
        #expect((lastBody["attachments"] as? [Any])?.isEmpty == true)
    }

    @Test func receivingResolvesTheImageToItsURL() async throws {
        let attachments = #"[{"uuid":"a","filename":"p.jpg","content_type":"image/jpeg","size":3,"url":"https://media.example/p.jpg","is_preview":true}]"#
        StubProtocol.reply = .init(
            body: capsuleJSON(
                shareType: "default", version: "null", payload: #"{"caption":"Hi","photo":{"attachment":"p.jpg"}}"#,
                attachments: attachments))
        let snapshot = try await sdk.capsule(from: linkURL, as: Snapshot.self)
        #expect(snapshot?.photo.url?.absoluteString == "https://media.example/p.jpg")
        #expect(snapshot?.photo.contentType == "image/jpeg")
    }

    @Test func anImageStillUploadingHasNoURL() async throws {
        StubProtocol.reply = .init(
            body: capsuleJSON(
                shareType: "default", version: "null", payload: #"{"caption":"Hi","photo":{"attachment":"p.jpg"}}"#))
        let snapshot = try #require(try await sdk.capsule(from: linkURL, as: Snapshot.self))
        #expect(snapshot.photo.url == nil)
        await #expect(throws: CapsuleCardsError.attachmentUnavailable) {
            _ = try await snapshot.photo.data()
        }
    }

    @Test func aLocalImageReturnsItsOwnBytes() async throws {
        #expect(try await CapsuleImage(jpeg: Data([9])).data() == Data([9]))
    }

    @Test func eachImageGetsItsOwnFilename() {
        #expect(CapsuleImage(jpeg: Data()).filename != CapsuleImage(jpeg: Data()).filename)
    }
}
