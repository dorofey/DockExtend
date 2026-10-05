import Foundation
import SQLite3

struct ZedSidebarProject: Identifiable {
    let id: String
    let paths: [String]
    var title: String { paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ") }
}

enum ZedProjectStore {
    static func read() -> [ZedSidebarProject] {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Zed/db/0-stable/db.sqlite").path
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)
        // Use the live session's window stack, never all historical sidebar rows.
        let sql = """
        SELECT s.value FROM scoped_kv_store s
        JOIN json_each((SELECT value FROM kv_store WHERE key='session_window_stack')) w
          ON s.key=CAST(w.value AS TEXT)
        WHERE s.namespace='multi_workspace_state' ORDER BY w.key
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var projects: [ZedSidebarProject] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            projects += parse(Data(String(cString: text).utf8))
        }
        var seen = Set<String>()
        return projects.filter { seen.insert($0.id).inserted }
    }

    static func parse(_ data: Data) -> [ZedSidebarProject] {
        guard let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let groups = state["project_groups"] as? [[String: Any]] else { return [] }
        return groups.compactMap { group in
            guard group["location"] as? String == "Local",
                  let list = group["path_list"] as? [String: Any],
                  let raw = list["paths"] as? String else { return nil }
            let paths = raw.components(separatedBy: .newlines).filter { $0.hasPrefix("/") }
            guard !paths.isEmpty else { return nil }
            let order = (list["order"] as? String ?? "").split(separator: ",").compactMap { Int($0) }
            let ordered = order.count == paths.count && Set(order) == Set(paths.indices) ? order.map { paths[$0] } : paths
            return ZedSidebarProject(id: paths.sorted().joined(separator: "\n"), paths: ordered)
        }
    }
}
