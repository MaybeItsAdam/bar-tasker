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
use crate::tui::outline::OutlineStore;
use chrono::Local;
use serde_json::Value;
use std::collections::{HashMap, HashSet};

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
    /// The task the All tab is zoomed into, as `]`/`[` walk the tree. `None` is
    /// the list root.
    pub scope: Option<i64>,
    /// Tasks whose children are shown indented underneath them, as `l`/`h`
    /// open and shut them. Remembered per list between runs.
    pub expanded: HashSet<i64>,
    pub status: Option<String>,
    /// The text being typed after `a`. `Some` means every key goes to the
    /// buffer rather than to the bindings.
    pub input: Option<String>,
    pub show_help: bool,
    pub should_quit: bool,
    outline: OutlineStore,
}

impl App {
    /// An app with no remembered outline. Tests only — the real one always has
    /// a store, even when that store is disabled for want of a list id.
    #[cfg(test)]
    pub fn new(data: Data) -> Self {
        Self::with_outline(data, OutlineStore::disabled())
    }

    pub fn with_outline(data: Data, outline: OutlineStore) -> Self {
        let mut app = App {
            data,
            tab: Tab::All,
            selected: 0,
            scope: None,
            expanded: outline.load(),
            status: None,
            input: None,
            show_help: false,
            should_quit: false,
            outline,
        };
        app.clamp_selection();
        app
    }

    pub fn rows(&self) -> Vec<Row> {
        rows_for(self.tab, &self.data, self.scope, &self.expanded)
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

    /// `l` — open the selected row, then step into what it shows. The list
    /// keeps its scope; `]` is what changes that.
    pub fn expand_or_descend(&mut self) {
        let Some(id) = self.selected_task_id() else {
            return;
        };
        if !self.has_children(id) {
            return;
        }
        if self.expanded.insert(id) {
            self.outline.save(&self.expanded);
            return;
        }
        let rows = self.rows();
        let Some(depth) = row_depth(&rows, self.selected) else {
            return;
        };
        if row_depth(&rows, self.selected + 1) == Some(depth + 1) {
            self.selected += 1;
        }
    }

    /// `h` — shut the selected row, step up to the parent showing it, or leave
    /// the scope, in that order.
    pub fn collapse_or_ascend(&mut self) {
        if let Some(id) = self.selected_task_id()
            && self.expanded.remove(&id)
        {
            self.outline.save(&self.expanded);
            self.clamp_selection();
            return;
        }
        let rows = self.rows();
        match row_depth(&rows, self.selected) {
            Some(depth) if depth > 0 => {
                if let Some(parent) = (0..self.selected)
                    .rev()
                    .find(|index| row_depth(&rows, *index).is_some_and(|other| other < depth))
                {
                    self.selected = parent;
                }
            }
            _ => self.exit_scope(),
        }
    }

    fn has_children(&self, task_id: i64) -> bool {
        self.data
            .tasks
            .iter()
            .any(|task| parent_id_of(task) == task_id)
    }

    /// `]` — descend into the selected task's subtasks, if it has any.
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

    /// `[` — back out to the parent of whatever we're scoped to.
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

/// The indent of a row, or `None` when it isn't a task row.
fn row_depth(rows: &[Row], index: usize) -> Option<usize> {
    match rows.get(index) {
        Some(Row::Task { depth, .. }) => Some(*depth),
        _ => None,
    }
}

// -- row building -------------------------------------------------------------

pub fn rows_for(tab: Tab, data: &Data, scope: Option<i64>, expanded: &HashSet<i64>) -> Vec<Row> {
    if tab.needs_checkvist()
        && let Some(error) = &data.task_error
    {
        return vec![
            Row::Note(error.clone()),
            Row::Note("Press F5 to retry.".into()),
        ];
    }

    match tab {
        Tab::All => all_rows(data, scope, expanded),
        Tab::Due => due_rows(data, expanded),
        Tab::Tags => tag_rows(data, expanded),
        Tab::Priority => priority_rows(data, expanded),
        Tab::Kanban => kanban_rows(data, expanded),
        Tab::Matrix => matrix_rows(data, expanded),
        Tab::Daily => daily_rows(data),
    }
}

// -- the outline ---------------------------------------------------------------

/// One task in a group: its index into `data.tasks`, and the badge that group
/// wants shown beside it.
type Member = (usize, Option<String>);
/// A titled run of tasks — a due bucket, a tag, a kanban column, a quadrant.
/// The count in the header is added here rather than by the builders, because
/// expanding a row can move a task from one group into another.
type Group = (String, Vec<Member>);

fn task_id_at(data: &Data, index: usize) -> Option<i64> {
    data.task(index)?.get("id")?.as_i64()
}

fn children_by_parent(data: &Data) -> HashMap<i64, Vec<usize>> {
    let mut children: HashMap<i64, Vec<usize>> = HashMap::new();
    for (index, task) in data.tasks.iter().enumerate() {
        children.entry(parent_id_of(task)).or_default().push(index);
    }
    children
}

/// Assembles grouped tabs into rows, with each expanded task followed by its
/// children, indented.
///
/// A task listed in its own right *and* sitting under an expanded ancestor
/// appears once, under the ancestor — the same rule the app's
/// `TaskOutlineBuilder` follows, so the two don't disagree about what an open
/// outline looks like.
fn grouped_rows(groups: Vec<Group>, data: &Data, expanded: &HashSet<i64>) -> Vec<Row> {
    let children = children_by_parent(data);
    let listed: HashSet<i64> = groups
        .iter()
        .flat_map(|(_, members)| members.iter())
        .filter_map(|(index, _)| task_id_at(data, *index))
        .collect();

    let mut absorbed: HashSet<i64> = HashSet::new();
    for (_, members) in &groups {
        for (index, _) in members {
            let Some(id) = task_id_at(data, *index) else {
                continue;
            };
            if expanded.contains(&id) && !absorbed.contains(&id) {
                let mut visited: HashSet<i64> = HashSet::from([id]);
                absorb_revealed(
                    id,
                    data,
                    &children,
                    expanded,
                    &listed,
                    &mut visited,
                    &mut absorbed,
                );
            }
        }
    }

    let mut emitted: HashSet<i64> = HashSet::new();
    let mut rows = Vec::new();
    for (label, members) in groups {
        let mut group_rows: Vec<Row> = Vec::new();
        let mut top_level = 0;
        for (index, badge) in members {
            let Some(id) = task_id_at(data, index) else {
                continue;
            };
            if absorbed.contains(&id) {
                continue;
            }
            top_level += 1;
            emit_subtree(
                index,
                badge,
                0,
                data,
                &children,
                expanded,
                &mut emitted,
                &mut group_rows,
            );
        }
        if group_rows.is_empty() {
            continue;
        }
        rows.push(Row::Header(format!("{label}  ({top_level})")));
        rows.append(&mut group_rows);
    }
    rows
}

/// Ids that expanding `task_id` will reveal, limited to tasks the tab already
/// lists — those are the only ones that can end up shown twice. `visited`
/// starts on the row the walk began at, so a malformed parent cycle can't
/// absorb it and make it vanish.
fn absorb_revealed(
    task_id: i64,
    data: &Data,
    children: &HashMap<i64, Vec<usize>>,
    expanded: &HashSet<i64>,
    listed: &HashSet<i64>,
    visited: &mut HashSet<i64>,
    absorbed: &mut HashSet<i64>,
) {
    for index in children.get(&task_id).into_iter().flatten() {
        let Some(child) = task_id_at(data, *index) else {
            continue;
        };
        if !visited.insert(child) {
            continue;
        }
        if listed.contains(&child) {
            absorbed.insert(child);
        }
        if expanded.contains(&child) {
            absorb_revealed(child, data, children, expanded, listed, visited, absorbed);
        }
    }
}

/// Bounded rather than free recursion, for the same reason `depth_within` is.
const MAX_DEPTH: usize = 64;

#[allow(clippy::too_many_arguments)]
fn emit_subtree(
    index: usize,
    badge: Option<String>,
    depth: usize,
    data: &Data,
    children: &HashMap<i64, Vec<usize>>,
    expanded: &HashSet<i64>,
    emitted: &mut HashSet<i64>,
    rows: &mut Vec<Row>,
) {
    let Some(id) = task_id_at(data, index) else {
        return;
    };
    if !emitted.insert(id) {
        return;
    }
    rows.push(Row::Task {
        index,
        depth,
        badge,
    });
    if !expanded.contains(&id) || depth >= MAX_DEPTH {
        return;
    }
    for child in children.get(&id).into_iter().flatten() {
        emit_subtree(
            *child,
            None,
            depth + 1,
            data,
            children,
            expanded,
            emitted,
            rows,
        );
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

fn kanban_rows(data: &Data, expanded: &HashSet<i64>) -> Vec<Row> {
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

    let groups: Vec<Group> = columns
        .iter()
        .zip(&members)
        .map(|(column, tasks)| {
            let name = column.get("name").and_then(Value::as_str).unwrap_or("");
            let members: Vec<Member> = tasks
                .iter()
                .map(|index| {
                    let due = data
                        .task(*index)
                        .and_then(|task| task.get("due").and_then(Value::as_str))
                        .filter(|due| !due.is_empty())
                        .map(str::to_string);
                    (*index, due)
                })
                .collect();
            (name.to_string(), members)
        })
        .collect();
    grouped_rows(groups, data, expanded)
}

// -- matrix -------------------------------------------------------------------

/// The four Eisenhower quadrants, as `EisenhowerMatrixView` labels them:
/// urgency is the X axis and importance the Y, both centred on zero.
fn matrix_rows(data: &Data, expanded: &HashSet<i64>) -> Vec<Row> {
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

    let groups: Vec<Group> = [
        ("DO — urgent & important", true, true),
        ("SCHEDULE — important, not urgent", false, true),
        ("DELEGATE — urgent, not important", true, false),
        ("ELIMINATE — neither", false, false),
    ]
    .into_iter()
    .map(|(label, urgent, important)| {
        let members: Vec<Member> = placed
            .iter()
            .filter(|(_, urgency, importance)| {
                (*urgency > 0.0) == urgent && (*importance > 0.0) == important
            })
            .map(|(index, urgency, importance)| {
                (*index, Some(format!("U{urgency:.0} I{importance:.0}")))
            })
            .collect();
        (label.to_string(), members)
    })
    .collect();

    let mut rows = grouped_rows(groups, data, expanded);
    if rows.is_empty() {
        rows.push(Row::Note(
            "Nothing placed on the matrix yet. Use `m` in the app.".into(),
        ));
    }
    rows
}

/// The tasks at the current scope, each expanded row followed by its children.
///
/// Starts shut rather than showing the whole tree: a long list is easier to
/// read a level at a time, and `l` opens what you actually want to see.
fn all_rows(data: &Data, scope: Option<i64>, expanded: &HashSet<i64>) -> Vec<Row> {
    let root = scope.unwrap_or(0);
    let children = children_by_parent(data);
    let mut emitted: HashSet<i64> = HashSet::new();
    let mut rows = Vec::new();
    for index in children.get(&root).into_iter().flatten() {
        emit_subtree(
            *index,
            None,
            0,
            data,
            &children,
            expanded,
            &mut emitted,
            &mut rows,
        );
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

fn due_rows(data: &Data, expanded: &HashSet<i64>) -> Vec<Row> {
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

    let groups: Vec<Group> = [
        (
            "OVERDUE",
            Box::new(|due: &str| due < today.as_str()) as Box<dyn Fn(&str) -> bool>,
        ),
        ("TODAY", Box::new(|due: &str| due == today.as_str())),
        ("LATER", Box::new(|due: &str| due > today.as_str())),
    ]
    .into_iter()
    .map(|(label, matches)| {
        let members: Vec<Member> = dated
            .iter()
            .filter(|(_, due)| matches(due.as_str()))
            .map(|(index, due)| (*index, Some(due.clone())))
            .collect();
        (label.to_string(), members)
    })
    .collect();

    let mut rows = grouped_rows(groups, data, expanded);
    if rows.is_empty() {
        rows.push(Row::Note("Nothing due.".into()));
    }
    rows
}

fn tag_rows(data: &Data, expanded: &HashSet<i64>) -> Vec<Row> {
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

    let mut groups: Vec<Group> = by_tag
        .iter()
        .map(|(tag, members)| {
            (
                format!("#{tag}"),
                members.iter().map(|index| (*index, None)).collect(),
            )
        })
        .collect();
    if !untagged.is_empty() {
        groups.push((
            "UNTAGGED".to_string(),
            untagged.into_iter().map(|index| (index, None)).collect(),
        ));
    }

    let mut rows = grouped_rows(groups, data, expanded);
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
fn priority_rows(data: &Data, expanded: &HashSet<i64>) -> Vec<Row> {
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

    let members = |ranked: Vec<(usize, i64)>| -> Vec<Member> {
        ranked
            .into_iter()
            .map(|(index, rank)| (index, Some(format!("P{rank}"))))
            .collect()
    };

    let mut groups: Vec<Group> = Vec::new();

    let absolute = ranked(data.metadata.get("absolute_priority_rank"));
    if !absolute.is_empty() {
        groups.push(("ABSOLUTE".to_string(), members(absolute)));
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
            groups.push((label, members(group)));
        }
    }

    let mut rows = grouped_rows(groups, data, expanded);
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

pub fn id_of(task: &Value) -> i64 {
    task.get("id").and_then(Value::as_i64).unwrap_or(0)
}

/// Whether anything hangs off this task — what the disclosure marker is drawn
/// from, and what `l` needs to know before opening a row.
pub fn has_children(data: &Data, task: &Value) -> bool {
    let id = id_of(task);
    id != 0 && data.tasks.iter().any(|other| parent_id_of(other) == id)
}

pub fn status_marker(task: &Value) -> &'static str {
    match status_of(task) {
        0 => "[ ]",
        1 => "[x]",
        _ => "[~]",
    }
}
