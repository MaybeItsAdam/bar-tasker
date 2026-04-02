#!/usr/bin/env python3
"""Bar Tasker MCP server.

This server speaks MCP over stdio and exposes tools for Checkvist list/task operations.
It talks directly to the Checkvist API using credentials from environment variables.
"""

from __future__ import annotations

import json
import os
import sys
import traceback
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Optional


JSONRPC_VERSION = "2.0"
DEFAULT_PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "bar-tasker-mcp"
SERVER_VERSION = "0.1.0"
USER_AGENT = "BarTaskerMCP/0.1"

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


def _tool_result_text(title: str, payload: Any) -> str:
    return f"{title}\n\n{json.dumps(payload, indent=2, sort_keys=True)}"


class BarTaskerMCPServer:
    def __init__(self) -> None:
        self.config = CheckvistConfig.from_env()
        self.client = CheckvistClient(self.config)
        self.protocol_version = DEFAULT_PROTOCOL_VERSION
        self.initialized = False

    @property
    def tools(self) -> list[dict[str, Any]]:
        return [
            {
                "name": "checkvist_list_lists",
                "description": "List available Checkvist checklists (non-archived).",
                "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
            },
            {
                "name": "checkvist_fetch_tasks",
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
                "name": "checkvist_quick_add_task",
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
                "name": "checkvist_update_task",
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
                "name": "checkvist_complete_task",
                "description": "Mark a task as complete (close).",
                "inputSchema": {
                    "type": "object",
                    "properties": {"list_id": {"type": "string"}, "task_id": {"type": "integer"}},
                    "required": ["task_id"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "checkvist_reopen_task",
                "description": "Reopen a task.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"list_id": {"type": "string"}, "task_id": {"type": "integer"}},
                    "required": ["task_id"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "checkvist_invalidate_task",
                "description": "Invalidate a task.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"list_id": {"type": "string"}, "task_id": {"type": "integer"}},
                    "required": ["task_id"],
                    "additionalProperties": False,
                },
            },
            {
                "name": "checkvist_delete_task",
                "description": "Delete a task.",
                "inputSchema": {
                    "type": "object",
                    "properties": {"list_id": {"type": "string"}, "task_id": {"type": "integer"}},
                    "required": ["task_id"],
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
            if name == "checkvist_list_lists":
                payload = self.client.list_lists()
                text = _tool_result_text("Checklists", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "checkvist_fetch_tasks":
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

            if name == "checkvist_quick_add_task":
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

            if name == "checkvist_update_task":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                task_id = _required_int(arguments, "task_id")
                content = _as_optional_string(arguments.get("content"))
                due = _as_optional_string(arguments.get("due"))
                payload = self.client.update_task(list_id, task_id, content=content, due=due)
                text = _tool_result_text("Task updated", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "checkvist_complete_task":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                task_id = _required_int(arguments, "task_id")
                payload = self.client.task_action(list_id, task_id, "close")
                text = _tool_result_text("Task completed", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "checkvist_reopen_task":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                task_id = _required_int(arguments, "task_id")
                payload = self.client.task_action(list_id, task_id, "reopen")
                text = _tool_result_text("Task reopened", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "checkvist_invalidate_task":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                task_id = _required_int(arguments, "task_id")
                payload = self.client.task_action(list_id, task_id, "invalidate")
                text = _tool_result_text("Task invalidated", payload)
                return {"content": [{"type": "text", "text": text}]}

            if name == "checkvist_delete_task":
                list_id = self.client.resolve_list_id(_as_string(arguments.get("list_id")))
                task_id = _required_int(arguments, "task_id")
                payload = self.client.delete_task(list_id, task_id)
                text = _tool_result_text("Task deleted", payload)
                return {"content": [{"type": "text", "text": text}]}

            raise JsonRpcError(JSONRPC_INVALID_PARAMS, f"Unknown tool: {name}")
        except CheckvistError as err:
            detail = {"status": err.status, "body": err.body}
            text = _tool_result_text(f"Error: {err}", detail)
            return {"content": [{"type": "text", "text": text}], "isError": True}

    def _read_message(self) -> Optional[dict[str, Any]]:
        headers: dict[str, str] = {}

        while True:
            line = sys.stdin.buffer.readline()
            if not line:
                return None
            if line in (b"\r\n", b"\n"):
                break
            decoded = line.decode("utf-8", errors="replace").strip()
            if not decoded:
                continue
            if ":" not in decoded:
                raise JsonRpcError(JSONRPC_PARSE_ERROR, "Malformed header line.")
            name, value = decoded.split(":", 1)
            headers[name.strip().lower()] = value.strip()

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

        try:
            decoded_body = body.decode("utf-8")
            parsed = json.loads(decoded_body)
        except (UnicodeDecodeError, json.JSONDecodeError) as err:
            raise JsonRpcError(JSONRPC_PARSE_ERROR, "Invalid JSON payload.") from err

        return parsed

    def _send_result(self, msg_id: Any, result: Any) -> None:
        payload = {"jsonrpc": JSONRPC_VERSION, "id": msg_id, "result": result}
        self._write_message(payload)

    def _send_error(self, msg_id: Any, code: int, message: str, data: Any = None) -> None:
        error_obj: dict[str, Any] = {"code": code, "message": message}
        if data is not None:
            error_obj["data"] = data
        payload = {"jsonrpc": JSONRPC_VERSION, "id": msg_id, "error": error_obj}
        self._write_message(payload)

    @staticmethod
    def _write_message(payload: dict[str, Any]) -> None:
        raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
        header = f"Content-Length: {len(raw)}\r\n\r\n".encode("ascii")
        sys.stdout.buffer.write(header)
        sys.stdout.buffer.write(raw)
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
    server = BarTaskerMCPServer()
    server.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
