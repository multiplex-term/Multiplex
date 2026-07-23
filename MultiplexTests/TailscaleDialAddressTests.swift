import XCTest
@testable import Multiplex

final class TailscaleDialAddressTests: XCTestCase {
    func testFormatsPlainHostname() {
        XCTAssertEqual(
            TailscaleDialAddress.format(hostname: "devbox", port: 22),
            "devbox:22"
        )
    }

    func testPreservesMagicDNSName() {
        XCTAssertEqual(
            TailscaleDialAddress.format(
                hostname: "devbox.tail1234.ts.net",
                port: 22
            ),
            "devbox.tail1234.ts.net:22"
        )
    }

    func testFormatsIPv4Literal() {
        XCTAssertEqual(
            TailscaleDialAddress.format(hostname: "100.64.0.8", port: 22),
            "100.64.0.8:22"
        )
    }

    func testBracketsIPv6Literal() {
        XCTAssertEqual(
            TailscaleDialAddress.format(hostname: "::1", port: 22),
            "[::1]:22"
        )
    }

    func testPreservesBracketedIPv6Literal() {
        XCTAssertEqual(
            TailscaleDialAddress.format(hostname: "[::1]", port: 22),
            "[::1]:22"
        )
    }

    func testFormatsNonDefaultPort() {
        XCTAssertEqual(
            TailscaleDialAddress.format(hostname: "devbox", port: 2222),
            "devbox:2222"
        )
    }

    func testFormatsNodeHostnameFromDeviceName() {
        XCTAssertEqual(
            TailscaleNodeHostname.format(deviceName: "Jhen’s iPad Pro"),
            "multiplex-jhen-s-ipad-pro"
        )
        XCTAssertEqual(
            TailscaleNodeHostname.format(deviceName: "🛰️"),
            "multiplex"
        )
    }
}
