import Foundation
import SwiftUI
import Combine

enum AudioFormat: String, CaseIterable, Identifiable {
    case m4a
    case wav
    var id: String { rawValue }
    var fileExtension: String { rawValue }
}

enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    var id: String { rawValue }
}

@MainActor
final class PreferencesStore: ObservableObject {
    static let shared = PreferencesStore()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let saveFolder = "saveFolder"
        static let format = "format"
        static let launchAtLogin = "launchAtLogin"
        static let showFloatingPill = "showFloatingPill"
        static let openInFinderAfter = "openInFinderAfter"
        static let autoTranscribe = "autoTranscribe"
        static let transcriptionLanguage = "transcriptionLanguage"
        static let theme = "theme"
        static let microphoneDeviceUID = "microphoneDeviceUID"
        static let transcriptionEngineID = "transcriptionEngineID"
        static let whisperModelID = "whisperModelID"
        static let whisperOfferHandled = "whisperOfferHandled"
        static let toggleRecordingShortcut = "toggleRecordingShortcut"
        static let voiceNoteShortcut = "voiceNoteShortcut"
        static let pillPositionX = "pillPositionX"
        static let pillPositionY = "pillPositionY"
    }

    @Published var saveFolder: URL {
        didSet { defaults.set(saveFolder.path, forKey: Key.saveFolder) }
    }
    @Published var format: AudioFormat {
        didSet { defaults.set(format.rawValue, forKey: Key.format) }
    }
    @Published var launchAtLogin: Bool {
        didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) }
    }
    @Published var showFloatingPill: Bool {
        didSet { defaults.set(showFloatingPill, forKey: Key.showFloatingPill) }
    }
    @Published var openInFinderAfter: Bool {
        didSet { defaults.set(openInFinderAfter, forKey: Key.openInFinderAfter) }
    }
    @Published var autoTranscribe: Bool {
        didSet { defaults.set(autoTranscribe, forKey: Key.autoTranscribe) }
    }
    @Published var transcriptionLanguage: String {
        didSet { defaults.set(transcriptionLanguage, forKey: Key.transcriptionLanguage) }
    }
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }
    /// Which transcription engine to use: "apple" or "whisper".
    @Published var transcriptionEngineID: String {
        didSet { defaults.set(transcriptionEngineID, forKey: Key.transcriptionEngineID) }
    }
    /// The Whisper model chosen for transcription (a `WhisperModelCatalog` id).
    /// True once the user has answered (or dismissed) the first-run offer to download Whisper.
    @Published var whisperOfferHandled: Bool {
        didSet { defaults.set(whisperOfferHandled, forKey: Key.whisperOfferHandled) }
    }
    @Published var whisperModelID: String {
        didSet { defaults.set(whisperModelID, forKey: Key.whisperModelID) }
    }
    /// UID of the microphone chosen in Settings (nil = automatic).
    @Published var microphoneDeviceUID: String? {
        didSet {
            if let uid = microphoneDeviceUID {
                defaults.set(uid, forKey: Key.microphoneDeviceUID)
            } else {
                defaults.removeObject(forKey: Key.microphoneDeviceUID)
            }
        }
    }
    /// Global shortcut that starts or stops a recording (nil = off).
    @Published var toggleRecordingShortcut: Shortcut? {
        didSet { Self.save(toggleRecordingShortcut, to: defaults, key: Key.toggleRecordingShortcut) }
    }
    /// Global shortcut that starts or stops a voice note (nil = off).
    @Published var voiceNoteShortcut: Shortcut? {
        didSet { Self.save(voiceNoteShortcut, to: defaults, key: Key.voiceNoteShortcut) }
    }
    @Published var pillPosition: CGPoint? {
        didSet {
            if let p = pillPosition {
                defaults.set(p.x, forKey: Key.pillPositionX)
                defaults.set(p.y, forKey: Key.pillPositionY)
            } else {
                defaults.removeObject(forKey: Key.pillPositionX)
                defaults.removeObject(forKey: Key.pillPositionY)
            }
        }
    }

    private init() {
        let defaultFolder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Plume", isDirectory: true)
        if let path = defaults.string(forKey: Key.saveFolder), !path.isEmpty {
            saveFolder = URL(fileURLWithPath: path)
        } else {
            saveFolder = defaultFolder
            defaults.set(defaultFolder.path, forKey: Key.saveFolder)
        }

        format = AudioFormat(rawValue: defaults.string(forKey: Key.format) ?? "") ?? .m4a
        launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        showFloatingPill = defaults.object(forKey: Key.showFloatingPill) as? Bool ?? true
        openInFinderAfter = defaults.bool(forKey: Key.openInFinderAfter)
        autoTranscribe = defaults.bool(forKey: Key.autoTranscribe)
        transcriptionLanguage = defaults.string(forKey: Key.transcriptionLanguage) ?? "en-US"
        theme = AppTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system
        microphoneDeviceUID = defaults.string(forKey: Key.microphoneDeviceUID)
        transcriptionEngineID = defaults.string(forKey: Key.transcriptionEngineID) ?? "apple"
        whisperModelID = defaults.string(forKey: Key.whisperModelID) ?? WhisperModelCatalog.defaultMultilingual
        whisperOfferHandled = defaults.bool(forKey: Key.whisperOfferHandled)
        toggleRecordingShortcut = Self.loadShortcut(from: defaults, key: Key.toggleRecordingShortcut,
                                                    fallback: .defaultToggleRecording)
        voiceNoteShortcut = Self.loadShortcut(from: defaults, key: Key.voiceNoteShortcut, fallback: nil)

        if defaults.object(forKey: Key.pillPositionX) != nil {
            pillPosition = CGPoint(
                x: defaults.double(forKey: Key.pillPositionX),
                y: defaults.double(forKey: Key.pillPositionY)
            )
        } else {
            pillPosition = nil
        }

        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
    }

    /// A missing key means "never set" (use the fallback); the string "none" means switched off.
    private static func loadShortcut(from defaults: UserDefaults, key: String, fallback: Shortcut?) -> Shortcut? {
        guard let stored = defaults.object(forKey: key) else { return fallback }
        guard let data = stored as? Data,
              let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data),
              shortcut.isValid else { return nil }
        return shortcut
    }

    private static func save(_ shortcut: Shortcut?, to defaults: UserDefaults, key: String) {
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: key)
        } else {
            defaults.set("none", forKey: key)
        }
    }

    var resolvedColorScheme: ColorSchemePreference {
        switch theme {
        case .system: return .system
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum ColorSchemePreference {
    case system, light, dark
}
