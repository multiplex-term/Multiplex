/// The license families represented by code shipped in the app.
enum LicenseFamily: String, CaseIterable, Sendable {
    case apache2
    case mit
    case bsd

    var displayName: String {
        switch self {
        case .apache2: "Apache-2.0"
        case .mit: "MIT"
        case .bsd: "BSD"
        }
    }
}

/// One runtime dependency and the complete license notice shipped with it.
/// Presentation metadata stays beside the legal text so every licenses surface
/// reads from the same audited catalog.
struct OpenSourceComponent: Equatable, Sendable {
    let name: String
    let version: String
    let family: LicenseFamily
    let copyrightHolder: String
    let isVendored: Bool
    let vendorNote: String?
    let licenseText: String
}
