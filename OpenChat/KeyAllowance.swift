import Foundation

struct KeyAllowance: Decodable, Equatable {
    let configured: Bool
    let limit: Double?
    let remaining: Double?
}

enum KeyAllowanceState: Equatable {
    case idle
    case loading
    case loaded(KeyAllowance)
    case unavailable
}
