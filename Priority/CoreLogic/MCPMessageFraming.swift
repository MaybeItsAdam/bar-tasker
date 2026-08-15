import Foundation

/// How JSON-RPC messages are delimited on the wire.
enum MCPMessageFraming: Equatable {
  /// The MCP stdio transport: one JSON object per line, no headers. This is
  /// what Claude Code, Claude Desktop, Cursor, Zed and every other MCP client
  /// speaks, and it is the default.
  case newlineDelimited

  /// LSP-style `Content-Length` headers. Not part of the MCP stdio transport,
  /// but Priority's server used to require it, so it stays accepted for
  /// anything already wired up that way.
  case contentLength
}

enum MCPFrameError: LocalizedError, Equatable {
  case malformedHeader
  case missingContentLength

  var errorDescription: String? {
    switch self {
    case .malformedHeader: "Malformed MCP headers."
    case .missingContentLength: "Missing or invalid Content-Length header."
    }
  }
}

/// Splits an incoming byte stream into message bodies, accepting either framing
/// and remembering which one the peer used so replies can match it.
struct MCPFrameDecoder {
  private static let newline: UInt8 = 0x0A
  private static let headerSeparator = Data([0x0D, 0x0A, 0x0D, 0x0A])
  private static let fallbackHeaderSeparator = Data([0x0A, 0x0A])
  private static let contentLengthPrefix = "content-length:"

  private var buffer = Data()

  /// The framing of the most recently decoded message. Newline-delimited until
  /// proven otherwise, so a server that has read nothing still replies in the
  /// format the MCP spec requires.
  private(set) var detectedFraming: MCPMessageFraming = .newlineDelimited

  var hasBufferedBytes: Bool { !buffer.isEmpty }

  mutating func append(_ chunk: Data) {
    buffer.append(chunk)
  }

  /// The next complete message body, or `nil` when more bytes are needed.
  ///
  /// Anything thrown has already been consumed from the buffer, so a caller that
  /// reports the error and loops makes progress instead of spinning on it.
  mutating func nextMessageBody() throws -> Data? {
    dropLeadingBlankLines()
    guard !buffer.isEmpty else { return nil }

    if startsWithContentLengthHeader() {
      return try nextHeaderFramedBody()
    }
    return nextLineFramedBody()
  }

  // MARK: - Newline framing

  private mutating func nextLineFramedBody() -> Data? {
    guard let newlineOffset = offset(ofFirstByte: Self.newline) else { return nil }
    let line = Data(buffer.prefix(newlineOffset))
    consume(newlineOffset + 1)
    detectedFraming = .newlineDelimited
    return line
  }

  // MARK: - Content-Length framing

  private mutating func nextHeaderFramedBody() throws -> Data? {
    guard let separator = headerSeparatorRange() else { return nil }

    let headerData = Data(buffer.prefix(separator.offset))
    guard let headerText = String(data: headerData, encoding: .utf8) else {
      consume(separator.offset + separator.length)
      throw MCPFrameError.malformedHeader
    }

    var contentLength: Int?
    for rawLine in headerText.split(separator: "\n", omittingEmptySubsequences: true) {
      let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
      guard !line.isEmpty else { continue }
      let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
      guard parts.count == 2 else {
        consume(separator.offset + separator.length)
        throw MCPFrameError.malformedHeader
      }
      if parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
        contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces))
      }
    }

    guard let contentLength, contentLength >= 0 else {
      consume(separator.offset + separator.length)
      throw MCPFrameError.missingContentLength
    }

    let bodyStart = separator.offset + separator.length
    guard buffer.count >= bodyStart + contentLength else { return nil }

    let body = Data(buffer.dropFirst(bodyStart).prefix(contentLength))
    consume(bodyStart + contentLength)
    detectedFraming = .contentLength
    return body
  }

  // MARK: - Buffer helpers

  private mutating func dropLeadingBlankLines() {
    while let first = buffer.first, first == Self.newline || first == 0x0D {
      consume(1)
    }
  }

  private func startsWithContentLengthHeader() -> Bool {
    let probe = Data(buffer.prefix(Self.contentLengthPrefix.utf8.count))
    guard let text = String(data: probe, encoding: .utf8) else { return false }
    return text.lowercased() == Self.contentLengthPrefix
  }

  private func offset(ofFirstByte byte: UInt8) -> Int? {
    guard let index = buffer.firstIndex(of: byte) else { return nil }
    return buffer.distance(from: buffer.startIndex, to: index)
  }

  private func headerSeparatorRange() -> (offset: Int, length: Int)? {
    if let range = buffer.range(of: Self.headerSeparator) {
      return (buffer.distance(from: buffer.startIndex, to: range.lowerBound), 4)
    }
    if let range = buffer.range(of: Self.fallbackHeaderSeparator) {
      return (buffer.distance(from: buffer.startIndex, to: range.lowerBound), 2)
    }
    return nil
  }

  /// Rebuilding rather than `removeSubrange` keeps `startIndex` at zero, so the
  /// offset arithmetic above stays valid after the first consumed message.
  private mutating func consume(_ count: Int) {
    buffer = Data(buffer.dropFirst(count))
  }
}

enum MCPFrameEncoder {
  static func encode(body: Data, framing: MCPMessageFraming) -> Data {
    switch framing {
    case .newlineDelimited:
      var framed = body
      framed.append(0x0A)
      return framed
    case .contentLength:
      var framed = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
      framed.append(body)
      return framed
    }
  }
}
