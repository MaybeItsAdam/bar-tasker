//! A direct Checkvist API client.
//!
//! Talks to the API rather than to the running app, so every command here works
//! whether or not Priority is open. Mirrors `CheckvistClient`, the client
//! embedded in `Priority/Plugins/MCP/MCPServer.swift`.

use crate::config::Config;
use crate::error::{Result, ToolError};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::time::Duration;

pub const USER_AGENT: &str = "PriorityMCP/0.3";
pub const DEFAULT_BASE_URL: &str = "https://checkvist.com";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);

pub struct CheckvistConfig {
    pub username: String,
    pub remote_key: String,
    pub default_list_id: String,
    pub base_url: String,
}

impl CheckvistConfig {
    /// Environment first, then the CLI's own config file — see `config.rs` for
    /// why that order, and why this never consults the app's keychain item.
    pub fn resolve(config: &Config) -> Self {
        let value = |env_key, config_key| config.resolve(env_key, config_key).0.unwrap_or_default();
        CheckvistConfig {
            username: value("CHECKVIST_USERNAME", "username"),
            remote_key: value("CHECKVIST_REMOTE_KEY", "remote_key"),
            default_list_id: value("CHECKVIST_LIST_ID", "list_id"),
            base_url: config
                .resolve("CHECKVIST_BASE_URL", "base_url")
                .0
                .unwrap_or_else(|| DEFAULT_BASE_URL.into()),
        }
    }

    pub fn has_credentials(&self) -> bool {
        !self.username.is_empty() && !self.remote_key.is_empty()
    }
}

pub struct CheckvistClient {
    pub config: CheckvistConfig,
    agent: ureq::Agent,
    token: RefCell<Option<String>>,
}

impl CheckvistClient {
    pub fn new(config: CheckvistConfig) -> Self {
        CheckvistClient {
            config,
            agent: ureq::AgentBuilder::new()
                .timeout(REQUEST_TIMEOUT)
                .user_agent(USER_AGENT)
                .build(),
            token: RefCell::new(None),
        }
    }

    fn build_url(&self, path: &str) -> String {
        let base = self.config.base_url.trim_end_matches('/');
        if path.starts_with('/') {
            format!("{base}{path}")
        } else {
            format!("{base}/{path}")
        }
    }

    fn request(
        &self,
        method: &str,
        path: &str,
        query: &[(&str, &str)],
        body: Option<Value>,
        require_auth: bool,
    ) -> Result<Value> {
        // One retry only, and only for 401: a token can expire between calls,
        // but a second rejection means the credentials themselves are wrong and
        // retrying would just lock the account out slower.
        let mut retry_unauthorized = true;
        loop {
            let mut request = self.agent.request(method, &self.build_url(path));
            request = request.set("Accept", "application/json");
            for (key, value) in query {
                request = request.query(key, value);
            }
            if require_auth {
                request = request.set("X-Client-Token", &self.ensure_token()?);
            }

            let outcome = match &body {
                Some(payload) => request.send_json(payload.clone()),
                None => request.call(),
            };

            let (status, parsed) = match outcome {
                Ok(response) => {
                    let status = response.status();
                    (status, parse_body(response))
                }
                Err(ureq::Error::Status(status, response)) => (status, parse_body(response)),
                Err(ureq::Error::Transport(transport)) => {
                    return Err(ToolError::new(format!("Network error: {transport}")));
                }
            };

            if status == 401 && require_auth && retry_unauthorized {
                *self.token.borrow_mut() = None;
                retry_unauthorized = false;
                continue;
            }

            if !(200..300).contains(&status) {
                return Err(ToolError::http(
                    format!("Checkvist API request failed with status {status}."),
                    Some(status),
                    Some(parsed),
                ));
            }

            return Ok(parsed);
        }
    }

    fn ensure_token(&self) -> Result<String> {
        if let Some(token) = self.token.borrow().clone() {
            return Ok(token);
        }
        self.login()?;
        self.token
            .borrow()
            .clone()
            .ok_or_else(|| ToolError::new("Authentication failed."))
    }

    pub fn login(&self) -> Result<()> {
        if !self.config.has_credentials() {
            return Err(ToolError::new(
                "Missing credentials. Set CHECKVIST_USERNAME and CHECKVIST_REMOTE_KEY.",
            ));
        }
        let payload = json!({
            "username": self.config.username,
            "remote_key": self.config.remote_key,
        });
        let response = self.request("POST", "/auth/login.json", &[], Some(payload), false)?;

        let token = match &response {
            Value::Object(_) => response.get("token").and_then(Value::as_str).map(str::trim),
            Value::String(text) => Some(text.trim().trim_matches('"')),
            _ => None,
        }
        .filter(|token| !token.is_empty())
        .ok_or_else(|| ToolError::new("Authentication response did not include a token."))?;

        *self.token.borrow_mut() = Some(token.to_string());
        Ok(())
    }

    pub fn resolve_list_id(&self, explicit: Option<&str>) -> Result<String> {
        let explicit = explicit.unwrap_or("").trim();
        let list_id = if explicit.is_empty() {
            self.config.default_list_id.as_str()
        } else {
            explicit
        };
        if list_id.is_empty() {
            return Err(ToolError::new(
                "Missing list ID. Set CHECKVIST_LIST_ID or pass list_id.",
            ));
        }
        Ok(list_id.to_string())
    }

    pub fn list_lists(&self) -> Result<Vec<Value>> {
        let response = self.request("GET", "/checklists.json", &[], None, true)?;
        let Value::Array(items) = response else {
            return Err(ToolError::http(
                "Unexpected response while listing checklists.",
                None,
                Some(response),
            ));
        };
        Ok(items
            .into_iter()
            .filter(|item| item.is_object() && item.get("archived") != Some(&Value::Bool(true)))
            .collect())
    }

    pub fn fetch_tasks(
        &self,
        list_id: &str,
        include_closed: bool,
        with_notes: bool,
    ) -> Result<Vec<Value>> {
        let response = self.request(
            "GET",
            &format!("/checklists/{list_id}/tasks.json"),
            &[("with_notes", if with_notes { "true" } else { "false" })],
            None,
            true,
        )?;
        let Value::Array(items) = response else {
            return Err(ToolError::http(
                "Unexpected response while fetching tasks.",
                None,
                Some(response),
            ));
        };

        let mut tasks: Vec<Value> = items.into_iter().filter(Value::is_object).collect();
        if !include_closed {
            tasks.retain(|task| status_of(task) == 0);
        }
        Ok(depth_first_tasks(tasks))
    }

    pub fn create_task(
        &self,
        list_id: &str,
        content: &str,
        parent_id: Option<i64>,
        position: Option<i64>,
        due: Option<&str>,
    ) -> Result<Value> {
        let mut task = serde_json::Map::new();
        task.insert("content".into(), json!(content));
        if let Some(parent_id) = parent_id {
            task.insert("parent_id".into(), json!(parent_id));
        }
        if let Some(position) = position {
            task.insert("position".into(), json!(position));
        }
        if let Some(due) = due {
            task.insert("due".into(), json!(due));
        }

        let response = self.request(
            "POST",
            &format!("/checklists/{list_id}/tasks.json"),
            &[("parse", "true")],
            Some(json!({ "task": task })),
            true,
        )?;
        if !response.is_object() {
            return Err(ToolError::http(
                "Unexpected response while creating task.",
                None,
                Some(response),
            ));
        }
        Ok(response)
    }

    pub fn update_task(
        &self,
        list_id: &str,
        task_id: i64,
        content: Option<&str>,
        due: Option<&str>,
    ) -> Result<Value> {
        let mut payload = serde_json::Map::new();
        if let Some(content) = content {
            payload.insert("content".into(), json!(content));
        }
        if let Some(due) = due {
            payload.insert("due".into(), json!(due));
        }
        if payload.is_empty() {
            return Err(ToolError::new(
                "No updates provided. Pass content and/or due.",
            ));
        }
        self.put_task(list_id, task_id, Value::Object(payload))
    }

    /// Reorder within the current parent. Checkvist positions are 1-based.
    pub fn move_task(&self, list_id: &str, task_id: i64, position: i64) -> Result<Value> {
        self.put_task(list_id, task_id, json!({ "position": position }))
    }

    /// `parent_id = None` promotes to the list root.
    ///
    /// Sent explicitly as null rather than omitted: omitting the key means
    /// "leave the parent alone", which is a different request.
    pub fn reparent_task(
        &self,
        list_id: &str,
        task_id: i64,
        parent_id: Option<i64>,
    ) -> Result<Value> {
        let parent = parent_id.map_or(Value::Null, Value::from);
        self.put_task(list_id, task_id, json!({ "parent_id": parent }))
    }

    fn put_task(&self, list_id: &str, task_id: i64, task: Value) -> Result<Value> {
        let response = self.request(
            "PUT",
            &format!("/checklists/{list_id}/tasks/{task_id}.json"),
            &[],
            Some(json!({ "task": task })),
            true,
        )?;
        Ok(ok_or_wrapped(response))
    }

    pub fn create_list(&self, name: &str) -> Result<Value> {
        let response = self.request(
            "POST",
            "/checklists.json",
            &[],
            Some(json!({ "checklist": { "name": name } })),
            true,
        )?;
        Ok(ok_or_wrapped(response))
    }

    /// Notes are Checkvist "comments" — a separate resource from the task,
    /// which is why `update_task` cannot write them.
    pub fn add_note(&self, list_id: &str, task_id: i64, comment: &str) -> Result<Value> {
        let response = self.request(
            "POST",
            &format!("/checklists/{list_id}/tasks/{task_id}/comments.json"),
            &[],
            Some(json!({ "comment": { "comment": comment } })),
            true,
        )?;
        Ok(ok_or_wrapped(response))
    }

    pub fn task_action(&self, list_id: &str, task_id: i64, action: &str) -> Result<Value> {
        if !matches!(action, "close" | "reopen" | "invalidate") {
            return Err(ToolError::new(format!("Unsupported task action: {action}")));
        }
        let response = self.request(
            "POST",
            &format!("/checklists/{list_id}/tasks/{task_id}/{action}.json"),
            &[],
            None,
            true,
        )?;
        Ok(ok_or_wrapped(response))
    }

    pub fn delete_task(&self, list_id: &str, task_id: i64) -> Result<Value> {
        let response = self.request(
            "DELETE",
            &format!("/checklists/{list_id}/tasks/{task_id}.json"),
            &[],
            None,
            true,
        )?;
        Ok(ok_or_wrapped(response))
    }
}

fn parse_body(response: ureq::Response) -> Value {
    let Ok(text) = response.into_string() else {
        return Value::Null;
    };
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Value::Null;
    }
    serde_json::from_str(trimmed).unwrap_or_else(|_| Value::String(trimmed.to_string()))
}

/// Some endpoints answer with a bare `true` or an empty body. Wrapping keeps
/// every tool result an object, matching the other two servers.
fn ok_or_wrapped(response: Value) -> Value {
    if response.is_object() {
        response
    } else {
        json!({ "ok": true, "response": response })
    }
}

pub fn status_of(task: &Value) -> i64 {
    task.get("status").and_then(Value::as_i64).unwrap_or(0)
}

pub fn parent_id_of(task: &Value) -> i64 {
    match task.get("parent_id") {
        Some(Value::Number(number)) => number.as_i64().unwrap_or(0),
        Some(Value::String(text)) => text.parse().unwrap_or(0),
        _ => 0,
    }
}

/// Parents before children, siblings in `position` order — the order the app
/// shows, so a task list read here reads the same as the popover.
pub fn depth_first_tasks(tasks: Vec<Value>) -> Vec<Value> {
    let mut children_by_parent: Vec<(i64, Vec<Value>)> = Vec::new();
    for task in tasks {
        let parent_id = parent_id_of(&task);
        match children_by_parent
            .iter_mut()
            .find(|(id, _)| *id == parent_id)
        {
            Some((_, siblings)) => siblings.push(task),
            None => children_by_parent.push((parent_id, vec![task])),
        }
    }
    for (_, siblings) in &mut children_by_parent {
        siblings.sort_by_key(|task| task.get("position").and_then(Value::as_i64).unwrap_or(0));
    }

    let mut ordered = Vec::new();
    let mut visited: Vec<i64> = Vec::new();
    walk(0, &children_by_parent, &mut ordered, &mut visited);
    ordered
}

fn walk(
    parent_id: i64,
    children_by_parent: &[(i64, Vec<Value>)],
    ordered: &mut Vec<Value>,
    visited: &mut Vec<i64>,
) {
    // A parent cycle would otherwise recurse until the stack runs out. The API
    // should never return one; a malformed list should still produce a partial
    // answer rather than a crash.
    if visited.contains(&parent_id) {
        return;
    }
    visited.push(parent_id);

    let Some((_, children)) = children_by_parent.iter().find(|(id, _)| *id == parent_id) else {
        return;
    };
    for child in children {
        ordered.push(child.clone());
        if let Some(child_id) = child.get("id").and_then(Value::as_i64) {
            walk(child_id, children_by_parent, ordered, visited);
        }
    }
}
