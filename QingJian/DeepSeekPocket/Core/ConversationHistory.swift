import Foundation

// Old releases created a new thread for every edit/retry. Group only explicit
// parent links; equal titles alone never establish a relationship. Old versions
// remain in the backup data but do not each occupy a sidebar row.
enum ConversationHistory {
    static func familyKeys(in threads: [ChatThread]) -> [UUID: UUID] {
        var parents: [UUID: UUID] = [:]
        for thread in threads {
            parents[thread.id] = thread.id
            if let parent = thread.parentThreadID, parents[parent] == nil { parents[parent] = parent }
        }
        func root(_ id: UUID) -> UUID {
            var current = id
            while let next = parents[current], next != current { current = next }
            return current
        }
        for thread in threads {
            guard let parent = thread.parentThreadID else { continue }
            let a = root(thread.id), b = root(parent)
            if a != b {
                if a.uuidString < b.uuidString { parents[b] = a } else { parents[a] = b }
            }
        }
        return Dictionary(uniqueKeysWithValues: threads.map { ($0.id, root($0.id)) })
    }

    static func memberIDs(for id: UUID, in threads: [ChatThread]) -> Set<UUID> {
        let keys = familyKeys(in: threads)
        guard let key = keys[id] else { return [] }
        return Set(keys.filter { $0.value == key }.map(\.key))
    }

    static func displayTitle(for thread: ChatThread, in threads: [ChatThread]) -> String {
        let lookup = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        return displayTitle(for: thread, lookup: lookup)
    }

    private static func displayTitle(for thread: ChatThread, lookup: [UUID: ChatThread]) -> String {
        var current = thread
        var seen: Set<UUID> = []
        while seen.insert(current.id).inserted, let parentID = current.parentThreadID,
              let parent = lookup[parentID] {
            let base = String(parent.title.prefix(28))
            guard current.title == base + " · 重试" || current.title == base + " · 修改" else { break }
            current = parent
        }
        return current.title
    }

    static func visibleThreads(_ threads: [ChatThread], activeID: UUID?) -> [ChatThread] {
        let keys = familyKeys(in: threads)
        let lookup = Dictionary(uniqueKeysWithValues: threads.map { ($0.id, $0) })
        let groups = Dictionary(grouping: threads, by: { keys[$0.id] ?? $0.id })
        return groups.values.compactMap { members -> ChatThread? in
            let latest = members.max {
                $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt < $1.updatedAt
            }
            guard var selected = members.first(where: { $0.id == activeID }) ?? latest else { return nil }
            selected.title = displayTitle(for: selected, lookup: lookup)
            selected.isPinned = members.contains { $0.isPinned == true }
            return selected
        }.sorted {
            if ($0.isPinned == true) != ($1.isPinned == true) { return $0.isPinned == true }
            return $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
    }
}
