/// Audited inventory of third-party code linked into Multiplex.
/// Documentation-only Swift packages are intentionally absent because they do
/// not ship in the app binary.
enum LicenseCatalog {
    static let cleanRoomMoshNote = "The mosh transport is a clean-room implementation "
        + "from protocol facts and carries no third-party license."

    static let components: [OpenSourceComponent] = [
        OpenSourceComponent(
            name: "SwiftTerm",
            version: "1.15.0",
            family: .mit,
            copyrightHolder: "Miguel de Icaza, the xterm.js authors, SourceLair, "
                + "and Christopher Jeffrey",
            isVendored: true,
            vendorNote: "Vendored fork · rev dd2fb8a · Multiplex patches",
            licenseText: LicenseTexts.swiftTermMIT
        ),
        OpenSourceComponent(
            name: "Citadel",
            version: "0.12.0",
            family: .mit,
            copyrightHolder: "Copyright (c) 2022 Orlandos",
            isVendored: false,
            vendorNote: nil,
            licenseText: LicenseTexts.citadelMIT
        ),
        OpenSourceComponent(
            name: "SwiftNIO SSH",
            version: "0.3.5",
            family: .apache2,
            copyrightHolder: "Copyright (c) 2017-2022 Apple Inc. and the SwiftNIO "
                + "project authors",
            isVendored: true,
            vendorNote: "Vendored fork · Citadel's Joannis fork · manifest fix",
            licenseText: LicenseTexts.apache2
        ),
        OpenSourceComponent(
            name: "SwiftNIO",
            version: "2.101.2",
            family: .apache2,
            copyrightHolder: "Copyright (c) 2017-2023 Apple Inc. and the SwiftNIO "
                + "project authors",
            isVendored: false,
            vendorNote: nil,
            licenseText: LicenseTexts.apache2
        ),
        OpenSourceComponent(
            name: "Swift Crypto",
            version: "3.15.1",
            family: .apache2,
            copyrightHolder: "Copyright (c) 2019-2023 Apple Inc. and the SwiftCrypto "
                + "project authors",
            isVendored: false,
            vendorNote: nil,
            licenseText: LicenseTexts.apache2
        ),
        OpenSourceComponent(
            name: "BigInt",
            version: "5.7.0",
            family: .mit,
            copyrightHolder: "Copyright (c) 2016-2017 Károly Lőrentey",
            isVendored: false,
            vendorNote: nil,
            licenseText: LicenseTexts.bigIntMIT
        ),
        OpenSourceComponent(
            name: "swift-log",
            version: "1.14.0",
            family: .apache2,
            copyrightHolder: "Copyright 2018, 2019 The SwiftLog Project",
            isVendored: false,
            vendorNote: nil,
            licenseText: LicenseTexts.apache2
        ),
        OpenSourceComponent(
            name: "swift-collections",
            version: "1.6.0",
            family: .apache2,
            copyrightHolder: "Copyright (c) 2021-2026 Apple Inc. and the Swift project authors",
            isVendored: false,
            vendorNote: nil,
            licenseText: LicenseTexts.apache2
        ),
        OpenSourceComponent(
            name: "swift-atomics",
            version: "1.3.1",
            family: .apache2,
            copyrightHolder: "Copyright (c) 2020-2025 Apple Inc. and the Swift project authors",
            isVendored: false,
            vendorNote: nil,
            licenseText: LicenseTexts.apache2
        ),
        OpenSourceComponent(
            name: "swift-asn1",
            version: "1.7.1",
            family: .apache2,
            copyrightHolder: "Copyright (c) 2019-2025 Apple Inc. and the SwiftASN1 "
                + "project authors",
            isVendored: false,
            vendorNote: nil,
            licenseText: LicenseTexts.apache2
        ),
        OpenSourceComponent(
            name: "swift-system",
            version: "1.7.2",
            family: .apache2,
            copyrightHolder: "Copyright (c) 2020-2024 Apple Inc. and the Swift System "
                + "project authors",
            isVendored: false,
            vendorNote: nil,
            licenseText: LicenseTexts.apache2
        ),
        OpenSourceComponent(
            name: "swift-argument-parser",
            version: "1.8.2",
            family: .apache2,
            copyrightHolder: "Copyright (c) 2020 Apple Inc. and the Swift project authors",
            isVendored: false,
            vendorNote: nil,
            licenseText: LicenseTexts.apache2
        ),
        OpenSourceComponent(
            name: "bcrypt_pbkdf",
            version: "OpenBSD",
            family: .bsd,
            copyrightHolder: "Copyright (c) 2013 Ted Unangst; Copyright 1997 Niels Provos",
            isVendored: true,
            vendorNote: "Vendored source · mpxbind_ prefix · Bind key sealing",
            licenseText: LicenseTexts.openBSDBSD
        ),
    ]
}
