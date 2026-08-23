import LocalAuthentication
import SwiftUI

/// What this device can actually use to unlock.
///
/// The lock screen used to promise Face ID on every device. A Touch ID phone,
/// or one with only a passcode, was told to use hardware it does not have.
enum UnlockMethod {
    case faceID
    case touchID
    case opticID
    case passcode
    case unavailable

    /// `biometryType` is only populated after a policy evaluation check, so
    /// the order here matters.
    static var current: UnlockMethod {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else {
            return .unavailable
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .passcode
        }
    }

    var systemImage: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .passcode: "lock.fill"
        case .unavailable: "lock.slash.fill"
        }
    }

    var unlockTitle: LocalizedStringKey {
        switch self {
        case .faceID: "lock.unlock_face_id"
        case .touchID: "lock.unlock_touch_id"
        case .opticID: "lock.unlock_optic_id"
        case .passcode, .unavailable: "lock.unlock_passcode"
        }
    }

    var isAvailable: Bool { self != .unavailable }
}
