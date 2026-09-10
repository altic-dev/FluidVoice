import Foundation

enum LocalAPIMultipartFormData {
    struct Part: Sendable {
        let name: String
        let filename: String?
        let headers: [String: String]
        let body: Data

        var stringValue: String? {
            String(data: self.body, encoding: .utf8)
        }
    }

    static func parse(body: Data, contentType: String) throws -> [Part] {
        let boundary = try self.boundary(from: contentType)
        let delimiter = Data("--\(boundary)".utf8)
        let headerSeparator = Data("\r\n\r\n".utf8)

        guard body.starts(with: delimiter) else {
            throw self.error("Malformed multipart body: missing opening boundary.")
        }

        var parts: [Part] = []
        var cursor = body.startIndex + delimiter.count

        while true {
            if self.hasBytes([45, 45], at: cursor, in: body) {
                guard !parts.isEmpty else {
                    throw self.error("Malformed multipart body: no parts found.")
                }
                return parts
            }

            guard self.hasBytes([13, 10], at: cursor, in: body) else {
                throw self.error("Malformed multipart body: invalid boundary terminator.")
            }
            let partStart = cursor + 2

            guard let headerRange = body.range(of: headerSeparator, in: partStart..<body.endIndex) else {
                throw self.error("Malformed multipart body: missing part headers.")
            }
            let payloadStart = headerRange.upperBound
            guard let nextBoundary = self.nextBoundary(
                in: body,
                boundary: boundary,
                startingAt: payloadStart
            ) else {
                throw self.error("Malformed multipart body: missing closing boundary.")
            }

            let headers = try self.headers(from: Data(body[partStart..<headerRange.lowerBound]))
            guard let disposition = headers["content-disposition"] else {
                throw self.error("Malformed multipart body: missing Content-Disposition.")
            }

            let parameters = self.dispositionParameters(from: disposition)
            guard let name = parameters["name"], !name.isEmpty else {
                throw self.error("Malformed multipart body: missing part name.")
            }

            parts.append(
                Part(
                    name: name,
                    filename: parameters["filename"],
                    headers: headers,
                    body: body[payloadStart..<nextBoundary.lowerBound]
                )
            )
            cursor = nextBoundary.upperBound
        }
    }

    private static func nextBoundary(
        in body: Data,
        boundary: String,
        startingAt startIndex: Data.Index
    ) -> Range<Data.Index>? {
        let marker = Data("\r\n--\(boundary)".utf8)
        var searchStart = startIndex

        while searchStart < body.endIndex,
              let candidate = body.range(of: marker, in: searchStart..<body.endIndex)
        {
            let suffixStart = candidate.upperBound
            if self.hasBytes([45, 45], at: suffixStart, in: body)
                || self.hasBytes([13, 10], at: suffixStart, in: body)
            {
                return candidate
            }
            searchStart = candidate.lowerBound + 1
        }
        return nil
    }

    private static func boundary(from contentType: String) throws -> String {
        for component in self.parameterComponents(from: contentType) {
            let parameter = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = parameter.firstIndex(of: "=") else { continue }

            let key = parameter[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.caseInsensitiveCompare("boundary") == .orderedSame else { continue }

            let rawValue = parameter[parameter.index(after: separator)...]
            let value = self.parameterValue(from: String(rawValue))
            guard !value.isEmpty else { break }
            return value
        }
        throw self.error("Missing multipart boundary.")
    }

    private static func headers(from data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw self.error("Multipart headers must be UTF-8.")
        }

        var headers: [String: String] = [:]
        for line in text.components(separatedBy: "\r\n") where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw self.error("Malformed multipart header.")
            }
            let key = line[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    private static func dispositionParameters(from disposition: String) -> [String: String] {
        var parameters: [String: String] = [:]
        for component in self.parameterComponents(from: disposition).dropFirst() {
            let parameter = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = parameter.firstIndex(of: "=") else { continue }
            let key = parameter[..<separator]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let rawValue = parameter[parameter.index(after: separator)...]
            parameters[key] = self.parameterValue(from: String(rawValue))
        }
        return parameters
    }

    /// Splits MIME-style parameters only on semicolons outside quoted strings.
    /// Quoted-pair escapes are preserved here and decoded by `parameterValue(from:)`.
    private static func parameterComponents(from value: String) -> [String] {
        var components: [String] = []
        var current = ""
        var isQuoted = false
        var isEscaped = false

        for character in value {
            if isEscaped {
                current.append(character)
                isEscaped = false
                continue
            }

            if character == "\\", isQuoted {
                current.append(character)
                isEscaped = true
                continue
            }

            if character == "\"" {
                current.append(character)
                isQuoted.toggle()
                continue
            }

            if character == ";", !isQuoted {
                components.append(current)
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(character)
            }
        }

        components.append(current)
        return components
    }

    private static func parameterValue(from rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 2, value.first == "\"", value.last == "\"" else {
            return value
        }

        value.removeFirst()
        value.removeLast()

        var decoded = ""
        var isEscaped = false
        for character in value {
            if isEscaped {
                decoded.append(character)
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else {
                decoded.append(character)
            }
        }
        if isEscaped {
            decoded.append("\\")
        }
        return decoded
    }

    private static func hasBytes(_ bytes: [UInt8], at index: Data.Index, in data: Data) -> Bool {
        guard index >= data.startIndex, index + bytes.count <= data.endIndex else { return false }
        return zip(bytes, data[index..<(index + bytes.count)]).allSatisfy(==)
    }

    private static func error(_ message: String) -> NSError {
        NSError(
            domain: "LocalAPIMultipartFormData",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
