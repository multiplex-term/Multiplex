import XCTest
@testable import Multiplex

final class TailscaleRSDialAddressTests: XCTestCase {
    func testClassifiesIPv4Literal() {
        XCTAssertEqual(
            TailscaleRSDialAddress.classify(hostname: "100.64.0.8"),
            .literalIP("100.64.0.8")
        )
    }

    func testClassifiesIPv6Literal() {
        XCTAssertEqual(
            TailscaleRSDialAddress.classify(hostname: "fd7a:115c:a1e0::1"),
            .literalIP("fd7a:115c:a1e0::1")
        )
    }

    func testStripsBracketsFromIPv6Literal() {
        XCTAssertEqual(
            TailscaleRSDialAddress.classify(hostname: "[fd7a:115c:a1e0::1]"),
            .literalIP("fd7a:115c:a1e0::1")
        )
    }

    func testClassifiesMagicDNSNameAsPeer() {
        XCTAssertEqual(
            TailscaleRSDialAddress.classify(hostname: "devbox.tail1234.ts.net"),
            .peerName("devbox.tail1234.ts.net")
        )
    }

    func testClassifiesBareHostnameAsPeer() {
        XCTAssertEqual(
            TailscaleRSDialAddress.classify(hostname: "devbox"),
            .peerName("devbox")
        )
    }

    func testTrimsWhitespaceBeforeClassifying() {
        XCTAssertEqual(
            TailscaleRSDialAddress.classify(hostname: "  devbox  "),
            .peerName("devbox")
        )
    }

    func testIPv4Validation() {
        XCTAssertTrue(TailscaleRSDialAddress.isIPv4("10.0.0.1"))
        XCTAssertTrue(TailscaleRSDialAddress.isIPv4("255.255.255.255"))
        XCTAssertFalse(TailscaleRSDialAddress.isIPv4("256.0.0.1"))
        XCTAssertFalse(TailscaleRSDialAddress.isIPv4("10.0.0"))
        XCTAssertFalse(TailscaleRSDialAddress.isIPv4("devbox"))
        XCTAssertFalse(TailscaleRSDialAddress.isIPv4("10.0.0.1.2"))
    }

    func testIPv6Validation() {
        XCTAssertTrue(TailscaleRSDialAddress.isIPv6("::1"))
        XCTAssertTrue(TailscaleRSDialAddress.isIPv6("fd7a:115c:a1e0::3101:7939"))
        XCTAssertFalse(TailscaleRSDialAddress.isIPv6("devbox.ts.net"))
        XCTAssertFalse(TailscaleRSDialAddress.isIPv6("10.0.0.1"))
    }

    func testFormatsNodeHostnameFromDeviceName() {
        XCTAssertEqual(
            TailscaleNodeHostname.format(deviceName: "Jhen's iPad Pro"),
            "multiplex-jhen-s-ipad-pro"
        )
        XCTAssertEqual(
            TailscaleNodeHostname.format(deviceName: "🛰️"),
            "multiplex"
        )
    }
}
