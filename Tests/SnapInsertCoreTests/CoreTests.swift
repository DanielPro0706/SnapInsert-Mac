import Foundation
import Network
import XCTest
@testable import SnapInsertCore

final class CoreTests: XCTestCase {
    func testPairingURLRoundTripAndSecretLength() throws {
        let pairing = try PairingInfo.create(name: "Daniel 的 MacBook Pro")
        XCTAssertEqual(pairing.key.count, 32)
        XCTAssertEqual(try PairingInfo(urlString: pairing.urlString), pairing)
        XCTAssertNotEqual(pairing.key, try PairingInfo.create(name: "Mac").key)
    }

    func testRejectsUntrustedPairingLinks() throws {
        let pairing = try PairingInfo.create(name: "Mac")
        for candidate in [
            pairing.urlString.replacingOccurrences(of: "snapinsert://", with: "https://"),
            pairing.urlString + "&key=duplicate",
            pairing.urlString.replacingOccurrences(of: "v=2", with: "v=3"),
            pairing.urlString + "#fragment",
            "snapinsert://pair?v=1&id=bad&name=Mac&key=abc"
        ] {
            XCTAssertThrowsError(try PairingInfo(urlString: candidate))
        }
    }

    func testFrameRoundTripAndNetworkByteOrder() throws {
        let photo = WireMessage.photo(id: UUID(), jpeg: Data([0xff, 0xd8, 1, 2, 0xff, 0xd9]))
        let frame = try WireFrame.encode(photo)
        XCTAssertEqual(try WireFrame.payloadLength(header: frame.prefix(4)), frame.count - 4)
        XCTAssertEqual(try WireFrame.decode(payload: frame.dropFirst(4)), photo)
        XCTAssertEqual(try WireFrame.payloadLength(header: Data([0, 0, 1, 0])), 256)
    }

    func testRejectsFrameLengthsBeforeReadingPayload() {
        for header in [Data(), Data([0, 0, 0, 0]), Data([0xff, 0xff, 0xff, 0xff]), Data([0, 1, 0]) ] {
            XCTAssertThrowsError(try WireFrame.payloadLength(header: header))
        }
    }

    func testRejectsInvalidAndOversizedMessages() throws {
        XCTAssertThrowsError(try WireFrame.encode(.photo(id: UUID(), jpeg: Data())))
        XCTAssertThrowsError(try WireFrame.encode(.photo(id: UUID(), jpeg: Data(repeating: 0, count: WireFrame.maximumImageLength + 1))))
        XCTAssertThrowsError(try WireFrame.encode(.receipt(id: UUID(), status: "", detail: "")))
        XCTAssertThrowsError(try WireFrame.decode(payload: Data("{\"kind\":\"receipt\"}".utf8)))
        let receipt = WireMessage.receipt(id: UUID(), status: "pasteRequested", detail: "已发送粘贴指令")
        XCTAssertEqual(try WireFrame.decode(payload: WireFrame.encode(receipt).dropFirst(4)), receipt)
    }

    @MainActor
    func testTLSPhotoAndReceiptOverLoopback() async throws {
        let pairing = try PairingInfo.create(name: "Loopback")
        let listener = try NWListener(using: TransportSecurity.parameters(for: pairing), on: .any)
        let listening = expectation(description: "TLS listener ready")
        let receiptArrived = expectation(description: "Photo acknowledged over encrypted channel")
        let photo = WireMessage.photo(id: UUID(), jpeg: Data([0xff, 0xd8, 0xff, 0xd9]))
        var serverChannel: SecureChannel?
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let channel = SecureChannel(connection: connection)
                serverChannel = channel
                channel.onMessage = { message in
                    XCTAssertEqual(message, photo)
                    do { try channel.send(.receipt(id: message.id, status: "pasteRequested", detail: "Test acknowledged")) }
                    catch { XCTFail(error.localizedDescription) }
                }
                channel.start()
            }
        }
        listener.start(queue: .main)
        await fulfillment(of: [listening], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        let connection = NWConnection(host: "127.0.0.1", port: port, using: TransportSecurity.parameters(for: pairing))
        let client = SecureChannel(connection: connection)
        client.onReady = {
            do { try client.send(photo) }
            catch { XCTFail(error.localizedDescription) }
        }
        client.onMessage = { message in
            XCTAssertEqual(message.id, photo.id)
            XCTAssertEqual(message.kind, .receipt)
            receiptArrived.fulfill()
        }
        client.start()
        await fulfillment(of: [receiptArrived], timeout: 10)
        client.cancel()
        serverChannel?.cancel()
        listener.cancel()
    }

    @MainActor
    func testTLSRejectsWrongPairingSecret() async throws {
        let pairing = try PairingInfo.create(name: "Protected Mac")
        let other = try PairingInfo.create(name: "Wrong secret")
        let wrongSecret = PairingInfo(id: pairing.id, name: pairing.name, key: other.key)
        let listener = try NWListener(using: TransportSecurity.parameters(for: pairing), on: .any)
        let listening = expectation(description: "Protected listener ready")
        let rejected = expectation(description: "Mismatched PSK rejected")
        var serverChannel: SecureChannel?
        listener.stateUpdateHandler = { state in
            if case .ready = state { listening.fulfill() }
        }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                let channel = SecureChannel(connection: connection)
                serverChannel = channel
                channel.onReady = { XCTFail("Unauthorized peer completed TLS handshake") }
                channel.start()
            }
        }
        listener.start(queue: .main)
        await fulfillment(of: [listening], timeout: 5)
        let connection = NWConnection(host: "127.0.0.1", port: try XCTUnwrap(listener.port),
                                      using: TransportSecurity.parameters(for: wrongSecret))
        let client = SecureChannel(connection: connection)
        client.onReady = { XCTFail("Mismatched secret should fail authentication") }
        client.onClose = { _ in rejected.fulfill() }
        client.start()
        // Network may keep a failed TLS handshake in .waiting; the channel's 15-second
        // handshake deadline must still reject the peer, without ever calling onReady.
        await fulfillment(of: [rejected], timeout: 20)
        client.cancel()
        serverChannel?.cancel()
        listener.cancel()
    }
}
