#!/bin/sh
set -eu

cat > /app/eventlog.py <<'PY'
"""Append-only JSONL event log with hash-chain verification and snapshots."""

import hashlib
import json
import math
import os
from pathlib import Path


GENESIS_HASH = "0" * 64
SNAPSHOT_VERSION = 1


def _canonical(value):
    """Serialize JSON deterministically, rejecting non-standard numbers."""
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
        allow_nan=False,
    )


def _digest(value):
    return hashlib.sha256(_canonical(value).encode("utf-8")).hexdigest()


def _is_number(value):
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and (not isinstance(value, float) or math.isfinite(value))
    )


def _validate_key(key):
    if not isinstance(key, str) or not key.strip():
        raise ValueError("key must be a non-empty string")


def _apply(state, record):
    operation = record["operation"]
    key = record["key"]

    if operation == "set":
        state[key] = record["value"]
    elif operation == "increment":
        amount = record["value"]
        current = state.get(key, 0)
        if not _is_number(amount):
            raise ValueError("increment value must be a finite number")
        if not _is_number(current):
            raise ValueError("cannot increment a non-numeric current value")
        result = current + amount
        if not _is_number(result):
            raise ValueError("increment result must be finite")
        state[key] = result
    elif operation == "delete":
        state.pop(key, None)
    else:
        raise ValueError(f"unsupported operation: {operation!r}")


class EventLog:
    """Append-only event log backed by a JSON Lines file."""

    def __init__(self, path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            self.path.touch()

    @staticmethod
    def _record_hash(record):
        payload = {key: value for key, value in record.items() if key != "hash"}
        return _digest(payload)

    def _read_validated(self):
        records = []
        prev_hash = GENESIS_HASH

        try:
            with self.path.open("r", encoding="utf-8") as stream:
                for line_number, line in enumerate(stream, start=1):
                    if not line.strip():
                        raise ValueError(
                            f"blank line in log at line {line_number}"
                        )

                    try:
                        record = json.loads(line)
                    except (json.JSONDecodeError, TypeError) as exc:
                        raise ValueError(
                            f"malformed JSON at line {line_number}"
                        ) from exc

                    if not isinstance(record, dict):
                        raise ValueError(
                            f"record at line {line_number} must be an object"
                        )

                    required = {
                        "seq", "operation", "key", "value",
                        "prev_hash", "hash",
                    }
                    if set(record) != required:
                        raise ValueError(
                            f"invalid fields at line {line_number}"
                        )

                    seq = record["seq"]
                    if (
                        not isinstance(seq, int)
                        or isinstance(seq, bool)
                        or seq != len(records) + 1
                    ):
                        raise ValueError(
                            f"invalid sequence at line {line_number}"
                        )

                    if record["operation"] not in ("set", "increment", "delete"):
                        raise ValueError(
                            f"unsupported operation at line {line_number}"
                        )

                    try:
                        _validate_key(record["key"])
                        _canonical(record["value"])
                    except (TypeError, ValueError) as exc:
                        raise ValueError(
                            f"invalid record data at line {line_number}"
                        ) from exc

                    if record["prev_hash"] != prev_hash:
                        raise ValueError(
                            f"broken hash link at line {line_number}"
                        )

                    if not isinstance(record["hash"], str):
                        raise ValueError(
                            f"invalid hash at line {line_number}"
                        )

                    expected_hash = self._record_hash(record)
                    if record["hash"] != expected_hash:
                        raise ValueError(
                            f"hash mismatch at line {line_number}"
                        )

                    # Validate event semantics before accepting the record.
                    trial_state = self._state_for_records(records)
                    _apply(trial_state, record)

                    records.append(record)
                    prev_hash = record["hash"]

        except OSError as exc:
            raise ValueError(f"unable to read log: {exc}") from exc

        return records

    @staticmethod
    def _state_for_records(records):
        state = {}
        for record in records:
            _apply(state, record)
        return state

    def append(self, operation, key, value=None):
        if operation not in ("set", "increment", "delete"):
            raise ValueError(f"unsupported operation: {operation!r}")
        _validate_key(key)

        if operation == "increment" and not _is_number(value):
            raise ValueError("increment value must be a finite number")

        # Validate JSON compatibility before touching the file.
        try:
            _canonical(value)
        except (TypeError, ValueError) as exc:
            raise ValueError("value must be JSON-compatible") from exc

        records = self._read_validated()
        state = self._state_for_records(records)

        candidate = {
            "seq": len(records) + 1,
            "operation": operation,
            "key": key,
            "value": value,
        }

        try:
            _apply(state, candidate)
        except (TypeError, ValueError, OverflowError) as exc:
            raise ValueError(str(exc)) from exc

        candidate["prev_hash"] = (
            records[-1]["hash"] if records else GENESIS_HASH
        )
        candidate["hash"] = self._record_hash(candidate)

        serialized = _canonical(candidate) + "\n"
        with self.path.open("a", encoding="utf-8", newline="\n") as stream:
            stream.write(serialized)
            stream.flush()
            os.fsync(stream.fileno())

        return candidate

    def replay(self):
        records = self._read_validated()
        return self._state_for_records(records)

    def verify(self):
        try:
            records = self._read_validated()
            return {
                "valid": True,
                "events": len(records),
                "last_hash": records[-1]["hash"] if records else GENESIS_HASH,
            }
        except (ValueError, OSError, TypeError, KeyError, OverflowError):
            return {"valid": False, "events": 0}

    def snapshot(self, path):
        records = self._read_validated()
        state = self._state_for_records(records)

        payload = {
            "version": SNAPSHOT_VERSION,
            "seq": len(records),
            "last_hash": records[-1]["hash"] if records else GENESIS_HASH,
            "state": state,
        }
        snapshot = dict(payload)
        snapshot["snapshot_hash"] = _digest(payload)

        destination = Path(path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(destination.name + ".tmp")
        try:
            with temporary.open(
                "w", encoding="utf-8", newline="\n"
            ) as stream:
                stream.write(_canonical(snapshot) + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            temporary.replace(destination)
        finally:
            if temporary.exists():
                temporary.unlink()

        return snapshot

    def replay_from_snapshot(self, path):
        try:
            with Path(path).open("r", encoding="utf-8") as stream:
                snapshot = json.load(stream)
        except (OSError, json.JSONDecodeError, TypeError) as exc:
            raise ValueError("invalid snapshot file") from exc

        if not isinstance(snapshot, dict):
            raise ValueError("snapshot must be a JSON object")

        required = {
            "version", "seq", "last_hash", "state", "snapshot_hash"
        }
        if set(snapshot) != required:
            raise ValueError("invalid snapshot fields")

        payload = {
            key: value for key, value in snapshot.items()
            if key != "snapshot_hash"
        }

        if snapshot["version"] != SNAPSHOT_VERSION:
            raise ValueError("unsupported snapshot version")

        seq = snapshot["seq"]
        if (
            not isinstance(seq, int)
            or isinstance(seq, bool)
            or seq < 0
        ):
            raise ValueError("invalid snapshot sequence")

        if not isinstance(snapshot["state"], dict):
            raise ValueError("snapshot state must be an object")

        if not isinstance(snapshot["last_hash"], str):
            raise ValueError("invalid snapshot hash anchor")

        if snapshot["snapshot_hash"] != _digest(payload):
            raise ValueError("snapshot integrity check failed")

        try:
            _canonical(snapshot["state"])
        except (TypeError, ValueError) as exc:
            raise ValueError("snapshot state is not JSON-compatible") from exc

        records = self._read_validated()
        if seq > len(records):
            raise ValueError("snapshot is ahead of the event log")

        expected_anchor = records[seq - 1]["hash"] if seq else GENESIS_HASH
        if snapshot["last_hash"] != expected_anchor:
            raise ValueError("snapshot does not match this event log")

        state = dict(snapshot["state"])
        for record in records[seq:]:
            _apply(state, record)

        return state
PY