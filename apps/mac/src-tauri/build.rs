fn main() {
    tauri_build::try_build(
        tauri_build::Attributes::new().app_manifest(
            tauri_build::AppManifest::new().commands(&["set_badge", "notify", "take_pending_url", "open_external", "open_server", "get_server", "reset_server", "check_update", "install_update", "relaunch_app"]),
        ),
    )
    .expect("failed to run tauri-build");
}
