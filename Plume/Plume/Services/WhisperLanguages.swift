import Foundation

/// The languages Whisper's multilingual models understand, and how Plume's language setting
/// (a locale identifier such as "en-US") maps onto them.
enum WhisperLanguages {
    static let codes: [String] = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it",
        "id", "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur",
        "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr", "az", "sl", "kn",
        "et", "mk", "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si",
        "km", "sn", "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo",
        "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha",
        "ba", "jw", "su",
    ]

    /// Codes macOS uses that Whisper spells differently.
    private static let aliases = ["nb": "no", "iw": "he", "jv": "jw", "fil": "tl"]

    /// Whisper's code for a locale identifier, or nil if the model cannot transcribe that language.
    static func code(forLocaleIdentifier identifier: String, englishOnly: Bool) -> String? {
        let language = (Locale(identifier: identifier).language.languageCode?.identifier ?? identifier).lowercased()
        let code = aliases[language] ?? language
        if englishOnly { return code == "en" ? "en" : nil }
        return codes.contains(code) ? code : nil
    }
}
