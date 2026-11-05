import Foundation
import XCTest
@testable import SnapInsertCore

/// Opt in after deployment: SNAPINSERT_RELAY_INTEGRATION_URL=https://your-relay.example swift test
/// These tests use fresh random rooms and never inspect an existing user's transfers.
final class RelayIntegrationTests: XCTestCase {
    private func endpoint() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["SNAPINSERT_RELAY_INTEGRATION_URL"],
              let url = URL(string: raw) else {
            throw XCTSkip("Set SNAPINSERT_RELAY_INTEGRATION_URL to test a deployed HTTPS relay.")
        }
        return try RelayEndpoint.validated(url)
    }

    private func authorizedPairing(name: String, invitationVariable: String) async throws -> PairingInfo {
        let pairing = try PairingInfo.create(name: name, relayURL: endpoint())
        guard let code = ProcessInfo.processInfo.environment[invitationVariable] else {
            throw XCTSkip("Supply a dedicated group invitation to test authorized public relay transfers.")
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: RelayInvitation.request(code: code, pairing: pairing))
        try RelayInvitation.validateResponse(data: data, response: response)
        return pairing
    }

    @MainActor
    func testPublicRelayRejectsUnenrolledRoom() async throws {
        let pairing = try PairingInfo.create(name: "Isolated unauthorized test", relayURL: endpoint())
        let mac = RelayChannel(pairing: pairing, role: .mac)
        let denied = expectation(description: "Unenrolled room gets authorization callback")
        var cleaningUp = false
        mac.onAuthorizationRequired = { _ in denied.fulfill() }
        mac.onReady = { XCTFail("Unenrolled room admitted") }
        mac.onPeerUnavailable = { XCTFail("Unenrolled room allocated"); denied.fulfill() }
        mac.onClose = { _ in if !cleaningUp { XCTFail("Expected authorization-specific close"); denied.fulfill() } }
        defer { cleaningUp = true; mac.cancel() }
        mac.start()
        await fulfillment(of: [denied], timeout: 20)
    }

    @MainActor
    func testPublicRelayPhotoReceiptAndPeerOffline() async throws {
        let pairing = try await authorizedPairing(name: "Isolated integration test",
                                                  invitationVariable: "SNAPINSERT_RELAY_PHOTO_INVITATION")
        let mac = RelayChannel(pairing: pairing, role: .mac)
        let phone = RelayChannel(pairing: pairing, role: .phone)
        let macReady = expectation(description: "Mac sees phone online")
        let phoneReady = expectation(description: "Phone sees Mac online")
        let receipt = expectation(description: "Phone receives authenticated Mac receipt")
        let offline = expectation(description: "Mac stays connected after phone disconnects")
        let request = WireMessage.photoRequest(id: UUID(), attempt: UUID())
        let jpeg = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
        var authorization = PhotoAuthorization()
        var isMacReady = false
        var isPhoneReady = false
        var testingOffline = false
        var cleaningUp = false
        mac.onReady = { if !isMacReady { isMacReady = true; macReady.fulfill() } }
        phone.onReady = { if !isPhoneReady { isPhoneReady = true; phoneReady.fulfill() } }
        mac.onClose = { reason in if !cleaningUp { XCTFail(reason) } }
        phone.onClose = { reason in if !cleaningUp && !testingOffline { XCTFail(reason) } }
        mac.onPeerUnavailable = { if testingOffline { offline.fulfill() } }
        mac.onMessage = { received in
            do {
                if let challenge = authorization.issue(for: received) {
                    XCTAssertEqual(received, request)
                    try mac.send(challenge)
                } else {
                    XCTAssertTrue(authorization.consume(received))
                    XCTAssertEqual(received.jpeg, jpeg)
                    try mac.send(.receipt(id: received.id, status: "pasted", detail: "Integration receipt",
                                          attempt: received.attempt))
                }
            }
            catch { XCTFail(error.localizedDescription) }
        }
        phone.onMessage = { received in
            XCTAssertEqual(received.id, request.id)
            XCTAssertEqual(received.attempt, request.attempt)
            if received.kind == .photoChallenge {
                do {
                    try phone.send(.photo(id: request.id, jpeg: jpeg, attempt: request.attempt,
                                          challenge: XCTUnwrap(received.challenge)))
                } catch { XCTFail(error.localizedDescription) }
            } else {
                XCTAssertEqual(received.status, "pasted")
                receipt.fulfill()
            }
        }
        defer { cleaningUp = true; phone.cancel(); mac.cancel() }
        mac.start()
        phone.start()
        await fulfillment(of: [macReady, phoneReady], timeout: 20)
        try phone.send(request)
        await fulfillment(of: [receipt], timeout: 20)
        testingOffline = true
        phone.cancel()
        await fulfillment(of: [offline], timeout: 10)
    }

    @MainActor
    func testPublicRelaySameRoleReplacementCallsOnlyOnReplaced() async throws {
        let pairing = try await authorizedPairing(name: "Isolated replacement test",
                                                  invitationVariable: "SNAPINSERT_RELAY_REPLACEMENT_INVITATION")
        let original = RelayChannel(pairing: pairing, role: .phone)
        let replacement = RelayChannel(pairing: pairing, role: .phone)
        let originalConnected = expectation(description: "Original authenticated socket")
        let replaced = expectation(description: "Close 4001 handled without reconnect callback")
        let replacementConnected = expectation(description: "Replacement authenticated socket")
        var cleaningUp = false
        original.onPeerUnavailable = { originalConnected.fulfill() }
        original.onReplaced = { replaced.fulfill() }
        original.onClose = { reason in if !cleaningUp { XCTFail("Unexpected onClose: \(reason)") } }
        replacement.onPeerUnavailable = { replacementConnected.fulfill() }
        replacement.onClose = { reason in if !cleaningUp { XCTFail(reason) } }
        defer { cleaningUp = true; original.cancel(); replacement.cancel() }
        original.start()
        await fulfillment(of: [originalConnected], timeout: 20)
        replacement.start()
        await fulfillment(of: [replaced, replacementConnected], timeout: 20)
    }
}
