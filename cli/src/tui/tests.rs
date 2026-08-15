//! Tests for the terminal UI.
//!
//! Rendering is checked against `ratatui`'s `TestBackend`, which draws into an
//! in-memory buffer — so what actually reaches the screen is asserted, not just
//! the state that feeds it. A layout that compiles and produces an empty pane
//! would otherwise look exactly like a working one from here.

use crate::tui::render;
use crate::tui::state::{App, Data, Row, Tab, rows_for};
use ratatui::Terminal;
use ratatui::backend::TestBackend;
use serde_json::{Value, json};

// -- fixtures -----------------------------------------------------------------

fn task(id: i64, parent: i64, content: &str, status: i64, due: Option<&str>) -> Value {
    json!({
        "id": id, "parent_id": parent, "position": id, "status": status,
        "content": content, "due": due, "tags": []
    })
}

/// A small tree with a child, a closed task, a due date and a tag.
fn sample() -> Data {
    Data {
        tasks: vec![
            task(1, 0, "Ship v0.4", 0, None),
            task(2, 1, "Draft the release notes #work", 0, Some("2026-08-14")),
            task(3, 1, "Tag the commit", 1, None),
            task(4, 0, "Buy milk #home", 0, Some("2999-01-01")),
        ],
        dailies: json!({"day": "2026-08-15", "dailies": [
            {"id": "d1", "title": "Play Music", "schedule": "Every day", "due_today": true, "done": true},
            {"id": "d2", "title": "Stretch", "schedule": "Weekdays", "due_today": false, "done": false}
        ]}),
        today: Some(json!({
            "day": "2026-08-15", "completed_count": 2, "planned_count": 5,
            "unfinished_count": 3, "focus_seconds": 6000,
            "completed": [{"task_id": 3, "title": "Tag the commit", "at": "2026-08-15T10:04:00Z"}]
        })),
        metadata: json!({
            "absolute_priority_rank": {"4": 1, "1": 2},
            "scoped_priority_rank_by_parent_id": {"1": {"2": 1}}
        }),
        task_error: None,
    }
}

/// Renders and returns the screen as lines of text, trailing space trimmed.
fn screen(app: &App, width: u16, height: u16) -> Vec<String> {
    let mut terminal = Terminal::new(TestBackend::new(width, height)).expect("terminal");
    terminal
        .draw(|frame| render::draw(frame, app))
        .expect("draw");
    let buffer = terminal.backend().buffer().clone();
    (0..buffer.area.height)
        .map(|y| {
            (0..buffer.area.width)
                .map(|x| buffer[(x, y)].symbol().to_string())
                .collect::<String>()
                .trim_end()
                .to_string()
        })
        .collect()
}

fn rendered(app: &App) -> String {
    screen(app, 90, 24).join("\n")
}

// -- tabs ---------------------------------------------------------------------

#[test]
fn the_tabs_mirror_the_apps_root_views_and_their_keys() {
    // Deliberately the same letters as `KeyboardShortcutRouter`: someone who
    // knows the popover shouldn't need a second set of habits here.
    assert_eq!(
        Tab::ORDER.map(|tab| (tab.title(), tab.jump_key())),
        [
            ("All", 'q'),
            ("Due", 'w'),
            ("Tags", 'e'),
            ("Priority", 'r'),
            ("Daily", 'd')
        ]
    );
    assert_eq!(Tab::from_jump_key('w'), Some(Tab::Due));
    assert_eq!(Tab::from_jump_key('z'), None);
}

#[test]
fn cycling_tabs_wraps_in_both_directions() {
    assert_eq!(Tab::All.cycled(-1), Tab::Daily);
    assert_eq!(Tab::Daily.cycled(1), Tab::All);
    assert_eq!(Tab::All.cycled(2), Tab::Tags);
}

#[test]
fn every_tab_renders_without_panicking_even_with_no_data() {
    // An empty store is what a fresh install has, and a panic here would take
    // the terminal down with raw mode still on.
    for tab in Tab::ORDER {
        let mut app = App::new(Data::default());
        app.select_tab(tab);
        let text = rendered(&app);
        assert!(
            text.contains(tab.title()),
            "{} missing from its own tab",
            tab.title()
        );
    }
}

#[test]
fn the_tab_bar_shows_every_view_at_once() {
    let text = rendered(&App::new(sample()));
    for tab in Tab::ORDER {
        assert!(
            text.contains(tab.title()),
            "tab bar missing {}",
            tab.title()
        );
    }
}

// -- All ----------------------------------------------------------------------

#[test]
fn the_all_tab_indents_children_under_their_parent() {
    let app = App::new(sample());
    let rows = app.rows();
    assert_eq!(
        rows,
        vec![
            Row::Task {
                index: 0,
                depth: 0,
                badge: None
            },
            Row::Task {
                index: 1,
                depth: 1,
                badge: None
            },
            Row::Task {
                index: 2,
                depth: 1,
                badge: None
            },
            Row::Task {
                index: 3,
                depth: 0,
                badge: None
            },
        ]
    );
}

#[test]
fn inline_tags_are_stripped_from_the_task_text_and_shown_separately() {
    let text = rendered(&App::new(sample()));
    assert!(text.contains("Draft the release notes"));
    // Rendered as its own coloured span, not left in the middle of the title.
    assert!(!text.contains("release notes #work"));
    assert!(text.contains("#work"));
}

#[test]
fn a_completed_task_is_marked_done() {
    let text = rendered(&App::new(sample()));
    assert!(
        text.contains("[x] Tag the commit"),
        "expected a closed marker:\n{text}"
    );
    assert!(text.contains("[ ] Ship v0.4"));
}

#[test]
fn entering_a_task_scopes_the_list_to_its_subtasks() {
    let mut app = App::new(sample());
    app.enter_scope(); // on "Ship v0.4"
    assert_eq!(app.scope, Some(1));
    assert_eq!(
        app.rows(),
        vec![
            Row::Task {
                index: 1,
                depth: 0,
                badge: None
            },
            Row::Task {
                index: 2,
                depth: 0,
                badge: None
            },
        ]
    );
    assert_eq!(app.scope_title().as_deref(), Some("Ship v0.4"));

    app.exit_scope();
    assert_eq!(app.scope, None);
    assert_eq!(app.rows().len(), 4);
}

#[test]
fn entering_a_task_with_no_subtasks_says_so_rather_than_emptying_the_screen() {
    let mut app = App::new(sample());
    app.selected = 3; // "Buy milk", a leaf
    app.enter_scope();
    assert_eq!(app.scope, None);
    assert_eq!(app.status.as_deref(), Some("No subtasks"));
}

#[test]
fn scoping_is_confined_to_the_all_tab() {
    // `l`/`h` mean "focus column" on other views in the app, so silently
    // re-scoping the task list from the Due tab would be a surprise.
    let mut app = App::new(sample());
    app.select_tab(Tab::Due);
    app.enter_scope();
    assert_eq!(app.scope, None);
}

// -- Due ----------------------------------------------------------------------

#[test]
fn the_due_tab_groups_by_overdue_today_and_later() {
    let rows = rows_for(Tab::Due, &sample(), None);
    let headers: Vec<&String> = rows
        .iter()
        .filter_map(|row| match row {
            Row::Header(text) => Some(text),
            _ => None,
        })
        .collect();
    assert!(
        headers.iter().any(|h| h.starts_with("OVERDUE")),
        "{headers:?}"
    );
    assert!(
        headers.iter().any(|h| h.starts_with("LATER")),
        "{headers:?}"
    );
    // A task with no due date is not "due" anything and must not appear.
    assert_eq!(
        rows.iter()
            .filter(|row| matches!(row, Row::Task { .. }))
            .count(),
        2
    );
}

#[test]
fn nothing_due_says_so() {
    let data = Data {
        tasks: vec![task(1, 0, "No date", 0, None)],
        ..Data::default()
    };
    assert_eq!(
        rows_for(Tab::Due, &data, None),
        vec![Row::Note("Nothing due.".into())]
    );
}

// -- Tags ---------------------------------------------------------------------

#[test]
fn the_tags_tab_groups_by_tag_and_keeps_the_untagged_together() {
    let rows = rows_for(Tab::Tags, &sample(), None);
    let headers: Vec<String> = rows
        .iter()
        .filter_map(|row| match row {
            Row::Header(text) => Some(text.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(headers, vec!["#home  (1)", "#work  (1)", "UNTAGGED  (2)"]);
}

#[test]
fn tags_are_read_from_the_array_the_dictionary_and_the_content() {
    let from_array = json!({"id": 1, "content": "a", "tags": ["work"]});
    let from_dict = json!({"id": 2, "content": "b", "tags": {"work": "1"}});
    let inline = json!({"id": 3, "content": "c #work", "tags": []});
    for candidate in [from_array, from_dict, inline] {
        assert_eq!(
            crate::tui::state::tags_of(&candidate),
            vec!["work".to_string()]
        );
    }
}

// -- Priority -----------------------------------------------------------------

#[test]
fn the_priority_tab_orders_by_rank_and_labels_the_scope() {
    let rows = rows_for(Tab::Priority, &sample(), None);
    let rendered: Vec<String> = rows
        .iter()
        .map(|row| match row {
            Row::Header(text) => format!("H {text}"),
            Row::Task { index, badge, .. } => {
                format!("T {index} {}", badge.clone().unwrap_or_default())
            }
            other => format!("{other:?}"),
        })
        .collect();
    assert_eq!(
        rendered,
        vec![
            "H ABSOLUTE  (2)".to_string(),
            "T 3 P1".into(), // task id 4, rank 1
            "T 0 P2".into(), // task id 1, rank 2
            "H UNDER Ship v0.4  (1)".into(),
            "T 1 P1".into(),
        ]
    );
}

#[test]
fn no_priorities_points_at_where_they_are_set() {
    let data = Data {
        tasks: vec![task(1, 0, "a", 0, None)],
        ..Data::default()
    };
    let rows = rows_for(Tab::Priority, &data, None);
    assert!(matches!(&rows[0], Row::Note(text) if text.contains("1-9")));
}

// -- Daily --------------------------------------------------------------------

#[test]
fn the_daily_tab_counts_only_the_dailies_expected_today() {
    // "Stretch" is a weekday habit that isn't due, so it is neither done nor
    // outstanding and must not drag the ratio down.
    let rows = rows_for(Tab::Daily, &sample(), None);
    assert!(
        matches!(&rows[0], Row::Header(text) if text == "DAILIES  (1/1)"),
        "{:?}",
        rows[0]
    );
}

#[test]
fn the_daily_tab_summarises_the_day_in_its_title() {
    let mut app = App::new(sample());
    app.select_tab(Tab::Daily);
    let text = rendered(&app);
    assert!(text.contains("2 done"), "{text}");
    assert!(text.contains("1h 40m focused"), "{text}");
    assert!(text.contains("Play Music"));
}

// -- degraded state -----------------------------------------------------------

#[test]
fn without_credentials_the_checkvist_tabs_explain_and_the_daily_tab_still_works() {
    // The state a fresh install is in. Losing the local tabs to a missing
    // remote key would make the tool look broken when it isn't.
    let data = Data {
        task_error: Some("Missing credentials.".into()),
        ..sample()
    };

    for tab in [Tab::All, Tab::Due, Tab::Tags, Tab::Priority] {
        let rows = rows_for(tab, &data, None);
        assert!(matches!(&rows[0], Row::Note(text) if text.contains("Missing credentials")));
    }

    let daily = rows_for(Tab::Daily, &data, None);
    assert!(
        daily.iter().any(|row| matches!(row, Row::Daily { .. })),
        "{daily:?}"
    );
}

// -- selection ----------------------------------------------------------------

#[test]
fn moving_skips_headers_and_stops_at_the_ends() {
    let mut app = App::new(sample());
    app.select_tab(Tab::Due);

    // Lands on the first task, never on the group header above it.
    assert!(matches!(app.selected_row(), Some(Row::Task { .. })));

    let first = app.selected;
    app.move_selection(-5);
    assert_eq!(app.selected, first, "should not run off the top");

    app.move_selection(50);
    assert!(
        matches!(app.selected_row(), Some(Row::Task { .. })),
        "should not land on a header"
    );
    let last = app.selected;
    app.move_selection(5);
    assert_eq!(app.selected, last, "should not run off the bottom");
}

#[test]
fn switching_tabs_resets_the_cursor_onto_something_selectable() {
    let mut app = App::new(sample());
    app.move_selection(3);
    app.select_tab(Tab::Daily);
    assert!(matches!(app.selected_row(), Some(Row::Daily { .. })));
    assert_eq!(app.selected_daily_id().as_deref(), Some("d1"));
}

#[test]
fn the_selected_ids_are_only_offered_for_the_matching_row_kind() {
    let mut app = App::new(sample());
    assert_eq!(app.selected_task_id(), Some(1));
    assert_eq!(app.selected_daily_id(), None);

    app.select_tab(Tab::Daily);
    assert_eq!(app.selected_task_id(), None);
    assert!(app.selected_daily_id().is_some());
}

// -- chrome -------------------------------------------------------------------

#[test]
fn typing_a_new_task_is_shown_in_the_footer() {
    let mut app = App::new(sample());
    app.input = Some("Buy stamps".into());
    let text = rendered(&app);
    assert!(text.contains("new task: Buy stamps"), "{text}");

    app.select_tab(Tab::Daily);
    assert!(rendered(&app).contains("new daily: Buy stamps"));
}

#[test]
fn help_lists_the_bindings_and_covers_the_screen() {
    let mut app = App::new(sample());
    app.show_help = true;
    let text = rendered(&app);
    assert!(text.contains("Jump to a tab"));
    assert!(text.contains("Enter / leave subtasks"));
    assert!(text.contains("mirror the menu bar app"));
}

#[test]
fn a_status_message_replaces_the_key_hints() {
    let mut app = App::new(sample());
    assert!(rendered(&app).contains("? help"));
    app.status = Some("Completed.".into());
    let text = rendered(&app);
    assert!(text.contains("Completed."));
    assert!(!text.contains("? help"));
}

#[test]
fn it_renders_in_a_small_terminal_without_panicking() {
    // Ratatui panics on some layouts when there is not enough room; an 80x24
    // assumption would fail on a split pane.
    let mut app = App::new(sample());
    app.show_help = true;
    for (width, height) in [(20_u16, 6_u16), (40, 10), (200, 60)] {
        let lines = screen(&app, width, height);
        assert_eq!(lines.len() as u16, height);
    }
}
