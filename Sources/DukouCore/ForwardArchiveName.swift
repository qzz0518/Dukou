import Foundation

/// Shared naming for exported chat and Moments ZIPs. Date ranges describe the
/// content only when both endpoints are known; otherwise the export is dated.
public enum ForwardArchiveName {
    private static let maximumBytes = 200

    public static func make(
        source: String,
        count: Int?,
        start: Date?,
        end: Date?,
        part: Int? = nil,
        exportedAt: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmm"

        let period: String
        if let start, let end,
           start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite {
            let first = formatter.string(from: min(start, end))
            let last = formatter.string(from: max(start, end))
            period = first == last ? first : "\(first)至\(last)"
        } else {
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            period = exportedAt.timeIntervalSince1970.isFinite
                ? "导出\(formatter.string(from: exportedAt))" : "导出时间未知"
        }
        let quantity = count.flatMap { $0 >= 0 ? "\($0)条" : nil } ?? "条数未知"
        let batch = part.map { "_第\($0)批" } ?? ""
        let suffix = "_\(period)_\(quantity)\(batch).zip"
        return shortened(sanitized(source), byteLimit: maximumBytes - suffix.utf8.count) + suffix
    }

    private static func sanitized(_ source: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:<>\"'`|?*%")
        var result = ""
        for scalar in source.precomposedStringWithCanonicalMapping.unicodeScalars {
            let category = scalar.properties.generalCategory
            if forbidden.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
                || [.control, .format, .lineSeparator, .paragraphSeparator].contains(category) {
                if !result.hasSuffix("_") { result.append("_") }
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " ._"))
        if result.isEmpty { return "记录" }

        // A Windows device name remains reserved when followed by an extension.
        let base = result.split(separator: ".", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
        let devices = ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"]
            + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }
            + ["¹", "²", "³"].flatMap { ["COM\($0)", "LPT\($0)"] }
        if devices.contains(base) { result = "_" + result }
        return result
    }

    private static func shortened(_ source: String, byteLimit: Int) -> String {
        guard source.utf8.count > byteLimit else { return source }
        let ellipsis = "…"
        var result = ""
        var bytes = 0
        // Cut only at character boundaries, leaving the complete date, count
        // and extension intact even for long names containing multibyte text.
        for character in source {
            let size = String(character).utf8.count
            guard bytes + size <= byteLimit - ellipsis.utf8.count else { break }
            result.append(character)
            bytes += size
        }
        return result.isEmpty ? "记录" : result + ellipsis
    }
}
