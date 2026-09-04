//! heyflare for iPhone and iPad: a thin native shell around a heyflare server.
//!
//! The web app runs remotely and already ships a hand-built mobile UI, so this crate stays small.
//! It stores which server to open, shows a bundled welcome screen until one is chosen, forwards
//! system notifications, and keeps every link that leaves the server in Safari.

use serde_json::json;
use std::sync::Mutex;
use tauri::{AppHandle, Manager, State, WebviewUrl, WebviewWindow};
use tauri_plugin_notification::{NotificationExt, PermissionState};
use tauri_plugin_opener::OpenerExt;
use tauri_plugin_store::StoreExt;

const STORE: &str = "config.json";

#[derive(Default)]
struct AppState {
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
/// The iPhone build has no dock badge and no self-updater, so it grants fewer than the Mac one.
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
            "allow-notify",
            "allow-take-pending-url",
            "allow-open-external",
            "allow-get-server",
            "allow-reset-server"
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

#[tauri::command]
fn open_server(app: AppHandle, url: String) -> Result<String, String> {
    let origin = normalize_server(&url)?;
    let store = app.store(STORE).map_err(|e| e.to_string())?;
    store.set("server", json!(origin));
    store.save().map_err(|e| e.to_string())?;
    grant_remote(&app, &origin);
    if let Some(w) = main_window(&app) {
        let target = url::Url::parse(&format!("{origin}/")).map_err(|_| "bad url".to_string())?;
        w.navigate(target).map_err(|e| e.to_string())?;
    }
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
        let home: url::Url = WebviewUrl::App("index.html".into()).to_string().parse().map_err(|_| "bad url".to_string())?;
        let _ = w.navigate(home);
    }
    Ok(())
}

#[tauri::command]
fn notify(app: AppHandle, state: State<'_, AppState>, title: String, body: String, url: Option<String>) {
    if let Some(u) = url {
        *state.pending_url.lock().unwrap() = Some(u);
    }
    let _ = app.notification().builder().title(title).body(body).show();
}

/// The web app calls this when the window regains focus (e.g. after a notification tap)
/// and navigates to the returned path, if any.
#[tauri::command]
fn take_pending_url(state: State<'_, AppState>) -> Option<String> {
    state.pending_url.lock().unwrap().take()
}

#[tauri::command]
fn open_external(app: AppHandle, url: String) -> Result<(), String> {
    if !(url.starts_with("https://") || url.starts_with("http://") || url.starts_with("mailto:") || url.starts_with("tel:")) {
        return Err("blocked".into());
    }
    app.opener().open_url(url, None::<&str>).map_err(|e| e.to_string())
}

/// iOS asks the user before an app may post notifications. Do it once, in the background, so the
/// prompt lands after the first screen is up rather than on a blank window.
fn request_notification_permission(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let n = app.notification();
        if matches!(n.permission_state(), Ok(PermissionState::Prompt) | Ok(PermissionState::PromptWithRationale)) {
            let _ = n.request_permission();
        }
    });
}

/// The webview is built here (not from config) so it can carry a navigation guard: any attempt to
/// leave the configured server — a link inside an email, a `target=_blank` the webview turned into a
/// navigation — is handed to Safari and blocked. This needs no IPC, so it works even where the JS
/// bridge isn't available on the remote page.
fn build_main_window(app: &AppHandle, url: WebviewUrl) -> tauri::Result<WebviewWindow> {
    tauri::WebviewWindowBuilder::new(app, "main", url)
        .title("heyflare")
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

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .manage(AppState { pending_url: Mutex::new(None) })
        .plugin(tauri_plugin_store::Builder::new().build())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![notify, take_pending_url, open_external, open_server, get_server, reset_server])
        .setup(|app| {
            let handle = app.handle().clone();
            // First launch shows the bundled welcome page; afterwards go straight to the server.
            let start = match stored_server(&handle) {
                Some(server) => {
                    grant_remote(&handle, &server);
                    url::Url::parse(&format!("{server}/")).map(WebviewUrl::External).unwrap_or_else(|_| WebviewUrl::App("index.html".into()))
                }
                None => WebviewUrl::App("index.html".into()),
            };
            build_main_window(&handle, start)?;
            request_notification_permission(&handle);
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running heyflare");
}
