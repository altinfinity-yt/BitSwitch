import Foundation

struct SourceFormat: Equatable, CustomStringConvertible {
    let sampleRate: Int
    let bitsPerSample: Int
    let channels: Int

    var description: String {
        let rateKHz = Double(sampleRate) / 1000.0
        let rateStr = rateKHz.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(rateKHz))"
            : String(format: "%.1f", rateKHz)
        return "\(rateStr)kHz / \(bitsPerSample)-bit"
    }

    var shortLabel: String {
        let rateKHz = Double(sampleRate) / 1000.0
        let rateStr = rateKHz.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(rateKHz))"
            : String(format: "%.1f", rateKHz)
        return "\(rateStr)/\(bitsPerSample)"
    }
}

enum AudioFileParser {
    enum ParseError: Error {
        case fileNotFound
        case unsupportedFormat
        case readError
    }

    static let supportedExtensions: Set<String> = ["flac", "wav", "mp3", "aiff", "aif"]

    static func parse(path: String) throws -> SourceFormat {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ParseError.fileNotFound
        }

        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "flac":
            return try parseFLAC(path: path)
        case "wav":
            return try parseWAV(path: path)
        case "mp3":
            return try parseMP3(path: path)
        case "aiff", "aif":
            return try parseAIFF(path: path)
        default:
            throw ParseError.unsupportedFormat
        }
    }

    // MARK: - FLAC

    private static func parseFLAC(path: String) throws -> SourceFormat {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ParseError.readError
        }
        defer { handle.closeFile() }

        let marker = handle.readData(ofLength: 4)
        guard marker.count == 4, String(data: marker, encoding: .ascii) == "fLaC" else {
            throw ParseError.unsupportedFormat
        }

        let blockHeader = handle.readData(ofLength: 4)
        guard blockHeader.count == 4, (blockHeader[0] & 0x7F) == 0 else {
            throw ParseError.readError
        }

        let si = handle.readData(ofLength: 34)
        guard si.count == 34 else { throw ParseError.readError }

        let sampleRate = (Int(si[10]) << 12) | (Int(si[11]) << 4) | (Int(si[12]) >> 4)
        let channels = Int((si[12] >> 1) & 0x07) + 1
        let bitsPerSample = ((Int(si[12] & 0x01) << 4) | (Int(si[13]) >> 4)) + 1

        guard sampleRate > 0, bitsPerSample > 0 else { throw ParseError.readError }
        return SourceFormat(sampleRate: sampleRate, bitsPerSample: bitsPerSample, channels: channels)
    }

    // MARK: - WAV

    private static func parseWAV(path: String) throws -> SourceFormat {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ParseError.readError
        }
        defer { handle.closeFile() }

        // RIFF header: "RIFF" + size(4) + "WAVE"
        let riffHeader = handle.readData(ofLength: 12)
        guard riffHeader.count == 12,
              String(data: riffHeader[0..<4], encoding: .ascii) == "RIFF",
              String(data: riffHeader[8..<12], encoding: .ascii) == "WAVE" else {
            throw ParseError.unsupportedFormat
        }

        // Search for "fmt " chunk
        while true {
            let chunkHeader = handle.readData(ofLength: 8)
            guard chunkHeader.count == 8 else { throw ParseError.readError }

            let chunkID = String(data: chunkHeader[0..<4], encoding: .ascii)
            let chunkSize = readUInt32LE(chunkHeader, offset: 4)

            if chunkID == "fmt " {
                let fmtData = handle.readData(ofLength: Int(min(chunkSize, 40)))
                guard fmtData.count >= 16 else { throw ParseError.readError }

                let channels = Int(readUInt16LE(fmtData, offset: 2))
                let sampleRate = Int(readUInt32LE(fmtData, offset: 4))
                let bitsPerSample = Int(readUInt16LE(fmtData, offset: 14))

                // For extensible WAV (format tag 0xFFFE), valid bits may differ
                let formatTag = readUInt16LE(fmtData, offset: 0)
                var effectiveBits = bitsPerSample
                if formatTag == 0xFFFE, fmtData.count >= 26 {
                    effectiveBits = Int(readUInt16LE(fmtData, offset: 18))
                }

                guard sampleRate > 0, effectiveBits > 0 else { throw ParseError.readError }
                return SourceFormat(sampleRate: sampleRate, bitsPerSample: effectiveBits, channels: channels)
            }

            // Skip to next chunk (chunks are word-aligned)
            let skip = UInt64((chunkSize + 1) & ~1)
            handle.seek(toFileOffset: handle.offsetInFile + skip)
        }
    }

    // MARK: - MP3

    private static func parseMP3(path: String) throws -> SourceFormat {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ParseError.readError
        }
        defer { handle.closeFile() }

        // Skip ID3v2 tag if present
        let id3Header = handle.readData(ofLength: 10)
        if id3Header.count >= 10, String(data: id3Header[0..<3], encoding: .ascii) == "ID3" {
            // Syncsafe integer: 4 bytes, 7 bits each
            let tagSize = (Int(id3Header[6]) << 21)
                | (Int(id3Header[7]) << 14)
                | (Int(id3Header[8]) << 7)
                | Int(id3Header[9])
            handle.seek(toFileOffset: UInt64(10 + tagSize))
        } else {
            handle.seek(toFileOffset: 0)
        }

        // Scan for sync word (up to 8KB)
        let scanData = handle.readData(ofLength: 8192)
        guard scanData.count >= 4 else { throw ParseError.readError }

        for i in 0..<(scanData.count - 3) {
            guard scanData[i] == 0xFF, (scanData[i + 1] & 0xE0) == 0xE0 else { continue }

            let b1 = scanData[i + 1]
            let b2 = scanData[i + 2]
            let b3 = scanData[i + 3]

            // MPEG version: bits 4-3 of byte 1
            let versionBits = (b1 >> 3) & 0x03
            // Layer: bits 2-1 of byte 1
            let layerBits = (b1 >> 1) & 0x03
            // Sample rate index: bits 3-2 of byte 2
            let srIndex = Int((b2 >> 2) & 0x03)
            // Channel mode: bits 7-6 of byte 3
            let channelMode = (b3 >> 6) & 0x03

            guard srIndex < 3, versionBits != 1, layerBits != 0 else { continue }

            let sampleRates: [[Int]] = [
                // MPEG 2.5     reserved    MPEG 2      MPEG 1
                [11025, 0, 22050, 44100],  // index 0
                [12000, 0, 24000, 48000],  // index 1
                [ 8000, 0, 16000, 32000],  // index 2
            ]

            let sampleRate = sampleRates[srIndex][Int(versionBits)]
            guard sampleRate > 0 else { continue }

            let channels = channelMode == 3 ? 1 : 2

            // MP3 decoded output is 16-bit PCM
            return SourceFormat(sampleRate: sampleRate, bitsPerSample: 16, channels: channels)
        }

        throw ParseError.readError
    }

    // MARK: - AIFF

    private static func parseAIFF(path: String) throws -> SourceFormat {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw ParseError.readError
        }
        defer { handle.closeFile() }

        // FORM header: "FORM" + size(4) + "AIFF"/"AIFC"
        let header = handle.readData(ofLength: 12)
        guard header.count == 12,
              String(data: header[0..<4], encoding: .ascii) == "FORM" else {
            throw ParseError.unsupportedFormat
        }
        let formType = String(data: header[8..<12], encoding: .ascii)
        guard formType == "AIFF" || formType == "AIFC" else {
            throw ParseError.unsupportedFormat
        }

        // Search for COMM chunk
        while true {
            let chunkHeader = handle.readData(ofLength: 8)
            guard chunkHeader.count == 8 else { throw ParseError.readError }

            let chunkID = String(data: chunkHeader[0..<4], encoding: .ascii)
            let chunkSize = Int(readUInt32BE(chunkHeader, offset: 4))

            if chunkID == "COMM" {
                let commData = handle.readData(ofLength: min(chunkSize, 26))
                guard commData.count >= 18 else { throw ParseError.readError }

                let channels = Int(readUInt16BE(commData, offset: 0))
                let bitsPerSample = Int(readUInt16BE(commData, offset: 6))
                // Sample rate is an 80-bit extended float at offset 8
                let sampleRate = Int(parseExtended80(commData, offset: 8))

                guard sampleRate > 0, bitsPerSample > 0 else { throw ParseError.readError }
                return SourceFormat(sampleRate: sampleRate, bitsPerSample: bitsPerSample, channels: channels)
            }

            // AIFF chunks are always even-aligned
            let skip = UInt64((chunkSize + 1) & ~1)
            handle.seek(toFileOffset: handle.offsetInFile + skip)
        }
    }

    // MARK: - Binary Helpers

    private static func readUInt16LE(_ data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt16BE(_ data: Data, offset: Int) -> UInt16 {
        (UInt16(data[offset]) << 8) | UInt16(data[offset + 1])
    }

    private static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        (UInt32(data[offset]) << 24)
            | (UInt32(data[offset + 1]) << 16)
            | (UInt32(data[offset + 2]) << 8)
            | UInt32(data[offset + 3])
    }

    // 80-bit IEEE 754 extended precision → Double (covers all common sample rates)
    private static func parseExtended80(_ data: Data, offset: Int) -> Double {
        let exponent = (Int(data[offset]) << 8) | Int(data[offset + 1])
        let sign = exponent & 0x8000
        let exp = exponent & 0x7FFF

        var mantissa: UInt64 = 0
        for i in 0..<8 {
            mantissa = (mantissa << 8) | UInt64(data[offset + 2 + i])
        }

        if exp == 0 && mantissa == 0 { return 0.0 }

        let f = Double(mantissa) / Double(UInt64(1) << 63) * pow(2.0, Double(exp - 16383))
        return sign != 0 ? -f : f
    }
}
