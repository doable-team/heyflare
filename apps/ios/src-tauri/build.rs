// Every command the crate exposes must be listed here. A command that exists in a capability but
// not in this manifest aborts the app at launch with `UnknownPermission` — keep the two in step.
fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new().app_manifest(
            tauri_build::AppManifest::new().commands(&["notify", "take_pending_url", "open_external", "open_server", "get_server", "reset_server"]),
        ),
    )
    .expect("failed to run tauri-build");
}
