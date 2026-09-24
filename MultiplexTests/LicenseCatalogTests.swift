import XCTest
@testable import Multiplex

final class LicenseCatalogTests: XCTestCase {
    func testCatalogContainsTheShippedDependencySet() {
        let components = LicenseCatalog.components

        XCTAssertEqual(components.count, 13)
        XCTAssertEqual(components.filter { $0.family == .apache2 }.count, 9)
        XCTAssertEqual(components.filter { $0.family == .mit }.count, 3)
        XCTAssertEqual(components.filter { $0.family == .bsd }.count, 1)
    }

    func testVendoredSetIsExact() {
        let vendored = Set(
            LicenseCatalog.components.filter(\.isVendored).map(\.name)
        )

        XCTAssertEqual(vendored, ["SwiftTerm", "SwiftNIO SSH", "bcrypt_pbkdf"])
    }

    func testEveryLicenseContainsTheRealTerms() {
        for component in LicenseCatalog.components {
            XCTAssertFalse(component.licenseText.isEmpty, component.name)
            switch component.family {
            case .mit:
                XCTAssertGreaterThan(component.licenseText.count, 500, component.name)
                XCTAssertTrue(
                    component.licenseText.contains("Permission is hereby granted"),
                    component.name
                )
            case .apache2:
                XCTAssertGreaterThan(component.licenseText.count, 500, component.name)
                XCTAssertTrue(component.licenseText.contains("Apache License"), component.name)
                XCTAssertTrue(component.licenseText.contains("Version 2.0"), component.name)
            case .bsd:
                let hasWarrantyLine = component.licenseText.contains(
                    "THE SOFTWARE IS PROVIDED"
                ) || component.licenseText.contains("THE AUTHOR DISCLAIMS ALL WARRANTIES")
                XCTAssertTrue(hasWarrantyLine, component.name)
            }
        }
    }

    func testApacheComponentsShareOneCanonicalText() throws {
        let apache = LicenseCatalog.components.filter { $0.family == .apache2 }
        let canonical = try XCTUnwrap(apache.first?.licenseText)

        XCTAssertTrue(apache.allSatisfy { $0.licenseText == canonical })
    }

    func testNamesAreUniqueAndVersionsArePresent() {
        let components = LicenseCatalog.components

        XCTAssertEqual(Set(components.map(\.name)).count, components.count)
        XCTAssertTrue(components.allSatisfy { !$0.version.isEmpty })
    }
}
