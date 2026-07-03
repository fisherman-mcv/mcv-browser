import Foundation

enum TranslationResult {
    case text(String)     // переклад знайдено в локальному словнику
    case url(URL)         // фолбек: відкрити Google Translate
}

/// Локальний словник для миттєвого перекладу поширених слів + фолбек на веб-перекладач.
struct Translator {
    private static let enToUk: [String: String] = [
        "hello": "привіт", "world": "світ", "browser": "браузер", "good": "добре",
        "morning": "ранок", "evening": "вечір", "night": "ніч", "day": "день",
        "thanks": "дякую", "please": "будь ласка", "yes": "так", "no": "ні",
        "cat": "кіт", "dog": "пес", "house": "дім", "water": "вода",
        "fire": "вогонь", "time": "час", "work": "робота", "code": "код",
        "search": "пошук", "page": "сторінка", "tab": "вкладка", "file": "файл",
        "friend": "друг", "love": "любов", "life": "життя", "book": "книга",
        "fast": "швидко", "slow": "повільно", "new": "новий", "old": "старий",
        "open": "відкрити", "close": "закрити", "read": "читати", "write": "писати",
    ]

    private static let ukToEn: [String: String] = Dictionary(
        enToUk.map { ($0.value, $0.key) },
        uniquingKeysWith: { first, _ in first }
    )

    static func translate(_ text: String, target: String) -> TranslationResult {
        let hasCyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        let dict = hasCyrillic ? ukToEn : enToUk

        let words = text.lowercased().split(separator: " ").map {
            $0.trimmingCharacters(in: .punctuationCharacters)
        }
        let hits = words.compactMap { dict[$0] }
        if !words.isEmpty, hits.count == words.count {
            return .text(hits.joined(separator: " "))
        }

        let targetLang = hasCyrillic ? "en" : target
        let query = text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let url = URL(string: "https://translate.google.com/?sl=auto&tl=\(targetLang)&text=\(query)&op=translate")!
        return .url(url)
    }
}
