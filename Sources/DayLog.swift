import Foundation

/// Parsed view of GET /logs/day for one local day.
/// Field names mirror the server payload exactly (dl.sm / dl.is / dl.st / dl.sp,
/// timed study entries in dl.ls / ls carrying sb + st), as the web client reads them.
struct DayLog {
    struct LiveSession {
        /// Start as epoch ms, for POST /study/stop's startedAt.
        let startedAtMs: Int
        let start: Date
        /// Subject name when the day log's timed sessions identify it, else nil.
        let subject: String?
    }

    let liveSession: LiveSession?

    /// Subject titles from sbs, in server order, regardless of any live session.
    let subjectTitles: [String]

    /// A session is live when st is set and sp is NOT after st.
    /// The `is` flag is not trusted on its own. Off days carry a 2019
    /// sentinel for st/sp, so implausible years are ignored.
    static func parse(_ json: [String: Any]) -> DayLog {
        // Subject titles come from sbs regardless of any live session.
        var titles: [String] = []
        var seen = Set<String>()
        if let sbs = json["sbs"] as? [[String: Any]] {
            for book in sbs {
                if let t = (book["t"] as? String) ?? (book["title"] as? String) {
                    let title = t.trimmingCharacters(in: .whitespaces)
                    if !title.isEmpty && !seen.contains(title) {
                        seen.insert(title)
                        titles.append(title)
                    }
                }
            }
        }
        let dl = json["dl"] as? [String: Any] ?? [:]
        guard let start = saneTime(dl["st"]) else { return DayLog(liveSession: nil, subjectTitles: titles) }
        let stop = saneTime(dl["sp"])
        guard stop == nil || stop! <= start else { return DayLog(liveSession: nil, subjectTitles: titles) }
        let subject = subjectForSession(start: start, json: json, dl: dl)
        return DayLog(liveSession: LiveSession(
            startedAtMs: Int(start.timeIntervalSince1970 * 1000),
            start: start,
            subject: subject), subjectTitles: titles)
    }

    /// The day log's timed sessions name the subject, if they cover this start.
    private static func subjectForSession(start: Date, json: [String: Any], dl: [String: Any]) -> String? {
        // Subject book: sbs[i].t (or .title) is the title for index i.
        var titleByIndex: [Int: String] = [:]
        if let sbs = json["sbs"] as? [[String: Any]] {
            for (i, book) in sbs.enumerated() {
                if let t = (book["t"] as? String) ?? (book["title"] as? String), !t.isEmpty {
                    titleByIndex[i] = t
                }
            }
        }
        // Scan timed entries (dl.ls first, then top-level ls) for this start.
        // An exact start match wins; otherwise the latest named entry at or
        // before the start is the best guess. Rest entries have no st, so
        // they are skipped by the st parse below.
        var latest: (start: Date, subject: String?)?
        for container in [dl, json] {
            guard let entries = container["ls"] as? [[String: Any]] else { continue }
            for entry in entries {
                guard let st = parseLogTime(entry["st"]) else { continue }
                let subject = subjectOfEntry(entry, titleByIndex: titleByIndex)
                if abs(st.timeIntervalSince(start)) < 1.0 { return subject }
                if st <= start, subject != nil {
                    if latest == nil || st > latest!.start { latest = (st, subject) }
                }
            }
        }
        return latest?.subject
    }

    private static func subjectOfEntry(_ entry: [String: Any], titleByIndex: [Int: String]) -> String? {
        if let sb = entry["sb"] as? String, !sb.isEmpty { return sb }
        let index = (entry["sbi"] as? Int) ?? (entry["sb"] as? Int)
        if let index, let title = titleByIndex[index] { return title }
        if let t = (entry["title"] as? String) ?? (entry["subject"] as? String), !t.isEmpty { return t }
        return nil
    }

    /// Accepts ISO strings ("2026-11-02T09:00:00", or with a space instead
    /// of T, as the server sometimes sends) and epoch numbers (ms when
    /// large, seconds otherwise).
    static func parseLogTime(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            let v = number.doubleValue
            let seconds = v > 1_000_000_000_000 ? v / 1000 : v
            return Date(timeIntervalSince1970: seconds)
        }
        guard var s = value as? String, !s.isEmpty else { return nil }
        if s.contains(" "), !s.contains("T") {
            s = s.replacingOccurrences(of: " ", with: "T")
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    /// parseLogTime plus the year sanity check (2019 off-day sentinel).
    private static func saneTime(_ value: Any?) -> Date? {
        guard let d = parseLogTime(value) else { return nil }
        let year = Calendar.current.component(.year, from: d)
        guard (2020...2100).contains(year) else { return nil }
        return d
    }
}
