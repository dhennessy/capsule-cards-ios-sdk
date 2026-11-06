import CryptoKit
import Foundation
import Testing

@testable import CapsuleCards

final class FakeAttester: DeviceAttester, @unchecked Sendable {
    var isSupported = true
    var attestHashes: [Data] = []
    var assertionHashes: [Data] = []
    var failAttest = false
    private(set) var generated = 0

    func generateKey() async throws -> String {
        generated += 1
        return "key-\(generated)"
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        if failAttest { throw CapsuleCardsError.invalidResponse }
        attestHashes.append(clientDataHash)
        return Data("attestation-\(keyID)".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        assertionHashes.append(clientDataHash)
        return Data("assertion-\(keyID)".utf8)
    }
}

private let session = #"{"session_token":"session-1","expires_in":3600}"#

extension CapsuleCardsTests {
    private func attestedSDK(_ attester: FakeAttester, keys: MemoryTokens = MemoryTokens()) -> CapsuleCards {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return CapsuleCards(
            publishableKey: "cc_pk_live_test",
            session: URLSession(configuration: configuration),
            editTokens: tokens,
            attester: attester,
            attestationKeys: keys)
    }

    private func route(mode: String = "enforce", assertionStatus: Int = 200) {
        StubProtocol.handler = { request in
            switch request.url?.path {
            case "/v1/attest/challenge":
                let challenge = mode == "off" ? "null" : #""challenge-1""#
                return .init(body: #"{"mode":"\#(mode)","challenge":\#(challenge)}"#)
            case "/v1/attest":
                return .init(status: 201, body: session)
            case "/v1/attest/assertion":
                return .init(status: assertionStatus, body: session)
            default:
                return .init(status: 201, body: created)
            }
        }
    }

    private func paths() -> [String] {
        StubProtocol.requests.compactMap { $0.request.url?.path }
    }

    private func createRequests() -> [URLRequest] {
        StubProtocol.requests.map(\.request).filter { $0.url?.path == "/v1/capsules" }
    }

    private var challengeHash: Data { Data(SHA256.hash(data: Data("challenge-1".utf8))) }

    @Test func aNewDeviceAttestsAndSendsItsSessionWithTheWrite() async throws {
        route()
        let attester = FakeAttester()
        let keys = MemoryTokens()
        _ = try await attestedSDK(attester, keys: keys).share(Note(text: "Hi"))

        #expect(paths() == ["/v1/attest/challenge", "/v1/attest", "/v1/capsules"])
        #expect(attester.attestHashes == [challengeHash])
        #expect(createRequests().first?.value(forHTTPHeaderField: "X-Capsule-Device-Session") == "session-1")
        #expect(try keys.token(for: "device-key") == "key-1")
        let body = try #require(StubProtocol.requests[1].body)
        let fields = try JSONSerialization.jsonObject(with: body) as? [String: String]
        #expect(fields?["key_id"] == "key-1")
        #expect(fields?["challenge"] == "challenge-1")
        #expect(fields?["attestation"] == Data("attestation-key-1".utf8).base64EncodedString())
    }

    @Test func aSessionIsReusedAcrossWrites() async throws {
        route()
        let sdk = attestedSDK(FakeAttester())
        _ = try await sdk.share(Note(text: "One"))
        _ = try await sdk.share(Note(text: "Two"))
        #expect(paths().filter { $0.hasPrefix("/v1/attest") }.count == 2)
        #expect(createRequests().count == 2)
    }

    @Test func anExistingKeyUsesAnAssertionInsteadOfAttestingAgain() async throws {
        route()
        let attester = FakeAttester()
        let keys = MemoryTokens()
        try keys.save("key-saved", for: "device-key")
        _ = try await attestedSDK(attester, keys: keys).share(Note(text: "Hi"))
        #expect(paths() == ["/v1/attest/challenge", "/v1/attest/assertion", "/v1/capsules"])
        #expect(attester.assertionHashes == [challengeHash])
        #expect(attester.generated == 0)
    }

    @Test func aRejectedAssertionReplacesTheKey() async throws {
        route(assertionStatus: 400)
        let keys = MemoryTokens()
        try keys.save("key-saved", for: "device-key")
        _ = try await attestedSDK(FakeAttester(), keys: keys).share(Note(text: "Hi"))
        #expect(
            paths() == [
                "/v1/attest/challenge", "/v1/attest/assertion", "/v1/attest/challenge", "/v1/attest", "/v1/capsules",
            ])
        #expect(try keys.token(for: "device-key") == "key-1")
        #expect(createRequests().first?.value(forHTTPHeaderField: "X-Capsule-Device-Session") == "session-1")
    }

    @Test func whenAttestationIsOffTheDeviceDoesNotAttestOrAskAgainStraightAway() async throws {
        route(mode: "off")
        let attester = FakeAttester()
        let sdk = attestedSDK(attester)
        _ = try await sdk.share(Note(text: "One"))
        _ = try await sdk.share(Note(text: "Two"))
        #expect(paths().filter { $0 == "/v1/attest/challenge" }.count == 1)
        #expect(attester.generated == 0)
        #expect(createRequests().allSatisfy { $0.value(forHTTPHeaderField: "X-Capsule-Device-Session") == nil })
    }

    @Test func anUnsupportedDeviceMakesNoAttestationRequests() async throws {
        route()
        let attester = FakeAttester()
        attester.isSupported = false
        _ = try await attestedSDK(attester).share(Note(text: "Hi"))
        #expect(paths() == ["/v1/capsules"])
    }

    @Test func aFailedAttestationStillSendsTheWriteAndKeepsNoKey() async throws {
        route()
        let attester = FakeAttester()
        attester.failAttest = true
        let keys = MemoryTokens()
        _ = try await attestedSDK(attester, keys: keys).share(Note(text: "Hi"))
        #expect(createRequests().first?.value(forHTTPHeaderField: "X-Capsule-Device-Session") == nil)
        #expect(try keys.token(for: "device-key") == nil)
    }

    @Test func readsDoNotAttest() async throws {
        route()
        StubProtocol.handler = nil
        StubProtocol.reply = .init(body: capsuleJSON(payload: #"{"name":"L","servings":1}"#))
        _ = try await attestedSDK(FakeAttester()).capsule(from: linkURL, as: Recipe.self)
        #expect(paths() == ["/v1/capsules/aB3dE5gH7j"])
    }
}
