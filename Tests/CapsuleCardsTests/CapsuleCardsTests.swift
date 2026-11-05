import Foundation
import Testing

@testable import CapsuleCards

struct Recipe: Shareable, Equatable {
    static let shareType = "recipe"
    static let schemaVersion = 2

    var name: String
    var servings: Int
    var addedOn: Date?

    var preview: CapsulePreview {
        CapsulePreview(title: name, description: "Serves \(servings)", imageURL: URL(string: "https://a.example/i.jpg"))
    }

    static func migrate(_ payload: Data, from version: Int) throws -> Recipe {
        struct OldRecipe: Decodable { let title: String }
        return Recipe(name: try JSONDecoder().decode(OldRecipe.self, from: payload).title, servings: 1)
    }
}

struct Note: Shareable, Equatable {
    var text: String
    var preview: CapsulePreview { CapsulePreview(title: text) }
}

final class MemoryTokens: EditTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String: String] = [:]
    var failsToSave = false

    func token(for publicID: String) throws -> String? { lock.withLock { tokens[publicID] } }
    func save(_ token: String, for publicID: String) throws {
        if failsToSave { throw KeychainError(status: -1) }
        lock.withLock { tokens[publicID] = token }
    }
    func remove(for publicID: String) throws { lock.withLock { tokens[publicID] = nil } }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = "{}"
    }

    nonisolated(unsafe) static var reply = Reply()
    nonisolated(unsafe) static var requests: [(request: URLRequest, body: Data?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requests.append((request, Self.readBody(of: request)))
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readBody(of request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return request.httpBody }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

let linkURL = URL(string: "https://mealmate.capsule.cards/aB3dE5gH7j")!
let created = #"{"public_id":"aB3dE5gH7j","url":"https://mealmate.capsule.cards/aB3dE5gH7j","edit_token":"token-1"}"#

func capsuleJSON(shareType: String = "recipe", version: String = "2", payload: String) -> String {
    #"{"public_id":"aB3dE5gH7j","share_type":"\#(shareType)","schema_version":\#(version),"payload":\#(payload)}"#
}

@Suite(.serialized)
final class CapsuleCardsTests {
    let tokens = MemoryTokens()
    let sdk: CapsuleCards

    init() {
        StubProtocol.reply = .init()
        StubProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        sdk = CapsuleCards(
            publishableKey: "cc_pk_live_test", session: URLSession(configuration: configuration), editTokens: tokens)
    }

    var lastRequest: URLRequest { StubProtocol.requests.last!.request }

    var lastBody: [String: Any] {
        try! JSONSerialization.jsonObject(with: StubProtocol.requests.last!.body!) as! [String: Any]
    }

    func link() -> CapsuleLink { CapsuleLink(url: linkURL)! }

    // MARK: Sharing

    @Test func shareSendsThePreviewPayloadAndKey() async throws {
        StubProtocol.reply = .init(status: 201, body: created)
        let link = try await sdk.share(Recipe(name: "Lasagne", servings: 6))

        #expect(link.url == linkURL)
        #expect(link.publicID == "aB3dE5gH7j")
        #expect(lastRequest.url?.absoluteString == "https://api.capsule.cards/v1/capsules")
        #expect(lastRequest.httpMethod == "POST")
        #expect(lastRequest.value(forHTTPHeaderField: "Authorization") == "Bearer cc_pk_live_test")
        #expect(lastBody["share_type"] as? String == "recipe")
        #expect(lastBody["schema_version"] as? Int == 2)
        #expect(lastBody["title"] as? String == "Lasagne")
        #expect(lastBody["description"] as? String == "Serves 6")
        #expect(lastBody["image_url"] as? String == "https://a.example/i.jpg")
        #expect((lastBody["payload"] as? [String: Any])?["servings"] as? Int == 6)
    }

    @Test func shareStoresTheEditToken() async throws {
        StubProtocol.reply = .init(status: 201, body: created)
        _ = try await sdk.share(Note(text: "Hello"))
        #expect(try tokens.token(for: "aB3dE5gH7j") == "token-1")
    }

    @Test func aTypeWithNoSchemaUsesTheDefaultShareTypeAndSendsNoVersion() async throws {
        StubProtocol.reply = .init(status: 201, body: created)
        _ = try await sdk.share(Note(text: "Hello"))
        #expect(lastBody["share_type"] as? String == "default")
        #expect(lastBody["schema_version"] == nil)
    }

    @Test func aKeychainFailureStillReturnsTheLink() async throws {
        tokens.failsToSave = true
        StubProtocol.reply = .init(status: 201, body: created)
        let link = try await sdk.share(Note(text: "Hello"))
        #expect(link.url == linkURL)
    }

    @Test func serverErrorsSurfaceWithTheirDetail() async throws {
        StubProtocol.reply = .init(status: 400, body: #"{"detail":"Nope."}"#)
        let error = await #expect(throws: CapsuleCardsError.self) { try await self.sdk.share(Note(text: "Hello")) }
        #expect(error?.errorDescription == "Nope.")
    }

    @Test func anUnreadableCreateResponseIsAnError() async throws {
        StubProtocol.reply = .init(status: 201, body: "not json")
        await #expect(throws: CapsuleCardsError.invalidResponse) { try await self.sdk.share(Note(text: "Hello")) }
    }

    // MARK: Updating and deleting

    @Test func updateSendsTheEditToken() async throws {
        try tokens.save("token-1", for: "aB3dE5gH7j")
        try await sdk.update(link(), with: Recipe(name: "Changed", servings: 2))
        #expect(lastRequest.httpMethod == "PATCH")
        #expect(lastRequest.url?.absoluteString == "https://api.capsule.cards/v1/capsules/aB3dE5gH7j")
        #expect(lastRequest.value(forHTTPHeaderField: "X-Capsule-Edit-Token") == "token-1")
        #expect(lastBody["title"] as? String == "Changed")
        #expect(lastBody["share_type"] == nil)
    }

    @Test func updateClearsFieldsTheValueNoLongerHas() async throws {
        try tokens.save("token-1", for: "aB3dE5gH7j")
        try await sdk.update(link(), with: Note(text: "Changed"))
        #expect(lastBody["description"] as? String == "")
        #expect(lastBody["image_url"] as? String == "")
    }

    @Test func updateNeedsAnEditToken() async throws {
        await #expect(throws: CapsuleCardsError.missingEditToken) {
            try await self.sdk.update(self.link(), with: Note(text: "Changed"))
        }
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func deleteSendsTheEditTokenAndForgetsIt() async throws {
        try tokens.save("token-1", for: "aB3dE5gH7j")
        StubProtocol.reply = .init(status: 204, body: "")
        try await sdk.delete(link())
        #expect(lastRequest.httpMethod == "DELETE")
        #expect(lastRequest.value(forHTTPHeaderField: "X-Capsule-Edit-Token") == "token-1")
        #expect(try tokens.token(for: "aB3dE5gH7j") == nil)
    }

    @Test func deletingACapsuleThatIsAlreadyGoneSucceeds() async throws {
        try tokens.save("token-1", for: "aB3dE5gH7j")
        StubProtocol.reply = .init(status: 410, body: #"{"detail":"Gone."}"#)
        try await sdk.delete(link())
        #expect(try tokens.token(for: "aB3dE5gH7j") == nil)
    }

    // MARK: Receiving

    @Test func capsuleReadsFromTheLinksOwnHostname() async throws {
        StubProtocol.reply = .init(body: capsuleJSON(payload: #"{"name":"Lasagne","servings":6}"#))
        let recipe = try await sdk.capsule(from: linkURL, as: Recipe.self)
        #expect(recipe == Recipe(name: "Lasagne", servings: 6))
        #expect(lastRequest.url?.absoluteString == "https://mealmate.capsule.cards/v1/capsules/aB3dE5gH7j")
        #expect(lastRequest.httpMethod == "GET")
        #expect(lastRequest.value(forHTTPHeaderField: "Authorization") == "Bearer cc_pk_live_test")
    }

    @Test func aQueryStringOnTheLinkIsIgnored() async throws {
        StubProtocol.reply = .init(body: capsuleJSON(payload: #"{"name":"Lasagne","servings":6}"#))
        let url = URL(string: "https://mealmate.capsule.cards/aB3dE5gH7j?utm=1")!
        _ = try await sdk.capsule(from: url, as: Recipe.self)
        #expect(lastRequest.url?.absoluteString == "https://mealmate.capsule.cards/v1/capsules/aB3dE5gH7j")
    }

    @Test func aDifferentShareTypeReturnsNil() async throws {
        StubProtocol.reply = .init(body: capsuleJSON(shareType: "meal_plan", payload: "{}"))
        #expect(try await sdk.capsule(from: linkURL, as: Recipe.self) == nil)
    }

    @Test(arguments: [
        "https://mealmate.capsule.cards/",
        "https://mealmate.capsule.cards/tooshort",
        "https://mealmate.capsule.cards/aB3dE5gH7j/extra",
        "https://mealmate.capsule.cards/aB3dE5gH7!",
        "http://mealmate.capsule.cards/aB3dE5gH7j",
        "mealmate://aB3dE5gH7j",
    ])
    func urlsThatAreNotCapsuleLinksReturnNilWithoutARequest(url: String) async throws {
        #expect(try await sdk.capsule(from: URL(string: url)!, as: Recipe.self) == nil)
        #expect(StubProtocol.requests.isEmpty)
    }

    @Test func anOlderSchemaVersionGoesThroughMigrate() async throws {
        StubProtocol.reply = .init(body: capsuleJSON(version: "1", payload: #"{"title":"Old"}"#))
        let recipe = try await sdk.capsule(from: linkURL, as: Recipe.self)
        #expect(recipe == Recipe(name: "Old", servings: 1))
    }

    @Test func anOlderVersionWithNoMigrationThrows() async throws {
        struct Strict: Shareable {
            static let schemaVersion = 2
            var preview: CapsulePreview { CapsulePreview(title: "") }
        }
        StubProtocol.reply = .init(body: capsuleJSON(shareType: "default", version: "1", payload: "{}"))
        await #expect(throws: CapsuleCardsError.migrationRequired(fromVersion: 1)) {
            _ = try await self.sdk.capsule(from: linkURL, as: Strict.self)
        }
    }

    @Test func aNewerSchemaVersionIsDecodedDirectly() async throws {
        StubProtocol.reply = .init(body: capsuleJSON(version: "3", payload: #"{"name":"New","servings":2,"extra":true}"#))
        #expect(try await sdk.capsule(from: linkURL, as: Recipe.self) == Recipe(name: "New", servings: 2))
    }

    @Test func aCapsuleWithNoVersionIsDecodedDirectly() async throws {
        StubProtocol.reply = .init(body: capsuleJSON(version: "null", payload: #"{"name":"Plain","servings":2}"#))
        #expect(try await sdk.capsule(from: linkURL, as: Recipe.self) == Recipe(name: "Plain", servings: 2))
    }

    @Test func datesSurviveTheRoundTrip() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        StubProtocol.reply = .init(status: 201, body: created)
        _ = try await sdk.share(Recipe(name: "Dated", servings: 1, addedOn: date))
        let payload = try #require(lastBody["payload"] as? [String: Any])
        #expect(payload["addedOn"] as? String == "2027-01-15T08:00:00Z")

        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        StubProtocol.reply = .init(body: capsuleJSON(payload: json))
        #expect(try await sdk.capsule(from: linkURL, as: Recipe.self)?.addedOn == date)
    }

    @Test func missingAndDeletedCapsulesThrow() async throws {
        StubProtocol.reply = .init(status: 404, body: "{}")
        await #expect(throws: CapsuleCardsError.capsuleNotFound) {
            _ = try await self.sdk.capsule(from: linkURL, as: Recipe.self)
        }
        StubProtocol.reply = .init(status: 410, body: "{}")
        await #expect(throws: CapsuleCardsError.capsuleDeleted) {
            _ = try await self.sdk.capsule(from: linkURL, as: Recipe.self)
        }
    }

    // MARK: Links

    @Test func linksAreCodable() throws {
        let data = try JSONEncoder().encode(link())
        #expect(try JSONDecoder().decode(CapsuleLink.self, from: data) == link())
    }
}
