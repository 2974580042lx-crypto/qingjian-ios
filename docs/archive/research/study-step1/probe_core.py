"""Isolated protocol experiment. This module is not linked into the iOS app."""

import hashlib
import json
import sqlite3
import uuid
from datetime import datetime, timezone


class ProbeError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(code)


def strict_json(text):
    def unique_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ProbeError("duplicate_json_key")
            result[key] = value
        return result

    def invalid_constant(value):
        raise ProbeError("invalid_json_number")

    if not isinstance(text, str) or len(text.encode("utf-8")) > 65536:
        raise ProbeError("invalid_json_size")
    try:
        return json.loads(text, object_pairs_hook=unique_pairs, parse_constant=invalid_constant)
    except (ValueError, TypeError, RecursionError) as error:
        raise ProbeError("invalid_json") from error


SCHEMAS = {
    "study_read_material": {
        "description": "读取当前项目的一份学习资料。只允许使用已提供的资料 ID。",
        "properties": {"material_id": {"type": "string"}},
    },
    "study_remember": {
        "description": "按用户明确要求，保存一条带用户原话出处的易混点。成功以应用返回的回执为准。",
        "properties": {
            "content": {"type": "string"},
            "evidence_message_id": {"type": "string"},
            "evidence_quote": {"type": "string"},
        },
    },
    "study_correct": {
        "description": "按用户明确更正，更新当前项目的一条记忆。必须提供当前版本和更正原话。",
        "properties": {
            "memory_id": {"type": "string"},
            "expected_revision": {"type": "integer"},
            "content": {"type": "string"},
            "evidence_message_id": {"type": "string"},
            "evidence_quote": {"type": "string"},
        },
    },
}


def tool_specs():
    return [
        {"type": "function", "function": {
            "name": name,
            "description": spec["description"],
            "parameters": {
                "type": "object", "properties": spec["properties"],
                "required": list(spec["properties"]), "additionalProperties": False,
            },
        }} for name, spec in SCHEMAS.items()
    ]


def validate_action(action, arguments):
    if not isinstance(action, str) or action not in SCHEMAS:
        raise ProbeError("unknown_action")
    properties = SCHEMAS[action]["properties"]
    if not isinstance(arguments, dict) or set(arguments) != set(properties):
        raise ProbeError("unexpected_arguments")
    for key, schema in properties.items():
        value = arguments[key]
        if schema["type"] == "integer":
            if type(value) is not int or value < 1:
                raise ProbeError("invalid_revision")
        elif not isinstance(value, str) or not value.strip() or len(value) > 1000:
            raise ProbeError("invalid_argument")


def decode_proposal(reply, mode):
    if not reply["complete"]:
        raise ProbeError("incomplete_stream")
    if mode == "native":
        calls = reply["tool_calls"]
        if reply["finish_reason"] != "tool_calls" or len(calls) != 1:
            raise ProbeError("expected_one_tool_call")
        call = calls[0]
        if not call.get("id") or call.get("type") != "function":
            raise ProbeError("invalid_tool_call")
        action = call["function"]["name"]
        arguments = strict_json(call["function"]["arguments"])
    else:
        if reply["tool_calls"] or reply["finish_reason"] != "stop":
            raise ProbeError("unexpected_completion")
        envelope = strict_json(reply["content"])
        if not isinstance(envelope, dict) or set(envelope) != {"action", "arguments"}:
            raise ProbeError("invalid_envelope")
        action, arguments = envelope["action"], envelope["arguments"]
    validate_action(action, arguments)
    return action, arguments


class ProbeStore:
    """Project scope is supplied by the application, never by model arguments."""

    def __init__(self, path, project_id):
        self.project_id = project_id
        self.connection = sqlite3.connect(path)
        self.connection.row_factory = sqlite3.Row
        self.connection.executescript("""
            CREATE TABLE IF NOT EXISTS material (
                project_id TEXT, id TEXT, content TEXT NOT NULL,
                PRIMARY KEY(project_id, id));
            CREATE TABLE IF NOT EXISTS source_message (
                project_id TEXT, id TEXT, content TEXT NOT NULL,
                PRIMARY KEY(project_id, id));
            CREATE TABLE IF NOT EXISTS memory (
                project_id TEXT, id TEXT, revision INTEGER NOT NULL,
                content TEXT NOT NULL, evidence_message_id TEXT NOT NULL,
                evidence_quote TEXT NOT NULL,
                PRIMARY KEY(project_id, id));
            CREATE TABLE IF NOT EXISTS event (
                id TEXT PRIMARY KEY, project_id TEXT NOT NULL,
                memory_id TEXT NOT NULL, before_json TEXT, after_json TEXT NOT NULL,
                created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS operation (
                project_id TEXT, id TEXT, fingerprint TEXT NOT NULL,
                receipt TEXT NOT NULL, PRIMARY KEY(project_id, id));
        """)

    def seed(self, material, messages):
        with self.connection:
            for key, text in material.items():
                self.connection.execute("INSERT OR IGNORE INTO material VALUES (?, ?, ?)",
                                        (self.project_id, key, text))
            for key, text in messages.items():
                self.connection.execute("INSERT OR IGNORE INTO source_message VALUES (?, ?, ?)",
                                        (self.project_id, key, text))

    def memories(self):
        rows = self.connection.execute("SELECT * FROM memory WHERE project_id = ? ORDER BY id",
                                       (self.project_id,)).fetchall()
        return [dict(row) for row in rows]

    def execute(self, action, arguments, operation_id, *, source_message_id, allowed_action):
        validate_action(action, arguments)
        if action != allowed_action:
            raise ProbeError("action_not_allowed_for_turn")
        fingerprint = hashlib.sha256(json.dumps(
            [action, arguments, source_message_id, allowed_action],
            sort_keys=True, ensure_ascii=False).encode()).hexdigest()
        db = self.connection
        try:
            db.execute("BEGIN IMMEDIATE")
            previous = db.execute("SELECT * FROM operation WHERE project_id = ? AND id = ?",
                                  (self.project_id, operation_id)).fetchone()
            if previous:
                if previous["fingerprint"] != fingerprint:
                    raise ProbeError("operation_id_reused_with_different_content")
                db.commit()
                return json.loads(previous["receipt"])

            if action == "study_read_material":
                row = db.execute("SELECT content FROM material WHERE project_id = ? AND id = ?",
                                 (self.project_id, arguments["material_id"])).fetchone()
                if not row:
                    raise ProbeError("material_not_found")
                receipt = {"status": "read", "material_id": arguments["material_id"],
                           "content": row["content"]}
            else:
                if arguments["evidence_message_id"] != source_message_id:
                    raise ProbeError("wrong_evidence_message")
                source = db.execute("SELECT content FROM source_message WHERE project_id = ? AND id = ?",
                                    (self.project_id, source_message_id)).fetchone()
                if not source or arguments["evidence_quote"] not in source["content"]:
                    raise ProbeError("evidence_not_in_user_message")
                before = None
                memory_id = str(uuid.uuid4())
                revision = 1
                if action == "study_correct":
                    memory_id = arguments["memory_id"]
                    row = db.execute("SELECT * FROM memory WHERE project_id = ? AND id = ?",
                                     (self.project_id, memory_id)).fetchone()
                    if not row:
                        raise ProbeError("memory_not_found")
                    before = dict(row)
                    if before["revision"] != arguments["expected_revision"]:
                        raise ProbeError("stale_revision")
                    revision = before["revision"] + 1
                after = {
                    "project_id": self.project_id, "id": memory_id, "revision": revision,
                    "content": arguments["content"],
                    "evidence_message_id": source_message_id,
                    "evidence_quote": arguments["evidence_quote"],
                }
                db.execute("INSERT OR REPLACE INTO memory VALUES (?, ?, ?, ?, ?, ?)",
                           tuple(after.values()))
                db.execute("INSERT INTO event VALUES (?, ?, ?, ?, ?, ?)",
                           (str(uuid.uuid4()), self.project_id, memory_id,
                            json.dumps(before, ensure_ascii=False),
                            json.dumps(after, ensure_ascii=False),
                            datetime.now(timezone.utc).isoformat()))
                receipt = {"status": "committed", "memory": after}
            receipt["operation_id"] = operation_id
            db.execute("INSERT INTO operation VALUES (?, ?, ?, ?)",
                       (self.project_id, operation_id, fingerprint,
                        json.dumps(receipt, ensure_ascii=False)))
            db.commit()
            return receipt
        except BaseException:
            db.rollback()
            raise

    def close(self):
        self.connection.close()
