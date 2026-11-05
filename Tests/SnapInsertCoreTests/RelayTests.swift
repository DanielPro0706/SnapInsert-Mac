import Foundation
import XCTest
@testable import SnapInsertCore

final class RelayTests: XCTestCase {
    func testInvitationRequestBindsOnlyRoutingRoomAndUsesHTTPSBody() throws {
        let pairing = try PairingInfo.create(name: "Invitation test")
        let code = "SI-" + String(repeating: "a", count: 32)
        let request = try RelayInvitation.request(code: " \(code)\n", pairing: pairing)
        let cipher = try RelayCipher(pairing: pairing)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.path, "/v1/snapinsert/invitations/redeem")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(cipher.relayToken)")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["code": code, "room": cipher.room])
        for invalid in ["", "SI-short", code + "a", "SI-" + String(repeating: "你", count: 32)] {
            XCTAssertThrowsError(try RelayInvitation.request(code: invalid, pairing: pairing))
        }
    }

    func testInvitationRequiresExplicitAuthorizationAndMapsFailure() throws {
        let url = URL(string: "https://relay.example.org/v1/snapinsert/invitations/redeem")!
        func response(_ status: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        }
        try RelayInvitation.validateResponse(data: Data(#"{"status":"authorized"}"#.utf8), response: response(200))
        XCTAssertThrowsError(try RelayInvitation.validateResponse(data: Data(), response: response(200)))
        for status in [301, 400, 403, 409, 429, 503] {
            XCTAssertThrowsError(try RelayInvitation.validateResponse(data: Data(), response: response(status)))
        }
    }

    func testV2PairingCarriesValidatedHTTPSRelay() throws {
        let pairing = try PairingInfo.create(name: "Mac", relayURL: URL(string: "https://relay.example.org/")!)
        XCTAssertEqual(pairing.relayURL.absoluteString, "https://relay.example.org")
        XCTAssertTrue(pairing.urlString.contains("v=2"))
        XCTAssertEqual(try PairingInfo(urlString: pairing.urlString), pairing)
        XCTAssertThrowsError(try PairingInfo(urlString: pairing.urlString.replacingOccurrences(of: "v=2", with: "v=1")))
    }

    func testRejectsInsecureOrAmbiguousRelayEndpoints() throws {
        for value in [
            "http://relay.example.org", "ws://relay.example.org", "wss://relay.example.org",
            "https://user@relay.example.org", "https://user:password@relay.example.org",
            "https://relay.example.org/path", "https://relay.example.org?token=secret",
            "https://relay.example.org#fragment", "https://relay.example.org/%2F",
            "https://relay.example.org:0", "https://relay.example.org:99999"
        ] {
            XCTAssertThrowsError(try RelayEndpoint.validated(XCTUnwrap(URL(string: value))), value)
        }
        XCTAssertEqual(try RelayEndpoint.validated(URL(string: "https://relay.example.org:8443/")!).absoluteString,
                       "https://relay.example.org:8443")
    }

    func testEncryptedPhotoAndReceiptRoundTrip() throws {
        let pairing = try PairingInfo.create(name: "Mac")
        let sender = try RelayCipher(pairing: pairing)
        let receiver = try RelayCipher(pairing: pairing)
        let message = WireMessage.photo(id: UUID(), jpeg: Data([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9]))
        let ciphertext = try sender.seal(message, sender: .phone)
        XCTAssertEqual(try receiver.open(ciphertext, sender: .phone), message)
        XCTAssertNotEqual(ciphertext, try sender.seal(message, sender: .phone), "Each encryption must use a fresh nonce")
        let receipt = WireMessage.receipt(id: message.id, status: "pasteRequested", detail: "已发送粘贴指令")
        XCTAssertEqual(try sender.open(receiver.seal(receipt, sender: .mac), sender: .mac), receipt)
    }

    func testCipherRejectsTamperingReflectionWrongKeyAndPairingID() throws {
        let pairing = try PairingInfo.create(name: "Mac")
        let cipher = try RelayCipher(pairing: pairing)
        let message = WireMessage.photo(id: UUID(), jpeg: Data([0xff, 0xd8, 0xff, 0xd9]))
        var ciphertext = try cipher.seal(message, sender: .phone)
        XCTAssertThrowsError(try cipher.open(ciphertext, sender: .mac), "Sender role is authenticated")
        let other = try RelayCipher(pairing: PairingInfo.create(name: "Other Mac"))
        XCTAssertThrowsError(try other.open(ciphertext, sender: .phone))
        let differentID = try RelayCipher(pairing: PairingInfo(id: UUID(), name: pairing.name, key: pairing.key))
        XCTAssertThrowsError(try differentID.open(ciphertext, sender: .phone), "Pairing ID is bound to the encryption key")
        ciphertext[ciphertext.count / 2] ^= 1
        XCTAssertThrowsError(try cipher.open(ciphertext, sender: .phone))
        XCTAssertThrowsError(try cipher.open(Data(repeating: 0, count: 27), sender: .phone))
    }

    func testRecordedPhotoFailsAfterManyTransfersAndReceiverRestart() throws {
        let cipher = try RelayCipher(pairing: PairingInfo.create(name: "Isolated replay test"))
        var authorization = PhotoAuthorization()
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        let request = WireMessage.photoRequest(id: UUID(), attempt: UUID())
        let challenge = try XCTUnwrap(authorization.issue(for: request))
        let original = WireMessage.photo(id: request.id, jpeg: jpeg, attempt: request.attempt,
                                         challenge: challenge.challenge)
        let recorded = try cipher.seal(original, sender: .phone)
        let opened = try cipher.open(recorded, sender: .phone)
        XCTAssertTrue(authorization.consume(opened))
        XCTAssertFalse(authorization.consume(opened))

        for _ in 0..<257 {
            let next = WireMessage.photoRequest(id: UUID(), attempt: UUID())
            let reply = try XCTUnwrap(authorization.issue(for: next))
            XCTAssertTrue(authorization.consume(.photo(id: next.id, jpeg: jpeg, attempt: next.attempt,
                                                       challenge: reply.challenge)))
        }
        XCTAssertFalse(authorization.consume(try cipher.open(recorded, sender: .phone)))

        authorization = PhotoAuthorization()
        let replayedRequest = try cipher.open(cipher.seal(request, sender: .phone), sender: .phone)
        let freshChallenge = try XCTUnwrap(authorization.issue(for: replayedRequest))
        XCTAssertNotEqual(freshChallenge.challenge, challenge.challenge)
        XCTAssertFalse(authorization.consume(try cipher.open(recorded, sender: .phone)))
        XCTAssertFalse(authorization.consume(.photo(id: request.id, jpeg: jpeg)))
        XCTAssertFalse(authorization.consume(.photo(id: UUID(), jpeg: jpeg, attempt: request.attempt,
                                                    challenge: freshChallenge.challenge)))

        let retry = WireMessage.photoRequest(id: request.id, attempt: UUID())
        let now = ContinuousClock.now
        let retryChallenge = try XCTUnwrap(authorization.issue(for: retry, now: now))
        let retriedPhoto = WireMessage.photo(id: retry.id, jpeg: jpeg, attempt: retry.attempt,
                                             challenge: retryChallenge.challenge)
        XCTAssertFalse(authorization.consume(retriedPhoto, now: now.advanced(by: .seconds(30))))
        XCTAssertFalse(authorization.consume(.photo(id: request.id, jpeg: jpeg, attempt: request.attempt,
                                                    challenge: retryChallenge.challenge), now: now))
        XCTAssertTrue(authorization.consume(retriedPhoto, now: now))
    }

    func testRelayTokensAreDeterministicAndDoNotContainPairingSecret() throws {
        let pairing = try PairingInfo.create(name: "Mac")
        let cipher = try RelayCipher(pairing: pairing)
        XCTAssertEqual(cipher.relayToken.count, 64)
        XCTAssertEqual(cipher.room.count, 64)
        XCTAssertTrue(cipher.room.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(cipher.relayToken, try RelayCipher(pairing: pairing).relayToken)
        XCTAssertNotEqual(cipher.relayToken, cipher.room)
        XCTAssertNotEqual(cipher.relayToken, pairing.key.map { String(format: "%02x", $0) }.joined())
        XCTAssertThrowsError(try RelayCipher(pairing: PairingInfo(id: UUID(), name: "Bad", key: Data())))
    }
}
