import SwiftUI

// The assistant's settings, ported from `AiSettingsSection.tsx`. The key is pasted rather
// than typed — a phone's clipboard is as good as a laptop's — and stored encrypted on the
// worker the same way. The earlier decision to keep this on the web read as "the phone
// cannot fix a missing provider", which is a poor thing to say to someone holding one.

struct AiSettingsScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Navigator.self) private var nav
    @Environment(ToastCenter.self) private var toasts

    @State private var store = AiSettingsStore()
    @State private var preset = ""
    @State private var baseURL = ""
    @State private var key = ""
    @State private var model = ""
    @State private var dirty = false
    @State private var saving = false
    @State private var testing = false
    @State private var learning = false
    @State private var confirmForget = false
    @State private var confirmRemoveKey = false

    private var current: AiPreset? {
        store.settings?.presets.first { $0.id == preset } ?? store.settings?.presets.first
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(title: "AI assistant") {
                BarButton(icon: "chevron.left", label: "Back") { dismiss() }
            } trailing: {
                EmptyView()
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.loading && store.settings == nil {
                        ProgressView().tint(Theme.Colors.mutedForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                    } else if let error = store.error, store.settings == nil {
                        EmptyState(icon: "exclamationmark.triangle", message: error, actionTitle: "Try again") {
                            Task { await store.load() }
                        }
                    } else if let settings = store.settings {
                        provider(settings)
                        behaviour(settings)
                        memory(settings)
                    }
                }
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .screenBackground()
        .tint(Theme.Colors.foreground)
        .task {
            await store.load()
            seed()
        }
        .onChange(of: store.settings?.preset) { _, _ in if !dirty { seed() } }
        .confirmationDialog("Forget everything?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Forget everything", role: .destructive) { Task { await forget() } }
            Button("Keep", role: .cancel) {}
        } message: {
            Text("Deletes every memory entry and the learning history. The assistant starts from scratch.")
        }
        .confirmationDialog("Remove the stored key?", isPresented: $confirmRemoveKey, titleVisibility: .visible) {
            Button("Remove key", role: .destructive) { Task { await save(["api_key": NSNull()]) } }
            Button("Keep", role: .cancel) {}
        }
    }

    private func seed() {
        guard let s = store.settings else { return }
        preset = s.preset
        baseURL = s.preset == "custom" ? s.baseURL : ""
        model = s.model
    }

    // MARK: Provider

    private func provider(_ s: AiSettings) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Provider")
            Text("Bring your own key. Mail only goes to the provider when you use an AI feature.")
                .font(Theme.Typography.small)
                .foregroundStyle(Theme.Colors.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Metrics.hPadding)
                .padding(.bottom, 10)

            if !s.serverReady {
                Text("SESSION_SECRET is not set on the server, so keys cannot be stored yet.")
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.foreground)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.Colors.muted)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.smallRadius, style: .continuous))
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .padding(.bottom, 10)
            }

            VStack(alignment: .leading, spacing: 14) {
                labelled("Provider") {
                    Menu {
                        ForEach(s.presets) { option in
                            Button {
                                choose(option)
                            } label: {
                                if option.id == preset {
                                    Label(option.label, systemImage: "checkmark")
                                } else {
                                    Text(option.label)
                                }
                            }
                        }
                    } label: {
                        HStack {
                            Text(current?.label ?? preset)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.foreground)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.Colors.mutedForeground)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 48)
                        .background(Theme.Colors.muted)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    if let p = current, p.id != "custom", !p.baseURL.isEmpty {
                        Text("Endpoint: \(p.baseURL)")
                            .font(Theme.Typography.micro)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }
                }

                if preset == "custom" {
                    labelled("Base URL", hint: "Any OpenAI-compatible server: Ollama, LM Studio, Groq, Mistral, Together…") {
                        TextField("http://localhost:11434/v1", text: $baseURL)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: baseURL) { _, _ in dirty = true }
                            .modifier(AiField())
                    }
                }

                labelled("API key", hint: s.keyHint.isEmpty ? "Stored encrypted on your server and never shown again." : "Stored · \(s.keyHint)") {
                    SecureField(current?.keyPlaceholder.isEmpty == false ? current!.keyPlaceholder : "API key", text: $key)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .onChange(of: key) { _, _ in dirty = true }
                        .modifier(AiField())
                    HStack(spacing: 14) {
                        if let url = current?.keyURL.flatMap(URL.init(string:)) {
                            Link("Get a key", destination: url)
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.foreground)
                        }
                        if !s.keyHint.isEmpty {
                            Button("Remove key") { confirmRemoveKey = true }
                                .font(Theme.Typography.small)
                                .foregroundStyle(Theme.Colors.foreground)
                        }
                    }
                }

                labelled("Model", hint: "Any model id the provider supports.") {
                    TextField(current?.defaultModel ?? "", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: model) { _, _ in dirty = true }
                        .modifier(AiField())
                    if let models = current?.models, !models.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(models, id: \.self) { option in
                                    Button {
                                        model = option
                                        dirty = true
                                    } label: {
                                        Text(option)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(model == option ? Theme.Colors.background : Theme.Colors.foreground)
                                            .padding(.horizontal, 10)
                                            .frame(height: 30)
                                            .background(model == option ? Theme.Colors.foreground : Theme.Colors.muted)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        Task { await saveProvider() }
                    } label: {
                        if saving { ProgressView().tint(Theme.Colors.background) } else { Text("Save") }
                    }
                    .buttonStyle(FilledButtonStyle(height: Theme.Metrics.minTouchTarget))
                    .disabled(saving || (!dirty && key.isEmpty))
                    .opacity(dirty || !key.isEmpty ? 1 : 0.5)

                    Button {
                        Task { await test() }
                    } label: {
                        if testing { ProgressView().tint(Theme.Colors.foreground) } else { Text("Test connection") }
                    }
                    .buttonStyle(OutlineButtonStyle(height: Theme.Metrics.minTouchTarget))
                    .disabled(testing || !s.configured || dirty)
                    .opacity(!s.configured || dirty ? 0.5 : 1)
                }

                if s.configured && !dirty {
                    Button {
                        nav.select(.assistant)
                    } label: {
                        Text("Ready · open the assistant")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Metrics.hPadding)
        }
    }

    private func choose(_ option: AiPreset) {
        preset = option.id
        model = option.defaultModel
        if option.id != "custom" { baseURL = "" }
        dirty = true
    }

    private func saveProvider() async {
        var patch: [String: Any] = ["preset": preset, "model": model.trimmingCharacters(in: .whitespaces)]
        if preset == "custom" { patch["base_url"] = baseURL.trimmingCharacters(in: .whitespaces) }
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        if !trimmedKey.isEmpty { patch["api_key"] = trimmedKey }
        await save(patch)
    }

    private func save(_ patch: [String: Any]) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await store.apply(patch)
            key = ""
            dirty = false
            seed()
            Haptics.success()
            toasts.show("AI settings saved")
        } catch let e as APIError {
            Haptics.warning()
            switch e {
            case .server("invalid_key", _): toasts.error("That key looks too short.")
            case .server("base_url_must_be_http", _): toasts.error("The base URL has to start with http:// or https://.")
            default: toasts.error(e.errorDescription ?? "Could not save.")
            }
        } catch {
            toasts.error(error.localizedDescription)
        }
    }

    private func test() async {
        guard !testing else { return }
        testing = true
        defer { testing = false }
        do {
            let result = try await APIClient.shared.testAiSettings()
            if result.ok {
                Haptics.success()
                toasts.show("Connected · \(result.model ?? "") said “\(result.reply ?? "")”")
            } else {
                Haptics.warning()
                toasts.error(result.error ?? "The provider did not answer.")
            }
        } catch APIError.server(let reason, 400) {
            Haptics.warning()
            toasts.error(reason)
        } catch {
            Haptics.warning()
            toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    // MARK: Behaviour

    private func behaviour(_ s: AiSettings) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Behaviour")
            toggleRow(
                "Learn from my mail",
                hint: "Reads what you send to learn your tone, sign-offs and recurring facts. Runs in the background, at most twice a day.",
                on: s.learn
            ) { value in Task { await save(["learn": value]) } }
            toggleRow(
                "Send mail without asking",
                hint: "Off: the assistant only prepares drafts and you press Send. On: it may send when you clearly ask it to.",
                on: s.autoSend
            ) { value in Task { await save(["auto_send": value]) } }
        }
    }

    private func toggleRow(_ title: String, hint: String, on: Bool, change: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: change)) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                Text(hint)
                    .font(Theme.Typography.small)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Theme.Colors.foreground)
        .disabled(saving)
        .padding(.horizontal, Theme.Metrics.hPadding)
        .padding(.vertical, 10)
        .frame(minHeight: Theme.Metrics.denseRowHeight)
    }

    // MARK: Memory

    private func memory(_ s: AiSettings) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Memory")
            Button {
                nav.push(.aiMemory)
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("What the assistant remembers")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.foreground)
                        Text(s.lastLearnedAt.map { "Last learned \(RelativeTime.long(Date(timeIntervalSince1970: $0 / 1000)))" } ?? "Has not learned from your mail yet")
                            .font(Theme.Typography.small)
                            .foregroundStyle(Theme.Colors.mutedForeground)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Colors.mutedForeground.opacity(0.5))
                }
                .padding(.horizontal, Theme.Metrics.hPadding)
                .frame(minHeight: Theme.Metrics.denseRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
            .hairline()

            Button {
                Task { await learnNow() }
            } label: {
                HStack(spacing: 12) {
                    Text("Learn from my mail now")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.foreground)
                    Spacer(minLength: 12)
                    if learning { ProgressView().tint(Theme.Colors.mutedForeground) }
                }
                .padding(.horizontal, Theme.Metrics.hPadding)
                .frame(minHeight: Theme.Metrics.denseRowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
            .disabled(learning || !s.configured)
            .opacity(s.configured ? 1 : 0.5)
            .hairline()

            Button {
                confirmForget = true
            } label: {
                Text("Forget everything")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.foreground)
                    .padding(.horizontal, Theme.Metrics.hPadding)
                    .frame(minHeight: Theme.Metrics.denseRowHeight)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableRowStyle())
        }
    }

    private func learnNow() async {
        learning = true
        defer { learning = false }
        do {
            let added = try await APIClient.shared.aiLearnNow().changed
            await store.load()
            Haptics.success()
            toasts.show(added == 0 ? "Nothing new to learn" : "Learned \(added) new thing\(added == 1 ? "" : "s")")
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func forget() async {
        do {
            try await APIClient.shared.clearAiMemory()
            await store.load()
            toasts.show("Memory cleared")
        } catch {
            toasts.error((error as? APIError)?.errorDescription ?? error.localizedDescription)
        }
    }

    @ViewBuilder
    private func labelled<Content: View>(_ label: String, hint: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(Theme.Typography.small.weight(.medium))
                .foregroundStyle(Theme.Colors.foreground)
            content()
            if let hint {
                Text(hint)
                    .font(Theme.Typography.micro)
                    .foregroundStyle(Theme.Colors.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct AiField: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(Theme.Typography.body)
            .foregroundStyle(Theme.Colors.foreground)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(Theme.Colors.muted)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.radius, style: .continuous))
    }
}
