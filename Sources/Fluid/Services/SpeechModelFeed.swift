import CryptoKit
import Foundation

/// The signed list of current speech model releases. Rules and format: docs/MODEL_UPDATE_FEED.md.
/// Foundation and CryptoKit only: Tools/model-release compiles this file to check a feed before it is published.
nonisolated enum SpeechModelFeed {
    struct Entry: Codable, Equatable, Sendable {
        let release: String
        let url: URL
        let bytes: Int64
        let sha256: String
        let manifestSHA256: String
        let format: Int
        let minBuild: Int
    }

    struct Payload: Codable, Equatable, Sendable {
        let schema: Int
        let sequence: Int
        let models: [String: [String: [Entry]]]
    }

    enum Rejection: String, Error, Equatable {
        case tooLarge
        case notAnEnvelope
        case badSignature
        case unreadablePayload
        case unknownSchema
        case staleSequence
        case badEntry
    }

    static let schema = 1
    static let maximumEnvelopeBytes = 64 * 1024
    static let host = "models.fluidvoice.app"
    static let pathPrefix = "/parakeet/"
    static let byteRange: ClosedRange<Int64> = 20_000_000...1_000_000_000

    private struct Envelope: Decodable {
        let payload: String
        let signature: String
    }

    /// The payload when the envelope is signed by one of `publicKeys` and every field of every entry is valid.
    static func verified(envelope: Data, publicKeys: [String], lastSequence: Int) throws -> Payload {
        guard envelope.count <= self.maximumEnvelopeBytes else { throw Rejection.tooLarge }
        guard let decoded = try? JSONDecoder().decode(Envelope.self, from: envelope),
              let payloadBytes = Data(base64Encoded: decoded.payload),
              let signature = Data(base64Encoded: decoded.signature)
        else { throw Rejection.notAnEnvelope }

        let signed = publicKeys.contains { key in
            guard let raw = Data(base64Encoded: key),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
            else { return false }
            return publicKey.isValidSignature(signature, for: payloadBytes)
        }
        guard signed else { throw Rejection.badSignature }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: payloadBytes) else {
            throw Rejection.unreadablePayload
        }
        guard payload.schema == self.schema else { throw Rejection.unknownSchema }
        guard payload.sequence >= 1, payload.sequence >= lastSequence else { throw Rejection.staleSequence }
        let entries = payload.models.values.flatMap { $0.values.flatMap { $0 } }
        guard entries.allSatisfy(self.isValid) else { throw Rejection.badEntry }
        return payload
    }

    /// Lists are newest first; the first release this build can run wins.
    static func entry(
        in payload: Payload,
        model: String,
        platform: String,
        build: Int,
        supportedFormat: Int
    ) -> Entry? {
        payload.models[model]?[platform]?.first { $0.format <= supportedFormat && $0.minBuild <= build }
    }

    static func isValid(_ entry: Entry) -> Bool {
        let releaseCharacters = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-")
        guard !entry.release.isEmpty, entry.release.count <= 32,
              entry.release.unicodeScalars.allSatisfy(releaseCharacters.contains)
        else { return false }

        let url = entry.url
        let pathComponents = url.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard url.scheme == "https", url.host == self.host, url.port == nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.hasPrefix(self.pathPrefix), url.path.hasSuffix(".tar"),
              pathComponents.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return false }

        return self.isSHA256(entry.sha256) && self.isSHA256(entry.manifestSHA256)
            && self.byteRange.contains(entry.bytes)
            && entry.format >= 1 && entry.minBuild >= 1
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
