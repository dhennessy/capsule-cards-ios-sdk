import Foundation

#if os(iOS)
import DeviceCheck
#endif

/// Apple's App Attest, behind a protocol so that tests can stand in for it.
protocol DeviceAttester: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

#if os(iOS)
struct AppleDeviceAttester: DeviceAttester {
    var isSupported: Bool { DCAppAttestService.shared.isSupported }

    func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}
#else
/// App Attest on macOS has different rules, and the service doesn't verify them yet.
struct AppleDeviceAttester: DeviceAttester {
    var isSupported: Bool { false }

    func generateKey() async throws -> String { throw CapsuleCardsError.invalidResponse }
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data { throw CapsuleCardsError.invalidResponse }
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        throw CapsuleCardsError.invalidResponse
    }
}
#endif
