import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from probe_core import ProbeError, ProbeStore, decode_proposal, strict_json
from run_probe import MATERIAL, MESSAGES, StreamReply


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.scratch = Path(__file__).resolve().parent / ".test-temp"
        self.scratch.mkdir(exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(dir=self.scratch)
        self.path = Path(self.temporary.name) / "probe.sqlite"
        self.store = ProbeStore(self.path, "english")
        self.store.seed(MATERIAL, MESSAGES)
        self.remember = {
            "content": "容易混淆 adapt 和 adopt",
            "evidence_message_id": "user-2",
            "evidence_quote": "我容易把 adapt 和 adopt 搞混",
        }

    def tearDown(self):
        self.store.close()
        assert Path(self.temporary.name).resolve().is_relative_to(self.scratch.resolve())
        self.temporary.cleanup()

    def execute(self, action, args, operation="remember-1", source="user-2"):
        return self.store.execute(action, args, operation, source_message_id=source,
                                  allowed_action=action)

    def correction(self, memory):
        return {"memory_id": memory["id"], "expected_revision": memory["revision"],
                "content": "容易混淆 affect 和 effect", "evidence_message_id": "user-3",
                "evidence_quote": "我其实容易混淆的是 affect 和 effect"}

    def test_read_returns_exact_fixture(self):
        receipt = self.execute("study_read_material", {"material_id": "sample-vocabulary-1"},
                               "read-1", "user-1")
        self.assertEqual(receipt["content"], MATERIAL["sample-vocabulary-1"])

    def test_save_correct_and_reopen(self):
        first = self.execute("study_remember", self.remember)
        corrected = self.execute("study_correct", self.correction(first["memory"]),
                                 "correct-1", "user-3")
        self.assertEqual(corrected["memory"]["revision"], 2)
        self.store.close()
        self.store = ProbeStore(self.path, "english")
        self.assertEqual(self.store.memories(), [corrected["memory"]])
        events = self.store.connection.execute("SELECT * FROM event ORDER BY rowid").fetchall()
        self.assertEqual(len(events), 2)
        self.assertEqual(json.loads(events[1]["before_json"]), first["memory"])

    def test_retry_returns_same_receipt_without_duplicate_event(self):
        first = self.execute("study_remember", self.remember)
        self.assertEqual(self.execute("study_remember", self.remember), first)
        self.assertEqual(self.store.connection.execute("SELECT COUNT(*) FROM event").fetchone()[0], 1)

    def test_same_operation_cannot_change_payload(self):
        self.execute("study_remember", self.remember)
        with self.assertRaisesRegex(ProbeError, "operation_id_reused"):
            self.execute("study_remember", dict(self.remember, content="另一条内容"))
        self.assertEqual(self.store.memories()[0]["content"], self.remember["content"])

    def test_replayed_correction_does_not_increment_revision(self):
        first = self.execute("study_remember", self.remember)
        args = self.correction(first["memory"])
        receipt = self.execute("study_correct", args, "correct-1", "user-3")
        self.assertEqual(self.execute("study_correct", args, "correct-1", "user-3"), receipt)
        self.assertEqual(self.store.memories()[0]["revision"], 2)

    def test_stale_update_is_rejected(self):
        first = self.execute("study_remember", self.remember)
        args = self.correction(first["memory"])
        self.execute("study_correct", args, "correct-1", "user-3")
        with self.assertRaisesRegex(ProbeError, "stale_revision"):
            self.execute("study_correct", args, "correct-2", "user-3")

    def test_other_project_cannot_read_or_correct_memory(self):
        first = self.execute("study_remember", self.remember)
        for project in ("history", "politics"):
            other = ProbeStore(self.path, project)
            try:
                other.seed({}, MESSAGES)
                self.assertEqual(other.memories(), [])
                with self.assertRaisesRegex(ProbeError, "memory_not_found"):
                    other.execute("study_correct", self.correction(first["memory"]), "other-1",
                                  source_message_id="user-3", allowed_action="study_correct")
                with self.assertRaisesRegex(ProbeError, "material_not_found"):
                    other.execute("study_read_material", {"material_id": "sample-vocabulary-1"},
                                  "other-2", source_message_id="user-1",
                                  allowed_action="study_read_material")
            finally:
                other.close()

    def test_model_cannot_set_project_or_instructions(self):
        for key in ("project_id", "instructions"):
            with self.assertRaisesRegex(ProbeError, "unexpected_arguments"):
                self.execute("study_remember", dict(self.remember, **{key: "override"}))
        self.assertEqual(self.store.memories(), [])

    def test_wrong_user_message_or_fabricated_quote_is_rejected(self):
        for patch, error in (({"evidence_message_id": "user-1"}, "wrong_evidence_message"),
                             ({"evidence_quote": "从未说过这句话"}, "evidence_not_in_user_message")):
            with self.assertRaisesRegex(ProbeError, error):
                self.execute("study_remember", dict(self.remember, **patch))
        self.assertEqual(self.store.memories(), [])

    def test_read_only_request_cannot_mutate(self):
        with self.assertRaisesRegex(ProbeError, "action_not_allowed_for_turn"):
            self.store.execute("study_remember", self.remember, "wrong-action",
                               source_message_id="user-2", allowed_action="study_read_material")

    def test_storage_failure_rolls_back_memory_and_receipt(self):
        self.store.connection.execute("""CREATE TRIGGER simulate_failure BEFORE INSERT ON event
            BEGIN SELECT RAISE(ABORT, 'simulated persistence failure'); END""")
        self.store.connection.commit()
        with self.assertRaises(sqlite3.DatabaseError):
            self.execute("study_remember", self.remember)
        self.assertEqual(self.store.memories(), [])
        self.assertEqual(self.store.connection.execute("SELECT COUNT(*) FROM operation").fetchone()[0], 0)


class ProtocolTests(unittest.TestCase):
    def test_duplicate_keys_and_invalid_numbers_rejected(self):
        for text in ('{"action":"read","action":"write"}', '{"x":NaN}', '```json\n{}\n```'):
            with self.assertRaises(ProbeError):
                strict_json(text)

    def test_stream_joins_fragmented_tool_arguments(self):
        stream = StreamReply()
        stream.consume(json.dumps({"choices": [{"index": 0, "delta": {"tool_calls": [{
            "index": 0, "id": "call_read", "type": "function", "function": {
                "name": "study_read_material", "arguments": '{"material_id":'}}]}}]}))
        stream.consume(json.dumps({"choices": [{"index": 0, "delta": {"tool_calls": [{
            "index": 0, "function": {"arguments": '"sample-vocabulary-1"}'}}]},
            "finish_reason": "tool_calls"}]}))
        stream.consume("[DONE]")
        self.assertEqual(decode_proposal(stream.result(), "native"),
                         ("study_read_material", {"material_id": "sample-vocabulary-1"}))

    def test_truncated_stream_cannot_execute(self):
        stream = StreamReply()
        stream.consume(json.dumps({"choices": [{"delta": {"content":
            '{"action":"study_read_material","arguments":{"material_id":"sample-vocabulary-1"}}'},
            "finish_reason": "stop"}]}))
        with self.assertRaisesRegex(ProbeError, "incomplete_stream"):
            decode_proposal(stream.result(), "structured")

    def test_plain_saved_claim_is_not_an_operation(self):
        reply = {"complete": True, "content": "已经帮你记住了", "tool_calls": [], "finish_reason": "stop"}
        with self.assertRaises(ProbeError):
            decode_proposal(reply, "structured")
        with self.assertRaises(ProbeError):
            decode_proposal(reply, "native")

    def test_unknown_action_and_boolean_revision_rejected(self):
        for action, args in (("delete_project", {}), ("study_correct", {
            "memory_id": "x", "expected_revision": True, "content": "x",
            "evidence_message_id": "user-3", "evidence_quote": "x"})):
            reply = {"complete": True, "content": json.dumps({"action": action, "arguments": args}),
                     "tool_calls": [], "finish_reason": "stop"}
            with self.assertRaises(ProbeError):
                decode_proposal(reply, "structured")


if __name__ == "__main__":
    unittest.main(verbosity=2)
