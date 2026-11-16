//
//  ICTRLClient.swift
//  MinisApp
//
//  [T-ictrl-envelope-v1] In-process client for the iCTRL rootless daemon.
//
//  The daemon listens on 127.0.0.1:8200 and speaks envelope v1: X25519 to
//  derive a pairwise secret, then HMAC-SHA256 for the key schedule, a
//  XOR keystream for the plaintext, and an HMAC tag over the request
//  metadata. Pairing is a one-time on-device approval that yields an opaque
//  token plus the token-encryption key; every later /rpc call is encrypted
//  and bound to that token, a timestamp and a nonce.
//
//  Why this lives here instead of shelling out to a CLI: the earlier
//  integration downloaded an iSH client binary from an XCTest runner over
//  HTTP. That runner no longer exists on this device — the rootless daemon
//  replaced it — and Minis can speak the same protocol directly. Nothing is
//  downloaded, nothing is executed, and the session key never leaves the app
//  container.
//
//  Scope: loopback or a private LAN address the user owns. Never a public
//  host, never a URL with a path or credentials.
//

import Foundation
import CryptoKit

enum ICTRLError: LocalizedError {
    case invalidHost(String)
    case notPaired
    case transport(String)
    case rejected(String)
    case malformedResponse(String)
    case tokenBindingMismatch
    case responseAuthenticationFailed

    var errorDescription: String? {
        switch self {
        case .invalidHost(let detail): return "iCTRL host is not allowed: \(detail)"
        case .notPaired: return "Not paired with the iCTRL daemon yet. Call action=pair first and approve the prompt on the device."
        case .transport(let detail): return "iCTRL daemon is unreachable: \(detail)"
        case .rejected(let detail): return "iCTRL daemon refused the request: \(detail)"
        case .malformedResponse(let detail): return "iCTRL daemon returned an unexpected response: \(detail)"
        case .tokenBindingMismatch: return "iCTRL pairing failed: the returned token did not bind to the derived key."
        case .responseAuthenticationFailed: return "iCTRL response failed authentication; it was discarded."
        }
    }
}

/// One paired session, keyed by daemon host.
struct ICTRLSession: Codable {
    var host: String
    var token: String
    var keyHex: String
    var clientName: String
    var deviceId: String?
    var pairedAt: Int

    var key: Data? { Data(hexString: keyHex) }
}

enum ICTRLClient {
    static let defaultHost = "127.0.0.1:8200"
    static let defaultPairingName = "Minis"

    // MARK: - Host policy

    /// Loopback or RFC1918 private address only, with an explicit port.
    /// Mirrors the check the removed shell client applied, so a stored LAN
    /// address cannot silently turn into an internet destination.
    static func validatedHost(_ raw: String?) throws -> String {
        let host = (raw?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? defaultHost
        guard !host.contains("/"), !host.contains("@"), !host.contains(" ") else {
            throw ICTRLError.invalidHost("it must be host:port without a path or credentials")
        }
        let name: String
        let port: Int
        if host.hasPrefix("[") {
            guard let close = host.firstIndex(of: "]") else { throw ICTRLError.invalidHost("unbalanced IPv6 brackets") }
            name = String(host[host.index(after: host.startIndex)..<close])
            let rest = host[host.index(after: close)...]
            guard rest.hasPrefix(":"), let value = Int(rest.dropFirst()) else {
                throw ICTRLError.invalidHost("missing port")
            }
            port = value
        } else {
            guard let colon = host.lastIndex(of: ":") else { throw ICTRLError.invalidHost("missing port") }
            name = String(host[host.startIndex..<colon])
            guard let value = Int(host[host.index(after: colon)...]) else {
                throw ICTRLError.invalidHost("port is not a number")
            }
            port = value
        }
        guard (1...65535).contains(port) else { throw ICTRLError.invalidHost("port is out of range") }
        if name == "localhost" || name == "::1" { return host }
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { Int($0) }
        guard parts.count == 4, octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            throw ICTRLError.invalidHost("only loopback or a private IPv4 address is accepted")
        }
        let loopback = octets[0] == 127
        let privateRange = octets[0] == 10
            || (octets[0] == 192 && octets[1] == 168)
            || (octets[0] == 172 && (16...31).contains(octets[1]))
        guard loopback || privateRange else {
            throw ICTRLError.invalidHost("only loopback or a private IPv4 address is accepted")
        }
        return host
    }

    // MARK: - Pairing

    /// One pairing attempt. The daemon enforces a 15 s cooldown between
    /// attempts and shows an on-device approval prompt, so the caller is
    /// expected to retry deliberately rather than in a tight loop.
    static func pair(host rawHost: String?, name: String, timeout: TimeInterval) async throws -> [String: Any] {
        let host = try validatedHost(rawHost)
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation
        let clientName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultPairingName : String(name.prefix(64))

        var response = try await postJSON(
            host: host, path: "/pair",
            body: ["client_name": clientName, "pub": publicKey.base64EncodedString()],
            timeout: timeout)
        if let paired = response["paired"] as? Bool, paired { return response }
        if let error = response["error"] as? String {
            // The daemon reports a wrong or missing approval this way; the
            // prompt can still be answered, so surface it verbatim.
            throw ICTRLError.rejected(error)
        }
        guard let devicePublicBase64 = response["pub"] as? String,
              let devicePublicData = Data(base64Encoded: devicePublicBase64),
              let cipherHex = response["token_ct"] as? String,
              let cipher = Data(hexString: cipherHex),
              let token = response["tok"] as? String,
              !token.isEmpty else {
            throw ICTRLError.malformedResponse("pairing reply is missing pub/token_ct/tok")
        }
        guard let deviceKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: devicePublicData) else {
            throw ICTRLError.malformedResponse("pairing public key is not a valid X25519 point")
        }
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: deviceKey)
        let sharedData = shared.withUnsafeBytes { Data(Array($0)) }
        let wrap = hmac(key: sharedData, [Data("ictrl-pair".utf8), publicKey, devicePublicData])
        let pad = hmac(key: wrap, [Data("ictrl-wrap".utf8)])
        let key = xor(cipher, pad)
        guard key.count == 32 else { throw ICTRLError.tokenBindingMismatch }
        let fingerprint = sha256(key).prefix(4).map { String(format: "%02x", $0) }.joined()
        guard fingerprint == token.lowercased() else { throw ICTRLError.tokenBindingMismatch }

        let session = ICTRLSession(host: host, token: token, keyHex: key.hexString,
                                   clientName: clientName, deviceId: nil,
                                   pairedAt: Int(Date().timeIntervalSince1970))
        store(session)
        response["paired"] = true
        response["client_name"] = clientName
        return response
    }

    // MARK: - RPC

    static func call(host rawHost: String?, method: String, params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let host = try validatedHost(rawHost)
        let trimmed = method.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 120 else {
            throw ICTRLError.rejected("method must be a non-empty name")
        }
        guard let session = session(for: host), let key = session.key, let tokenBytes = Data(hexString: session.token) else {
            throw ICTRLError.notPaired
        }

        // SystemRandomNumberGenerator is the platform CSPRNG; no Security
        // framework dependency is needed for a 16-byte nonce.
        var generator = SystemRandomNumberGenerator()
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) })

        let plain: [String: Any] = [
            "jsonrpc": "2.0",
            "id": Int(Date().timeIntervalSince1970),
            "method": trimmed,
            "params": params,
        ]
        guard let plainData = try? JSONSerialization.data(withJSONObject: plain, options: []) else {
            throw ICTRLError.rejected("parameters are not valid JSON")
        }
        let encKey = hmac(key: key, [Data("ictrl-v1|enc-req".utf8), nonce])
        let cipher = streamCrypt(key: encKey, nonce: nonce, data: plainData)
        let macKey = hmac(key: key, [Data("ictrl-v1|mac".utf8), nonce])
        let timestamp = UInt64(Date().timeIntervalSince1970)
        let tag = hmac(key: macKey, [Data("v1".utf8), tokenBytes, bigEndian64(timestamp), nonce, cipher])

        let envelope: [String: Any] = [
            "v": 1,
            "tok": session.token,
            "ts": Int(timestamp),
            "nonce": nonce.hexString,
            "ct": cipher.base64EncodedString(),
            "tag": tag.hexString,
        ]
        let response = try await postJSON(host: host, path: "/rpc", body: envelope, timeout: timeout)
        if let error = response["error"] as? String {
            throw ICTRLError.rejected(error)
        }
        guard let responseNonce = (response["nonce"] as? String).flatMap({ Data(hexString: $0) }),
              let responseCipher = (response["ct"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let responseTag = (response["tag"] as? String).flatMap({ Data(hexString: $0) }) else {
            throw ICTRLError.malformedResponse("reply is missing nonce/ct/tag")
        }
        let expected = hmac(key: macKey, [Data("resp".utf8), responseNonce, responseCipher])
        guard constantTimeEquals(expected, responseTag) else { throw ICTRLError.responseAuthenticationFailed }
        let decryptKey = hmac(key: key, [Data("ictrl-v1|enc-resp".utf8), responseNonce])
        let cleartext = streamCrypt(key: decryptKey, nonce: responseNonce, data: responseCipher)
        guard let decoded = try? JSONSerialization.jsonObject(with: cleartext) as? [String: Any] else {
            throw ICTRLError.malformedResponse("reply body is not a JSON object")
        }
        return decoded
    }

    // MARK: - Session storage

    private static var storeURL: URL {
        let base = ContainerLocator.applicationSupportDirectory.appendingPathComponent("iCTRL", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("sessions.json")
    }

    static func session(for host: String) -> ICTRLSession? {
        sessions()[host]
    }

    static func sessions() -> [String: ICTRLSession] {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: ICTRLSession].self, from: data) else { return [:] }
        return decoded
    }

    private static func store(_ session: ICTRLSession) {
        var all = sessions()
        all[session.host] = session
        guard let data = try? JSONEncoder().encode(all) else { return }
        let url = storeURL
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func forget(host rawHost: String?) {
        guard let host = try? validatedHost(rawHost) else { return }
        var all = sessions()
        all.removeValue(forKey: host)
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: storeURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Transport

    private static func endpoint(host: String, path: String) throws -> URL {
        guard let url = URL(string: "http://\(host)\(path)"), url.scheme == "http" else {
            throw ICTRLError.invalidHost("cannot build a loopback URL")
        }
        return url
    }

    private static func postJSON(host: String, path: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: try endpoint(host: host, path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = max(5, min(120, timeout))
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ICTRLError.transport(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            // The daemon answers refusals with a JSON body and a 4xx status;
            // prefer its message over the bare code.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = object["error"] as? String {
                throw ICTRLError.rejected(message)
            }
            throw ICTRLError.transport("HTTP \(http.statusCode)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ICTRLError.malformedResponse("body is not a JSON object")
        }
        return object
    }

    // MARK: - Primitives

    private static func hmac(key: Data, _ parts: [Data]) -> Data {
        var message = Data()
        for part in parts { message.append(part) }
        let code = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
        return Data(code)
    }

    /// XOR keystream: block i of the stream is HMAC(key, nonce || BE32(i)).
    /// Identical to the reference client's construction.
    private static func streamCrypt(key: Data, nonce: Data, data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        var output = Data(capacity: data.count)
        var block: UInt32 = 0
        var offset = data.startIndex
        while offset < data.endIndex {
            let stream = hmac(key: key, [nonce, bigEndian32(block)])
            let end = min(offset + 32, data.endIndex)
            let chunk = data[offset..<end]
            for (index, byte) in chunk.enumerated() {
                output.append(byte ^ stream[stream.startIndex + index])
            }
            offset = end
            block += 1
        }
        return output
    }

    private static func xor(_ lhs: Data, _ rhs: Data) -> Data {
        let count = min(lhs.count, rhs.count)
        var output = Data(capacity: count)
        for index in 0..<count {
            output.append(lhs[lhs.startIndex + index] ^ rhs[rhs.startIndex + index])
        }
        return output
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in 0..<lhs.count { difference |= lhs[lhs.startIndex + index] ^ rhs[rhs.startIndex + index] }
        return difference == 0
    }

    private static func bigEndian32(_ value: UInt32) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 4)
    }

    private static func bigEndian64(_ value: UInt64) -> Data {
        var be = value.bigEndian
        return Data(bytes: &be, count: 8)
    }

    private static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }
}

private extension Data {
    init?(hexString: String) {
        let trimmed = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count % 2 == 0, !trimmed.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(trimmed.count / 2)
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let next = trimmed.index(index, offsetBy: 2)
            guard let byte = UInt8(trimmed[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
