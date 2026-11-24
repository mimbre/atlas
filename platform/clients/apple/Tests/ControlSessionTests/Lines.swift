import AtlasControlKit
import ControlSession
import Foundation

/// Lines Control sends, as JSON, built for a test. Their shapes are those of the captured
/// lines in platform/atlas_control/backend/targets/swift/Tests/Fixtures/control/received.jsonl.
enum Lines {
    static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func welcome(env: String = "test", spec: String = Contract.version, surface: String? = "console") -> Data {
        var object: [String: Any] = ["op": "welcome", "env": env, "spec": spec]
        if let surface { object["surface"] = surface }
        return json(object)
    }

    static func tab(_ id: String, _ to: String, section: String = "work") -> [String: Any] {
        ["id": id, "label": "Label \(id)", "to": to, "section": section]
    }

    static var tabs: [[String: Any]] { [tab("widgets", "/k/widget"), tab("parts", "/k/part")] }

    static func boot(tabs: [[String: Any]] = Lines.tabs, initialTo: String = "/k/widget", activeTab: String? = "widgets", env: String = "test", title: String = "Console") -> Data {
        var object: [String: Any] = [
            "op": "boot", "env": env, "spec": Contract.version, "revision": "r1",
            "title": title, "tabs": tabs, "initial_to": initialTo,
        ]
        if let activeTab { object["active_tab"] = activeTab }
        return json(object)
    }

    static func bootError(_ text: String) -> Data {
        json(["op": "boot", "error": text])
    }

    static func row(_ id: String, to: String) -> [String: Any] {
        ["id": id, "key": id, "label": "Row \(id)", "to": to]
    }

    static func list(_ rows: [[String: Any]]) -> [String: Any] {
        ["id": "list", "type": "list", "props": ["rows": rows]]
    }

    static var form: [String: Any] {
        [
            "id": "form", "type": "form",
            "props": [
                "title": "Form", "submit_label": "Save",
                "submit_to": ["endpoint": "update", "params": ["kind": "widget", "key": "W-01"]],
                "inputs": [["kind": "text", "label": "Title", "name": "title", "required": true, "value": "Before"]],
            ],
        ]
    }

    static func page(_ path: String, reason: String = "open", position: Int? = nil, blocks: [[String: Any]]? = nil, title: String = "Page", count: String? = nil, at: String = "12:00:00") -> Data {
        var object: [String: Any] = [
            "op": "page", "path": path, "reason": reason, "title": title, "at": at,
            "blocks": blocks ?? [list([row("W-01", to: "/k/widget/W-01")])], "markup": [],
        ]
        object["position"] = position.map { $0 as Any } ?? NSNull()
        if let count { object["count"] = count }
        return json(object)
    }

    static func notice(_ text: String, tone: String = "ok") -> Data {
        json(["op": "notice", "tone": tone, "text": text, "at": "12:00:01"])
    }

    /// `line` with `key` set to `value`. A value of the wrong type makes a line of a known
    /// op that does not decode (`ControlMessage.undecodable`).
    static func with(_ line: Data, _ key: String, _ value: Any) -> Data {
        var object = try! JSONSerialization.jsonObject(with: line) as! [String: Any]
        object[key] = value
        return json(object)
    }

    static func bye(_ text: String) -> Data {
        json(["op": "bye", "text": text])
    }
}
