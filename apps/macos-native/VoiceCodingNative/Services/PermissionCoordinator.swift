import AVFAudio
import AVFoundation
import ApplicationServices
import Cocoa
import Foundation

@MainActor
final class PermissionCoordinator {
    func refresh() -> PermissionState {
        PermissionState(
            microphone: microphoneStatus(),
            accessibility: accessibilityStatus(prompt: false),
            inputMonitoring: inputMonitoringStatus()
        )
    }

    func requestMicrophoneAccess() async -> PermissionState {
        NSApp.activate(ignoringOtherApps: true)

        if #available(macOS 14.0, *) {
            _ = await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        } else {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        return refresh()
    }

    func requestAccessibilityAccess() -> PermissionState {
        _ = accessibilityStatus(prompt: true)
        return refresh()
    }

    func openSystemSettings(for area: PermissionArea) {
        let rawURL: String
        switch area {
        case .microphone:
            rawURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            rawURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .inputMonitoring:
            rawURL = "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        }

        guard let url = URL(string: rawURL) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func microphoneStatus() -> PermissionAuthorizationState {
        if #available(macOS 14.0, *) {
            switch AVAudioApplication.shared.recordPermission {
            case .granted:
                return .authorized
            case .denied:
                return .denied
            case .undetermined:
                return .unknown
            @unknown default:
                return .unknown
            }
        } else {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .authorized
            case .denied, .restricted:
                return .denied
            case .notDetermined:
                return .unknown
            @unknown default:
                return .unknown
            }
        }
    }

    private func accessibilityStatus(prompt: Bool) -> PermissionAuthorizationState {
        let promptKey = "AXTrustedCheckOptionPrompt"
        let options = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .authorized : .denied
    }

    private func inputMonitoringStatus() -> PermissionAuthorizationState {
        let mask = (1 << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
            userInfo: nil
        )
        guard let tap else {
            return .denied
        }
        CFMachPortInvalidate(tap)
        return .authorized
    }
}

enum PermissionArea {
    case microphone
    case accessibility
    case inputMonitoring
}
