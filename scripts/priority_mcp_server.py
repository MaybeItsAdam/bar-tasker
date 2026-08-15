#!/usr/bin/env python3
"""Priority MCP server.

This server speaks MCP over stdio and exposes tools for Checkvist list/task operations.
It talks directly to the Checkvist API using credentials from environment variables.
"""

from __future__ import annotations

import contextlib
import json
import os
import sys
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Any, Optional


JSONRPC_VERSION = "2.0"
DEFAULT_PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "priority-mcp"
SERVER_VERSION = "0.3.0"
USER_AGENT = "PriorityMCP/0.3"

JSONRPC_PARSE_ERROR = -32700
JSONRPC_INVALID_REQUEST = -32600
JSONRPC_METHOD_NOT_FOUND = -32601
JSONRPC_INVALID_PARAMS = -32602
JSONRPC_INTERNAL_ERROR = -32603


class JsonRpcError(Exception):
    def __init__(self, code: int, message: str, data: Any = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.data = data


class CheckvistError(Exception):
    def __init__(self, message: str, status: Optional[int] = None, body: Any = None) -> None:
        super().__init__(message)
        self.status = status
        self.body = body


@dataclass
class CheckvistConfig:
    username: str
    remote_key: str
    default_list_id: str
    base_url: str = "https://checkvist.com"

    @staticmethod
    def from_env() -> "CheckvistConfig":
        return CheckvistConfig(
            username=os.environ.get("CHECKVIST_USERNAME", "").strip(),
            remote_key=os.environ.get("CHECKVIST_REMOTE_KEY", "").strip(),
            default_list_id=os.environ.get("CHECKVIST_LIST_ID", "").strip(),
            base_url=os.environ.get("CHECKVIST_BASE_URL", "https://checkvist.com").strip()
            or "https://checkvist.com",
        )


class CheckvistClient:
    def __init__(self, config: CheckvistConfig) -> None:
        self.config = config
        self._token: Optional[str] = None

    def _build_url(self, path: str, query: Optional[dict[str, Any]] = None) -> str:
        base = self.config.base_url.rstrip("/")
        clean_path = path if path.startswith("/") else f"/{path}"
        if not query:
            return f"{base}{clean_path}"
        encoded_query = urllib.parse.urlencode(
            {k: v for k, v in query.items() if v is not None}, doseq=True
        )
        return f"{base}{clean_path}?{encoded_query}"

    def _request(
        self,
        method: str,
        path: str,
        *,
        query: Optional[dict[str, Any]] = None,
        body: Optional[dict[str, Any]] = None,
        require_auth: bool = False,
        retry_unauthorized: bool = True,
    ) -> Any:
        url = self._build_url(path, query)
        headers = {
            "Accept": "application/json",
            "User-Agent": USER_AGENT,
        }

        if body is not None:
            body_bytes = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        else:
            body_bytes = None

        if require_auth:
            headers["X-Client-Token"] = self._ensure_token()

        request = urllib.request.Request(url=url, data=body_bytes, method=method, headers=headers)

        status = None
        raw = b""
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                status = response.getcode()
                raw = response.read()
        except urllib.error.HTTPError as err:
            status = err.code
            raw = err.read() or b""
        except urllib.error.URLError as err:
            raise CheckvistError(f"Network error: {err.reason}") from err

        parsed: Any = None
        text = raw.decode("utf-8", errors="replace").strip() if raw else ""
        if text:
            try:
                parsed = json.loads(text)
            except json.JSONDecodeError:
                parsed = text

        if status == 401 and require_auth and retry_unauthorized:
            self._token = None
            return self._request(
                method,
                path,
                query=query,
                body=body,
                require_auth=require_auth,
                retry_unauthorized=False,
            )

        if status is None or status < 200 or status >= 300:
            raise CheckvistError(
                f"Checkvist API request failed with status {status}.",
                status=status,
                body=parsed,
            )

        return parsed

    def _ensure_token(self) -> str:
        if self._token:
            return self._token
        self.login()
        if not self._token:
            raise CheckvistError("Authentication failed.")
        return self._token

    def login(self) -> None:
        if not self.config.username or not self.config.remote_key:
            raise CheckvistError(
                "Missing credentials. Set CHECKVIST_USERNAME and CHECKVIST_REMOTE_KEY."
            )
        payload = {
            "username": self.config.username,
            "remote_key": self.config.remote_key,
        }
        response = self._request("POST", "/auth/login.json", body=payload, require_auth=False)

        token: Optional[str] = None
        if isinstance(response, dict):
            maybe_token = response.get("token")
            if isinstance(maybe_token, str):
                token = maybe_token.strip()
        elif isinstance(response, str):
            token = response.strip().strip('"')

        if not token:
            raise CheckvistError("Authentication response did not include a token.")
        self._token = token

    def resolve_list_id(self, explicit_list_id: Optional[str]) -> str:
        list_id = (explicit_list_id or "").strip() or self.config.default_list_id
        if not list_id:
            raise CheckvistError("Missing list ID. Set CHECKVIST_LIST_ID or pass list_id.")
        return list_id

    def list_lists(self) -> list[dict[str, Any]]:
        response = self._request("GET", "/checklists.json", require_auth=True)
        if not isinstance(response, list):
            raise CheckvistError("Unexpected response while listing checklists.", body=response)
        filtered = []
        for item in response:
            if not isinstance(item, dict):
                continue
            if item.get("archived") is True:
                continue
            filtered.append(item)
        return filtered

    def fetch_tasks(
        self, list_id: str, *, include_closed: bool = False, with_notes: bool = True
    ) -> list[dict[str, Any]]:
        query = {"with_notes": "true" if with_notes else "false"}
        response = self._request(
            "GET",
            f"/checklists/{list_id}/tasks.json",
            query=query,
            require_auth=True,
        )
        if not isinstance(response, list):
            raise CheckvistError("Unexpected response while fetching tasks.", body=response)

        tasks = [task for task in response if isinstance(task, dict)]
        if not include_closed:
            tasks = [task for task in tasks if int(task.get("status", 0) or 0) == 0]
        return self._depth_first_tasks(tasks)

    def create_task(
        self,
        list_id: str,
        content: str,
        *,
        parent_id: Optional[int] = None,
        position: Optional[int] = 1,
        due: Optional[str] = None,
    ) -> dict[str, Any]:
        task_payload: dict[str, Any] = {"content": content}
        if parent_id is not None:
            task_payload["parent_id"] = int(parent_id)
        if position is not None:
            task_payload["position"] = int(position)
        if due is not None:
            task_payload["due"] = due

        response = self._request(
            "POST",
            f"/checklists/{list_id}/tasks.json",
            query={"parse": "true"},
            body={"task": task_payload},
            require_auth=True,
        )
        if not isinstance(response, dict):
            raise CheckvistError("Unexpected response while creating task.", body=response)
        return response

    def update_task(
        self,
        list_id: str,
        task_id: int,
        *,
        content: Optional[str] = None,
        due: Optional[str] = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {}
        if content is not None:
            payload["content"] = content
        if due is not None:
            payload["due"] = due
        if not payload:
            raise CheckvistError("No updates provided. Pass content and/or due.")

        response = self._request(
            "PUT",
            f"/checklists/{list_id}/tasks/{int(task_id)}.json",
            body={"task": payload},
            require_auth=True,
        )
        if isinstance(response, dict):
            return response
        return {"ok": True, "response": response}

    def move_task(self, list_id: str, task_id: int, position: int) -> dict[str, Any]:
        """Reorder within the current parent. Checkvist positions are 1-based."""
        response = self._request(
            "PUT",
            f"/checklists/{list_id}/tasks/{int(task_id)}.json",
            body={"task": {"position": int(position)}},
            require_auth=True,
        )
        if isinstance(response, dict):
            return response
        return {"ok": True, "response": response}

    def reparent_task(self, list_id: str, task_id: int, parent_id: Optional[int]) -> dict[str, Any]:
        """``parent_id=None`` promotes to the list root.

        Sent explicitly as null rather than omitted: omitting the key means
        "leave the parent alone", which is a different request.
        """
        response = self._request(
            "PUT",
            f"/checklists/{list_id}/tasks/{int(task_id)}.json",
            body={"task": {"parent_id": None if parent_id is None else int(parent_id)}},
            require_auth=True,
        )
        if isinstance(response, dict):
            return response
        return {"ok": True, "response": response}

    def create_list(self, name: str) -> dict[str, Any]:
        response = self._request(
            "POST",
            "/checklists.json",
            body={"checklist": {"name": name}},
            require_auth=True,
        )
        if isinstance(response, dict):
            return response
        return {"ok": True, "response": response}

    def add_note(self, list_id: str, task_id: int, comment: str) -> dict[str, Any]:
        """Notes are Checkvist "comments" — a separate resource from the task,
        which is why ``update_task`` cannot write them."""
        response = self._request(
            "POST",
            f"/checklists/{list_id}/tasks/{int(task_id)}/comments.json",
            body={"comment": {"comment": comment}},
            require_auth=True,
        )
        if isinstance(response, dict):
            return response
        return {"ok": True, "response": response}

    def task_action(self, list_id: str, task_id: int, action: str) -> dict[str, Any]:
        if action not in {"close", "reopen", "invalidate"}:
            raise CheckvistError(f"Unsupported task action: {action}")
        response = self._request(
            "POST",
            f"/checklists/{list_id}/tasks/{int(task_id)}/{action}.json",
            require_auth=True,
        )
        if isinstance(response, dict):
            return response
        return {"ok": True, "response": response}

    def delete_task(self, list_id: str, task_id: int) -> dict[str, Any]:
        response = self._request(
            "DELETE",
            f"/checklists/{list_id}/tasks/{int(task_id)}.json",
            require_auth=True,
        )
        if isinstance(response, dict):
            return response
        return {"ok": True, "response": response}

    @staticmethod
    def _depth_first_tasks(tasks: list[dict[str, Any]]) -> list[dict[str, Any]]:
        children_by_parent: dict[int, list[dict[str, Any]]] = {}
        for task in tasks:
            raw_parent = task.get("parent_id")
            parent_id = int(raw_parent) if isinstance(raw_parent, (int, str)) and str(raw_parent) else 0
            children_by_parent.setdefault(parent_id, []).append(task)

        for siblings in children_by_parent.values():
            siblings.sort(key=lambda item: int(item.get("position") or 0))

        ordered: list[dict[str, Any]] = []

        def walk(parent_id: int) -> None:
            for child in children_by_parent.get(parent_id, []):
                ordered.append(child)
                child_id = child.get("id")
                if isinstance(child_id, int):
                    walk(child_id)

        walk(0)
        return ordered


class LocalState:
    """Reads the state Priority keeps on this machine rather than in Checkvist.

    Priorities, recurrence rules, start dates, focus history and dailies have no
    Checkvist representation, so a server limited to the API cannot see any of
    them. This is a faithful port of ``DayBoundary`` / ``DayLogAggregator``; the
    Swift side is the tested original (``corelogic-tests/PriorityDayLogTests``)
    and ``scripts/mcp_parity_check.py`` asserts the two agree.

    Read-only, for the same reason as the Swift implementation: the running app
    holds this state in memory and would overwrite any write from here.
    """

    BUNDLE_ID = "uk.co.maybeitsadam.priority"
    DEFAULT_ROLLOVER_HOUR = 4

    def __init__(self, store_directory: Optional[str] = None, prefs_path: Optional[str] = None) -> None:
        # The two env vars redirect both sources at fixture data, for
        # `scripts/mcp_parity_check.py` — see this class's docstring.
        home = os.path.expanduser("~")
        self.store_directory = (
            store_directory
            or os.environ.get("PRIORITY_MCP_STORE_DIR")
            or os.path.join(home, "Library", "Application Support", "Priority")
        )
        self.prefs_path = (
            prefs_path
            or os.environ.get("PRIORITY_MCP_PREFS_PATH")
            or os.path.join(home, "Library", "Preferences", f"{self.BUNDLE_ID}.plist")
        )

    # -- storage -------------------------------------------------------------

    def _prefs(self) -> dict[str, Any]:
        import plistlib

        try:
            with open(self.prefs_path, "rb") as handle:
                return plistlib.load(handle)
        except Exception:
            return {}

    def _events(self) -> list[dict[str, Any]]:
        """A damaged line costs that event, not the whole history — same
        tolerance as ``DayLogFileStore.loadAll``."""
        path = os.path.join(self.store_directory, "daylog.jsonl")
        events: list[dict[str, Any]] = []
        try:
            with open(path, "r", encoding="utf-8") as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        events.append(json.loads(line))
                    except ValueError:
                        continue
        except OSError:
            return []
        return events

    def _dailies(self) -> list[dict[str, Any]]:
        path = os.path.join(self.store_directory, "dailies.json")
        try:
            with open(path, "r", encoding="utf-8") as handle:
                return json.load(handle).get("dailies", [])
        except (OSError, ValueError, AttributeError):
            return []

    # -- day boundary --------------------------------------------------------

    @property
    def rollover_hour(self) -> int:
        raw = self._prefs().get("dailyLogRolloverHour")
        if not isinstance(raw, int):
            return self.DEFAULT_ROLLOVER_HOUR
        return min(23, max(0, raw))

    @staticmethod
    def _parse_at(raw: Any) -> Optional[datetime]:
        if not isinstance(raw, str):
            return None
        try:
            return datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone()
        except ValueError:
            return None

    def logical_day(self, moment: datetime) -> datetime:
        """The instant the logical day containing ``moment`` began."""
        shifted = moment - timedelta(hours=self.rollover_hour)
        midnight = shifted.replace(hour=0, minute=0, second=0, microsecond=0)
        return midnight.replace(hour=self.rollover_hour)

    def day_key(self, moment: datetime) -> str:
        return self.logical_day(moment).strftime("%Y-%m-%d")

    def days_ending_on(self, moment: datetime, count: int) -> list[datetime]:
        anchor = self.logical_day(moment)
        return [anchor - timedelta(days=offset) for offset in reversed(range(count))]

    # -- aggregation ---------------------------------------------------------

    @staticmethod
    def _net_completions(events: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Completion events that survive their compensating reopens. A reopen
        cancels the most recent surviving completion of the same task, whenever
        that completion happened."""
        open_by_task: dict[Any, list[int]] = {}
        cancelled: set[int] = set()
        for index, event in enumerate(events):
            kind = event.get("kind")
            if kind == "completed":
                open_by_task.setdefault(event.get("taskId"), []).append(index)
            elif kind == "reopened":
                pending = open_by_task.get(event.get("taskId"))
                if pending:
                    cancelled.add(pending.pop())
        return [
            event
            for index, event in enumerate(events)
            if event.get("kind") == "completed" and index not in cancelled
        ]

    def _completed_daily_ids(self, events: list[dict[str, Any]], on: datetime) -> set[str]:
        """Netted *within* the day: a daily is asked afresh each morning, so an
        un-tick can never reach back to a previous day."""
        key = self.day_key(on)
        completed: set[str] = set()
        for event in events:
            at = self._parse_at(event.get("at"))
            if at is None or self.day_key(at) != key:
                continue
            daily_id = event.get("dailyId")
            if not daily_id:
                continue
            if event.get("kind") == "dailyCompleted":
                completed.add(daily_id)
            elif event.get("kind") == "dailyUncompleted":
                completed.discard(daily_id)
        return completed

    @staticmethod
    def _ordered_unique_task_ids(events: list[dict[str, Any]]) -> list[int]:
        seen: set[int] = set()
        ordered: list[int] = []
        for event in events:
            task_id = event.get("taskId")
            if task_id in seen:
                continue
            seen.add(task_id)
            ordered.append(task_id)
        return ordered

    def _summary(self, events: list[dict[str, Any]], on: datetime) -> dict[str, Any]:
        key = self.day_key(on)
        on_this_day = [
            event
            for event in events
            if (at := self._parse_at(event.get("at"))) is not None and self.day_key(at) == key
        ]

        # Netting runs over the whole log, not just this day: the reopen that
        # cancels one of today's completions may itself land tomorrow.
        surviving = self._net_completions(events)
        completed = [
            event
            for event in surviving
            if (at := self._parse_at(event.get("at"))) is not None and self.day_key(at) == key
        ]

        planned: list[int] = []
        for event in on_this_day:
            if event.get("kind") == "planSnapshot":
                planned = event.get("plannedTaskIds") or []
        deferred = self._ordered_unique_task_ids(
            [event for event in on_this_day if event.get("kind") == "deferred"]
        )
        invalidated = self._ordered_unique_task_ids(
            [event for event in on_this_day if event.get("kind") == "invalidated"]
        )

        # Completions from any day settle a planned task, so something finished
        # before its snapshot day never shows up as outstanding.
        closed = {event.get("taskId") for event in surviving} | set(deferred) | set(invalidated)
        unfinished = [task_id for task_id in planned if task_id not in closed]

        focus_seconds = sum(
            event.get("durationSeconds") or 0
            for event in on_this_day
            if event.get("kind") == "focusSessionEnded"
        )

        return {
            "day": key,
            "completed_count": len(completed),
            "planned_count": len(planned),
            "unfinished_count": len(unfinished),
            "focus_seconds": focus_seconds,
            "completed": [
                {"task_id": e.get("taskId"), "title": e.get("title", ""), "at": e.get("at")}
                for e in completed
            ],
            "unfinished_task_ids": unfinished,
            "deferred_task_ids": deferred,
            "invalidated_task_ids": invalidated,
        }

    # -- dailies -------------------------------------------------------------

    @staticmethod
    def _is_archived(daily: dict[str, Any]) -> bool:
        return bool(daily.get("archivedAt"))

    @staticmethod
    def _sorted_dailies(dailies: list[dict[str, Any]]) -> list[dict[str, Any]]:
        return sorted(dailies, key=lambda d: (d.get("sortIndex", 0), d.get("createdAt", "")))

    def _due_on(self, dailies: list[dict[str, Any]], day: datetime) -> list[dict[str, Any]]:
        # Calendar weekday numbering, 1 = Sunday, matching ``Daily.activeWeekdays``.
        weekday = (day.weekday() + 1) % 7 + 1
        return [
            daily
            for daily in self._sorted_dailies(dailies)
            if not self._is_archived(daily) and weekday in (daily.get("activeWeekdays") or [])
        ]

    @staticmethod
    def _schedule_label(daily: dict[str, Any]) -> str:
        weekdays = set(daily.get("activeWeekdays") or [])
        if weekdays == {1, 2, 3, 4, 5, 6, 7}:
            return "Every day"
        if weekdays == {2, 3, 4, 5, 6}:
            return "Weekdays"
        names = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return " ".join(names[day] for day in sorted(weekdays))

    # -- tool payloads -------------------------------------------------------

    def day_summaries(self, ending_on: datetime, count: int) -> list[dict[str, Any]]:
        events = self._events()
        dailies = self._dailies()
        summaries = []
        for day in reversed(self.days_ending_on(ending_on, count)):
            summary = self._summary(events, day)
            ticked = self._completed_daily_ids(events, day)
            summary["dailies"] = [
                {"id": d.get("id"), "title": d.get("title", ""), "done": d.get("id") in ticked}
                for d in self._due_on(dailies, self.logical_day(day))
            ]
            summaries.append(summary)
        return summaries

    def dailies_snapshot(self, on: datetime) -> dict[str, Any]:
        events = self._events()
        dailies = self._dailies()
        ticked = self._completed_daily_ids(events, on)
        due_today = {d.get("id") for d in self._due_on(dailies, self.logical_day(on))}
        return {
            "day": self.day_key(on),
            "dailies": [
                {
                    "id": d.get("id"),
                    "title": d.get("title", ""),
                    "schedule": self._schedule_label(d),
                    "due_today": d.get("id") in due_today,
                    "done": d.get("id") in ticked,
                }
                for d in self._sorted_dailies([d for d in dailies if not self._is_archived(d)])
            ],
        }

    # -- writes --------------------------------------------------------------
    #
    # Only dailies are writable. Priorities, recurrence and start dates stay
    # read-only: they live in UserDefaults, which the running app holds in
    # memory and rewrites on its own schedule, so there is no equivalent of the
    # file lock that would let an external write survive.

    def _dailies_path(self) -> str:
        return os.path.join(self.store_directory, "dailies.json")

    @contextlib.contextmanager
    def _exclusive_lock(self, protecting: str):
        """`flock(2)` on a sibling `.lock` file — the same protocol, and the
        same lock file, as Swift's `FileLock`, so the app and this process
        genuinely exclude each other.

        The sibling file rather than the data file because `dailies.json` is
        saved atomically (temp + rename), which replaces the inode; a lock on
        the old inode would protect nothing.
        """
        import fcntl

        lock_path = protecting + ".lock"
        os.makedirs(os.path.dirname(lock_path), exist_ok=True)
        handle = open(lock_path, "a+")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            yield
        finally:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            finally:
                handle.close()

    def _save_dailies(self, collection: dict[str, Any]) -> None:
        path = self._dailies_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # Atomic, matching `DailyDefinitionsStore.save`: a crash mid-write must
        # leave the previous list intact rather than a half-written one.
        temp_path = path + ".tmp"
        with open(temp_path, "w", encoding="utf-8") as handle:
            json.dump(collection, handle, indent=2, sort_keys=True)
        os.replace(temp_path, path)

    def _load_collection(self) -> dict[str, Any]:
        try:
            with open(self._dailies_path(), "r", encoding="utf-8") as handle:
                collection = json.load(handle)
        except (OSError, ValueError):
            return {"version": 1, "dailies": []}
        if not isinstance(collection, dict) or not isinstance(collection.get("dailies"), list):
            return {"version": 1, "dailies": []}
        return collection

    def _mutate_dailies(self, transform) -> dict[str, Any]:
        """Read/modify/write with the file locked for the whole operation.

        The caller must express *what changed*, never hand over a snapshot it
        loaded earlier: the app is editing the same file, and saving a stale
        snapshot silently erases whatever it added in the meantime.
        """
        with self._exclusive_lock(self._dailies_path()):
            collection = self._load_collection()
            transform(collection)
            self._save_dailies(collection)
            return collection

    @staticmethod
    def _now_iso() -> str:
        """UTC, whole seconds, `Z` suffix.

        This must match Swift's `JSONDecoder.dateDecodingStrategy = .iso8601`
        exactly, which uses `.withInternetDateTime` and therefore **rejects
        fractional seconds**. `datetime.isoformat()` emits microseconds and a
        numeric offset, which fails that decode — and because
        `DailyDefinitionsStore.load()` treats a decode failure as an empty
        collection, the app would show no dailies at all and then save that
        emptiness back over the file. One timestamp, every daily gone.
        """
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    @staticmethod
    def _daily_payload(daily: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": daily.get("id"),
            "title": daily.get("title", ""),
            "schedule": LocalState._schedule_label(daily),
            "active_weekdays": sorted(daily.get("activeWeekdays") or []),
            "archived": bool(daily.get("archivedAt")),
        }

    def add_daily(self, title: str, active_weekdays: Optional[list[int]]) -> dict[str, Any]:
        trimmed = (title or "").strip()
        if not trimmed:
            raise CheckvistError("title must not be empty.")
        weekdays = sorted(set(active_weekdays)) if active_weekdays else [1, 2, 3, 4, 5, 6, 7]
        daily = {
            "id": str(uuid.uuid4()).upper(),
            "title": trimmed,
            "activeWeekdays": weekdays,
            "sortIndex": 0,
            "createdAt": self._now_iso(),
        }

        def transform(collection: dict[str, Any]) -> None:
            # Appended at the end of the current order, as `DailyCollection.add`.
            existing = [d.get("sortIndex", 0) for d in collection["dailies"]]
            daily["sortIndex"] = (max(existing) if existing else -1) + 1
            collection["dailies"].append(daily)

        saved = self._mutate_dailies(transform)
        stored = next((d for d in saved["dailies"] if d.get("id") == daily["id"]), None)
        if stored is None:
            raise CheckvistError("The daily was not saved.")
        return self._daily_payload(stored)

    def update_daily(
        self,
        daily_id: str,
        title: Optional[str],
        active_weekdays: Optional[list[int]],
        archived: Optional[bool],
    ) -> dict[str, Any]:
        if not any(d.get("id") == daily_id for d in self._load_collection()["dailies"]):
            raise CheckvistError(f"No daily with id {daily_id}.")

        def transform(collection: dict[str, Any]) -> None:
            for daily in collection["dailies"]:
                if daily.get("id") != daily_id:
                    continue
                if title is not None and title.strip():
                    daily["title"] = title.strip()
                if active_weekdays:
                    daily["activeWeekdays"] = sorted(set(active_weekdays))
                if archived is not None:
                    # Archive rather than delete, so history referencing this id
                    # still renders with a title instead of as an orphan.
                    if archived:
                        daily.setdefault("archivedAt", self._now_iso())
                    else:
                        daily.pop("archivedAt", None)

        saved = self._mutate_dailies(transform)
        stored = next((d for d in saved["dailies"] if d.get("id") == daily_id), None)
        if stored is None:
            raise CheckvistError(f"No daily with id {daily_id}.")
        return self._daily_payload(stored)

    def set_daily(self, daily_id: str, done: bool) -> dict[str, Any]:
        """Ticks by appending to the log, as `DailyLogService.setDaily` does —
        the tick is a fact about a day, not a field on the daily."""
        daily = next(
            (d for d in self._load_collection()["dailies"] if d.get("id") == daily_id), None
        )
        if daily is None:
            raise CheckvistError(f"No daily with id {daily_id}.")

        now = datetime.now().astimezone()
        already = daily_id in self._completed_daily_ids(self._events(), now)
        if already == done:
            return {
                "id": daily_id, "title": daily.get("title", ""), "done": already,
                "day": self.day_key(now), "changed": False,
            }

        log_path = os.path.join(self.store_directory, "daylog.jsonl")
        event = {
            "kind": "dailyCompleted" if done else "dailyUncompleted",
            "at": now.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "taskId": 0,
            "title": daily.get("title", ""),
            "dailyId": daily_id,
        }
        # Locked so a concurrent append from the app cannot splice a line — a
        # spliced line is dropped by the tolerant reader, losing both events.
        with self._exclusive_lock(log_path):
            os.makedirs(os.path.dirname(log_path), exist_ok=True)
            with open(log_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(event, sort_keys=True) + "\n")

        return {
            "id": daily_id, "title": daily.get("title", ""), "done": done,
            "day": self.day_key(now), "changed": True,
        }

    @staticmethod
    def _normalized_queue(queue: Any) -> list[int]:
        """Drop non-positive and duplicate ids, preserving order — matches
        ``normalizedQueue`` in both Swift stores."""
        if not isinstance(queue, list):
            return []
        seen: set[int] = set()
        normalized: list[int] = []
        for raw in queue:
            if not isinstance(raw, int) or isinstance(raw, bool) or raw <= 0 or raw in seen:
                continue
            seen.add(raw)
            normalized.append(raw)
        return normalized

    def task_metadata(self, list_id: str) -> dict[str, Any]:
        prefs = self._prefs()

        # Empty list id is the offline scope, matching ``ListScopedPriorityStore``.
        scope = list_id if list_id else "__offline__"

        # The two stores are encoded differently and it is load-bearing:
        # `ListScopedPriorityStore` writes a JSON blob via `defaults.set(Data)`,
        # while `ListScopedTaskIDStore` writes a plain plist dictionary. Reading
        # either one the other's way yields silently empty results.
        raw_scoped = prefs.get("priorityTaskIdsByParentIdByListId")
        scoped_all: dict[str, Any] = {}
        if isinstance(raw_scoped, bytes):
            try:
                scoped_all = json.loads(raw_scoped.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                scoped_all = {}

        scoped_ranks: dict[str, dict[str, int]] = {}
        for parent_id, queue in (scoped_all.get(scope) or {}).items():
            # Parent keys that aren't integers are dropped, as `Int(key)` does.
            try:
                int(parent_id)
            except (TypeError, ValueError):
                continue
            normalized = self._normalized_queue(queue)
            if not normalized:
                continue
            scoped_ranks[str(parent_id)] = {
                str(task_id): index + 1 for index, task_id in enumerate(normalized)
            }

        raw_absolute = prefs.get("absolutePriorityTaskIdsByListId")
        absolute_queue = self._normalized_queue(
            (raw_absolute or {}).get(scope) if isinstance(raw_absolute, dict) else None
        )
        absolute_ranks = {str(task_id): index + 1 for index, task_id in enumerate(absolute_queue)}

        # What the Matrix view is drawn from. A JSON blob under a `Data`
        # default, like the scoped priority store above and unlike the plain
        # dictionaries — read it the other way and you get silent emptiness.
        raw_levels = prefs.get("eisenhowerLevelsByTaskIdByListId")
        levels_all: dict[str, Any] = {}
        if isinstance(raw_levels, bytes):
            try:
                levels_all = json.loads(raw_levels.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                levels_all = {}
        eisenhower = {
            task_id: {
                "urgency": float(level.get("urgency", 0.0)),
                "importance": float(level.get("importance", 0.0)),
            }
            for task_id, level in (levels_all.get(scope) or {}).items()
            if isinstance(level, dict)
        }

        return {
            "list_id": list_id,
            "scoped_priority_rank_by_parent_id": scoped_ranks,
            "absolute_priority_rank": absolute_ranks,
            "recurrence_rule_by_task_id": prefs.get("recurrenceRulesByTaskId") or {},
            "start_date_by_task_id": prefs.get("taskStartDatesByTaskId") or {},
            "eisenhower_by_task_id": eisenhower,
            "kanban_columns": self._kanban_columns(prefs),
        }

    # `RootDueBucket` in the app, by raw value.
    DUE_BUCKETS = ["Overdue", "ASAP", "Today", "Tomorrow", "Next 7 days",
                   "Further in the future", "No due date"]

    # `KanbanColumn.defaults`, used when nothing has been configured.
    DEFAULT_KANBAN_COLUMNS = [
        ("Today", [("due_bucket", 1), ("due_bucket", 0), ("due_bucket", 2)]),
        ("Next 7 Days", [("due_bucket", 3), ("due_bucket", 4)]),
        ("Waiting On", [("tag", "waiting")]),
        ("Backlog", [("tag", "backlog")]),
    ]

    def _kanban_columns(self, prefs: dict[str, Any]) -> list[dict[str, Any]]:
        """The board's columns, in evaluation order.

        `KanbanColumnCondition` is a Swift enum with associated values, so it is
        stored in the synthesised `Codable` shape -- `{"tag": {"_0": "waiting"}}`.
        That encoding is Swift's business, so it is flattened here into
        something this side can state plainly.
        """
        def condition(raw: Any) -> Optional[dict[str, Any]]:
            if not isinstance(raw, dict) or len(raw) != 1:
                return None
            (case, payload), = raw.items()
            value = payload.get("_0") if isinstance(payload, dict) else None
            if case == "tag" and isinstance(value, str):
                return {"kind": "tag", "tag": value}
            if case == "dueBucket" and isinstance(value, int):
                title = self.DUE_BUCKETS[value] if 0 <= value < len(self.DUE_BUCKETS) else ""
                return {"kind": "due_bucket", "bucket_id": value, "bucket": title}
            if case == "catchAll":
                return {"kind": "catch_all"}
            return None

        stored = prefs.get("kanbanColumns")
        decoded = None
        if isinstance(stored, str) and stored.strip():
            try:
                candidate = json.loads(stored)
            except ValueError:
                candidate = None
            if isinstance(candidate, list) and candidate:
                decoded = candidate

        if decoded is None:
            return [
                {
                    "name": name,
                    "sort_order": "priorityThenDueAscending",
                    "conditions": [
                        {"kind": "tag", "tag": value} if kind == "tag" else
                        {"kind": "due_bucket", "bucket_id": value,
                         "bucket": self.DUE_BUCKETS[value]}
                        for kind, value in conditions
                    ],
                }
                for name, conditions in self.DEFAULT_KANBAN_COLUMNS
            ]

        columns = []
        for column in decoded:
            if not isinstance(column, dict):
                continue
            name = column.get("name", "")
            conditions = [
                c for c in (condition(raw) for raw in column.get("conditions") or []) if c
            ]
            # The same migration `KanbanManager` applies on load: a Backlog
            # column still saying "everything else" would swallow every task.
            if str(name).lower() == "backlog":
                conditions = [
                    {"kind": "tag", "tag": "backlog"} if c["kind"] == "catch_all" else c
                    for c in conditions
                ]
            columns.append({
                "name": name,
                "sort_order": column.get("sortOrder", "position"),
                "conditions": conditions,
            })
        return columns


def _filter_tasks(
    tasks: list[dict[str, Any]],
    *,
    query: Optional[str],
    tag: Optional[str],
    due_before: Optional[str],
) -> list[dict[str, Any]]:
    """Filtering runs server-side so a search over a large list costs one tool
    result instead of the whole list. All three filters are ANDed; omitting one
    drops it. Mirrors `MCPServer.filterTasks` on the Swift side."""
    matches = tasks

    if query and query.strip():
        needle = query.strip().casefold()
        matches = [t for t in matches if needle in str(t.get("content") or "").casefold()]

    if tag and tag.strip():
        # Checkvist returns tags as an array or a dict depending on the endpoint,
        # and also inline in the content as `#tag` — match any, rather than
        # silently missing half the tagged tasks.
        normalized = tag.strip().lstrip("#").casefold()

        def has_tag(task: dict[str, Any]) -> bool:
            raw = task.get("tags")
            if isinstance(raw, list):
                if any(str(t).casefold() == normalized for t in raw):
                    return True
            elif isinstance(raw, dict):
                if any(str(k).casefold() == normalized for k in raw):
                    return True
            return f"#{normalized}" in str(task.get("content") or "").casefold()

        matches = [t for t in matches if has_tag(t)]

    if due_before and due_before.strip():
        # Checkvist serialises `due` as YYYY-MM-DD, which compares correctly as a
        # string. A task with no due date is never "due before" anything.
        cutoff = due_before.strip()
        matches = [t for t in matches if str(t.get("due") or "") and str(t["due"]) < cutoff]

    return matches


def _tool_result_text(title: str, payload: Any) -> str:
    return f"{title}\n\n{json.dumps(payload, indent=2, sort_keys=True)}"


class PriorityMCPServer:
    def __init__(self) -> None:
        self.config = CheckvistConfig.from_env()
        self.client = CheckvistClient(self.config)
        self.local_state = LocalState()
        self.protocol_version = DEFAULT_PROTOCOL_VERSION
        self.initialized = False
        # "newline" is the MCP stdio transport and the right default before any
        # request has been read; switched to "content-length" if a peer uses it.
        self.framing = "newline"

    @property
    def tools(self) -> list[dict[str, Any]]:
        return [
            {
                "name": "task_lists",
                "description": "List available task lists (non-archived).",
                "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
            },
            {
                "name": "task_fetch",
                "description": "Fetch tasks for a list. Defaults to open tasks only.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "list_id": {"type": "string"},
                        "include_closed": {"type": "boolean", "default": False},
                        "with_notes": {"type": "boolean", "default": True},
                    },
                    "additionalProperties": False,
                },
            },
            {
                "name": "task_add",
                "description": "Quick-add a task to list root or to a specific parent task ID.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "list_id": {"type": "string"},
                        "content": {"type": "string", "minLength": 1},
                        "location": {
                            "type": "string",
                            "enum": ["default", "specific"],
                            "default": "default",
                        },
                        "parent_task_id": {"type": "integer"},
                        "position": {"type": "integer", "default": 1},
                        "due": {"type": "string"},
                    },
                    "required": ["content"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "task_update",
                "description": "Update task content and/or due field.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "list_id": {"type": "string"},
                        "task_id": {"type": "integer"},
                        "content": {"type": "string"},
                        "due": {"type": "string"},
                    },
                    "required": ["task_id"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "task_complete",
                "description": "Mark a task as complete (close).",
                "inputSchema": {
                    "type": "object",
                    "properties": {"list_id": {"type": "string"}, "task_id": {"type": "integer"}},
                    "required": ["task_id"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "task_reopen",
                "description": "Reopen a task.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"list_id": {"type": "string"}, "task_id": {"type": "integer"}},
                    "required": ["task_id"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "task_invalidate",
                "description": "Invalidate a task.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"list_id": {"type": "string"}, "task_id": {"type": "integer"}},
                    "required": ["task_id"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "task_delete",
                "description": "Delete a task.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"list_id": {"type": "string"}, "task_id": {"type": "integer"}},
                    "required": ["task_id"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "task_move",
                "description": "Reorder a task among its siblings. Position is 1-based.",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "list_id": {"type": "string"},
                        "task_id": {"type": "integer"},
                        "position": {"type": "integer", "minimum": 1},
                    },
                    "required": ["task_id", "position"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "task_reparent",
                "description": (
                    "Move a task under a different parent. Omit parent_task_id "
                    "(or pass 0) to move it to the list root."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "list_id": {"type": "string"},
                        "task_id": {"type": "integer"},
                        "parent_task_id": {"type": "integer"},
                    },
                    "required": ["task_id"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "task_note_add",
                "description": (
                    "Append a note (Checkvist comment) to a task. Notes are read "
                    "back via task_fetch with with_notes."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "list_id": {"type": "string"},
                        "task_id": {"type": "integer"},
                        "note": {"type": "string", "minLength": 1},
                    },
                    "required": ["task_id", "note"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "list_create",
                "description": "Create a new checklist.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"name": {"type": "string", "minLength": 1}},
                    "required": ["name"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "task_search",
                "description": (
                    "Search tasks in a list by content substring, tag, and/or due "
                    "date. Cheaper than fetching the whole list."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "list_id": {"type": "string"},
                        "query": {"type": "string"},
                        "tag": {"type": "string"},
                        "due_before": {"type": "string", "description": "YYYY-MM-DD, exclusive."},
                        "include_closed": {"type": "boolean", "default": False},
                        "limit": {"type": "integer", "default": 50, "minimum": 1},
                    },
                    "additionalProperties": False,
                },
            },
            {
                "name": "daily_log_fetch",
                "description": (
                    "What actually happened on recent days: completions, focus time, "
                    "unfinished and deferred tasks, and daily ticks. Local to Bar "
                    "Tasker; read-only."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "days": {
                            "type": "integer",
                            "default": 1,
                            "minimum": 1,
                            "maximum": 90,
                            "description": "How many logical days back to include, ending today.",
                        }
                    },
                    "additionalProperties": False,
                },
            },
            {
                "name": "dailies_list",
                "description": (
                    "The configured dailies (habits) with today's schedule and tick "
                    "state. Local to Priority; read-only."
                ),
                "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
            },
            {
                "name": "task_metadata",
                "description": (
                    "Priority-only per-task state that Checkvist does not store: "
                    "priority ranks, recurrence rules, and start dates. Read-only."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {"list_id": {"type": "string"}},
                    "additionalProperties": False,
                },
            },
            {
                "name": "daily_add",
                "description": (
                    "Create a daily (a habit that resets each day, not a task). "
                    "Local to Priority."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "title": {"type": "string", "minLength": 1},
                        "active_weekdays": {
                            "type": "array",
                            "items": {"type": "integer", "minimum": 1, "maximum": 7},
                            "description": "1 = Sunday. Omit for every day.",
                        },
                    },
                    "required": ["title"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "daily_update",
                "description": (
                    "Rename a daily, change which weekdays it's expected on, or "
                    "archive/unarchive it. Archiving keeps history readable rather "
                    "than deleting."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "daily_id": {"type": "string"},
                        "title": {"type": "string"},
                        "active_weekdays": {
                            "type": "array",
                            "items": {"type": "integer", "minimum": 1, "maximum": 7},
                            "description": "1 = Sunday.",
                        },
                        "archived": {"type": "boolean"},
                    },
                    "required": ["daily_id"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "daily_tick",
                "description": (
                    "Tick or un-tick a daily for today. Recorded against the current "
                    "logical day, honouring the configured rollover hour."
                ),
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "daily_id": {"type": "string"},
                        "done": {"type": "boolean", "default": True},
                    },
                    "required": ["daily_id"],
                    "additionalProperties": False,
                },
            },
        ]

    def run(self) -> None:
        while True:
            message = self._read_message()
            if message is None:
                return

            try:
                self._handle_message(message)
            except JsonRpcError as err:
                msg_id = message.get("id") if isinstance(message, dict) else None
                if msg_id is not None:
                    self._send_error(msg_id, err.code, err.message, err.data)
            except Exception as err:  # noqa: BLE001
                msg_id = message.get("id") if isinstance(message, dict) else None
                if msg_id is not None:
                    self._send_error(
                        msg_id,
                        JSONRPC_INTERNAL_ERROR,
                        str(err),
                        {"traceback": traceback.format_exc()},
                    )

    def _handle_message(self, message: Any) -> None:
        if not isinstance(message, dict):
            raise JsonRpcError(JSONRPC_INVALID_REQUEST, "Request must be an object.")

        if message.get("jsonrpc") != JSONRPC_VERSION:
            raise JsonRpcError(JSONRPC_INVALID_REQUEST, "Unsupported JSON-RPC version.")

        method = message.get("method")
        if not isinstance(method, str):
            raise JsonRpcError(JSONRPC_INVALID_REQUEST, "Missing method.")

        params = message.get("params")
        msg_id = message.get("id")
        is_notification = msg_id is None

        if method == "notifications/initialized":
            self.initialized = True
            return

        if method == "initialize":
            requested_protocol = None
            if isinstance(params, dict):
                maybe_protocol = params.get("protocolVersion")
                if isinstance(maybe_protocol, str) and maybe_protocol:
                    requested_protocol = maybe_protocol
            self.protocol_version = requested_protocol or DEFAULT_PROTOCOL_VERSION
            result = {
                "protocolVersion": self.protocol_version,
                "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
                "capabilities": {"tools": {}},
            }
            if not is_notification:
                self._send_result(msg_id, result)
            return

        if method == "ping":
            if not is_notification:
                self._send_result(msg_id, {})
            return

        if method == "tools/list":
            if not is_notification:
                self._send_result(msg_id, {"tools": self.tools})
            return

        if method == "tools/call":
            if not isinstance(params, dict):
                raise JsonRpcError(JSONRPC_INVALID_PARAMS, "tools/call params must be an object.")
            name = params.get("name")
            arguments = params.get("arguments", {})
            if not isinstance(name, str) or not name:
                raise JsonRpcError(JSONRPC_INVALID_PARAMS, "Missing tool name.")
            if arguments is None:
                arguments = {}
            if not isinstance(arguments, dict):
                raise JsonRpcError(JSONRPC_INVALID_PARAMS, "Tool arguments must be an object.")
            result = self._call_tool(name, arguments)
            if not is_notification:
                self._send_result(msg_id, result)
            return

        if method == "resources/list":
            if not is_notification:
                self._send_result(msg_id, {"resources": []})
            return

        if method == "prompts/list":
            if not is_notification:
                self._send_result(msg_id, {"prompts": []})
            return

        if method == "logging/setLevel":
            if not is_notification:
                self._send_result(msg_id, {})
            return

        raise JsonRpcError(JSONRPC_METHOD_NOT_FOUND, f"Method not found: {method}")

    def _call_tool(self, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        try:
            if name == "task_lists":
                payload = self.client.list_lists()
                text = _tool_result_text("Checklists", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "task_fetch":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                include_closed = _as_bool(arguments.get("include_closed"), default=False)
                with_notes = _as_bool(arguments.get("with_notes"), default=True)
                payload = self.client.fetch_tasks(
                    list_id,
                    include_closed=include_closed,
                    with_notes=with_notes,
                )
                text = _tool_result_text(
                    f"Tasks (list {list_id}, include_closed={include_closed})", payload
                )
                return {"content": [{"type": "text", "text": text}]}

            if name == "task_add":
                content = _required_string(arguments, "content").strip()
                location = _as_string(arguments.get("location")) or "default"
                if location not in {"default", "specific"}:
                    raise CheckvistError("location must be 'default' or 'specific'.")

                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                parent_task_id: Optional[int] = None
                if location == "specific":
                    parent_task_id = _required_int(arguments, "parent_task_id")

                position = _as_optional_int(arguments.get("position"))
                due = _as_optional_string(arguments.get("due"))

                payload = self.client.create_task(
                    list_id,
                    content,
                    parent_id=parent_task_id,
                    position=position if position is not None else 1,
                    due=due,
                )
                text = _tool_result_text("Task created", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "task_update":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                task_id = _required_int(arguments, "task_id")
                content = _as_optional_string(arguments.get("content"))
                due = _as_optional_string(arguments.get("due"))
                payload = self.client.update_task(list_id, task_id, content=content, due=due)
                text = _tool_result_text("Task updated", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "task_complete":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                task_id = _required_int(arguments, "task_id")
                payload = self.client.task_action(list_id, task_id, "close")
                text = _tool_result_text("Task completed", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "task_reopen":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                task_id = _required_int(arguments, "task_id")
                payload = self.client.task_action(list_id, task_id, "reopen")
                text = _tool_result_text("Task reopened", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "task_invalidate":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                task_id = _required_int(arguments, "task_id")
                payload = self.client.task_action(list_id, task_id, "invalidate")
                text = _tool_result_text("Task invalidated", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "task_delete":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                task_id = _required_int(arguments, "task_id")
                payload = self.client.delete_task(list_id, task_id)
                text = _tool_result_text("Task deleted", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "task_move":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                task_id = _required_int(arguments, "task_id")
                position = _required_int(arguments, "position")
                if position < 1:
                    raise CheckvistError("position must be 1 or greater.")
                payload = self.client.move_task(list_id, task_id, position)
                text = _tool_result_text("Task moved", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "task_reparent":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                task_id = _required_int(arguments, "task_id")
                # Absent means "move to root". 0 means the same, so a client that
                # cannot express null still has a way to say it.
                raw_parent = _as_optional_int(arguments.get("parent_task_id"))
                parent_id = None if raw_parent in (None, 0) else raw_parent
                if parent_id is not None and parent_id == task_id:
                    raise CheckvistError("A task cannot be its own parent.")
                payload = self.client.reparent_task(list_id, task_id, parent_id)
                text = _tool_result_text("Task reparented", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "task_note_add":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                task_id = _required_int(arguments, "task_id")
                note = _required_string(arguments, "note")
                payload = self.client.add_note(list_id, task_id, note)
                text = _tool_result_text("Note added", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "list_create":
                payload = self.client.create_list(_required_string(arguments, "name"))
                text = _tool_result_text("List created", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "task_search":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                include_closed = _as_bool(arguments.get("include_closed"), default=False)
                tasks = self.client.fetch_tasks(
                    list_id, include_closed=include_closed, with_notes=False
                )
                matches = _filter_tasks(
                    tasks,
                    query=_as_optional_string(arguments.get("query")),
                    tag=_as_optional_string(arguments.get("tag")),
                    due_before=_as_optional_string(arguments.get("due_before")),
                )
                limit = _as_optional_int(arguments.get("limit")) or 50
                suffix = f", showing {limit}" if len(matches) > limit else ""
                text = _tool_result_text(
                    f"Search (list {list_id}, {len(matches)} match(es){suffix})",
                    matches[: max(0, limit)],
                )
                return {"content": [{"type": "text", "text": text}]}

            if name == "daily_log_fetch":
                days = _as_optional_int(arguments.get("days")) or 1
                if days < 1 or days > 90:
                    raise CheckvistError("days must be between 1 and 90.")
                payload = self.local_state.day_summaries(datetime.now().astimezone(), days)
                text = _tool_result_text(f"Daily log ({days} day(s))", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "dailies_list":
                payload = self.local_state.dailies_snapshot(datetime.now().astimezone())
                text = _tool_result_text("Dailies", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "task_metadata":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                payload = self.local_state.task_metadata(list_id)
                text = _tool_result_text(f"Priority metadata (list {list_id})", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "daily_add":
                title = _required_string(arguments, "title")
                weekdays = _as_optional_weekdays(arguments.get("active_weekdays"))
                payload = self.local_state.add_daily(title, weekdays)
                text = _tool_result_text("Daily added", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "daily_update":
                daily_id = _required_string(arguments, "daily_id")
                title = _as_optional_string(arguments.get("title"))
                weekdays = _as_optional_weekdays(arguments.get("active_weekdays"))
                archived = (
                    None
                    if arguments.get("archived") is None
                    else _as_bool(arguments.get("archived"), default=False)
                )
                if title is None and weekdays is None and archived is None:
                    raise CheckvistError(
                        "No updates provided. Pass title, active_weekdays and/or archived."
                    )
                payload = self.local_state.update_daily(daily_id, title, weekdays, archived)
                text = _tool_result_text("Daily updated", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "daily_tick":
                daily_id = _required_string(arguments, "daily_id")
                done = _as_bool(arguments.get("done"), default=True)
                payload = self.local_state.set_daily(daily_id, done)
                if payload["changed"]:
                    title = "Daily ticked" if done else "Daily un-ticked"
                else:
                    title = "Daily already in that state"
                text = _tool_result_text(title, payload)
                return {"content": [{"type": "text", "text": text}]}

            raise JsonRpcError(JSONRPC_INVALID_PARAMS, f"Unknown tool: {name}")
        except CheckvistError as err:
            detail = {"status": err.status, "body": err.body}
            text = _tool_result_text(f"Error: {err}", detail)
            return {"content": [{"type": "text", "text": text}], "isError": True}

    def _read_message(self) -> Optional[dict[str, Any]]:
        # The MCP stdio transport is newline-delimited JSON: one object per
        # line, no headers. LSP-style Content-Length framing is still accepted
        # for anything already wired up that way, and replies mirror whichever
        # arrived. Mirrors `MCPFrameDecoder` on the Swift side.
        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                return None
            stripped = line.strip()
            if not stripped:
                continue
            if stripped.lower().startswith(b"content-length:"):
                return self._read_header_framed_message(stripped)
            self.framing = "newline"
            return self._parse_body(stripped)

    def _read_header_framed_message(self, first_line: bytes) -> dict[str, Any]:
        self.framing = "content-length"
        headers: dict[str, str] = {}
        line = first_line
        while True:
            decoded = line.decode("utf-8", errors="replace").strip()
            if decoded:
                if ":" not in decoded:
                    raise JsonRpcError(JSONRPC_PARSE_ERROR, "Malformed header line.")
                name, value = decoded.split(":", 1)
                headers[name.strip().lower()] = value.strip()
            line = sys.stdin.buffer.readline()
            if not line or line in (b"\r\n", b"\n"):
                break

        content_length_raw = headers.get("content-length")
        if not content_length_raw:
            raise JsonRpcError(JSONRPC_PARSE_ERROR, "Missing Content-Length header.")
        try:
            content_length = int(content_length_raw)
        except ValueError as err:
            raise JsonRpcError(JSONRPC_PARSE_ERROR, "Invalid Content-Length header.") from err

        body = sys.stdin.buffer.read(content_length)
        if len(body) != content_length:
            raise JsonRpcError(JSONRPC_PARSE_ERROR, "Unexpected EOF while reading message body.")
        return self._parse_body(body)

    @staticmethod
    def _parse_body(body: bytes) -> dict[str, Any]:
        try:
            return json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as err:
            raise JsonRpcError(JSONRPC_PARSE_ERROR, "Invalid JSON payload.") from err

    def _send_result(self, msg_id: Any, result: Any) -> None:
        payload = {"jsonrpc": JSONRPC_VERSION, "id": msg_id, "result": result}
        self._write_message(payload)

    def _send_error(self, msg_id: Any, code: int, message: str, data: Any = None) -> None:
        error_obj: dict[str, Any] = {"code": code, "message": message}
        if data is not None:
            error_obj["data"] = data
        payload = {"jsonrpc": JSONRPC_VERSION, "id": msg_id, "error": error_obj}
        self._write_message(payload)

    def _write_message(self, payload: dict[str, Any]) -> None:
        raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        if self.framing == "content-length":
            sys.stdout.buffer.write(f"Content-Length: {len(raw)}\r\n\r\n".encode("ascii"))
            sys.stdout.buffer.write(raw)
        else:
            sys.stdout.buffer.write(raw + b"\n")
        sys.stdout.buffer.flush()


def _as_string(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        return value
    return str(value)


def _as_optional_string(value: Any) -> Optional[str]:
    if value is None:
        return None
    return _as_string(value)


def _as_bool(value: Any, *, default: bool) -> bool:
    if value is None:
        return default
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"true", "1", "yes", "y"}:
            return True
        if normalized in {"false", "0", "no", "n"}:
            return False
    if isinstance(value, int):
        return value != 0
    raise CheckvistError(f"Expected boolean value, got {type(value).__name__}.")


def _as_optional_int(value: Any) -> Optional[int]:
    if value is None:
        return None
    if isinstance(value, bool):
        raise CheckvistError("Boolean value is not a valid integer.")
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        raw = value.strip()
        if not raw:
            return None
        try:
            return int(raw)
        except ValueError as err:
            raise CheckvistError(f"Invalid integer value: {value}") from err
    raise CheckvistError(f"Expected integer value, got {type(value).__name__}.")


def _as_optional_weekdays(value: Any) -> Optional[list[int]]:
    """`Calendar` weekday numbering, 1 = Sunday, matching `Daily.activeWeekdays`."""
    if value is None:
        return None
    if not isinstance(value, list):
        raise CheckvistError("active_weekdays must be an array of integers 1-7.")
    weekdays: set[int] = set()
    for element in value:
        if isinstance(element, bool) or not isinstance(element, int) or not 1 <= element <= 7:
            raise CheckvistError("active_weekdays entries must be integers 1-7 (1 = Sunday).")
        weekdays.add(element)
    if not weekdays:
        raise CheckvistError("active_weekdays must not be empty.")
    return sorted(weekdays)


def _required_string(arguments: dict[str, Any], key: str) -> str:
    value = arguments.get(key)
    if value is None:
        raise CheckvistError(f"Missing required argument: {key}")
    result = _as_string(value)
    if result is None or not result.strip():
        raise CheckvistError(f"Missing required argument: {key}")
    return result


def _required_int(arguments: dict[str, Any], key: str) -> int:
    value = arguments.get(key)
    if value is None:
        raise CheckvistError(f"Missing required argument: {key}")
    parsed = _as_optional_int(value)
    if parsed is None:
        raise CheckvistError(f"Missing required argument: {key}")
    return parsed


def main() -> int:
    server = PriorityMCPServer()
    server.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
