# Event Log and Deterministic Replay Engine

Implement a reliable, append-only event log in Python. Your implementation must support ordered event recording, deterministic state reconstruction, and integrity validation.

## Required interface

Implement `eventlog.py` in the provided workspace. It must expose an `EventLog` class initialized with a path to a JSON Lines (`.jsonl`) log file.

The class must provide:

- `append(operation, key, value=None)`: append one event and return its record.
- `replay()`: reconstruct and return the current state as a dictionary.
- `verify()`: validate the entire log and return a dictionary containing at least `valid` and `events`.
- `snapshot(path)`: save a validated snapshot of the current state.
- `replay_from_snapshot(path)`: validate a snapshot and reconstruct the state using it and the subsequent log entries.

## Event semantics

Support these operations:

- `set`: assign the supplied JSON-compatible value to a key.
- `increment`: add a numeric value to the current numeric value for a key, treating a missing key as zero.
- `delete`: remove a key if present.

Reject unsupported operations, invalid keys, and invalid increment values with clear exceptions. Boolean values must not be treated as numbers for increment operations.

Each log record must contain a strictly increasing sequence number, operation, key, and the data required to apply that operation. Records must be serialized as JSON Lines, with one complete JSON object per line.

## Reliability and integrity

Use a deterministic serialization scheme and a cryptographic hash chain so that modifications to existing records can be detected. Each record must include the previous record's hash and its own hash. Define and consistently apply the hash calculation.

Appending must not silently accept a malformed existing log. Verification must detect malformed JSON, missing or invalid fields, sequence gaps, incorrect hashes, and broken hash links.

Repeated replays of the same valid log must produce the same state. A snapshot must contain sufficient information to validate its integrity and resume replay without applying events twice. Invalid snapshots must be rejected.

Document the public interface, record format, exceptions, and design decisions. Handle empty logs and missing keys consistently. Avoid silently repairing corrupted data.

## Constraints

Use only the Python standard library. Do not depend on network access, databases, or external services. Keep the implementation modular and readable. Do not hard-code expected test results or bypass integrity checks.

The implementation must work from the provided workspace and support paths supplied by the caller.
