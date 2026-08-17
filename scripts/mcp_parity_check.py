#!/usr/bin/env python3
"""Assert every Priority MCP server implementation agrees.

Priority ships three implementations of the same MCP server:

  swift   the one embedded in the app        (`Priority --mcp-server`)
  python  the bundled fallback script        (`scripts/priority_mcp_server.py`)
  rust    the command-line tool              (`cli/`, `priority --mcp-server`)

A client may be pointed at any of them, so a tool that exists in one and not
another — or answers differently — is a bug the user experiences as the
assistant "forgetting" a capability depending on how it was wired up. The Rust
one carries the extra weight of being what the CLI itself runs on, so a
divergence there is also a divergence between the terminal and the assistant.

None of them can import the others (one is Swift compiled into the app, one is a
dependency-free script, one is a separate cargo crate), so parity is asserted
from the outside: drive all of them over stdio with identical requests and diff
the results against the Swift implementation, which is the tested original.

All nineteen tools are covered. The local-state tools are driven against a
temporary fixture directory, one per implementation; the Checkvist tools against
a stub API that records what was asked of it, so their *requests* are compared
and not just their answers. Nothing here reads your real history, touches your
lists, or needs credentials.

    python3 scripts/mcp_parity_check.py

Exits non-zero on any divergence. A missing Rust build is reported and skipped
rather than failing, so the check still runs on a machine without a toolchain.
"""

from __future__ import annotations

import contextlib
import http.server
import json
import os
import plistlib
import re
import select
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
from datetime import datetime, timedelta, timezone
from typing import Any, Optional


REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PYTHON_SERVER = os.path.join(REPO_ROOT, "scripts", "priority_mcp_server.py")
RUST_BUILD_HINT = "cargo build --release --manifest-path cli/Cargo.toml"

# A fixed log exercising the cases where the two aggregators could disagree:
# a completion cancelled by a later reopen, a completion that survives, a daily
# ticked then un-ticked, a daily that stays ticked, focus time, a deferral, and
# a plan snapshot with an unfinished task left over.
FIXTURE_EVENTS = [
    {"kind": "planSnapshot", "at": "2026-08-14T09:00:00Z", "taskId": 0, "title": "",
     "plannedTaskIds": [11, 12, 13, 14]},
    {"kind": "completed", "at": "2026-08-14T10:00:00Z", "taskId": 11, "title": "Survives"},
    {"kind": "completed", "at": "2026-08-14T10:05:00Z", "taskId": 12, "title": "Gets reopened"},
    {"kind": "reopened", "at": "2026-08-14T11:00:00Z", "taskId": 12, "title": "Gets reopened"},
    {"kind": "deferred", "at": "2026-08-14T11:30:00Z", "taskId": 13, "title": "Pushed"},
    {"kind": "focusSessionEnded", "at": "2026-08-14T12:00:00Z", "taskId": 11,
     "title": "Survives", "durationSeconds": 1500},
    {"kind": "invalidated", "at": "2026-08-14T12:30:00Z", "taskId": 15, "title": "Won't do"},
    {"kind": "dailyCompleted", "at": "2026-08-14T13:00:00Z", "taskId": 0, "title": "",
     "dailyId": "daily-a"},
    {"kind": "dailyCompleted", "at": "2026-08-14T13:10:00Z", "taskId": 0, "title": "",
     "dailyId": "daily-b"},
    {"kind": "dailyUncompleted", "at": "2026-08-14T14:00:00Z", "taskId": 0, "title": "",
     "dailyId": "daily-b"},
]

FIXTURE_DAILIES = {
    "version": 1,
    "dailies": [
        {"id": "daily-a", "title": "Every day habit", "activeWeekdays": [1, 2, 3, 4, 5, 6, 7],
         "sortIndex": 0, "createdAt": "2026-08-01T00:00:00Z"},
        {"id": "daily-b", "title": "Weekday habit", "activeWeekdays": [2, 3, 4, 5, 6],
         "sortIndex": 1, "createdAt": "2026-08-01T00:00:00Z"},
        {"id": "daily-c", "title": "Archived habit", "activeWeekdays": [1, 2, 3, 4, 5, 6, 7],
         "sortIndex": 2, "createdAt": "2026-08-01T00:00:00Z",
         "archivedAt": "2026-08-10T00:00:00Z"},
        # A rotating schedule, anchored in the past on a fixed date so its
        # due-ness is a pure function of today rather than of when this ran.
        # Every third day from a Saturday: no weekday set can express it, so all
        # three have to be doing the same day arithmetic to agree.
        {"id": "daily-d", "title": "Every third day habit",
         "activeWeekdays": [1, 2, 3, 4, 5, 6, 7], "intervalDays": 3,
         "intervalAnchor": "2026-08-01T09:00:00Z",
         "sortIndex": 3, "createdAt": "2026-08-01T00:00:00Z"},
        # Left alone by the calls below, so `daily_log_fetch` compares a cycle
        # that alternates across the three days it reports — the read side of
        # the same arithmetic, after daily-d has been rescheduled off it.
        {"id": "daily-e", "title": "Every other day habit",
         "activeWeekdays": [1, 2, 3, 4, 5, 6, 7], "intervalDays": 2,
         "intervalAnchor": "2026-08-01T09:00:00Z",
         "sortIndex": 4, "createdAt": "2026-08-01T00:00:00Z"},
    ],
}

# The local-state tools: the ones whose *logic* is duplicated, so a divergence
# here is a genuine reimplementation bug rather than a different HTTP call. The
# Checkvist tools are compared separately, in CHECKVIST_CALLS below.
#
# Ordered: the writes run before the reads that observe them, so `dailies_list`
# has to reflect the added and ticked daily identically everywhere. Each server
# gets its own copy of the fixture, so they never write to the same file.
COMPARED_CALLS = [
    ("daily_add", {"title": "Added via MCP", "active_weekdays": [2, 4, 6]}),
    ("daily_add", {"title": "Cycling via MCP", "interval_days": 4}),
    ("daily_update", {"daily_id": "daily-b", "title": "Renamed via MCP"}),
    # Onto a cycle and back off it: the weekday set has to survive the round
    # trip, and the interval has to be gone rather than merely overridden.
    ("daily_update", {"daily_id": "daily-d", "interval_days": 5}),
    ("daily_update", {"daily_id": "daily-d", "active_weekdays": [2, 3, 4, 5, 6]}),
    ("daily_update", {"daily_id": "daily-a", "archived": True}),
    ("daily_tick", {"daily_id": "daily-b", "done": True}),
    ("daily_tick", {"daily_id": "daily-b", "done": True}),  # idempotent: changed=false
    ("dailies_list", {}),
    ("daily_log_fetch", {"days": 3}),
    ("task_metadata", {"list_id": "999"}),
]

# The Checkvist tools, driven against the stub API below rather than the real
# one. These are thin HTTP wrappers, so what has to agree is the *request* each
# one makes — a wrong verb, a missing `parse=true`, or a `parent_id` omitted
# instead of sent as null is invisible in the response but changes what Checkvist
# does. Both the traffic and the tool results are compared.
CHECKVIST_CALLS = [
    ("task_lists", {}),
    ("task_fetch", {}),
    ("task_fetch", {"include_closed": True, "with_notes": False}),
    ("task_search", {"query": "report", "tag": "work", "due_before": "2026-09-01", "limit": 2}),
    ("task_add", {"content": "Added by parity"}),
    ("task_add", {"content": "Nested", "location": "specific", "parent_task_id": 11,
                  "position": 2, "due": "tomorrow"}),
    ("task_update", {"task_id": 11, "content": "Renamed", "due": "2026-09-01"}),
    ("task_move", {"task_id": 11, "position": 3}),
    ("task_reparent", {"task_id": 12, "parent_task_id": 11}),
    ("task_reparent", {"task_id": 12}),  # to the root: parent_id must be sent as null
    ("task_note_add", {"task_id": 11, "note": "A note"}),
    ("task_complete", {"task_id": 11}),
    ("task_reopen", {"task_id": 11}),
    ("task_invalidate", {"task_id": 11}),
    ("task_delete", {"task_id": 11}),
    ("list_create", {"name": "New list"}),
]

# Deliberately includes a closed task, a child, and a tag returned as a dict —
# the three shapes where the tree-building and filtering could disagree.
STUB_TASKS = [
    {"id": 11, "parent_id": 0, "position": 1, "status": 0, "content": "Write the report #work",
     "due": "2026-08-20", "tags": {"work": "1"}},
    {"id": 12, "parent_id": 11, "position": 1, "status": 0, "content": "Sub task",
     "due": None, "tags": {}},
    {"id": 13, "parent_id": 0, "position": 2, "status": 1, "content": "Closed thing",
     "due": None, "tags": {}},
]

UUID_PATTERN = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
TIMESTAMP_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def normalize(value: Any, run_start: str) -> Any:
    """Blank out the two genuinely unpredictable fields, and nothing else.

    - `daily_add` mints a fresh UUID, which two runs can never agree on. The
      fixture's own ids are deliberately *not* UUID-shaped (`daily-a`), so every
      id that should match stays under comparison — including a mismatch in
      which daily got ticked.
    - Writes stamp "now", and the two servers run seconds apart. Timestamps at
      or after `run_start` collapse to `<now>`; the fixture's own timestamps are
      historical, so they stay compared exactly. ISO-8601 UTC sorts
      lexicographically, so a string compare is a chronological one.

    Deliberately narrow: the *format* of these fields is the cross-process
    contract, and blanket-scrubbing timestamps would have hidden the
    fractional-seconds bug this check exists to catch.
    """
    if isinstance(value, dict):
        return {key: normalize(item, run_start) for key, item in value.items()}
    if isinstance(value, list):
        return [normalize(item, run_start) for item in value]
    if isinstance(value, str):
        if UUID_PATTERN.match(value):
            return "<uuid>"
        if TIMESTAMP_PATTERN.match(value) and value >= run_start:
            return "<now>"
    return value


def find_swift_binary() -> Optional[str]:
    """The Debug app binary from DerivedData, if it has been built."""
    candidates = subprocess.run(
        ["find", os.path.expanduser("~/Library/Developer/Xcode/DerivedData"),
         "-name", "Priority", "-type", "f", "-perm", "+111", "-path", "*Debug*"],
        capture_output=True, text=True, check=False,
    ).stdout.split("\n")
    for path in candidates:
        if path.strip() and path.strip().endswith("Contents/MacOS/Priority"):
            return path.strip()
    return None


def find_rust_binary() -> Optional[str]:
    """The CLI binary, release preferred over debug."""
    for profile in ("release", "debug"):
        path = os.path.join(REPO_ROOT, "cli", "target", profile, "priority")
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


class StubCheckvist(http.server.BaseHTTPRequestHandler):
    """A stand-in Checkvist that records what was asked of it.

    Lets the API-backed tools be compared without credentials and without
    touching anyone's real lists. The responses are only plausible enough for
    each tool to parse them; the point of the exercise is the recorded requests.
    """

    recorded: list[dict[str, Any]] = []

    def log_message(self, *args: Any) -> None:  # noqa: D102 - silence the default access log
        pass

    def _handle(self, method: str) -> None:
        parsed = urllib.parse.urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = raw.decode("utf-8", "replace")

        StubCheckvist.recorded.append({
            "method": method,
            "path": parsed.path,
            "query": sorted(urllib.parse.parse_qsl(parsed.query)),
            "body": body,
            "user_agent": self.headers.get("User-Agent"),
            # Not the token itself: it comes from this stub, so comparing it
            # would only assert that each server echoed what it was handed.
            "authenticated": self.headers.get("X-Client-Token") is not None,
        })

        payload = self._payload_for(method, parsed.path)
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    @staticmethod
    def _payload_for(method: str, path: str) -> Any:
        if path == "/auth/login.json":
            return {"token": "stub-token"}
        if path == "/checklists.json":
            if method == "GET":
                return [{"id": 999, "name": "Work", "archived": False},
                        {"id": 1000, "name": "Archived", "archived": True}]
            return {"id": 1001, "name": "New list"}
        if path.endswith("/tasks.json"):
            if method == "GET":
                return STUB_TASKS
            return {"id": 50, "content": "Created", "parent_id": 0, "position": 1, "status": 0}
        if path.endswith("/comments.json"):
            return {"id": 7, "comment": "A note"}
        if path.endswith(("/close.json", "/reopen.json", "/invalidate.json")):
            return {"id": 11, "status": 1}
        return {"id": 11, "content": "Updated", "parent_id": 0, "position": 1, "status": 0}

    do_GET = lambda self: self._handle("GET")        # noqa: E731
    do_POST = lambda self: self._handle("POST")      # noqa: E731
    do_PUT = lambda self: self._handle("PUT")        # noqa: E731
    do_DELETE = lambda self: self._handle("DELETE")  # noqa: E731


def drive(command: list[str], env: dict[str, str], calls: list[Any] = None) -> dict[int, Any]:
    """Send initialize + one call per compared tool; collect results by id."""
    calls = COMPARED_CALLS if calls is None else calls
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize",
         "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                    "clientInfo": {"name": "parity", "version": "1"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    ]
    for index, (name, arguments) in enumerate(calls):
        requests.append({
            "jsonrpc": "2.0", "id": 100 + index, "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        })

    # Replies are collected with stdin still open, the way a real client works,
    # and the pipe is only closed once they have all arrived. Feeding the whole
    # script in and reading what falls out at exit would pass against a server
    # that answers nothing until EOF — which is a server no MCP client can talk
    # to, and exactly the hang this check exists to notice.
    expected = {request["id"] for request in requests}
    results: dict[int, Any] = {}
    pending = b""

    process = subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, env=env,
    )
    try:
        for request in requests:
            process.stdin.write(json.dumps(request).encode() + b"\n")
        process.stdin.flush()

        deadline = time.monotonic() + 120
        while expected:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            if not select.select([process.stdout], [], [], remaining)[0]:
                break
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break  # The server closed stdout; nothing more is coming.
            pending += chunk

            while b"\n" in pending:
                line, _, pending = pending.partition(b"\n")
                try:
                    message = json.loads(line.strip())
                except ValueError:
                    continue
                if isinstance(message, dict) and "id" in message:
                    results[message["id"]] = message
                    expected.discard(message["id"])
    finally:
        with contextlib.suppress(OSError):
            process.stdin.close()
        with contextlib.suppress(subprocess.TimeoutExpired):
            process.wait(timeout=10)
        if process.poll() is None:
            process.kill()
            process.wait()

    return results


def payload_of(message: Any) -> Any:
    """The JSON body of a tool result, parsed.

    Compared as data rather than text because the two servers pretty-print
    differently (Swift's `JSONSerialization` puts a space before the colon), and
    that difference is cosmetic.
    """
    try:
        text = message["result"]["content"][0]["text"]
    except (KeyError, IndexError, TypeError):
        return {"__unparsed__": message}
    _, _, body = text.partition("\n\n")
    try:
        return json.loads(body)
    except ValueError:
        return {"__unparsed__": body}


def write_fixture(directory: str) -> str:
    """Lays down a fresh copy of the fixture and returns the prefs path."""
    with open(os.path.join(directory, "daylog.jsonl"), "w", encoding="utf-8") as handle:
        for event in FIXTURE_EVENTS:
            handle.write(json.dumps(event) + "\n")
    with open(os.path.join(directory, "dailies.json"), "w", encoding="utf-8") as handle:
        json.dump(FIXTURE_DAILIES, handle)

    prefs_path = os.path.join(directory, "prefs.plist")
    with open(prefs_path, "wb") as handle:
        plistlib.dump({
            "dailyLogRolloverHour": 4,
            "recurrenceRulesByTaskId": {"11": "every day"},
            "taskStartDatesByTaskId": {"12": "2026-08-20"},
            # Encoded differently on purpose, mirroring the app: the scoped
            # store is a JSON blob, the absolute one a plain plist dict.
            # Getting this wrong is what the first run of this check caught.
            "priorityTaskIdsByParentIdByListId":
                json.dumps({"999": {"0": [11, 12], "11": [13]}}).encode("utf-8"),
            "absolutePriorityTaskIdsByListId": {"999": [12, 11]},
            # A `Data` blob again, and per-list like the priority queues.
            "eisenhowerLevelsByTaskIdByListId": json.dumps(
                {"999": {"11": {"urgency": 8.0, "importance": 3.5},
                         "12": {"urgency": 0.0, "importance": 9.0}}}).encode("utf-8"),
            # A plain string, in Swift's synthesised enum Codable shape. The
            # Backlog column deliberately still says catchAll, to exercise the
            # migration all three have to apply.
            "kanbanColumns": json.dumps([
                {"id": "00000000-0000-0000-0000-000000000001", "name": "Today",
                 "conditions": [{"dueBucket": {"_0": 1}}, {"dueBucket": {"_0": 2}}],
                 "sortOrder": "priorityThenDueAscending"},
                {"id": "00000000-0000-0000-0000-000000000002", "name": "Waiting On",
                 "conditions": [{"tag": {"_0": "waiting"}}], "sortOrder": "position"},
                {"id": "00000000-0000-0000-0000-000000000003", "name": "Backlog",
                 "conditions": [{"catchAll": {}}], "sortOrder": "alphabetical"},
            ]),
        }, handle)
    return prefs_path


def read_resulting_files(directory: str) -> dict[str, Any]:
    """The on-disk state after the writes, so the *files* are compared and not
    just the tool responses. A server could answer correctly and still persist
    a subtly different shape that the app then has to read."""
    result: dict[str, Any] = {}
    try:
        with open(os.path.join(directory, "dailies.json"), "r", encoding="utf-8") as handle:
            result["dailies.json"] = json.load(handle)
    except (OSError, ValueError) as err:
        result["dailies.json"] = f"<unreadable: {err}>"

    events = []
    try:
        with open(os.path.join(directory, "daylog.jsonl"), "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    events.append(json.loads(line))
    except (OSError, ValueError) as err:
        events = [f"<unreadable: {err}>"]
    result["daylog.jsonl"] = events
    return result


def tool_names(results: dict[int, Any]) -> list[str]:
    return sorted(t["name"] for t in results.get(2, {}).get("result", {}).get("tools", []))


def main() -> int:
    swift_binary = find_swift_binary()
    if not swift_binary:
        print("No Debug build found. Build the app first:", file=sys.stderr)
        print("  xcodebuild -project 'Priority.xcodeproj' -scheme 'Priority' "
              "-configuration Debug -destination 'platform=macOS' build", file=sys.stderr)
        return 2

    # Swift first: it is the reference every other implementation is diffed
    # against, because its logic is the one `corelogic-tests/` covers directly.
    implementations = [
        ("swift", [swift_binary, "--mcp-server"]),
        ("python", [sys.executable, PYTHON_SERVER]),
    ]

    rust_binary = find_rust_binary()
    if rust_binary:
        implementations.append(("rust", [rust_binary, "--mcp-server"]))
    else:
        # Reported rather than silently dropped: a check that quietly compares
        # fewer things than you think reads as a pass it hasn't earned.
        print(f"SKIPPING rust: no CLI binary built. Build it with\n  {RUST_BUILD_HINT}\n")

    # A second of slack: the servers stamp "now" a moment after this.
    run_start = (datetime.now(timezone.utc) - timedelta(seconds=1)).strftime("%Y-%m-%dT%H:%M:%SZ")

    # The Rust CLI also reads its own config file (`cli/src/config.rs`), which
    # would otherwise make this check depend on whatever the developer running
    # it happens to have signed in as. Pointed at a path inside a temporary
    # directory, so it reliably finds nothing. The environment wins over that
    # file anyway, and every credential below is set in the environment — this
    # is belt and braces for the settings that aren't.
    isolation = tempfile.mkdtemp(prefix="priority-parity-")
    absent_config = os.path.join(isolation, "absent.json")

    results: dict[str, dict[int, Any]] = {}
    files: dict[str, dict[str, Any]] = {}

    with contextlib.ExitStack() as stack:
        for name, command in implementations:
            # A directory each: the compared calls *write*, so a shared fixture
            # would have one server reading another's mutations.
            directory = stack.enter_context(tempfile.TemporaryDirectory())
            prefs = write_fixture(directory)

            env = dict(os.environ)
            env["CHECKVIST_LIST_ID"] = "999"
            env["PRIORITY_MCP_STORE_DIR"] = directory
            env["PRIORITY_MCP_PREFS_PATH"] = prefs
            env["PRIORITY_CONFIG_PATH"] = absent_config

            results[name] = drive(command, env)
            files[name] = read_resulting_files(directory)

    failures: list[str] = []
    reference, *others = [name for name, _ in implementations]

    def compare(label: str, expected: Any, subject: str, actual: Any, width: int) -> bool:
        if expected == actual:
            return True
        failures.append(
            f"{label} differs between {reference} and {subject}\n"
            f"  {reference}: {json.dumps(expected, sort_keys=True)[:width]}\n"
            f"  {subject}: {json.dumps(actual, sort_keys=True)[:width]}"
        )
        return False

    reference_tools = tool_names(results[reference])
    for name in others:
        names = tool_names(results[name])
        if names == reference_tools:
            print(f"tools/list: {len(names)} tools, {name} matches {reference}")
            continue
        failures.append(
            f"tool lists differ\n"
            f"  only in {reference}: {sorted(set(reference_tools) - set(names))}\n"
            f"  only in {name}: {sorted(set(names) - set(reference_tools))}"
        )

    for index, (tool, arguments) in enumerate(COMPARED_CALLS):
        label = f"{tool}({json.dumps(arguments, sort_keys=True)})" if arguments else tool
        expected = normalize(payload_of(results[reference].get(100 + index)), run_start)
        agreed = [
            name
            for name in others
            if compare(
                label, expected, name,
                normalize(payload_of(results[name].get(100 + index)), run_start), 400,
            )
        ]
        if len(agreed) == len(others):
            print(f"{label}: identical across {len(implementations)}")

    for filename in ("dailies.json", "daylog.jsonl"):
        expected = normalize(files[reference].get(filename), run_start)
        agreed = [
            name
            for name in others
            if compare(
                f"{filename} on disk", expected, name,
                normalize(files[name].get(filename), run_start), 600,
            )
        ]
        if len(agreed) == len(others):
            print(f"{filename} on disk: identical across {len(implementations)}")

    # -- the Checkvist tools, against a stub API -----------------------------
    print()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), StubCheckvist)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    traffic: dict[str, list[Any]] = {}
    api_results: dict[str, dict[int, Any]] = {}
    try:
        for name, command in implementations:
            StubCheckvist.recorded = []
            env = dict(os.environ)
            env.update({
                "CHECKVIST_BASE_URL": f"http://127.0.0.1:{server.server_address[1]}",
                "CHECKVIST_USERNAME": "you@example.com",
                "CHECKVIST_REMOTE_KEY": "stub-key",
                "CHECKVIST_LIST_ID": "999",
                "PRIORITY_CONFIG_PATH": absent_config,
            })
            api_results[name] = drive(command, env, CHECKVIST_CALLS)
            traffic[name] = StubCheckvist.recorded
    finally:
        server.shutdown()
        server.server_close()
        shutil.rmtree(isolation, ignore_errors=True)

    for name in others:
        expected_traffic, actual_traffic = traffic[reference], traffic[name]
        if expected_traffic == actual_traffic:
            print(
                f"Checkvist HTTP traffic: {len(actual_traffic)} requests, "
                f"{name} matches {reference}"
            )
            continue
        if len(expected_traffic) != len(actual_traffic):
            failures.append(
                f"Checkvist request count differs: {reference}={len(expected_traffic)} "
                f"{name}={len(actual_traffic)}"
            )
        for index, (expected, actual) in enumerate(zip(expected_traffic, actual_traffic)):
            if expected != actual:
                failures.append(
                    f"Checkvist request {index} differs between {reference} and {name}\n"
                    f"  {reference}: {json.dumps(expected, sort_keys=True)}\n"
                    f"  {name}: {json.dumps(actual, sort_keys=True)}"
                )

    for index, (tool, arguments) in enumerate(CHECKVIST_CALLS):
        label = f"{tool}({json.dumps(arguments, sort_keys=True)})" if arguments else tool
        expected = payload_of(api_results[reference].get(100 + index))
        agreed = [
            name
            for name in others
            if compare(label, expected, name, payload_of(api_results[name].get(100 + index)), 400)
        ]
        if len(agreed) == len(others):
            print(f"{label}: identical across {len(implementations)}")

    if failures:
        print("\nPARITY FAILURES:\n", file=sys.stderr)
        for failure in failures:
            print(failure + "\n", file=sys.stderr)
        return 1

    print(f"\n{', '.join(name for name, _ in implementations)} MCP servers agree.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
