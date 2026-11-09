import SwiftUI

struct ImagesPage: View {
    @Environment(Engine.self) private var engine
    @State private var query = ""
    @State private var isConfirmingPrune = false

    var body: some View {
        let shown = engine.images.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        let usersByImage = Dictionary(grouping: engine.containers, by: \.ImageID).mapValues { $0.map(\.name) }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SearchField(text: $query, prompt: "Search images")
                if unusedBytes > 0 {
                    Button("Remove unused, \(Bytes.disk(unusedBytes))") { isConfirmingPrune = true }.buttonStyle(RowButton())
                }
            }
            .padding(16)
            StorageHeader(name: "IMAGE")
            Divider().overlay(Theme.line)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if shown.isEmpty { EmptyState(title: engine.images.isEmpty ? "No images" : "Nothing matches", detail: engine.images.isEmpty ? "docker run pulls what it needs." : "Try another name.", command: engine.images.isEmpty ? "docker pull nginx" : nil).frame(height: 240) }
                    ForEach(shown) { img in
                        StorageRow(name: img.name, detail: "built \(img.created.formatted(.relative(presentation: .named)))", isDetailMono: false,
                                   users: usersByImage[img.Id] ?? [], size: img.Size, removeTitle: "Remove image \(img.name)?",
                                   removeMessage: "It can be pulled again later.") {
                            Task { await engine.remove(img) }
                        }
                        Divider().overlay(Theme.line)
                    }
                }
            }
            PageFooter(text: engine.images.isEmpty ? "" : "\(engine.images.count) images, \(Bytes.disk(engine.images.reduce(0) { $0 + $1.Size })). \(unusedBytes > 0 ? "\(Bytes.disk(unusedBytes)) is not used by any container." : "Every image is in use.")")
        }
        .confirmationDialog("Remove every image no container uses?", isPresented: $isConfirmingPrune) {
            Button("Remove unused images", role: .destructive) { Task { await engine.pruneImages() } }
        } message: {
            Text("This frees up to \(Bytes.disk(unusedBytes)), less where they share layers with images you keep. They can be pulled again later.")
        }
    }

    private var unusedBytes: Int64 {
        let used = Set(engine.containers.map(\.ImageID))
        return engine.images.filter { !used.contains($0.Id) }.reduce(0) { $0 + $1.Size }
    }
}

struct VolumesPage: View {
    @Environment(Engine.self) private var engine
    @State private var query = ""

    var body: some View {
        let usersByVolume = engine.containers.reduce(into: [String: [String]]()) { map, c in
            for v in c.volumeNames { map[v, default: []].append(c.name) }
        }
        let shown = engine.volumes.filter { v in
            query.isEmpty || v.Name.localizedCaseInsensitiveContains(query) || (usersByVolume[v.Name] ?? []).contains { $0.localizedCaseInsensitiveContains(query) }
        }
        VStack(spacing: 0) {
            SearchField(text: $query, prompt: "Search volumes or the containers using them").padding(16)
            StorageHeader(name: "VOLUME")
            Divider().overlay(Theme.line)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if shown.isEmpty { EmptyState(title: engine.volumes.isEmpty ? "No volumes" : "Nothing matches", detail: engine.volumes.isEmpty ? "Volumes keep data across container restarts." : "Try another name.", command: nil).frame(height: 240) }
                    ForEach(shown) { v in
                        // An anonymous volume's name is a 64-character hash, so it is named after its container instead.
                        let users = usersByVolume[v.Name] ?? []
                        StorageRow(name: v.isAnonymous ? (users.first.map { "\($0) data" } ?? "unnamed volume") : v.Name,
                                   detail: v.isAnonymous ? String(v.Name.prefix(12)) : nil, isDetailMono: true,
                                   users: users, size: v.UsageData?.Size ?? 0,
                                   removeTitle: "Remove volume \(v.isAnonymous ? String(v.Name.prefix(12)) : v.Name)?",
                                   removeMessage: "Its data is deleted and cannot be recovered.") {
                            Task { await engine.remove(v) }
                        }
                        Divider().overlay(Theme.line)
                    }
                }
            }
            PageFooter(text: volumeSummary(usersByVolume))
        }
    }

    private func volumeSummary(_ usersByVolume: [String: [String]]) -> String {
        guard !engine.volumes.isEmpty else { return "" }
        let total = engine.volumes.reduce(0) { $0 + ($1.UsageData?.Size ?? 0) }
        let unused = engine.volumes.filter { usersByVolume[$0.Name] == nil }
        let unusedBytes = unused.reduce(0) { $0 + ($1.UsageData?.Size ?? 0) }
        return "\(engine.volumes.count) volumes, \(Bytes.disk(total)). " + (unused.isEmpty ? "Every volume is in use." : "\(unused.count) unused, \(Bytes.disk(unusedBytes)).")
    }
}

/// One line of totals under a list, so the answer to "how much is this using" needs no adding up.
struct PageFooter: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            VStack(spacing: 0) {
                Divider().overlay(Theme.line)
                Text(text)
                    .font(.system(size: 11.5)).monospacedDigit()
                    .foregroundStyle(Theme.soft)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 9)
            }
            .background(Theme.surface)
        }
    }
}

private enum StorageColumn {
    static let users: CGFloat = 260
    static let size: CGFloat = 90
    static let actions: CGFloat = 80
}

private struct StorageHeader: View {
    let name: String

    var body: some View {
        HStack(spacing: 12) {
            Text(name).frame(maxWidth: .infinity, alignment: .leading)
            Text("USED BY").frame(width: StorageColumn.users, alignment: .leading)
            Text("SIZE").frame(width: StorageColumn.size, alignment: .trailing)
            Color.clear.frame(width: StorageColumn.actions, height: 1)
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .tracking(0.6)
        .foregroundStyle(Theme.dim)
        .padding(.horizontal, 16).padding(.bottom, 6)
    }
}

private struct StorageRow: View {
    let name: String
    let detail: String?
    let isDetailMono: Bool
    let users: [String]
    let size: Int64
    let removeTitle: String
    let removeMessage: String
    let onRemove: () -> Void
    @State private var isConfirming = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                if let detail { Text(detail).font(.system(size: 11, design: isDetailMono ? .monospaced : .default)).foregroundStyle(Theme.soft) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(users.isEmpty ? "unused" : users.joined(separator: ", "))
                .foregroundStyle(users.isEmpty ? Theme.dim : Theme.text)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: StorageColumn.users, alignment: .leading)
            Text(Bytes.disk(size)).monospacedDigit().foregroundStyle(Theme.soft)
                .frame(width: StorageColumn.size, alignment: .trailing)
            HStack {
                Spacer(minLength: 0)
                // Only something nothing uses can go, so in-use rows show no button instead of a dead one.
                if isHovered && users.isEmpty {
                    Button("Remove") { isConfirming = true }.buttonStyle(RowButton(isDestructive: true))
                }
            }
            .frame(width: StorageColumn.actions)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: 48)
        .background(isHovered ? Theme.hover : .clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .help(users.isEmpty ? "" : "Used by \(users.joined(separator: ", ")). Remove those containers first to remove this.")
        .confirmationDialog(removeTitle, isPresented: $isConfirming) {
            Button("Remove", role: .destructive, action: onRemove)
        } message: {
            Text(removeMessage)
        }
    }
}
