import Foundation

@main struct ReleaseNotesTests {
    static func main() {
        var failures = 0
        func check(_ condition: Bool, _ message: String) {
            if condition { print("PASS \(message)") } else { print("FAIL \(message)"); failures += 1 }
        }

        let sample = """
        # Changelog

        ## 1.0.2

        - 第一条改动
        - 第二条 `CHANGELOG.md` 带反引号

        ## 1.0.1

        - 更早的改动

        ## 1.0.0

        - 首个版本
        """

        let parsed = ReleaseNotes.parse(sample)
        check(parsed.count == 3, "parses every version section, got \(parsed.count)")
        check(parsed.map(\.version) == ["1.0.2", "1.0.1", "1.0.0"], "keeps newest-first order")
        check(parsed.first?.changes.count == 2, "counts bullets per section")
        check(parsed.first?.changes.last == "第二条 `CHANGELOG.md` 带反引号", "preserves bullet text")
        check(ReleaseNotes.parse("# Changelog\nno sections here").isEmpty, "empty document yields no notes")
        check(ReleaseNotes.parse("## 9.9.9\n\n## 1.0.0\n- only one").count == 1, "skips sections without bullets")

        if let bundled = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") {
            check(!ReleaseNotes.load().isEmpty, "bundled changelog parses, from \(bundled.lastPathComponent)")
        } else {
            print("SKIP bundled changelog is not present in this test binary")
        }

        if failures == 0 { print("ALL RELEASE NOTE TESTS PASSED") } else { print("\(failures) FAILURE(S)"); exit(1) }
    }
}
