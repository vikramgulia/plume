import Foundation
import AVFoundation
import AppKit
import ScreenCaptureKit
import CoreGraphics

@MainActor
final class PermissionsService: ObservableObject {
    enum ScreenStatus: String {
        case granted, denied, unknown
    }

    @Published var screenStatus: ScreenStatus = .unknown
    @Published var micGranted: Bool = false

    func refresh() async {
        micGranted = AVAudioApplication.shared.recordPermission == .granted
        screenStatus = await checkScreenRecording()
    }

    func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            micGranted = true
            return true
        case .undetermined:
            let ok = await AVAudioApplication.requestRecordPermission()
            micGranted = ok
            return ok
        default:
            micGranted = false
            return false
        }
    }

    /// Asks macOS for microphone access, which shows the system prompt the first time. If the prompt
    /// can no longer be shown (access was refused earlier), opens System Settings instead. Declining
    /// the prompt just now doesn't open Settings: that was an answer, not a missing permission.
    func requestMicrophoneOrOpenSettings() async {
        let neverAsked = AVAudioApplication.shared.recordPermission == .undetermined
        let granted = await requestMicrophone()
        if !granted && !neverAsked {
            openMicrophoneSettings()
        }
    }

    private func checkScreenRecording() async -> ScreenStatus {
        if #available(macOS 13.0, *) {
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                // If we get content without prompting, permission is granted (or will prompt on first capture).
                // Probe with CGPreflightScreenCaptureAccess when available.
                if CGPreflightScreenCaptureAccess() {
                    return .granted
                }
                return .unknown
            } catch {
                return .denied
            }
        }
        return .denied
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
