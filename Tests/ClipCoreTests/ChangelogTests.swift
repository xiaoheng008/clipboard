import Foundation
import Testing
@testable import ClipCore

/// 7A: the shipped version has release notes. CHANGELOG.md's newest entry must be the version in Version.swift.
@Suite struct ChangelogTests {
    @Test func newestEntryMatchesAppVersion() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let first = try #require(text.split(separator: "\n").first { $0.hasPrefix("## ") && !$0.contains("未发布") })
        #expect(first.hasPrefix("## \(AppVersion.marketing)（build \(AppVersion.build)）"), "\(first)")
    }
}
