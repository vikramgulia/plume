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
