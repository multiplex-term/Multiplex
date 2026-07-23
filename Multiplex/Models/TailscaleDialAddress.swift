import Foundation

enum TailscaleDialAddress {
    static func format(hostname: String, port: Int) -> String {
        let formattedHostname: String
        if hostname.hasPrefix("[") && hostname.hasSuffix("]") {
            formattedHostname = hostname
        } else if hostname.contains(":") {
            formattedHostname = "[\(hostname)]"
        } else {
            formattedHostname = hostname
        }
        return "\(formattedHostname):\(port)"
    }
}

enum TailscaleNodeHostname {
    static func format(deviceName: String) -> String {
        var sanitized = ""
        var needsSeparator = false

        for scalar in deviceName.lowercased().unicodeScalars {
            let isLowercaseLetter = scalar.value >= 97 && scalar.value <= 122
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            if isLowercaseLetter || isDigit {
                if needsSeparator, !sanitized.isEmpty {
                    sanitized.append("-")
                }
                sanitized.unicodeScalars.append(scalar)
                needsSeparator = false
            } else if !sanitized.isEmpty {
                needsSeparator = true
            }
        }

        return sanitized.isEmpty ? "multiplex" : "multiplex-\(sanitized)"
    }
}
