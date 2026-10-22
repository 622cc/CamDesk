import SwiftUI
import AppKit

/// One parsed release section from the bundled changelog.
struct ReleaseNote: Identifiable, Hashable {
    let id: String
    let version: String
    let changes: [String]
}

enum ReleaseNotes {
    /// Reads `CHANGELOG.md` from the app bundle. Returns an empty list when the
    /// file is missing, so the window can say so instead of showing nothing.
    static func load(bundle: Bundle = .main) -> [ReleaseNote] {
        guard let url = bundle.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }

    static func parse(_ text: String) -> [ReleaseNote] {
        var notes: [ReleaseNote] = []
        var version: String?
        var changes: [String] = []
        func flush() {
            if let version, !changes.isEmpty { notes.append(ReleaseNote(id: version, version: version, changes: changes)) }
            changes = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flush()
                version = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- "), version != nil {
                changes.append(String(line.dropFirst(2)))
            }
        }
        flush()
        return notes
    }
}

struct ReleaseNotesView: View {
    private let notes = ReleaseNotes.load()
    private static let installedVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    var body: some View {
        Group {
            if notes.isEmpty {
                ContentUnavailableView {
                    Label("没有找到更新日志", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("这个构建没有附带更新日志文件。最新版本说明可以在项目的 GitHub Releases 页面查看。")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(notes) { note in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(note.version).font(.title3.weight(.semibold))
                                    if note.version == Self.installedVersion {
                                        Text("当前版本")
                                            .font(.caption.weight(.medium))
                                            .padding(.horizontal, 7)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                                    }
                                }
                                ForEach(note.changes, id: \.self) { change in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(inline(change))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            Divider()
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle("更新日志")
    }

    /// Renders `backtick` spans as monospaced text instead of showing the backticks.
    private func inline(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in text.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            var piece = AttributedString(String(part))
            if index % 2 == 1 { piece.font = .system(.body, design: .monospaced) }
            result += piece
        }
        return result
    }
}
