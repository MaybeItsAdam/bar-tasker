import XCTest

@testable import PriorityCore

final class MCPMessageFramingTests: XCTestCase {
  private func text(_ data: Data?) -> String? {
    guard let data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func decoder(fed input: String) -> MCPFrameDecoder {
    var decoder = MCPFrameDecoder()
    decoder.append(Data(input.utf8))
    return decoder
  }

  // MARK: - Newline framing (the MCP stdio transport)

  func testDecodesNewlineDelimitedMessages() throws {
    var subject = decoder(fed: "{\"id\":1}\n{\"id\":2}\n")
    XCTAssertEqual(text(try subject.nextMessageBody()), "{\"id\":1}")
    XCTAssertEqual(text(try subject.nextMessageBody()), "{\"id\":2}")
    XCTAssertNil(try subject.nextMessageBody())
    XCTAssertEqual(subject.detectedFraming, .newlineDelimited)
  }

  func testNewlineFramingIsTheDefaultBeforeAnythingIsRead() {
    // Every MCP client speaks newline-delimited JSON, so a reply written before
    // a request arrives (or after an unparseable one) must use it.
    XCTAssertEqual(MCPFrameDecoder().detectedFraming, .newlineDelimited)
  }

  func testPartialLineWaitsForTheRestOfTheStream() throws {
    var subject = decoder(fed: "{\"id\":")
    XCTAssertNil(try subject.nextMessageBody())

    subject.append(Data("1}\n".utf8))
    XCTAssertEqual(text(try subject.nextMessageBody()), "{\"id\":1}")
  }

  func testBlankLinesBetweenMessagesAreSkipped() throws {
    var subject = decoder(fed: "\n\n{\"id\":1}\n")
    XCTAssertEqual(text(try subject.nextMessageBody()), "{\"id\":1}")
  }

  // MARK: - Content-Length framing (legacy)

  func testDecodesContentLengthFramedMessages() throws {
    var subject = decoder(fed: "Content-Length: 8\r\n\r\n{\"id\":1}")
    XCTAssertEqual(text(try subject.nextMessageBody()), "{\"id\":1}")
    XCTAssertEqual(subject.detectedFraming, .contentLength)
  }

  func testContentLengthBodyWaitsUntilFullyBuffered() throws {
    var subject = decoder(fed: "Content-Length: 8\r\n\r\n{\"id\"")
    XCTAssertNil(try subject.nextMessageBody())

    subject.append(Data(":1}".utf8))
    XCTAssertEqual(text(try subject.nextMessageBody()), "{\"id\":1}")
  }

  func testFramingIsDetectedPerMessage() throws {
    var subject = decoder(fed: "Content-Length: 8\r\n\r\n{\"id\":1}{\"id\":2}\n")
    _ = try subject.nextMessageBody()
    XCTAssertEqual(subject.detectedFraming, .contentLength)
    _ = try subject.nextMessageBody()
    XCTAssertEqual(subject.detectedFraming, .newlineDelimited)
  }

  // MARK: - Error recovery

  /// The old reader rethrew on a buffer it never drained, so the server wrote
  /// the same parse error in a tight loop until the pipe closed.
  func testHeaderErrorsConsumeTheirBytesSoDecodingCanProgress() throws {
    var subject = decoder(fed: "Content-Length: nope\r\n\r\n{\"id\":2}\n")
    XCTAssertThrowsError(try subject.nextMessageBody()) { error in
      XCTAssertEqual(error as? MCPFrameError, .missingContentLength)
    }
    XCTAssertEqual(text(try subject.nextMessageBody()), "{\"id\":2}")
  }

  func testTrailingPartialMessageLeavesBufferedBytes() throws {
    var subject = decoder(fed: "{\"id\":1}\n{\"par")
    _ = try subject.nextMessageBody()
    XCTAssertNil(try subject.nextMessageBody())
    XCTAssertTrue(subject.hasBufferedBytes)
  }

  // MARK: - Encoding

  func testNewlineEncodingAppendsExactlyOneNewline() {
    let encoded = MCPFrameEncoder.encode(body: Data("{\"ok\":1}".utf8), framing: .newlineDelimited)
    XCTAssertEqual(text(encoded), "{\"ok\":1}\n")
  }

  func testContentLengthEncodingCountsBytesNotCharacters() {
    let body = Data("{\"a\":\"é\"}".utf8)
    let encoded = MCPFrameEncoder.encode(body: body, framing: .contentLength)
    XCTAssertEqual(text(encoded), "Content-Length: \(body.count)\r\n\r\n{\"a\":\"é\"}")
  }

  func testEncodedMessagesRoundTripThroughTheDecoder() throws {
    for framing in [MCPMessageFraming.newlineDelimited, .contentLength] {
      var subject = MCPFrameDecoder()
      subject.append(MCPFrameEncoder.encode(body: Data("{\"id\":7}".utf8), framing: framing))
      XCTAssertEqual(text(try subject.nextMessageBody()), "{\"id\":7}", "framing: \(framing)")
      XCTAssertEqual(subject.detectedFraming, framing)
    }
  }
}
