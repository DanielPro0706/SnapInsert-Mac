import CryptoKit
import Foundation

/// Server authentication and message encryption use separate derived material.
/// The relay sees the room/token and ciphertext, never the pairing key or JPEG.
struct RelayCipher {
    let relayToken: String
    let room: String
    private let key: SymmetricKey

    init(pairing: PairingInfo) throws {
        guard pairing.key.count == 32 else { throw RelayError.invalidKey }
        let tokenMaterial = Data("snapinsert-relay-auth-v2".utf8) + pairing.key
        relayToken = Self.hex(SHA256.hash(data: tokenMaterial))
        room = Self.hex(SHA256.hash(data: Data(relayToken.utf8)))
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: pairing.key),
            salt: Data(pairing.id.uuidString.lowercased().utf8),
            info: Data("snapinsert-e2e-v2".utf8), outputByteCount: 32
        )
    }

    func seal(_ message: WireMessage, sender: RelayChannel.Role) throws -> Data {
        let payload = try WireFrame.encode(message).dropFirst(4)
        guard let combined = try AES.GCM.seal(payload, using: key, authenticating: aad(sender: sender)).combined
        else { throw RelayError.invalidMessage }
        return combined
    }

    func open(_ data: Data, sender: RelayChannel.Role) throws -> WireMessage {
        guard data.count >= 28, data.count <= WireFrame.maximumFrameLength + 28 else { throw WireError.invalidLength }
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            let payload = try AES.GCM.open(box, using: key, authenticating: aad(sender: sender))
            return try WireFrame.decode(payload: payload)
        } catch { throw RelayError.invalidMessage }
    }

    private func aad(sender: RelayChannel.Role) -> Data {
        Data("snapinsert-v2|\(room)|\(sender.rawValue)".utf8)
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

@MainActor
final class RelayChannel {
    enum Role: String, Codable, Sendable {
        case phone, mac
        var peer: Role { self == .phone ? .mac : .phone }
    }

    var onMessage: ((WireMessage) -> Void)?
    var onReady: (() -> Void)?
    var onClose: ((String) -> Void)?
    var onPeerUnavailable: (() -> Void)?
    var onReplaced: (() -> Void)?
    var onAuthorizationRequired: ((String) -> Void)?

    private let pairing: PairingInfo
    private let role: Role
    private var cipher: RelayCipher?
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var pingDeadline: Task<Void, Never>?
    private var handshakeDeadline: Task<Void, Never>?
    private var pendingPing: UUID?
    private var outgoing: [Data] = []
    private var queuedBytes = 0
    private var started = false
    private var closed = false
    private var peerReady = false

    init(pairing: PairingInfo, role: Role) {
        self.pairing = pairing
        self.role = role
    }

    func start() {
        guard !started, !closed else { return }
        started = true
        do {
            let endpoint = try RelayEndpoint.validated(pairing.relayURL)
            let cipher = try RelayCipher(pairing: pairing)
            self.cipher = cipher
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
            components.scheme = "wss"
            components.path = "/v1/rooms/\(cipher.room)/socket/\(role.rawValue)"
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(cipher.relayToken)", forHTTPHeaderField: "Authorization")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            let session = URLSession(configuration: configuration)
            self.session = session
            let socket = session.webSocketTask(with: request)
            socket.maximumMessageSize = WireFrame.maximumFrameLength + 28
            self.socket = socket
            socket.resume()
            receiveTask = Task { [weak self] in await self?.receiveLoop() }
            handshakeDeadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { return }
                self?.close(reason: "连接中转服务器超时，请检查网络及服务器地址。")
            }
            pingTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 20_000_000_000) } catch { return }
                    guard let self, !self.closed else { return }
                    self.ping()
                }
            }
        } catch { close(reason: error.localizedDescription) }
    }

    func send(_ message: WireMessage) throws {
        guard !closed, peerReady, socket != nil, let cipher else { throw WireError.notReady }
        let data = try cipher.seal(message, sender: role)
        guard outgoing.count < 4, queuedBytes + data.count <= WireFrame.maximumFrameLength + 28
        else { throw RelayError.queueFull }
        outgoing.append(data)
        queuedBytes += data.count
        if sendTask == nil {
            sendTask = Task { [weak self] in await self?.drainOutgoing() }
        }
    }

    func cancel() { close(reason: "连接已断开。") }

    private func receiveLoop() async {
        guard let socket else { return }
        while !closed, !Task.isCancelled {
            do {
                let message = try await socket.receive()
                switch message {
                case .data(let bytes):
                    guard let cipher else { throw RelayError.invalidMessage }
                    let decoded = try cipher.open(bytes, sender: role.peer)
                    // A relay cannot turn a phone photo into a Mac acknowledgement or vice versa.
                    switch (role, decoded.kind) {
                    case (.mac, .photo), (.mac, .photoRequest), (.phone, .receipt), (.phone, .photoChallenge):
                        break
                    default: throw RelayError.invalidMessage
                    }
                    onMessage?(decoded)
                case .string(let text):
                    guard text.utf8.count <= 1024 else { throw RelayError.invalidMessage }
                    let presence = try JSONDecoder().decode(Presence.self, from: Data(text.utf8))
                    guard presence.type == "presence" else { throw RelayError.invalidMessage }
                    handshakeDeadline?.cancel()
                    if presence.peer {
                        if !peerReady { peerReady = true; onReady?() }
                    } else {
                        peerReady = false
                        outgoing.removeAll()
                        queuedBytes = 0
                        onPeerUnavailable?()
                    }
                @unknown default: throw RelayError.invalidMessage
                }
            } catch {
                if !closed {
                    if socket.closeCode.rawValue == 4004 {
                        close(reason: "此邀请码的流量额度已用完，请联系维护者调整额度。", authorizationRequired: true)
                    } else if socket.closeCode.rawValue == 4003 || (socket.response as? HTTPURLResponse)?.statusCode == 403 {
                        close(reason: "中转授权不可用，请检查邀请码或联系维护者确认剩余额度。", authorizationRequired: true)
                    } else if socket.closeCode.rawValue == 4001 {
                        close(reason: "连接已被另一台设备替换，请点“重新连接”后继续。", replaced: true)
                    } else {
                        close(reason: "中转连接已断开：\(error.localizedDescription)")
                    }
                }
                return
            }
        }
    }

    private func drainOutgoing() async {
        defer { sendTask = nil }
        while !closed, !Task.isCancelled, !outgoing.isEmpty {
            let data = outgoing.removeFirst()
            queuedBytes -= data.count
            do { try await socket?.send(.data(data)) }
            catch { close(reason: "照片发送失败：\(error.localizedDescription)"); return }
        }
    }

    private func ping() {
        guard let socket, pendingPing == nil else { return }
        let id = UUID()
        pendingPing = id
        pingDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard self?.pendingPing == id else { return }
            self?.close(reason: "中转连接无响应，请重新连接。")
        }
        socket.sendPing { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self, !self.closed, self.pendingPing == id else { return }
                self.pendingPing = nil
                self.pingDeadline?.cancel()
                if let error { self.close(reason: "中转连接已断开：\(error.localizedDescription)") }
            }
        }
    }

    private func close(reason: String, replaced: Bool = false, authorizationRequired: Bool = false) {
        guard !closed else { return }
        closed = true
        peerReady = false
        receiveTask?.cancel()
        sendTask?.cancel()
        pingTask?.cancel()
        pingDeadline?.cancel()
        handshakeDeadline?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
        socket = nil
        session = nil
        receiveTask = nil
        sendTask = nil
        pingTask = nil
        pingDeadline = nil
        handshakeDeadline = nil
        outgoing.removeAll()
        queuedBytes = 0
        if authorizationRequired, let onAuthorizationRequired { onAuthorizationRequired(reason) }
        else if replaced { onReplaced?() }
        else { onClose?(reason) }
    }

    private struct Presence: Decodable {
        let type: String
        let peer: Bool
    }
}
