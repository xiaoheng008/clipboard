import Foundation

/// The panel's bounded window of loaded rows (H6 / C36), as pure functions so the cap and the
/// no-duplicates rule are testable (AC5.3).
public enum RowWindow {
    /// Next page appended below; rows already present are skipped; never more than `cap`.
    public static func append<T: Identifiable>(_ page: [T], to rows: [T], cap: Int) -> [T] {
        let known = Set(rows.map(\.id))
        return Array((rows + page.filter { !known.contains($0.id) }).prefix(cap))
    }

    /// Newest rows placed on top, the rest kept below in their order (E24 / R9); never more than `cap`.
    public static func mergeTop<T: Identifiable>(_ top: [T], onto rows: [T], cap: Int) -> [T] {
        let topIDs = Set(top.map(\.id))
        return Array((top + rows.filter { !topIDs.contains($0.id) }).prefix(cap))
    }
}
