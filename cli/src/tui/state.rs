//! The TUI's state, and the pure transitions over it.
//!
//! Deliberately free of `ratatui` and `crossterm`: everything here is data in,
//! data out, so the tab layouts and the selection behaviour are testable
//! without a terminal. `render.rs` turns this into widgets, and `mod.rs` drives
//! it from key events.
//!
//! The tabs mirror the app's root views, down to the keys that jump to them —
//! `q` `w` `e` `r`, as in `KeyboardShortcutRouter`. Someone who knows the
//! popover should not have to learn a second set of habits for the terminal.

use crate::checkvist::{parent_id_of, status_of};
use chrono::Local;
use serde_json::Value;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tab {
    All,
    Due,
    Tags,
    Priority,
    Kanban,
    Matrix,
    Daily,
}

impl Tab {
    /// Left-to-right order, matching the app's root views.
    pub const ORDER: [Tab; 7] = [
        Tab::All,
        Tab::Due,
        Tab::Tags,
        Tab::Priority,
        Tab::Kanban,
        Tab::Matrix,
        Tab::Daily,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Tab::All => "All",
            Tab::Due => "Due",
            Tab::Tags => "Tags",
            Tab::Priority => "Priority",
            Tab::Kanban => "Kanban",
            Tab::Matrix => "Matrix",
            Tab::Daily => "Daily",
        }
    }

    /// The key that jumps straight here, as in the app.
    pub fn jump_key(self) -> char {
        match self {
            Tab::All => 'q',
            Tab::Due => 'w',
            Tab::Tags => 'e',
            Tab::Priority => 'r',
            Tab::Kanban => 't',
            Tab::Matrix => 'y',
            // The app uses `Shift+T`, which a terminal reports inconsistently
            // across emulators; `d` is unclaimed and unambiguous.
            Tab::Daily => 'd',
        }
    }

    pub fn from_jump_key(key: char) -> Option<Tab> {
        Tab::ORDER.into_iter().find(|tab| tab.jump_key() == key)
    }

    fn index(self) -> usize {
        Tab::ORDER.iter().position(|tab| *tab == self).unwrap_or(0)
    }

    pub fn cycled(self, delta: isize) -> Tab {
        let count = Tab::ORDER.len() as isize;
        let next = (self.index() as isize + delta).rem_euclid(count);
        Tab::ORDER[next as usize]
    }

    /// Whether this tab needs Checkvist. The local tabs keep working when
    /// there are no credentials, which is the state a new install is in.
    pub fn needs_checkvist(self) -> bool {
        self != Tab::Daily
    }
}

/// One line in the list. Headers and notes are drawn but never selected, so
/// moving the cursor steps over them rather than landing on a group title.
#[derive(Clone, PartialEq, Debug)]
pub enum Row {
    Header(String),
    Note(String),
    Task {
        index: usize,
        depth: usize,
        badge: Option<String>,
    },
    Daily {
        index: usize,
    },
}

impl Row {
    pub fn is_selectable(&self) -> bool {
        matches!(self, Row::Task { .. } | Row::Daily { .. })
    }
}

/// Everything fetched, plus whatever went wrong fetching it.
#[derive(Default)]
pub struct Data {
    pub tasks: Vec<Value>,
    /// The `dailies_list` payload.
    pub dailies: Value,
    /// Today's entry from `daily_log_fetch`.
    pub today: Option<Value>,
    /// The `task_metadata` payload, for priority ranks.
    pub metadata: Value,
    /// Set when the Checkvist-backed tools failed — missing credentials, or
    /// offline. The local tabs stay usable, so this is shown rather than fatal.
    pub task_error: Option<String>,
}

impl Data {
    pub fn dailies_list(&self) -> &[Value] {
        self.dailies
            .get("dailies")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[])
    }

    pub fn task(&self, index: usize) -> Option<&Value> {
        self.tasks.get(index)
    }

    pub fn daily(&self, index: usize) -> Option<&Value> {
        self.dailies_list().get(index)
    }
}

pub struct App {
    pub data: Data,
    pub tab: Tab,
    pub selected: usize,
    /// The task whose subtasks the All tab is scoped to, as `h`/`l` walk the
    /// tree. `None` is the list root.
    pub scope: Option<i64>,
    pub status: Option<String>,
    /// The text being typed after `a`. `Some` means every key goes to the
    /// buffer rather than to the bindings.
    pub input: Option<String>,
    pub show_help: bool,
    pub should_quit: bool,
}

impl App {
    pub fn new(data: Data) -> Self {
        let mut app = App {
            data,
            tab: Tab::All,
            selected: 0,
            scope: None,
            status: None,
            input: None,
            show_help: false,
            should_quit: false,
        };
        app.clamp_selection();
        app
    }

    pub fn rows(&self) -> Vec<Row> {
        rows_for(self.tab, &self.data, self.scope)
    }

    pub fn selected_row(&self) -> Option<Row> {
        self.rows().get(self.selected).cloned()
    }

    pub fn selected_task_id(&self) -> Option<i64> {
        match self.selected_row()? {
            Row::Task { index, .. } => self.data.task(index)?.get("id")?.as_i64(),
            _ => None,
        }
    }

    pub fn selected_daily_id(&self) -> Option<String> {
        match self.selected_row()? {
            Row::Daily { index } => Some(self.data.daily(index)?.get("id")?.as_str()?.to_string()),
            _ => None,
        }
    }

    /// Moves by `delta`, skipping headers and notes, and stopping at the ends
    /// rather than wrapping — wrapping in a long list loses your place.
    pub fn move_selection(&mut self, delta: isize) {
        let rows = self.rows();
        if rows.is_empty() {
            self.selected = 0;
            return;
        }
        let step = if delta >= 0 { 1_isize } else { -1 };
        let mut cursor = self.selected as isize;
        for _ in 0..delta.abs() {
            let mut next = cursor + step;
            while next >= 0 && (next as usize) < rows.len() && !rows[next as usize].is_selectable()
            {
                next += step;
            }
            if next < 0 || next as usize >= rows.len() {
                break;
            }
            cursor = next;
        }
        self.selected = cursor.max(0) as usize;
    }

    pub fn select_tab(&mut self, tab: Tab) {
        if self.tab == tab {
            return;
        }
        self.tab = tab;
        self.selected = 0;
        self.clamp_selection();
    }

    /// Lands on the first selectable row, so an empty or header-led tab never
    /// leaves the cursor on something that can't be acted on.
    pub fn clamp_selection(&mut self) {
        let rows = self.rows();
        if rows.is_empty() {
            self.selected = 0;
            return;
        }
        if self.selected >= rows.len() {
            self.selected = rows.len() - 1;
        }
        if !rows[self.selected].is_selectable() {
            let forward = (self.selected..rows.len()).find(|i| rows[*i].is_selectable());
            let backward = (0..=self.selected).rev().find(|i| rows[*i].is_selectable());
            self.selected = forward.or(backward).unwrap_or(0);
        }
    }

    /// `l` — descend into the selected task's subtasks, if it has any.
    pub fn enter_scope(&mut self) {
        guard_all_tab(self, |app| {
            let Some(id) = app.selected_task_id() else {
                return;
            };
            if !app.data.tasks.iter().any(|task| parent_id_of(task) == id) {
                app.status = Some("No subtasks".into());
                return;
            }
            app.scope = Some(id);
            app.selected = 0;
            app.clamp_selection();
        });
    }

    /// `h` — back out to the parent of whatever we're scoped to.
    pub fn exit_scope(&mut self) {
        guard_all_tab(self, |app| {
            let Some(current) = app.scope else { return };
            let parent = app
                .data
                .tasks
                .iter()
                .find(|task| task.get("id").and_then(Value::as_i64) == Some(current))
                .map(parent_id_of)
                .filter(|parent| *parent != 0);
            app.scope = parent;
            app.selected = 0;
            app.clamp_selection();
        });
    }

    /// The task the scope is on, for the header line.
    pub fn scope_title(&self) -> Option<String> {
        let id = self.scope?;
        self.data
            .tasks
            .iter()
            .find(|task| task.get("id").and_then(Value::as_i64) == Some(id))
            .and_then(|task| task.get("content").and_then(Value::as_str))
            .map(str::to_string)
    }
}

fn guard_all_tab(app: &mut App, body: impl FnOnce(&mut App)) {
    if app.tab == Tab::All {
        body(app);
    }
}

// -- row building -------------------------------------------------------------

pub fn rows_for(tab: Tab, data: &Data, scope: Option<i64>) -> Vec<Row> {
    if tab.needs_checkvist()
        && let Some(error) = &data.task_error
    {
        return vec![
            Row::Note(error.clone()),
            Row::Note("Press F5 to retry.".into()),
        ];
    }

    match tab {
        Tab::All => all_rows(data, scope),
        Tab::Due => due_rows(data),
        Tab::Tags => tag_rows(data),
        Tab::Priority => priority_rows(data),
        Tab::Kanban => kanban_rows(data),
        Tab::Matrix => matrix_rows(data),
        Tab::Daily => daily_rows(data),
    }
}

// -- kanban -------------------------------------------------------------------

/// `RootDueBucket`, by raw value — the numbering `kanban_columns` uses.
mod bucket {
    pub const OVERDUE: i64 = 0;
    pub const ASAP: i64 = 1;
    pub const TODAY: i64 = 2;
    pub const TOMORROW: i64 = 3;
    pub const NEXT_SEVEN_DAYS: i64 = 4;
    pub const FUTURE: i64 = 5;
    pub const NO_DUE_DATE: i64 = 6;
}

/// A faithful port of `TaskFilterEngine.classifyDueBucket`.
///
/// The board is only as right as this is: put a task in the wrong bucket and it
/// lands in the wrong column, which reads as the terminal disagreeing with the
/// app about your day.
pub fn due_bucket(task: &Value, today: chrono::NaiveDate) -> i64 {
    let due = task
        .get("due")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_lowercase();
    if due.is_empty() {
        return bucket::NO_DUE_DATE;
    }
    match due.as_str() {
        "asap" => return bucket::ASAP,
        "today" => return bucket::TODAY,
        "tomorrow" | "tmr" => return bucket::TOMORROW,
        "next week" | "next 7 days" => return bucket::NEXT_SEVEN_DAYS,
        _ => {}
    }

    // Checkvist may append a time; the date is the leading `YYYY-MM-DD`. An
    // unparseable due is "future", matching a nil `dueDate` on the Swift side.
    let Some(date) = due
        .get(..10)
        .and_then(|head| chrono::NaiveDate::parse_from_str(head, "%Y-%m-%d").ok())
    else {
        return bucket::FUTURE;
    };

    if date < today {
        return bucket::OVERDUE;
    }
    if date == today {
        return bucket::TODAY;
    }
    if Some(date) == today.succ_opt() {
        return bucket::TOMORROW;
    }
    // `todayStart + 8 days`, exclusive — so today+7 is still "next 7 days".
    match today.checked_add_days(chrono::Days::new(8)) {
        Some(limit) if date < limit => bucket::NEXT_SEVEN_DAYS,
        _ => bucket::FUTURE,
    }
}

fn condition_matches(condition: &Value, task: &Value, today: chrono::NaiveDate) -> bool {
    match condition.get("kind").and_then(Value::as_str) {
        Some("tag") => {
            let wanted = condition
                .get("tag")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim_start_matches(['#', '@'])
                .to_lowercase();
            !wanted.is_empty() && tags_of(task).iter().any(|tag| tag.to_lowercase() == wanted)
        }
        Some("due_bucket") => {
            condition.get("bucket_id").and_then(Value::as_i64) == Some(due_bucket(task, today))
        }
        // Handled separately: catch-all takes what the earlier columns left,
        // so it cannot be evaluated in the same pass as the real conditions.
        _ => false,
    }
}

fn kanban_rows(data: &Data) -> Vec<Row> {
    let columns = data
        .metadata
        .get("kanban_columns")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    if columns.is_empty() {
        return vec![Row::Note(
            "No columns configured. Set them up in the app.".into(),
        )];
    }

    let today = Local::now().date_naive();
    let mut members: Vec<Vec<usize>> = vec![Vec::new(); columns.len()];
    let catch_all = columns.iter().position(|column| {
        column
            .get("conditions")
            .and_then(Value::as_array)
            .is_some_and(|conditions| {
                conditions
                    .iter()
                    .any(|c| c.get("kind").and_then(Value::as_str) == Some("catch_all"))
            })
    });

    for (index, task) in data.tasks.iter().enumerate() {
        // Columns are evaluated in order and a task belongs to the first it
        // matches, exactly as `KanbanManager.columnForTask` decides.
        let placed = columns.iter().position(|column| {
            column
                .get("conditions")
                .and_then(Value::as_array)
                .is_some_and(|conditions| {
                    conditions
                        .iter()
                        .any(|condition| condition_matches(condition, task, today))
                })
        });
        match placed.or(catch_all) {
            Some(column) => members[column].push(index),
            None => continue,
        }
    }

    let mut rows = Vec::new();
    for (column, tasks) in columns.iter().zip(&members) {
        let name = column.get("name").and_then(Value::as_str).unwrap_or("");
        rows.push(Row::Header(format!("{name}  ({})", tasks.len())));
        for index in tasks {
            rows.push(Row::Task {
                index: *index,
                depth: 0,
                badge: data
                    .task(*index)
                    .and_then(|task| task.get("due").and_then(Value::as_str))
                    .filter(|due| !due.is_empty())
                    .map(str::to_string),
            });
        }
    }
    rows
}

// -- matrix -------------------------------------------------------------------

/// The four Eisenhower quadrants, as `EisenhowerMatrixView` labels them:
/// urgency is the X axis and importance the Y, both centred on zero.
fn matrix_rows(data: &Data) -> Vec<Row> {
    let Some(levels) = data
        .metadata
        .get("eisenhower_by_task_id")
        .and_then(Value::as_object)
    else {
        return vec![Row::Note("Nothing placed on the matrix yet.".into())];
    };

    let mut placed: Vec<(usize, f64, f64)> = Vec::new();
    for (task_id, level) in levels {
        let Ok(id) = task_id.parse::<i64>() else {
            continue;
        };
        let Some(index) = data
            .tasks
            .iter()
            .position(|task| task.get("id").and_then(Value::as_i64) == Some(id))
        else {
            continue;
        };
        let axis = |key: &str| level.get(key).and_then(Value::as_f64).unwrap_or(0.0);
        let (urgency, importance) = (axis("urgency"), axis("importance"));
        // The app plots only what has been placed; a task at the origin has
        // not been judged, and showing it as "eliminate" would be a lie.
        if urgency != 0.0 || importance != 0.0 {
            placed.push((index, urgency, importance));
        }
    }

    let mut rows = Vec::new();
    for (label, urgent, important) in [
        ("DO — urgent & important", true, true),
        ("SCHEDULE — important, not urgent", false, true),
        ("DELEGATE — urgent, not important", true, false),
        ("ELIMINATE — neither", false, false),
    ] {
        let group: Vec<&(usize, f64, f64)> = placed
            .iter()
            .filter(|(_, urgency, importance)| {
                (*urgency > 0.0) == urgent && (*importance > 0.0) == important
            })
            .collect();
        if group.is_empty() {
            continue;
        }
        rows.push(Row::Header(format!("{label}  ({})", group.len())));
        for (index, urgency, importance) in group {
            rows.push(Row::Task {
                index: *index,
                depth: 0,
                badge: Some(format!("U{urgency:.0} I{importance:.0}")),
            });
        }
    }

    if rows.is_empty() {
        rows.push(Row::Note(
            "Nothing placed on the matrix yet. Use `m` in the app.".into(),
        ));
    }
    rows
}

/// The tree as Checkvist returned it — already parents-before-children — with
/// depth taken from each task's parent chain.
fn all_rows(data: &Data, scope: Option<i64>) -> Vec<Row> {
    let root = scope.unwrap_or(0);
    let mut rows = Vec::new();
    for (index, task) in data.tasks.iter().enumerate() {
        let Some(depth) = depth_within(data, task, root) else {
            continue;
        };
        rows.push(Row::Task {
            index,
            depth,
            badge: None,
        });
    }
    if rows.is_empty() {
        rows.push(Row::Note(if scope.is_some() {
            "No subtasks here.".into()
        } else {
            "Nothing open. Add one with `a`.".into()
        }));
    }
    rows
}

/// How far below `root` this task sits, or `None` if it isn't below it at all.
fn depth_within(data: &Data, task: &Value, root: i64) -> Option<usize> {
    let mut parent = parent_id_of(task);
    // Bounded rather than `loop`: a malformed parent cycle must not spin here.
    for depth in 0..64 {
        if parent == root {
            return Some(depth);
        }
        if parent == 0 {
            return None;
        }
        let next = data
            .tasks
            .iter()
            .find(|candidate| candidate.get("id").and_then(Value::as_i64) == Some(parent))?;
        parent = parent_id_of(next);
    }
    None
}

fn due_rows(data: &Data) -> Vec<Row> {
    let today = Local::now().format("%Y-%m-%d").to_string();

    let mut dated: Vec<(usize, String)> = data
        .tasks
        .iter()
        .enumerate()
        .filter_map(|(index, task)| {
            let due = task.get("due").and_then(Value::as_str)?;
            (!due.is_empty()).then(|| (index, due.to_string()))
        })
        .collect();
    // Checkvist serialises `due` as YYYY-MM-DD, which sorts correctly as text.
    dated.sort_by(|left, right| left.1.cmp(&right.1));

    let mut rows = Vec::new();
    for (label, matches) in [
        (
            "OVERDUE",
            Box::new(|due: &str| due < today.as_str()) as Box<dyn Fn(&str) -> bool>,
        ),
        ("TODAY", Box::new(|due: &str| due == today.as_str())),
        ("LATER", Box::new(|due: &str| due > today.as_str())),
    ] {
        let group: Vec<&(usize, String)> = dated
            .iter()
            .filter(|(_, due)| matches(due.as_str()))
            .collect();
        if group.is_empty() {
            continue;
        }
        rows.push(Row::Header(format!("{label}  ({})", group.len())));
        for (index, due) in group {
            rows.push(Row::Task {
                index: *index,
                depth: 0,
                badge: Some(due.clone()),
            });
        }
    }

    if rows.is_empty() {
        rows.push(Row::Note("Nothing due.".into()));
    }
    rows
}

fn tag_rows(data: &Data) -> Vec<Row> {
    let mut by_tag: Vec<(String, Vec<usize>)> = Vec::new();
    let mut untagged: Vec<usize> = Vec::new();

    for (index, task) in data.tasks.iter().enumerate() {
        let tags = tags_of(task);
        if tags.is_empty() {
            untagged.push(index);
            continue;
        }
        for tag in tags {
            match by_tag.iter_mut().find(|(name, _)| *name == tag) {
                Some((_, members)) => members.push(index),
                None => by_tag.push((tag, vec![index])),
            }
        }
    }
    by_tag.sort_by(|left, right| left.0.cmp(&right.0));

    let mut rows = Vec::new();
    for (tag, members) in &by_tag {
        rows.push(Row::Header(format!("#{tag}  ({})", members.len())));
        for index in members {
            rows.push(Row::Task {
                index: *index,
                depth: 0,
                badge: None,
            });
        }
    }
    if !untagged.is_empty() {
        rows.push(Row::Header(format!("UNTAGGED  ({})", untagged.len())));
        for index in untagged {
            rows.push(Row::Task {
                index,
                depth: 0,
                badge: None,
            });
        }
    }
    if rows.is_empty() {
        rows.push(Row::Note("No tasks to group.".into()));
    }
    rows
}

/// Tags come back as an array or a dictionary depending on the endpoint, and
/// also appear inline in the content as `#tag`.
pub fn tags_of(task: &Value) -> Vec<String> {
    let mut tags: Vec<String> = Vec::new();
    let mut push = |tag: String| {
        let tag = tag.trim().trim_start_matches('#').to_string();
        if !tag.is_empty() && !tags.contains(&tag) {
            tags.push(tag);
        }
    };

    match task.get("tags") {
        Some(Value::Array(items)) => {
            for item in items {
                if let Some(text) = item.as_str() {
                    push(text.to_string());
                }
            }
        }
        Some(Value::Object(entries)) => {
            for key in entries.keys() {
                push(key.clone());
            }
        }
        _ => {}
    }

    for word in task
        .get("content")
        .and_then(Value::as_str)
        .unwrap_or("")
        .split_whitespace()
    {
        if let Some(tag) = word.strip_prefix('#') {
            push(tag.to_string());
        }
    }
    tags
}

/// The absolute priority queue first, then per-parent scoped ranks — the same
/// two stores the app keeps, and `task_metadata` reports.
fn priority_rows(data: &Data) -> Vec<Row> {
    let index_of = |task_id: &str| -> Option<usize> {
        let id: i64 = task_id.parse().ok()?;
        data.tasks
            .iter()
            .position(|task| task.get("id").and_then(Value::as_i64) == Some(id))
    };

    let ranked = |ranks: Option<&Value>| -> Vec<(usize, i64)> {
        let Some(Value::Object(ranks)) = ranks else {
            return Vec::new();
        };
        let mut out: Vec<(usize, i64)> = ranks
            .iter()
            .filter_map(|(task_id, rank)| Some((index_of(task_id)?, rank.as_i64()?)))
            .collect();
        out.sort_by_key(|(_, rank)| *rank);
        out
    };

    let mut rows = Vec::new();

    let absolute = ranked(data.metadata.get("absolute_priority_rank"));
    if !absolute.is_empty() {
        rows.push(Row::Header(format!("ABSOLUTE  ({})", absolute.len())));
        for (index, rank) in absolute {
            rows.push(Row::Task {
                index,
                depth: 0,
                badge: Some(format!("P{rank}")),
            });
        }
    }

    if let Some(Value::Object(by_parent)) = data.metadata.get("scoped_priority_rank_by_parent_id") {
        for (parent, ranks) in by_parent {
            let group = ranked(Some(ranks));
            if group.is_empty() {
                continue;
            }
            let label = if parent == "0" {
                "ROOT".to_string()
            } else {
                let title = index_of(parent)
                    .and_then(|index| data.tasks.get(index))
                    .and_then(|task| task.get("content").and_then(Value::as_str))
                    .unwrap_or(parent);
                format!("UNDER {title}")
            };
            rows.push(Row::Header(format!("{label}  ({})", group.len())));
            for (index, rank) in group {
                rows.push(Row::Task {
                    index,
                    depth: 0,
                    badge: Some(format!("P{rank}")),
                });
            }
        }
    }

    if rows.is_empty() {
        rows.push(Row::Note(
            "Nothing prioritised. Rank tasks in the app with 1-9.".into(),
        ));
    }
    rows
}

fn daily_rows(data: &Data) -> Vec<Row> {
    let dailies = data.dailies_list();
    let mut rows = Vec::new();

    let due_today = dailies
        .iter()
        .filter(|d| d.get("due_today") == Some(&Value::Bool(true)));
    let done = due_today
        .clone()
        .filter(|d| d.get("done") == Some(&Value::Bool(true)))
        .count();
    let total = due_today.count();

    if dailies.is_empty() {
        rows.push(Row::Note("No dailies yet. Add one with `a`.".into()));
    } else {
        rows.push(Row::Header(format!("DAILIES  ({done}/{total})")));
        for index in 0..dailies.len() {
            rows.push(Row::Daily { index });
        }
    }

    if let Some(today) = &data.today {
        let completed = today
            .get("completed")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[]);
        if !completed.is_empty() {
            rows.push(Row::Header(format!("DONE TODAY  ({})", completed.len())));
            for entry in completed {
                let at = entry
                    .get("at")
                    .and_then(Value::as_str)
                    .and_then(|at| at.get(11..16));
                let title = entry.get("title").and_then(Value::as_str).unwrap_or("");
                rows.push(Row::Note(format!("  {}  {title}", at.unwrap_or("     "))));
            }
        }
    }
    rows
}

/// The one-line summary under the list on the Daily tab.
pub fn day_summary(data: &Data) -> Option<String> {
    let today = data.today.as_ref()?;
    let completed = today
        .get("completed_count")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let planned = today
        .get("planned_count")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let unfinished = today
        .get("unfinished_count")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let focus = today
        .get("focus_seconds")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    Some(format!(
        "{completed} done · {planned} planned · {unfinished} left · {} focused",
        format_duration(focus)
    ))
}

pub fn format_duration(seconds: i64) -> String {
    if seconds <= 0 {
        return "no time".into();
    }
    let (hours, minutes) = (seconds / 3600, (seconds % 3600) / 60);
    if hours > 0 {
        format!("{hours}h {minutes:02}m")
    } else {
        format!("{minutes}m")
    }
}

/// Task content with inline `#tags` stripped, as the app's rows show it.
pub fn display_content(task: &Value) -> String {
    task.get("content")
        .and_then(Value::as_str)
        .unwrap_or("")
        .split_whitespace()
        .filter(|word| !word.starts_with('#'))
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn status_marker(task: &Value) -> &'static str {
    match status_of(task) {
        0 => "[ ]",
        1 => "[x]",
        _ => "[~]",
    }
}
