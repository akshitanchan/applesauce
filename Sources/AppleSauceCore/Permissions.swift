import Foundation

#if os(macOS)
import Contacts
import CoreServices
import EventKit
#endif

/// A macOS privacy permission that some module needs.
public enum Permission: String, CaseIterable, Sendable, Codable {
    case calendars
    case reminders
    case contacts
    case automationMail = "automation_mail"
    case automationNotes = "automation_notes"
    case fullDiskAccess = "full_disk_access"

    public var title: String {
        switch self {
        case .calendars: "Calendars"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        case .automationMail: "Automation: Mail"
        case .automationNotes: "Automation: Notes"
        case .fullDiskAccess: "Full Disk Access"
        }
    }

    /// Modules that use this permission (shown by `doctor`).
    public var neededBy: [String] {
        switch self {
        case .calendars: ["calendar"]
        case .reminders: ["reminders"]
        case .contacts: ["contacts"]
        case .automationMail: ["mail"]
        case .automationNotes: ["notes"]
        case .fullDiskAccess: ["mail (fast search)"]
        }
    }

    /// Bundle ID of the app that an Automation permission targets.
    public var automationTarget: String? {
        switch self {
        case .automationMail: "com.apple.mail"
        case .automationNotes: "com.apple.Notes"
        default: nil
        }
    }

    var settingsPane: String {
        switch self {
        case .calendars: "Calendars"
        case .reminders: "Reminders"
        case .contacts: "Contacts"
        case .automationMail, .automationNotes: "Automation"
        case .fullDiskAccess: "Full Disk Access"
        }
    }

    /// The exact step that fixes a missing permission.
    public func fix(for state: PermissionState) -> String? {
        let settings = "System Settings > Privacy & Security > \(settingsPane)"
        switch state {
        case .granted:
            return nil
        case .notDetermined:
            if self == .fullDiskAccess {
                return "Open \(settings), click +, and add the applesauce binary. Then restart your AI app."
            }
            return "macOS asks the first time a \(neededBy.joined(separator: ", ")) tool runs. Click Allow."
        case .denied, .writeOnly, .limited:
            if self == .fullDiskAccess {
                return "Open \(settings), click +, and add the applesauce binary. Then restart your AI app."
            }
            return "Open \(settings) and turn on applesauce. After an applesauce update, turn it off and on again."
        case .restricted:
            return "A device policy (for example MDM) blocks this permission. Ask your administrator."
        case .appNotRunning:
            return "Open \(title.replacingOccurrences(of: "Automation: ", with: "")) and run doctor again."
        case .unknown:
            return "Run doctor again. If this stays, check \(settings)."
        case .unsupported:
            return "applesauce runs only on macOS."
        }
    }
}

public enum PermissionState: String, Sendable, Codable {
    case granted
    case denied
    case notDetermined = "not_determined"
    case restricted
    case writeOnly = "write_only"
    case limited
    case appNotRunning = "app_not_running"
    case unknown
    /// Not macOS, so there is no such permission.
    case unsupported
}

/// Reads permission states. Tests use a fake.
public protocol PermissionChecker: Sendable {
    func state(of permission: Permission) -> PermissionState
}

#if os(macOS)
/// Reads the real permission states. It never shows a prompt.
public struct SystemPermissionChecker: PermissionChecker {
    public init() {}

    public func state(of permission: Permission) -> PermissionState {
        switch permission {
        case .calendars: Self.eventKit(.event)
        case .reminders: Self.eventKit(.reminder)
        case .contacts: Self.contacts()
        case .automationMail, .automationNotes:
            Self.automation(bundleID: permission.automationTarget ?? "")
        case .fullDiskAccess: Self.fullDiskAccess()
        }
    }

    static func eventKit(_ type: EKEntityType) -> PermissionState {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    static func contacts() -> PermissionState {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        case .limited: .limited
        @unknown default: .unknown
        }
    }

    /// Asks the Apple Event system without a prompt. The target app must be running.
    static func automation(bundleID: String) -> PermissionState {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .unknown }
        let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(procNotFound): return .appNotRunning
        default: return .unknown
        }
    }

    /// Mail's data folder is protected by Full Disk Access, so listing it is the test.
    static func fullDiskAccess() -> PermissionState {
        let mail = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail").path
        guard FileManager.default.fileExists(atPath: mail) else { return .unknown }
        return (try? FileManager.default.contentsOfDirectory(atPath: mail)) != nil ? .granted : .denied
    }
}
#else
/// Other systems have no macOS permissions.
public struct SystemPermissionChecker: PermissionChecker {
    public init() {}
    public func state(of permission: Permission) -> PermissionState { .unsupported }
}
#endif
