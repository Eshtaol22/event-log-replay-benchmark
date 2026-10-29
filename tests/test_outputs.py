"""Behavioral tests for the EventLog implementation."""

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path

MODULE = Path("/app/eventlog.py")
if not MODULE.exists():
    MODULE = Path(os.environ.get("TASK_WORKSPACE", "/app")) / "eventlog.py"

if not MODULE.exists():
    raise RuntimeError("eventlog.py was not found in the task workspace")

spec = importlib.util.spec_from_file_location("eventlog", MODULE)
eventlog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(eventlog)
EventLog = eventlog.EventLog


class EventLogTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.log_path = Path(self.tmp.name) / "events.jsonl"
        self.log = EventLog(self.log_path)

    def test_empty_log_replays_to_empty_state(self):
        self.assertEqual(self.log.replay(), {})
        result = self.log.verify()
        self.assertTrue(result["valid"])
        self.assertEqual(result["events"], 0)

    def test_set_increment_delete_and_replay(self):
        self.log.append("set", "visits", 4)
        self.log.append("increment", "visits", 3)
        self.log.append("set", "name", "Ada")
        self.log.append("delete", "name")
        self.assertEqual(self.log.replay(), {"visits": 7})

    def test_append_returns_monotonic_sequence(self):
        first = self.log.append("set", "a", 1)
        second = self.log.append("set", "b", 2)
        self.assertLess(first["seq"], second["seq"])
        self.assertEqual(second["seq"], first["seq"] + 1)

    def test_hash_chain_fields_exist(self):
        record = self.log.append("set", "a", {"x": 1})
        self.assertIn("hash", record)
        self.assertIn("prev_hash", record)
        self.assertTrue(self.log.verify()["valid"])

    def test_reopening_log_continues_sequence(self):
        self.log.append("set", "a", 1)
        reopened = EventLog(self.log_path)
        record = reopened.append("set", "b", 2)
        self.assertEqual(record["seq"], 2)
        self.assertEqual(reopened.replay(), {"a": 1, "b": 2})

    def test_unknown_operation_is_rejected(self):
        with self.assertRaises((ValueError, TypeError)):
            self.log.append("multiply", "a", 2)

    def test_invalid_increment_is_rejected(self):
        with self.assertRaises((ValueError, TypeError)):
            self.log.append("increment", "a", True)

    def test_malformed_existing_log_is_not_silently_accepted(self):
        self.log.append("set", "a", 1)
        with self.log_path.open("a", encoding="utf-8") as f:
            f.write("{not-json}\n")
        result = self.log.verify()
        self.assertFalse(result["valid"])
        with self.assertRaises((ValueError, TypeError)):
            self.log.append("set", "b", 2)

    def test_modified_record_is_detected(self):
        self.log.append("set", "balance", 10)
        self.log.append("increment", "balance", 5)
        records = [json.loads(line) for line in self.log_path.read_text(encoding="utf-8").splitlines()]
        records[0]["value"] = 999
        self.log_path.write_text(
            "".join(json.dumps(r) + "\n" for r in records),
            encoding="utf-8",
        )
        self.assertFalse(self.log.verify()["valid"])

    def test_snapshot_round_trip(self):
        self.log.append("set", "score", 10)
        self.log.append("increment", "score", 2)
        snapshot_path = Path(self.tmp.name) / "state.snapshot.json"
        self.log.snapshot(snapshot_path)
        self.log.append("increment", "score", 5)
        self.assertEqual(self.log.replay_from_snapshot(snapshot_path), {"score": 17})

    def test_invalid_snapshot_is_rejected(self):
        self.log.append("set", "score", 10)
        snapshot_path = Path(self.tmp.name) / "bad.snapshot.json"
        snapshot_path.write_text('{"state": {}, "seq": 1, "hash": "wrong"}', encoding="utf-8")
        with self.assertRaises((ValueError, TypeError)):
            self.log.replay_from_snapshot(snapshot_path)


if __name__ == "__main__":
    unittest.main()
