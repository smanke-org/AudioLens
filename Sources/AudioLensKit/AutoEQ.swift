import Foundation

/// Headphone-correction curves from the AutoEQ project (github.com/jaakkopasanen/AutoEq,
/// MIT License): an index of measured headphones, and a parser for their parametric EQ
/// files, which are also what you'd import by hand.
public enum AutoEQ {
    public static let resultsBase = URL(string: "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/")!
    public static let indexURL = resultsBase.appending(path: "INDEX.md")

    /// One measured headphone in the index.
    public struct Entry: Hashable, Sendable, Identifiable {
        public var id: String { path }
        public let name: String
        /// "crinacle on 711".
        public let source: String
        /// Relative to `resultsBase`, percent-encoded as the index writes it.
        public let path: String

        /// The parametric EQ file for this entry.
        public var parametricURL: URL? {
            let folder = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
            let fileName = (name + " ParametricEQ.txt").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            guard let fileName else { return nil }
            return URL(string: folder + "/" + fileName, relativeTo: resultsBase)?.absoluteURL
        }
    }

    /// Reads INDEX.md, whose lines look like
    /// `- [Apple AirPods Pro](./crinacle/711%20in-ear/Apple%20AirPods%20Pro) by crinacle on 711`.
    public static func parseIndex(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        for line in text.split(separator: "\n") where line.hasPrefix("- [") {
            guard let close = line.range(of: "](") else { continue }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
            let rest = line[close.upperBound...]
            // The path may itself contain parentheses: "(ANC%20On)". The link ends at the last
            // ")" before " by ".
            guard let by = rest.range(of: ") by ", options: .backwards) else { continue }
            let path = String(rest[..<by.lowerBound])
            let source = String(rest[by.upperBound...]).trimmingCharacters(in: .whitespaces)
            entries.append(Entry(name: name, source: source, path: path))
        }
        return entries
    }

    /// Entries whose name contains every word of the query, best matches first.
    public static func search(_ entries: [Entry], for query: String, limit: Int = 60) -> [Entry] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        let hits = entries.filter { entry in
            let name = entry.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
        let q = query.lowercased()
        return Array(hits.sorted { a, b in
            let aStarts = a.name.lowercased().hasPrefix(q), bStarts = b.name.lowercased().hasPrefix(q)
            if aStarts != bStarts { return aStarts }
            if a.name.count != b.name.count { return a.name.count < b.name.count }
            return a.source < b.source
        }.prefix(limit))
    }

    public enum ParseError: LocalizedError {
        case noFilters
        public var errorDescription: String? {
            "The file has no filters AudioLens can read. It should look like an EqualizerAPO or AutoEQ ParametricEQ.txt file."
        }
    }

    /// Reads a ParametricEQ.txt / EqualizerAPO file:
    ///
    ///     Preamp: -6.0 dB
    ///     Filter 1: ON LSC Fc 105 Hz Gain 2.6 dB Q 0.70
    ///     Filter 2: ON PK Fc 514 Hz Gain -4.4 dB Q 0.68
    public static func parseParametric(_ text: String, name: String, source: String? = nil) throws -> HeadphoneCorrection {
        var preamp = 0.0
        var filters: [ParametricFilter] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("preamp:") {
                preamp = number(after: "preamp:", in: line) ?? 0
                continue
            }
            guard line.lowercased().hasPrefix("filter"), line.uppercased().contains(" ON ") else { continue }
            let tokens = line.split(separator: " ").map(String.init)
            guard let onIndex = tokens.firstIndex(where: { $0.uppercased() == "ON" }), onIndex + 1 < tokens.count else { continue }
            let kind: ParametricFilter.Kind
            switch tokens[onIndex + 1].uppercased() {
            case "PK", "PEQ", "MODAL": kind = .peak
            case "LS", "LSC", "LSQ": kind = .lowShelf
            case "HS", "HSC", "HSQ": kind = .highShelf
            case "LP", "LPQ": kind = .lowPass
            case "HP", "HPQ": kind = .highPass
            default: continue
            }
            func value(_ label: String) -> Double? {
                guard let i = tokens.firstIndex(where: { $0.caseInsensitiveCompare(label) == .orderedSame }),
                      i + 1 < tokens.count else { return nil }
                return Double(tokens[i + 1])
            }
            guard let frequency = value("Fc"), frequency > 0 else { continue }
            let gain = value("Gain") ?? 0
            let q = value("Q") ?? 0.707
            filters.append(ParametricFilter(kind: kind, frequency: frequency, gain: gain, q: q))
        }
        guard !filters.isEmpty else { throw ParseError.noFilters }
        return HeadphoneCorrection(name: name, source: source, preamp: preamp, filters: filters)
    }

    private static func number(after prefix: String, in line: String) -> Double? {
        let rest = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return Double(rest.split(separator: " ").first ?? "")
    }
}
