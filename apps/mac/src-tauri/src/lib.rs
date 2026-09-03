//! heyflare for Mac: a thin native shell around a heyflare server.
//! The web app runs remotely; this crate adds the Mac chrome — menu bar, dock badge,
//! notifications, external-link handling, window state and auto-updates.

use serde_json::json;
use std::sync::Mutex;
use tauri::menu::{AboutMetadataBuilder, MenuBuilder, MenuItemBuilder, PredefinedMenuItem, SubmenuBuilder};
use tauri::{AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindow};
use tauri_plugin_notification::NotificationExt;
use tauri_plugin_opener::OpenerExt;
use tauri_plugin_store::StoreExt;
use tauri_plugin_updater::UpdaterExt;

const STORE: &str = "config.json";
const DEFAULT_SERVER: &str = "https://hey.far.hn";

#[derive(Default)]
struct AppState {
    zoom: Mutex<f64>,
    pending_url: Mutex<Option<String>>,
}

fn main_window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window("main")
}

fn normalize_server(input: &str) -> Result<String, String> {
    let raw = input.trim();
    let with_scheme = if raw.starts_with("http://") || raw.starts_with("https://") { raw.to_string() } else { format!("https://{raw}") };
    let parsed = url::Url::parse(&with_scheme).map_err(|_| "That doesn't look like a URL.".to_string())?;
    if parsed.scheme() != "https" && parsed.host_str() != Some("localhost") && parsed.host_str() != Some("127.0.0.1") {
        return Err("Use https:// for your server.".into());
    }
    let host = parsed.host_str().ok_or("Missing host.")?;
    let port = parsed.port().map(|p| format!(":{p}")).unwrap_or_default();
    Ok(format!("{}://{}{}", parsed.scheme(), host, port))
}

/// Grant the remote origin access to the small set of commands the web app uses.
fn grant_remote(app: &AppHandle, origin: &str) {
    let cap = json!({
        "identifier": format!("remote-{}", origin.replace(|c: char| !c.is_ascii_alphanumeric(), "-")),
        "windows": ["main"],
        "remote": { "urls": [format!("{origin}/*")] },
        "permissions": [
            "core:event:default",
            "core:window:allow-set-focus",
            "core:window:allow-is-focused",
            "notification:default",
            "opener:allow-open-url",
            "allow-set-badge",
            "allow-notify",
            "allow-take-pending-url",
            "allow-open-external",
            "allow-get-server",
            "allow-reset-server",
            "allow-check-update",
            "allow-install-update",
            "allow-relaunch-app"
        ]
    });
    if let Err(e) = app.add_capability(cap.to_string()) {
        eprintln!("heyflare: could not add remote capability: {e}");
    }
}

fn stored_server(app: &AppHandle) -> Option<String> {
    let store = app.store(STORE).ok()?;
    store.get("server").and_then(|v| v.as_str().map(|s| s.to_string()))
}

fn navigate_to_server(app: &AppHandle, origin: &str) {
    grant_remote(app, origin);
    if let Some(w) = main_window(app) {
        if let Ok(u) = url::Url::parse(&format!("{origin}/")) {
            let _ = w.navigate(u);
        }
    }
}

#[tauri::command]
fn open_server(app: AppHandle, url: String) -> Result<String, String> {
    let origin = normalize_server(&url)?;
    let store = app.store(STORE).map_err(|e| e.to_string())?;
    store.set("server", json!(origin));
    store.save().map_err(|e| e.to_string())?;
    navigate_to_server(&app, &origin);
    Ok(origin)
}

#[tauri::command]
fn get_server(app: AppHandle) -> Option<String> {
    stored_server(&app)
}

#[tauri::command]
fn reset_server(app: AppHandle) -> Result<(), String> {
    let store = app.store(STORE).map_err(|e| e.to_string())?;
    store.delete("server");
    store.save().map_err(|e| e.to_string())?;
    if let Some(w) = main_window(&app) {
        let _ = w.navigate(WebviewUrl::App("index.html".into()).to_string().parse().map_err(|_| "bad url".to_string())?);
    }
    Ok(())
}

#[tauri::command]
fn set_badge(app: AppHandle, count: i64) {
    if let Some(w) = main_window(&app) {
        let _ = w.set_badge_count(if count > 0 { Some(count) } else { None });
    }
}

#[tauri::command]
fn notify(app: AppHandle, state: State<'_, AppState>, title: String, body: String, url: Option<String>) {
    if let Some(u) = url {
        *state.pending_url.lock().unwrap() = Some(u);
    }
    let _ = app.notification().builder().title(title).body(body).show();
}

/// The web app calls this when the window regains focus (e.g. after a notification click)
/// and navigates to the returned path, if any.
#[tauri::command]
fn take_pending_url(state: State<'_, AppState>) -> Option<String> {
    state.pending_url.lock().unwrap().take()
}

#[tauri::command]
fn open_external(app: AppHandle, url: String) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://") || url.starts_with("mailto:")) {
        return Err("blocked".into());
    }
    app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
}

fn apply_zoom(app: &AppHandle, state: &AppState, delta: Option<f64>) {
    let mut z = state.zoom.lock().unwrap();
    *z = match delta {
        None => 1.0,
        Some(d) => (*z + d).clamp(0.6, 2.0),
    };
    if let Some(w) = main_window(app) {
        let _ = w.set_zoom(*z);
    }
}

/// Is there a newer build? Returns `{available, version, notes}`; a failed check is non-fatal.
#[tauri::command]
async fn check_update(app: AppHandle) -> Result<serde_json::Value, String> {
    let updater = app.updater().map_err(|e| e.to_string())?;
    match updater.check().await.map_err(|e| e.to_string())? {
        Some(u) => Ok(json!({ "available": true, "version": u.version, "notes": u.body })),
        None => Ok(json!({ "available": false })),
    }
}

/// Download and install the update, then relaunch. Emits `update://progress` with a 0..1
/// fraction (or -1 when the server sends no content length).
#[tauri::command]
async fn install_update(app: AppHandle) -> Result<(), String> {
    let updater = app.updater().map_err(|e| e.to_string())?;
    let update = updater.check().await.map_err(|e| e.to_string())?.ok_or("Already up to date.")?;
    let total = std::sync::Mutex::new(0u64);
    let handle = app.clone();
    update
        .download_and_install(
            move |chunk, len| {
                let mut done = total.lock().unwrap();
                *done += chunk as u64;
                let fraction = match len {
                    Some(t) if t > 0 => (*done as f64 / t as f64).min(1.0),
                    _ => -1.0,
                };
                let _ = handle.emit("update://progress", json!({ "fraction": fraction }));
            },
            || {},
        )
        .await
        .map_err(|e| e.to_string())?;
    app.restart();
}

#[tauri::command]
fn relaunch_app(app: AppHandle) {
    app.restart();
}

fn build_menu(app: &AppHandle) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    let about = AboutMetadataBuilder::new()
        .name(Some("heyflare"))
        .version(Some(env!("CARGO_PKG_VERSION")))
        .website(Some("https://github.com/doable-team/heyflare"))
        .website_label(Some("github.com/doable-team/heyflare"))
        .comments(Some("A calm, HEY-style mail client with a built-in AI agent."))
        .build();

    let app_menu = SubmenuBuilder::new(app, "heyflare")
        .about(Some(about))
        .separator()
        .item(&MenuItemBuilder::with_id("check-updates", "Check for Updates…").build(app)?)
        .separator()
        .item(&MenuItemBuilder::with_id("nav:/settings", "Settings…").accelerator("CmdOrCtrl+,").build(app)?)
        .item(&MenuItemBuilder::with_id("switch-server", "Switch Server…").build(app)?)
        .separator()
        .services()
        .separator()
        .hide()
        .hide_others()
        .show_all()
        .separator()
        .quit()
        .build()?;

    let file = SubmenuBuilder::new(app, "File")
        .item(&MenuItemBuilder::with_id("compose", "New Message").accelerator("CmdOrCtrl+N").build(app)?)
        .separator()
        .close_window()
        .build()?;

    let edit = SubmenuBuilder::new(app, "Edit")
        .undo()
        .redo()
        .separator()
        .cut()
        .copy()
        .paste()
        .select_all()
        .build()?;

    let view = SubmenuBuilder::new(app, "View")
        .item(&MenuItemBuilder::with_id("nav:/", "Imbox").accelerator("CmdOrCtrl+1").build(app)?)
        .item(&MenuItemBuilder::with_id("nav:/feed", "The Feed").accelerator("CmdOrCtrl+2").build(app)?)
        .item(&MenuItemBuilder::with_id("nav:/paper-trail", "Paper Trail").accelerator("CmdOrCtrl+3").build(app)?)
        .item(&MenuItemBuilder::with_id("nav:/screener", "Screener").accelerator("CmdOrCtrl+4").build(app)?)
        .item(&MenuItemBuilder::with_id("nav:/reply-later", "Reply Later").accelerator("CmdOrCtrl+5").build(app)?)
        .item(&MenuItemBuilder::with_id("nav:/set-aside", "Set Aside").accelerator("CmdOrCtrl+6").build(app)?)
        .item(&MenuItemBuilder::with_id("nav:/bubble-up", "Bubble Up").accelerator("CmdOrCtrl+7").build(app)?)
        .item(&MenuItemBuilder::with_id("nav:/previously-seen", "Previously Seen").accelerator("CmdOrCtrl+8").build(app)?)
        .item(&MenuItemBuilder::with_id("nav:/contacts", "Contacts").accelerator("CmdOrCtrl+9").build(app)?)
        .separator()
        .item(&MenuItemBuilder::with_id("toggle-sidebar", "Toggle Sidebar").accelerator("CmdOrCtrl+B").build(app)?)
        .item(&MenuItemBuilder::with_id("assistant", "Assistant").accelerator("CmdOrCtrl+J").build(app)?)
        .separator()
        .item(&MenuItemBuilder::with_id("reload", "Reload").accelerator("CmdOrCtrl+R").build(app)?)
        .item(&MenuItemBuilder::with_id("zoom-reset", "Actual Size").accelerator("CmdOrCtrl+0").build(app)?)
        .item(&MenuItemBuilder::with_id("zoom-in", "Zoom In").accelerator("CmdOrCtrl+=").build(app)?)
        .item(&MenuItemBuilder::with_id("zoom-out", "Zoom Out").accelerator("CmdOrCtrl+-").build(app)?)
        .separator()
        .fullscreen()
        .build()?;

    let go = SubmenuBuilder::new(app, "Go")
        .item(&MenuItemBuilder::with_id("palette", "Search").accelerator("CmdOrCtrl+K").build(app)?)
        .separator()
        .item(&MenuItemBuilder::with_id("back", "Back").accelerator("CmdOrCtrl+[").build(app)?)
        .item(&MenuItemBuilder::with_id("forward", "Forward").accelerator("CmdOrCtrl+]").build(app)?)
        .build()?;

    let window = SubmenuBuilder::new(app, "Window")
        .minimize()
        .maximize()
        .separator()
        .item(&PredefinedMenuItem::fullscreen(app, Some("Enter Full Screen"))?)
        .build()?;

    let help = SubmenuBuilder::new(app, "Help")
        .item(&MenuItemBuilder::with_id("help", "heyflare on GitHub").build(app)?)
        .build()?;

    MenuBuilder::new(app).items(&[&app_menu, &file, &edit, &view, &go, &window, &help]).build()
}

/// The main window is built here (not from config) so it can carry a navigation guard: any attempt
/// to leave the configured server — a link inside an email, a `target=_blank` the webview turned
/// into a navigation — is handed to the default browser and blocked. This needs no IPC, so it works
/// even where the JS bridge isn't available on the remote page.
fn build_main_window(app: &AppHandle, url: WebviewUrl) -> tauri::Result<WebviewWindow> {
    tauri::WebviewWindowBuilder::new(app, "main", url)
        .title("heyflare")
        .inner_size(1280.0, 820.0)
        .min_inner_size(900.0, 600.0)
        .title_bar_style(tauri::TitleBarStyle::Overlay)
        .hidden_title(true)
        .traffic_light_position(tauri::LogicalPosition::new(16.0, 18.0))
        .disable_drag_drop_handler()
        .on_navigation({
            let app = app.clone();
            move |url| {
                let scheme = url.scheme();
                if scheme == "tauri" || scheme == "about" || scheme == "data" || scheme == "blob" {
                    return true;
                }
                if let Some(server) = stored_server(&app) {
                    if server.trim_end_matches('/') == url.origin().ascii_serialization() {
                        return true;
                    }
                }
                if matches!(scheme, "http" | "https" | "mailto" | "tel") {
                    let _ = app.opener().open_url(url.to_string(), None::<&str>);
                }
                false
            }
        })
        .build()
}

pub fn run() {
    tauri::Builder::default()
        .manage(AppState { zoom: Mutex::new(1.0), pending_url: Mutex::new(None) })
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(tauri_plugin_window_state::Builder::new().build())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_process::init())
        .invoke_handler(tauri::generate_handler![set_badge, notify, take_pending_url, open_external, open_server, get_server, reset_server, check_update, install_update, relaunch_app])
        .setup(|app| {
            let handle = app.handle().clone();
            let menu = build_menu(&handle)?;
            app.set_menu(menu)?;
            app.on_menu_event(move |app, event| {
                let id = event.id().as_ref().to_string();
                let state = app.state::<AppState>();
                match id.as_str() {
                    "zoom-in" => apply_zoom(app, &state, Some(0.1)),
                    "zoom-out" => apply_zoom(app, &state, Some(-0.1)),
                    "zoom-reset" => apply_zoom(app, &state, None),
                    "reload" => {
                        if let Some(w) = main_window(app) {
                            let _ = w.eval("location.reload()");
                        }
                    }
                    "check-updates" => {
                        let _ = app.emit("menu", "check-updates");
                    }
                    "help" => {
                        let _ = app.opener().open_url("https://github.com/doable-team/heyflare", None::<&str>);
                    }
                    "switch-server" => {
                        let _ = reset_server(app.clone());
                    }
                    other => {
                        let _ = app.emit("menu", other);
                    }
                }
            });
            // First launch shows the bundled welcome page; afterwards go straight to the server.
            let start = match stored_server(&handle) {
                Some(server) => {
                    grant_remote(&handle, &server);
                    url::Url::parse(&format!("{server}/")).map(WebviewUrl::External).unwrap_or_else(|_| WebviewUrl::App("index.html".into()))
                }
                None => WebviewUrl::App("index.html".into()),
            };
            build_main_window(&handle, start)?;
            let _ = DEFAULT_SERVER;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running heyflare");
}
