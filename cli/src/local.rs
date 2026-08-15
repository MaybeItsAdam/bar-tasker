//! The state Priority keeps on this machine rather than in Checkvist.
//!
//! Priorities, recurrence rules, start dates, focus history and dailies have no
//! Checkvist representation, so anything limited to the API cannot see them.
//!
//! This is the third implementation of this logic. The Swift one
//! (`Priority/CoreLogic/`) is the tested original, the Python one
//! (`scripts/priority_mcp_server.py`) is the fallback server's port, and
//! `scripts/mcp_parity_check.py` drives all three against a fixture and diffs
//! both the answers and the files they leave behind. Change any rule in here
//! and that check is what tells you whether the other two agreed.

use crate::config::Config;
use crate::error::{Result, ToolError};
use crate::lock::FileLock;
use chrono::{DateTime, Datelike, Duration, Local, NaiveDate, TimeZone, Utc};
use serde_json::{Map, Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;

pub const BUNDLE_ID: &str = "uk.co.maybeitsadam.priority";
pub const DEFAULT_ROLLOVER_HOUR: u32 = 4;

const ALL_WEEKDAYS: [i64; 7] = [1, 2, 3, 4, 5, 6, 7];
const WEEKDAY_NAMES: [&str; 8] = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];

pub struct LocalState {
    pub store_directory: PathBuf,
    pub prefs_path: PathBuf,
}

impl LocalState {
    /// Environment, then the CLI's config file, then the app's own locations.
    ///
    /// The env vars are the ones the other two servers use, and they redirect
    /// both sources at fixture data for `scripts/mcp_parity_check.py`. The
    /// config keys exist so a machine without the app — or with it installed
    /// somewhere unusual — can still be pointed at a store.
    pub fn resolve(config: &Config) -> Self {
        LocalState {
            store_directory: config
                .resolve_path("PRIORITY_MCP_STORE_DIR", "store_directory")
                .0
                .unwrap_or_else(crate::config::default_store_directory),
            prefs_path: config
                .resolve_path("PRIORITY_MCP_PREFS_PATH", "prefs_path")
                .0
                .unwrap_or_else(|| crate::config::default_prefs_path(BUNDLE_ID)),
        }
    }

    // -- storage -------------------------------------------------------------

    fn prefs(&self) -> plist::Dictionary {
        match plist::Value::from_file(&self.prefs_path) {
            Ok(plist::Value::Dictionary(dictionary)) => dictionary,
            _ => plist::Dictionary::new(),
        }
    }

    /// A damaged line costs that event, not the whole history — the same
    /// tolerance as `DayLogFileStore.loadAll`.
    fn events(&self) -> Vec<Value> {
        let Ok(file) = std::fs::File::open(self.daylog_path()) else {
            return Vec::new();
        };
        BufReader::new(file)
            .lines()
            .map_while(std::result::Result::ok)
            .filter_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
            .collect()
    }

    fn dailies(&self) -> Vec<Value> {
        self.load_collection()
            .get("dailies")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default()
    }

    pub fn dailies_path(&self) -> PathBuf {
        self.store_directory.join("dailies.json")
    }

    pub fn daylog_path(&self) -> PathBuf {
        self.store_directory.join("daylog.jsonl")
    }

    // -- day boundary --------------------------------------------------------

    pub fn rollover_hour(&self) -> u32 {
        self.prefs()
            .get("dailyLogRolloverHour")
            .and_then(plist::Value::as_signed_integer)
            .map_or(DEFAULT_ROLLOVER_HOUR, |raw| raw.clamp(0, 23) as u32)
    }

    /// The instant the logical day containing `moment` began.
    ///
    /// Mirrors `DayBoundary.logicalDay`: shift back by the rollover hours, take
    /// the local calendar day that lands in, then re-anchor at the rollover
    /// hour. Anchoring by setting the hour rather than adding an offset is what
    /// keeps a DST transition from landing the anchor on the wrong day, and it
    /// is what makes this idempotent — these values are passed back in as day
    /// identifiers.
    pub fn logical_day(&self, moment: DateTime<Local>) -> DateTime<Local> {
        let hour = self.rollover_hour();
        let shifted = moment - Duration::hours(i64::from(hour));
        local_at(shifted.date_naive(), hour)
    }

    pub fn day_key(&self, moment: DateTime<Local>) -> String {
        self.logical_day(moment).format("%Y-%m-%d").to_string()
    }

    /// The `count` logical days ending on (and including) the day containing
    /// `moment`, oldest first.
    fn days_ending_on(&self, moment: DateTime<Local>, count: i64) -> Vec<DateTime<Local>> {
        let anchor = self.logical_day(moment);
        let hour = self.rollover_hour();
        (0..count)
            .rev()
            // Calendar-day arithmetic, not 24-hour arithmetic, matching
            // `Calendar.date(byAdding: .day)`: across a DST change the two
            // differ by an hour, which is enough to key an event to the
            // neighbouring day.
            .filter_map(|offset| {
                anchor
                    .date_naive()
                    .checked_sub_days(chrono::Days::new(offset as u64))
            })
            .map(|date| local_at(date, hour))
            .collect()
    }

    // -- aggregation ---------------------------------------------------------

    /// Completion events that survive their compensating reopens. A reopen
    /// cancels the most recent surviving completion of the same task, whenever
    /// that completion happened.
    fn net_completions(events: &[Value]) -> Vec<&Value> {
        let mut open_by_task: Vec<(Value, Vec<usize>)> = Vec::new();
        let mut cancelled: Vec<usize> = Vec::new();

        for (index, event) in events.iter().enumerate() {
            let task_id = event.get("taskId").cloned().unwrap_or(Value::Null);
            match kind_of(event) {
                "completed" => match open_by_task.iter_mut().find(|(id, _)| *id == task_id) {
                    Some((_, pending)) => pending.push(index),
                    None => open_by_task.push((task_id, vec![index])),
                },
                "reopened" => {
                    if let Some((_, pending)) =
                        open_by_task.iter_mut().find(|(id, _)| *id == task_id)
                        && let Some(latest) = pending.pop()
                    {
                        cancelled.push(latest);
                    }
                }
                _ => {}
            }
        }

        events
            .iter()
            .enumerate()
            .filter(|(index, event)| kind_of(event) == "completed" && !cancelled.contains(index))
            .map(|(_, event)| event)
            .collect()
    }

    /// Netted *within* the day: a daily is asked afresh each morning, so an
    /// un-tick can never reach back to a previous day.
    fn completed_daily_ids(&self, events: &[Value], on: DateTime<Local>) -> Vec<String> {
        let key = self.day_key(on);
        let mut completed: Vec<String> = Vec::new();

        for event in events {
            let Some(at) = parse_at(event.get("at")) else {
                continue;
            };
            if self.day_key(at) != key {
                continue;
            }
            let Some(daily_id) = event.get("dailyId").and_then(Value::as_str) else {
                continue;
            };
            if daily_id.is_empty() {
                continue;
            }
            match kind_of(event) {
                "dailyCompleted" => {
                    if !completed.iter().any(|id| id == daily_id) {
                        completed.push(daily_id.to_string());
                    }
                }
                "dailyUncompleted" => completed.retain(|id| id != daily_id),
                _ => {}
            }
        }
        completed
    }

    fn ordered_unique_task_ids<'a>(events: impl Iterator<Item = &'a Value>) -> Vec<Value> {
        let mut ordered: Vec<Value> = Vec::new();
        for event in events {
            let task_id = event.get("taskId").cloned().unwrap_or(Value::Null);
            if !ordered.contains(&task_id) {
                ordered.push(task_id);
            }
        }
        ordered
    }

    fn summary(&self, events: &[Value], on: DateTime<Local>) -> Map<String, Value> {
        let key = self.day_key(on);
        let on_this_day: Vec<&Value> = events
            .iter()
            .filter(|event| parse_at(event.get("at")).is_some_and(|at| self.day_key(at) == key))
            .collect();

        // Netting runs over the whole log, not just this day: the reopen that
        // cancels one of today's completions may itself land tomorrow.
        let surviving = Self::net_completions(events);
        let completed: Vec<&&Value> = surviving
            .iter()
            .filter(|event| parse_at(event.get("at")).is_some_and(|at| self.day_key(at) == key))
            .collect();

        let mut planned: Vec<Value> = Vec::new();
        for event in &on_this_day {
            if kind_of(event) == "planSnapshot" {
                planned = event
                    .get("plannedTaskIds")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
            }
        }

        let deferred = Self::ordered_unique_task_ids(
            on_this_day
                .iter()
                .copied()
                .filter(|event| kind_of(event) == "deferred"),
        );
        let invalidated = Self::ordered_unique_task_ids(
            on_this_day
                .iter()
                .copied()
                .filter(|event| kind_of(event) == "invalidated"),
        );

        // Completions from any day settle a planned task, so something finished
        // before its snapshot day never shows up as outstanding.
        let mut closed: Vec<Value> = surviving
            .iter()
            .map(|event| event.get("taskId").cloned().unwrap_or(Value::Null))
            .collect();
        closed.extend(deferred.iter().cloned());
        closed.extend(invalidated.iter().cloned());
        let unfinished: Vec<Value> = planned
            .iter()
            .filter(|id| !closed.contains(id))
            .cloned()
            .collect();

        let focus_seconds: i64 = on_this_day
            .iter()
            .filter(|event| kind_of(event) == "focusSessionEnded")
            .filter_map(|event| event.get("durationSeconds").and_then(Value::as_i64))
            .sum();

        let completed_payload: Vec<Value> = completed
            .iter()
            .map(|event| {
                json!({
                    "task_id": event.get("taskId").cloned().unwrap_or(Value::Null),
                    "title": event.get("title").and_then(Value::as_str).unwrap_or(""),
                    "at": event.get("at").cloned().unwrap_or(Value::Null),
                })
            })
            .collect();

        let mut summary = Map::new();
        summary.insert("day".into(), json!(key));
        summary.insert("completed_count".into(), json!(completed.len()));
        summary.insert("planned_count".into(), json!(planned.len()));
        summary.insert("unfinished_count".into(), json!(unfinished.len()));
        summary.insert("focus_seconds".into(), json!(focus_seconds));
        summary.insert("completed".into(), json!(completed_payload));
        summary.insert("unfinished_task_ids".into(), json!(unfinished));
        summary.insert("deferred_task_ids".into(), json!(deferred));
        summary.insert("invalidated_task_ids".into(), json!(invalidated));
        summary
    }

    // -- dailies -------------------------------------------------------------

    fn is_archived(daily: &Value) -> bool {
        match daily.get("archivedAt") {
            None | Some(Value::Null) => false,
            Some(Value::String(text)) => !text.is_empty(),
            Some(Value::Bool(flag)) => *flag,
            Some(_) => true,
        }
    }

    fn sorted_dailies(dailies: &[Value]) -> Vec<Value> {
        let mut sorted = dailies.to_vec();
        sorted.sort_by_key(sort_key);
        sorted
    }

    fn active_weekdays_of(daily: &Value) -> Vec<i64> {
        daily
            .get("activeWeekdays")
            .and_then(Value::as_array)
            .map(|days| days.iter().filter_map(Value::as_i64).collect())
            .unwrap_or_default()
    }

    fn due_on(dailies: &[Value], day: DateTime<Local>) -> Vec<Value> {
        // `Calendar` weekday numbering, 1 = Sunday, matching
        // `Daily.activeWeekdays`.
        let weekday = i64::from(day.weekday().num_days_from_sunday()) + 1;
        Self::sorted_dailies(dailies)
            .into_iter()
            .filter(|daily| {
                !Self::is_archived(daily) && Self::active_weekdays_of(daily).contains(&weekday)
            })
            .collect()
    }

    fn schedule_label(daily: &Value) -> String {
        let mut weekdays = Self::active_weekdays_of(daily);
        weekdays.sort_unstable();
        weekdays.dedup();
        if weekdays == ALL_WEEKDAYS {
            return "Every day".into();
        }
        if weekdays == [2, 3, 4, 5, 6] {
            return "Weekdays".into();
        }
        weekdays
            .iter()
            .map(|day| WEEKDAY_NAMES.get(*day as usize).copied().unwrap_or(""))
            .collect::<Vec<_>>()
            .join(" ")
    }

    // -- tool payloads -------------------------------------------------------

    pub fn day_summaries(&self, ending_on: DateTime<Local>, count: i64) -> Vec<Value> {
        let events = self.events();
        let dailies = self.dailies();

        let mut summaries = Vec::new();
        // Newest first, as the other two servers report it.
        for day in self.days_ending_on(ending_on, count).into_iter().rev() {
            let mut summary = self.summary(&events, day);
            let ticked = self.completed_daily_ids(&events, day);
            let due = Self::due_on(&dailies, self.logical_day(day));
            let payload: Vec<Value> = due
                .iter()
                .map(|daily| {
                    let id = daily.get("id").cloned().unwrap_or(Value::Null);
                    json!({
                        "id": id,
                        "title": daily.get("title").and_then(Value::as_str).unwrap_or(""),
                        "done": id.as_str().is_some_and(|id| ticked.iter().any(|t| t == id)),
                    })
                })
                .collect();
            summary.insert("dailies".into(), json!(payload));
            summaries.push(Value::Object(summary));
        }
        summaries
    }

    pub fn dailies_snapshot(&self, on: DateTime<Local>) -> Value {
        let events = self.events();
        let dailies = self.dailies();
        let ticked = self.completed_daily_ids(&events, on);
        let due_today: Vec<Value> = Self::due_on(&dailies, self.logical_day(on))
            .iter()
            .map(|daily| daily.get("id").cloned().unwrap_or(Value::Null))
            .collect();

        let active: Vec<Value> = dailies
            .iter()
            .filter(|daily| !Self::is_archived(daily))
            .cloned()
            .collect();

        let payload: Vec<Value> = Self::sorted_dailies(&active)
            .iter()
            .map(|daily| {
                let id = daily.get("id").cloned().unwrap_or(Value::Null);
                json!({
                    "id": id,
                    "title": daily.get("title").and_then(Value::as_str).unwrap_or(""),
                    "schedule": Self::schedule_label(daily),
                    "due_today": due_today.contains(&id),
                    "done": id.as_str().is_some_and(|id| ticked.iter().any(|t| t == id)),
                })
            })
            .collect();

        json!({ "day": self.day_key(on), "dailies": payload })
    }

    // -- writes --------------------------------------------------------------
    //
    // Only dailies are writable. Priorities, recurrence and start dates stay
    // read-only: they live in `UserDefaults`, which the running app holds in
    // memory and rewrites on its own schedule, so there is no equivalent of the
    // file lock that would let an external write survive.

    fn load_collection(&self) -> Value {
        let empty = || json!({ "version": 1, "dailies": [] });
        let Ok(text) = std::fs::read_to_string(self.dailies_path()) else {
            return empty();
        };
        let Ok(collection) = serde_json::from_str::<Value>(&text) else {
            return empty();
        };
        if !collection.get("dailies").is_some_and(Value::is_array) {
            return empty();
        }
        collection
    }

    fn save_collection(&self, collection: &Value) -> Result<()> {
        let path = self.dailies_path();
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|err| {
                ToolError::new(format!("Could not create {}: {err}", parent.display()))
            })?;
        }
        // Two-space indent with sorted keys, matching Swift's
        // `[.sortedKeys, .prettyPrinted]` and the Python server — this file is
        // small and a human opening it to fix a typo is reasonable.
        // `serde_json::Map` is a `BTreeMap`, so keys come out sorted already.
        let encoded = serde_json::to_string_pretty(collection)
            .map_err(|err| ToolError::new(format!("Could not encode dailies: {err}")))?;

        // Atomic, matching `DailyDefinitionsStore.save`: a crash mid-write must
        // leave the previous list intact rather than a half-written one.
        let temp_path = path.with_extension("json.tmp");
        std::fs::write(&temp_path, encoded).map_err(|err| {
            ToolError::new(format!("Could not write {}: {err}", temp_path.display()))
        })?;
        std::fs::rename(&temp_path, &path)
            .map_err(|err| ToolError::new(format!("Could not save {}: {err}", path.display())))
    }

    /// Read/modify/write with the file locked for the whole operation.
    ///
    /// The caller must express *what changed*, never hand over a snapshot it
    /// loaded earlier: two other processes edit the same file, and saving a
    /// stale snapshot silently erases whatever they added in the meantime.
    fn mutate_dailies(&self, transform: impl FnOnce(&mut Vec<Value>)) -> Result<Value> {
        let path = self.dailies_path();
        FileLock::protecting(&path).with_exclusive(|| {
            let mut collection = self.load_collection();
            let mut dailies = collection
                .get("dailies")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            transform(&mut dailies);
            collection["dailies"] = Value::Array(dailies);
            self.save_collection(&collection)?;
            Ok(collection)
        })
    }

    /// UTC, whole seconds, `Z` suffix.
    ///
    /// This must match Swift's `JSONDecoder.dateDecodingStrategy = .iso8601`
    /// exactly, which uses `.withInternetDateTime` and therefore **rejects
    /// fractional seconds**. A timestamp with microseconds fails that decode —
    /// and because `DailyDefinitionsStore.load()` treats a decode failure as an
    /// empty collection, the app would show no dailies at all and then save
    /// that emptiness back over the file. One timestamp, every daily gone.
    fn now_iso() -> String {
        Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
    }

    fn daily_payload(daily: &Value) -> Value {
        let mut weekdays = Self::active_weekdays_of(daily);
        weekdays.sort_unstable();
        weekdays.dedup();
        json!({
            "id": daily.get("id").cloned().unwrap_or(Value::Null),
            "title": daily.get("title").and_then(Value::as_str).unwrap_or(""),
            "schedule": Self::schedule_label(daily),
            "active_weekdays": weekdays,
            "archived": Self::is_archived(daily),
        })
    }

    pub fn add_daily(&self, title: &str, active_weekdays: Option<Vec<i64>>) -> Result<Value> {
        let trimmed = title.trim();
        if trimmed.is_empty() {
            return Err(ToolError::new("title must not be empty."));
        }
        let weekdays = match active_weekdays {
            Some(days) if !days.is_empty() => {
                let mut days = days;
                days.sort_unstable();
                days.dedup();
                days
            }
            _ => ALL_WEEKDAYS.to_vec(),
        };

        // Uppercase to match Swift's `UUID().uuidString`, which is what every
        // id already in the file looks like.
        let id = uuid::Uuid::new_v4().to_string().to_uppercase();
        let mut daily = json!({
            "id": id,
            "title": trimmed,
            "activeWeekdays": weekdays,
            "sortIndex": 0,
            "createdAt": Self::now_iso(),
        });

        let saved = self.mutate_dailies(|dailies| {
            // Appended at the end of the current order, as `DailyCollection.add`.
            let next = dailies
                .iter()
                .filter_map(|existing| existing.get("sortIndex").and_then(Value::as_i64))
                .max()
                .unwrap_or(-1)
                + 1;
            daily["sortIndex"] = json!(next);
            dailies.push(daily.clone());
        })?;

        find_daily(&saved, &id)
            .map(|stored| Self::daily_payload(&stored))
            .ok_or_else(|| ToolError::new("The daily was not saved."))
    }

    pub fn update_daily(
        &self,
        daily_id: &str,
        title: Option<&str>,
        active_weekdays: Option<Vec<i64>>,
        archived: Option<bool>,
    ) -> Result<Value> {
        if find_daily(&self.load_collection(), daily_id).is_none() {
            return Err(ToolError::new(format!("No daily with id {daily_id}.")));
        }

        let saved = self.mutate_dailies(|dailies| {
            for daily in dailies.iter_mut() {
                if daily.get("id").and_then(Value::as_str) != Some(daily_id) {
                    continue;
                }
                if let Some(title) = title
                    && !title.trim().is_empty()
                {
                    daily["title"] = json!(title.trim());
                }
                if let Some(days) = &active_weekdays
                    && !days.is_empty()
                {
                    let mut days = days.clone();
                    days.sort_unstable();
                    days.dedup();
                    daily["activeWeekdays"] = json!(days);
                }
                if let Some(archived) = archived
                    && let Some(object) = daily.as_object_mut()
                {
                    // Archive rather than delete, so history referencing this id
                    // still renders with a title instead of as an orphan.
                    if archived {
                        object
                            .entry("archivedAt")
                            .or_insert_with(|| json!(Self::now_iso()));
                    } else {
                        object.remove("archivedAt");
                    }
                }
            }
        })?;

        find_daily(&saved, daily_id)
            .map(|stored| Self::daily_payload(&stored))
            .ok_or_else(|| ToolError::new(format!("No daily with id {daily_id}.")))
    }

    /// Ticks by appending to the log, as `DailyLogService.setDaily` does — the
    /// tick is a fact about a day, not a field on the daily.
    pub fn set_daily(&self, daily_id: &str, done: bool) -> Result<Value> {
        let daily = find_daily(&self.load_collection(), daily_id)
            .ok_or_else(|| ToolError::new(format!("No daily with id {daily_id}.")))?;
        let title = daily
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();

        let now = Local::now();
        let already = self
            .completed_daily_ids(&self.events(), now)
            .iter()
            .any(|id| id == daily_id);
        if already == done {
            return Ok(json!({
                "id": daily_id, "title": title, "done": already,
                "day": self.day_key(now), "changed": false,
            }));
        }

        let event = json!({
            "kind": if done { "dailyCompleted" } else { "dailyUncompleted" },
            "at": Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string(),
            "taskId": 0,
            "title": title,
            "dailyId": daily_id,
        });

        let path = self.daylog_path();
        // Locked so a concurrent append from the app or the other servers
        // cannot splice a line — a spliced line is dropped by the tolerant
        // reader, losing both events.
        FileLock::protecting(&path).with_exclusive(|| {
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent).map_err(|err| {
                    ToolError::new(format!("Could not create {}: {err}", parent.display()))
                })?;
            }
            let mut file = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
                .map_err(|err| {
                    ToolError::new(format!("Could not open {}: {err}", path.display()))
                })?;
            writeln!(file, "{event}")
                .map_err(|err| ToolError::new(format!("Could not append to the day log: {err}")))
        })?;

        Ok(json!({
            "id": daily_id, "title": title, "done": done,
            "day": self.day_key(now), "changed": true,
        }))
    }

    /// Drop non-positive and duplicate ids, preserving order — matches
    /// `normalizedQueue` in both Swift stores.
    fn normalized_queue(queue: Option<&Value>) -> Vec<i64> {
        let Some(Value::Array(items)) = queue else {
            return Vec::new();
        };
        let mut normalized: Vec<i64> = Vec::new();
        for item in items {
            // `as_i64` rejects booleans and floats, which is what the Python
            // `isinstance(raw, int) and not isinstance(raw, bool)` guard does.
            let Some(id) = item.as_i64() else { continue };
            if id <= 0 || normalized.contains(&id) {
                continue;
            }
            normalized.push(id);
        }
        normalized
    }

    pub fn task_metadata(&self, list_id: &str) -> Value {
        let prefs = self.prefs();

        // Empty list id is the offline scope, matching `ListScopedPriorityStore`.
        let scope = if list_id.is_empty() {
            "__offline__"
        } else {
            list_id
        };

        // The two stores are encoded differently and it is load-bearing:
        // `ListScopedPriorityStore` writes a JSON blob via `defaults.set(Data)`,
        // while `ListScopedTaskIDStore` writes a plain plist dictionary.
        // Reading either one the other's way yields silently empty results.
        let scoped_all = match prefs.get("priorityTaskIdsByParentIdByListId") {
            Some(plist::Value::Data(bytes)) => {
                serde_json::from_slice::<Value>(bytes).unwrap_or(Value::Null)
            }
            _ => Value::Null,
        };

        let mut scoped_ranks = Map::new();
        if let Some(by_parent) = scoped_all.get(scope).and_then(Value::as_object) {
            for (parent_id, queue) in by_parent {
                // Parent keys that aren't integers are dropped, as `Int(key)` does.
                if parent_id.parse::<i64>().is_err() {
                    continue;
                }
                let normalized = Self::normalized_queue(Some(queue));
                if normalized.is_empty() {
                    continue;
                }
                scoped_ranks.insert(parent_id.clone(), ranks_of(&normalized));
            }
        }

        let absolute_queue = match prefs.get("absolutePriorityTaskIdsByListId") {
            Some(plist::Value::Dictionary(by_list)) => {
                Self::normalized_queue(by_list.get(scope).map(plist_to_json).as_ref())
            }
            _ => Vec::new(),
        };

        json!({
            "list_id": list_id,
            "scoped_priority_rank_by_parent_id": Value::Object(scoped_ranks),
            "absolute_priority_rank": ranks_of(&absolute_queue),
            "recurrence_rule_by_task_id": prefs
                .get("recurrenceRulesByTaskId")
                .map_or_else(|| json!({}), plist_to_json),
            "start_date_by_task_id": prefs
                .get("taskStartDatesByTaskId")
                .map_or_else(|| json!({}), plist_to_json),
        })
    }
}

// -- helpers -----------------------------------------------------------------

fn kind_of(event: &Value) -> &str {
    event.get("kind").and_then(Value::as_str).unwrap_or("")
}

/// The event's `at` as a local instant, or `None` if it is missing or
/// unparseable — a bad timestamp costs that event, not the whole read.
fn parse_at(raw: Option<&Value>) -> Option<DateTime<Local>> {
    let text = raw?.as_str()?;
    DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|parsed| parsed.with_timezone(&Local))
}

/// `date` at `hour` local time, resolving the two DST edge cases rather than
/// failing: a skipped hour steps forward to the first valid instant, an
/// ambiguous one takes the earlier offset.
fn local_at(date: NaiveDate, hour: u32) -> DateTime<Local> {
    for candidate_hour in hour..24 {
        if let Some(naive) = date.and_hms_opt(candidate_hour, 0, 0)
            && let Some(resolved) = Local.from_local_datetime(&naive).earliest()
        {
            return resolved;
        }
    }
    // Unreachable for a real calendar; falling back to the day's start keeps
    // this total rather than panicking on a date library surprise.
    Local
        .from_local_datetime(&date.and_hms_opt(0, 0, 0).unwrap_or_default())
        .earliest()
        .unwrap_or_else(Local::now)
}

fn sort_key(daily: &Value) -> (i64, String) {
    (
        daily.get("sortIndex").and_then(Value::as_i64).unwrap_or(0),
        daily
            .get("createdAt")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
    )
}

fn find_daily(collection: &Value, daily_id: &str) -> Option<Value> {
    collection
        .get("dailies")?
        .as_array()?
        .iter()
        .find(|daily| daily.get("id").and_then(Value::as_str) == Some(daily_id))
        .cloned()
}

/// 1-based ranks, keyed by task id as a string.
fn ranks_of(queue: &[i64]) -> Value {
    let ranks: Map<String, Value> = queue
        .iter()
        .enumerate()
        .map(|(index, task_id)| (task_id.to_string(), json!(index + 1)))
        .collect();
    Value::Object(ranks)
}

/// Enough of a plist to render the metadata dictionaries as JSON.
///
/// `Data` becomes null: the only `Data` value in these preferences is the
/// scoped-priority blob, which is read as JSON above rather than through here,
/// and Python's `json.dumps` would raise on bytes rather than emit anything.
fn plist_to_json(value: &plist::Value) -> Value {
    match value {
        plist::Value::String(text) => json!(text),
        plist::Value::Integer(number) => number
            .as_signed()
            .map(Value::from)
            .or_else(|| number.as_unsigned().map(Value::from))
            .unwrap_or(Value::Null),
        plist::Value::Real(number) => json!(number),
        plist::Value::Boolean(flag) => json!(flag),
        plist::Value::Array(items) => Value::Array(items.iter().map(plist_to_json).collect()),
        plist::Value::Dictionary(entries) => Value::Object(
            entries
                .iter()
                .map(|(key, item)| (key.clone(), plist_to_json(item)))
                .collect(),
        ),
        plist::Value::Date(date) => json!(date.to_xml_format()),
        _ => Value::Null,
    }
}
