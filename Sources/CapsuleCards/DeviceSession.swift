import CryptoKit
import Foundation
import os

/// Keeps a short-lived session token that proves requests come from a genuine copy of the app on a real device.
///
/// This never fails a request by itself. If there's no token, the request goes out without one and the service
/// applies the app's attestation mode, so a developer controls what happens from the dashboard.
actor DeviceSession {
    private static let logger = Logger(subsystem: "cards.capsule.sdk", category: "DeviceSession")
    private static let keyAccount = "device-key"
    /// How long to wait before asking again, after finding attestation is off or after a failure.
    private static let retryInterval: TimeInterval = 300
    /// Renew this long before the token expires, so that a token isn't used as it runs out.
    private static let expiryMargin: TimeInterval = 60

    private let attester: any DeviceAttester
    private let keys: any EditTokenStore
    private let baseURL: URL
    private let publishableKey: String
    private let session: URLSession

    private var token: String?
    private var tokenExpiry = Date.distantPast
    private var nextAttempt = Date.distantPast
    private var inFlight: Task<String?, Never>?

    init(
        attester: any DeviceAttester,
        keys: any EditTokenStore,
        baseURL: URL,
        publishableKey: String,
        session: URLSession
    ) {
        self.attester = attester
        self.keys = keys
        self.baseURL = baseURL
        self.publishableKey = publishableKey
        self.session = session
    }

    /// The current token, renewing it if needed, or `nil` if the device can't or needn't attest.
    func currentToken() async -> String? {
        if let token, Date.now < tokenExpiry {
            return token
        }
        guard attester.isSupported, Date.now >= nextAttempt else {
            return nil
        }
        // Actors can interleave at each await, so concurrent writes share one attempt rather than each making one.
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await renew() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func renew() async -> String? {
        do {
            guard let challenge = try await fetchChallenge() else {
                nextAttempt = Date.now.addingTimeInterval(Self.retryInterval)
                return nil
            }
            let response = try await establishSession(challenge: challenge)
            token = response.sessionToken
            tokenExpiry = Date.now.addingTimeInterval(TimeInterval(response.expiresIn) - Self.expiryMargin)
            return response.sessionToken
        } catch {
            Self.logger.error("Couldn't attest this device: \(error)")
            nextAttempt = Date.now.addingTimeInterval(Self.retryInterval)
            return nil
        }
    }

    private func establishSession(challenge: String) async throws -> SessionResponse {
        if let keyID = try keys.token(for: Self.keyAccount) {
            do {
                return try await assert(keyID: keyID, challenge: challenge)
            } catch {
                // The key can stop working, for example after restoring to a new device. Start again with a new one.
                Self.logger.info("Replacing the App Attest key: \(error)")
                try keys.remove(for: Self.keyAccount)
                guard let fresh = try await fetchChallenge() else {
                    throw CapsuleCardsError.invalidResponse
                }
                return try await attestNewKey(challenge: fresh)
            }
        }
        return try await attestNewKey(challenge: challenge)
    }

    private func attestNewKey(challenge: String) async throws -> SessionResponse {
        let keyID = try await attester.generateKey()
        let attestation = try await attester.attestKey(keyID, clientDataHash: Self.hash(challenge))
        let response = try await post(
            "attest",
            body: ["key_id": keyID, "attestation": attestation.base64EncodedString(), "challenge": challenge])
        // Saved only once the service has accepted it, because Apple allows a key to be attested only once.
        try keys.save(keyID, for: Self.keyAccount)
        return try JSONDecoder().decode(SessionResponse.self, from: response)
    }

    private func assert(keyID: String, challenge: String) async throws -> SessionResponse {
        let assertion = try await attester.generateAssertion(keyID, clientDataHash: Self.hash(challenge))
        let response = try await post(
            "attest/assertion",
            body: ["key_id": keyID, "assertion": assertion.base64EncodedString(), "challenge": challenge])
        return try JSONDecoder().decode(SessionResponse.self, from: response)
    }

    private func fetchChallenge() async throws -> String? {
        let response = try await post("attest/challenge", body: nil)
        return try JSONDecoder().decode(ChallengeResponse.self, from: response).challenge
    }

    private func post(_ path: String, body: [String: String]?) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(publishableKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(status) else {
            throw CapsuleCardsError.invalidResponse
        }
        return data
    }

    private static func hash(_ challenge: String) -> Data {
        Data(SHA256.hash(data: Data(challenge.utf8)))
    }

    private struct ChallengeResponse: Decodable {
        let challenge: String?
    }

    private struct SessionResponse: Decodable {
        let sessionToken: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case sessionToken = "session_token"
            case expiresIn = "expires_in"
        }
    }
}
