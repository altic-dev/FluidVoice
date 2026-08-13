import Foundation
import Opus

enum OggOpusDecoder {
    enum DecoderError: LocalizedError {
        case invalidContainer(String)
        case unsupportedStream(String)
        case decodeFailed(String)
        case durationLimit

        var errorDescription: String? {
            switch self {
            case let .invalidContainer(message):
                return "Invalid OGG/Opus audio: \(message)"
            case let .unsupportedStream(message):
                return "Unsupported OGG/Opus audio: \(message)"
            case let .decodeFailed(message):
                return "Could not decode OGG/Opus audio: \(message)"
            case .durationLimit:
                return "Audio file exceeds the \(Int(LocalAPIAudioDecoder.maxDurationSeconds)) second API limit."
            }
        }
    }

    private struct Stream {
        let channels: Int
        let preSkip: Int
        let finalGranule: UInt64
        let precedingMaxGranule: UInt64?
        let packets: [Data]
    }

    private static let opusRate = 48_000
    private static let maxDecodedFrames = Int(LocalAPIAudioDecoder.maxDurationSeconds * Double(opusRate))

    static func isOggOpus(_ data: Data) -> Bool {
        data.starts(with: Data("OggS".utf8)) && data.range(of: Data("OpusHead".utf8)) != nil
    }

    static func samples(from data: Data) throws -> [Float] {
        let stream = try self.parse(data)
        guard stream.channels == 1 || stream.channels == 2 else {
            throw DecoderError.unsupportedStream("only mono and stereo streams are supported.")
        }
        guard stream.finalGranule != UInt64.max, stream.finalGranule <= UInt64(Int.max) else {
            throw DecoderError.invalidContainer("invalid final granule position.")
        }
        let finalGranule = Int(stream.finalGranule)

        var error: Int32 = 0
        guard let decoder = opus_decoder_create(Int32(self.opusRate), Int32(stream.channels), &error), error == OPUS_OK else {
            throw DecoderError.decodeFailed("Opus decoder initialization failed (code \(error)).")
        }
        defer { opus_decoder_destroy(decoder) }

        var decoded: [Float] = []
        decoded.reserveCapacity(min(self.maxDecodedFrames, finalGranule) * stream.channels)
        var frameBuffer = [Float](repeating: 0, count: 5_760 * stream.channels)

        for packet in stream.packets {
            let frameCount = packet.withUnsafeBytes { bytes -> Int32 in
                guard let baseAddress = bytes.bindMemory(to: UInt8.self).baseAddress else { return OPUS_BAD_ARG }
                return frameBuffer.withUnsafeMutableBufferPointer { output in
                    guard let outputAddress = output.baseAddress else { return OPUS_BAD_ARG }
                    return opus_decode_float(decoder, baseAddress, Int32(packet.count), outputAddress, 5_760, 0)
                }
            }
            guard frameCount >= 0 else {
                throw DecoderError.decodeFailed("Opus packet decode failed (code \(frameCount)).")
            }
            decoded.append(contentsOf: frameBuffer.prefix(Int(frameCount) * stream.channels))
            if decoded.count / stream.channels > self.maxDecodedFrames + stream.preSkip + 5_760 {
                throw DecoderError.durationLimit
            }
        }

        let decodedFrames = decoded.count / stream.channels
        guard finalGranule >= stream.preSkip else {
            throw DecoderError.invalidContainer("final granule precedes Opus pre-skip.")
        }
        if let precedingMaxGranule = stream.precedingMaxGranule, stream.finalGranule < precedingMaxGranule {
            throw DecoderError.invalidContainer("final granule trims previously completed audio.")
        }
        let streamFrames = finalGranule - stream.preSkip
        guard streamFrames <= self.maxDecodedFrames else { throw DecoderError.durationLimit }
        guard decodedFrames >= stream.preSkip, streamFrames <= decodedFrames - stream.preSkip else {
            throw DecoderError.invalidContainer("final granule exceeds decoded audio.")
        }
        let availableFrames = streamFrames
        guard availableFrames > 0 else { return [] }

        if stream.channels == 1 {
            return Array(decoded[stream.preSkip ..< stream.preSkip + availableFrames])
        }

        var mono = [Float]()
        mono.reserveCapacity(availableFrames)
        for frame in 0 ..< availableFrames {
            let offset = (stream.preSkip + frame) * 2
            mono.append((decoded[offset] + decoded[offset + 1]) * 0.5)
        }
        return mono
    }

    private static func parse(_ data: Data) throws -> Stream {
        var offset = 0
        var expectedSerial: UInt32?
        var expectedSequence: UInt32 = 0
        var packet = Data()
        var packets: [Data] = []
        var finalGranule: UInt64 = 0
        var precedingMaxGranule: UInt64?
        var sawEOS = false

        while offset < data.count {
            guard offset + 27 <= data.count, data[offset ..< offset + 4].elementsEqual("OggS".utf8) else {
                throw DecoderError.invalidContainer("missing Ogg page header.")
            }
            guard data[offset + 4] == 0 else {
                throw DecoderError.unsupportedStream("unsupported Ogg bitstream version.")
            }
            guard !sawEOS else {
                throw DecoderError.invalidContainer("data follows the EOS page.")
            }
            let headerType = data[offset + 5]
            let pageSegments = Int(data[offset + 26])
            guard offset + 27 + pageSegments <= data.count else {
                throw DecoderError.invalidContainer("truncated segment table.")
            }
            let serial = self.uint32(data, at: offset + 14)
            let sequence = self.uint32(data, at: offset + 18)
            if let expectedSerial {
                guard serial == expectedSerial else {
                    throw DecoderError.unsupportedStream("chained or multiplexed streams are not supported.")
                }
                guard sequence == expectedSequence else {
                    throw DecoderError.invalidContainer("missing or reordered Ogg page.")
                }
            } else {
                expectedSerial = serial
            }
            expectedSequence = sequence &+ 1
            sawEOS = headerType & 0x04 != 0
            let pageGranule = self.uint64(data, at: offset + 6)
            if finalGranule != UInt64.max {
                precedingMaxGranule = max(precedingMaxGranule ?? 0, finalGranule)
            }
            finalGranule = pageGranule

            let payloadOffset = offset + 27 + pageSegments
            let payloadLength = data[offset + 27 ..< payloadOffset].reduce(0) { $0 + Int($1) }
            guard payloadOffset + payloadLength <= data.count else {
                throw DecoderError.invalidContainer("truncated page payload.")
            }
            let pageEnd = payloadOffset + payloadLength
            guard self.oggPageChecksum(data, range: offset ..< pageEnd) == self.uint32(data, at: offset + 22) else {
                throw DecoderError.invalidContainer("Ogg page checksum mismatch.")
            }

            var cursor = payloadOffset
            for lengthByte in data[offset + 27 ..< payloadOffset] {
                let length = Int(lengthByte)
                packet.append(data[cursor ..< cursor + length])
                cursor += length
                if length < 255 {
                    packets.append(packet)
                    packet.removeAll(keepingCapacity: true)
                }
            }
            offset = pageEnd
        }

        guard packet.isEmpty else { throw DecoderError.invalidContainer("truncated packet.") }
        guard sawEOS else { throw DecoderError.invalidContainer("stream ended before EOS.") }
        guard packets.count >= 2, packets[0].starts(with: Data("OpusHead".utf8)) else {
            throw DecoderError.unsupportedStream("the Ogg stream does not contain Opus audio.")
        }
        let header = packets[0]
        guard header.count >= 19 else { throw DecoderError.invalidContainer("truncated Opus header.") }
        guard header[8] == 1 else { throw DecoderError.unsupportedStream("unsupported Opus header version.") }
        guard header[18] == 0 else {
            throw DecoderError.unsupportedStream("channel-mapped Opus streams are not supported.")
        }
        guard packets[1].starts(with: Data("OpusTags".utf8)) else {
            throw DecoderError.invalidContainer("missing OpusTags header.")
        }

        return Stream(
            channels: Int(header[9]),
            preSkip: Int(self.uint16(header, at: 10)),
            finalGranule: finalGranule,
            precedingMaxGranule: precedingMaxGranule,
            packets: Array(packets.dropFirst(2))
        )
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        (0 ..< 4).reduce(0) { $0 | (UInt32(data[offset + $1]) << UInt32($1 * 8)) }
    }

    private static func uint64(_ data: Data, at offset: Int) -> UInt64 {
        (0 ..< 8).reduce(0) { $0 | (UInt64(data[offset + $1]) << UInt64($1 * 8)) }
    }

    private static func oggPageChecksum(_ data: Data, range: Range<Int>) -> UInt32 {
        var checksum: UInt32 = 0
        let checksumRange = range.lowerBound + 22 ..< range.lowerBound + 26
        for index in range {
            let byte = checksumRange.contains(index) ? UInt8.zero : data[index]
            checksum ^= UInt32(byte) << 24
            for _ in 0 ..< 8 {
                checksum = checksum & 0x8000_0000 != 0
                    ? (checksum &<< 1) ^ 0x04C1_1DB7
                    : checksum &<< 1
            }
        }
        return checksum
    }
}
