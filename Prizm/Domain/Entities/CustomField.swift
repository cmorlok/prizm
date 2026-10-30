import Foundation

/// A user-defined or linked extra field attached to a vault item.
nonisolated struct CustomField: Equatable, Hashable {
    /// Nil for a field stored without a name (imports, the CLI, the API). Kept as nil, so a save
    /// sends it back unchanged (openspec change `fix-read-mapping-lossless-fields`, design D1).
    let name: String?
    let value: String?
    let type: CustomFieldType
    /// Non-nil only when `type == .linked`.
    let linkedId: LinkedFieldId?
}

/// Discriminates how a custom field's value is stored and displayed.
///
/// `unknown` keeps a type a newer client wrote, so a save sends the same integer back instead of
/// turning the field into text (`fix-read-mapping-lossless-fields`, design D3). `init(rawValue:)`
/// therefore never fails.
nonisolated enum CustomFieldType: RawRepresentable, Equatable, Hashable {
    case text
    case hidden
    case boolean
    case linked
    /// A value Prizm does not know, kept so it is sent back unchanged. Built by `init(rawValue:)`
    /// only: `.unknown` with a known raw value would compare equal to that case (`RawRepresentable`
    /// equality compares raw values).
    case unknown(Int)

    init(rawValue: Int) {
        switch rawValue {
        case 0:  self = .text
        case 1:  self = .hidden
        case 2:  self = .boolean
        case 3:  self = .linked
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: Int {
        switch self {
        case .text:             return 0
        case .hidden:           return 1
        case .boolean:          return 2
        case .linked:           return 3
        case .unknown(let raw): return raw
        }
    }
}

/// Identifies a native vault-item field that a linked custom field mirrors.
/// Raw values match the Bitwarden API schema (`LinkedIdType` in the Bitwarden SDK).
///
/// `unknown` keeps an id Prizm does not know, so a save sends it back unchanged
/// (`fix-read-mapping-lossless-fields`, design D3). `init(rawValue:)` therefore never fails.
nonisolated enum LinkedFieldId: RawRepresentable, Equatable, Hashable {
    // MARK: - Login fields
    case loginUsername
    case loginPassword

    // MARK: - Card fields
    case cardCardholderName
    case cardExpMonth
    case cardExpYear
    case cardCode
    case cardBrand
    case cardNumber

    // MARK: - Identity fields
    case identityTitle
    case identityMiddleName
    case identityAddress1
    case identityAddress2
    case identityAddress3
    case identityCity
    case identityState
    case identityPostalCode
    case identityCountry
    case identityCompany
    case identityEmail
    case identityPhone
    case identitySsn
    case identityUsername
    case identityPassportNumber
    case identityLicenseNumber
    case identityFirstName
    case identityLastName
    case identityFullName

    /// A value Prizm does not know, kept so it is sent back unchanged. Built by `init(rawValue:)`
    /// only: `.unknown` with a known raw value would compare equal to that case (`RawRepresentable`
    /// equality compares raw values).
    case unknown(Int)

    init(rawValue: Int) {
        switch rawValue {
        case 100: self = .loginUsername
        case 101: self = .loginPassword
        case 300: self = .cardCardholderName
        case 301: self = .cardExpMonth
        case 302: self = .cardExpYear
        case 303: self = .cardCode
        case 304: self = .cardBrand
        case 305: self = .cardNumber
        case 400: self = .identityTitle
        case 401: self = .identityMiddleName
        case 402: self = .identityAddress1
        case 403: self = .identityAddress2
        case 404: self = .identityAddress3
        case 405: self = .identityCity
        case 406: self = .identityState
        case 407: self = .identityPostalCode
        case 408: self = .identityCountry
        case 409: self = .identityCompany
        case 410: self = .identityEmail
        case 411: self = .identityPhone
        case 412: self = .identitySsn
        case 413: self = .identityUsername
        case 414: self = .identityPassportNumber
        case 415: self = .identityLicenseNumber
        case 416: self = .identityFirstName
        case 417: self = .identityLastName
        case 418: self = .identityFullName
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: Int {
        switch self {
        case .loginUsername: return 100
        case .loginPassword: return 101
        case .cardCardholderName: return 300
        case .cardExpMonth: return 301
        case .cardExpYear: return 302
        case .cardCode: return 303
        case .cardBrand: return 304
        case .cardNumber: return 305
        case .identityTitle: return 400
        case .identityMiddleName: return 401
        case .identityAddress1: return 402
        case .identityAddress2: return 403
        case .identityAddress3: return 404
        case .identityCity: return 405
        case .identityState: return 406
        case .identityPostalCode: return 407
        case .identityCountry: return 408
        case .identityCompany: return 409
        case .identityEmail: return 410
        case .identityPhone: return 411
        case .identitySsn: return 412
        case .identityUsername: return 413
        case .identityPassportNumber: return 414
        case .identityLicenseNumber: return 415
        case .identityFirstName: return 416
        case .identityLastName: return 417
        case .identityFullName: return 418
        case .unknown(let raw): return raw
        }
    }

    /// Human-readable label shown in the linked field row (e.g. "Username").
    var displayName: String {
        switch self {
        case .loginUsername:        return "Username"
        case .loginPassword:        return "Password"
        case .cardCardholderName:   return "Cardholder Name"
        case .cardExpMonth:         return "Expiration Month"
        case .cardExpYear:          return "Expiration Year"
        case .cardCode:             return "Security Code"
        case .cardBrand:            return "Brand"
        case .cardNumber:           return "Number"
        case .identityTitle:        return "Title"
        case .identityMiddleName:   return "Middle Name"
        case .identityAddress1:     return "Address 1"
        case .identityAddress2:     return "Address 2"
        case .identityAddress3:     return "Address 3"
        case .identityCity:         return "City"
        case .identityState:        return "State"
        case .identityPostalCode:   return "Postal Code"
        case .identityCountry:      return "Country"
        case .identityCompany:      return "Company"
        case .identityEmail:        return "Email"
        case .identityPhone:        return "Phone"
        case .identitySsn:          return "SSN"
        case .identityUsername:     return "Username"
        case .identityPassportNumber: return "Passport Number"
        case .identityLicenseNumber:  return "License Number"
        case .identityFirstName:    return "First Name"
        case .identityLastName:     return "Last Name"
        case .identityFullName:     return "Full Name"
        case .unknown:              return "Unknown field"
        }
    }
}
