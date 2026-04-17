import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
            LLMSettingsView()
                .tabItem { Label("LLM", systemImage: "sparkles") }
            SyncSettingsView()
                .tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
            AboutSettingsView()
                .tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 380)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage("hotkeyEnabled") private var hotkeyEnabled = true
    @AppStorage("soundEnabled")  private var soundEnabled  = true

    var body: some View {
        Form {
            Section("快捷键") {
                Toggle("启用全局快捷键", isOn: $hotkeyEnabled)
                Text("⌥⌘P 新建项目（周级）· ⌥⌘N 记临时任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("反馈") {
                Toggle("完成任务时播放音效", isOn: $soundEnabled)
            }
        }
        .formStyle(.grouped)
    }
}

private struct LLMSettingsView: View {
    @AppStorage(LLMProviderResolver.providerKindKey) private var providerRaw: String = LLMProviderKind.anthropic.rawValue
    @AppStorage("userPersona") private var persona: String = ""

    private var providerKind: LLMProviderKind {
        LLMProviderKind(rawValue: providerRaw) ?? .anthropic
    }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Provider", selection: $providerRaw) {
                    ForEach(LLMProviderKind.allCases) { kind in
                        Text(kind.label).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.segmented)

                Text(providerHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            switch providerKind {
            case .anthropic: AnthropicConfigSection()
            case .openai:    OpenAIConfigSection()
            case .ollama:    OllamaConfigSection()
            }

            Section("个人画像") {
                TextEditor(text: $persona)
                    .font(.system(size: 12))
                    .frame(minHeight: 60)
                Text("告诉 LLM 你是谁、如何工作。例：「研究生，ADHD，写作拖延，只要一眼就能动手的任务」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var providerHint: String {
        switch providerKind {
        case .anthropic: return "官方 Anthropic 或兼容端点（MiniMax 等）。通过 `x-api-key` + `/v1/messages` 走 tool-use 结构化输出。"
        case .openai:    return "OpenAI Chat Completions。走 `response_format: json_schema (strict)` 强制结构化输出。"
        case .ollama:    return "本地 Ollama 守护进程（默认 http://localhost:11434）。无需 Key；走 `format` 字段的 JSON schema。"
        }
    }
}

// MARK: - Anthropic

private struct AnthropicConfigSection: View {
    @AppStorage("llmBaseURL") private var baseURL: String = ClaudeProvider.defaultBaseURL
    @AppStorage("llmModel") private var model: String = ClaudeProvider.defaultModel
    @State private var apiKey: String = ""
    @State private var keySaved: Bool = false
    @State private var revealed: Bool = false

    private enum Preset: String, CaseIterable, Identifiable {
        case anthropic, minimax, custom
        var id: String { rawValue }
        var label: String {
            switch self {
            case .anthropic: return "Anthropic 官方"
            case .minimax:   return "MiniMax 兼容"
            case .custom:    return "自定义"
            }
        }
    }

    private var preset: Preset {
        switch baseURL {
        case "https://api.anthropic.com": return .anthropic
        case "https://api.minimaxi.com/anthropic": return .minimax
        default: return .custom
        }
    }

    var body: some View {
        Section("接入点") {
            Picker("预设", selection: Binding(
                get: { preset },
                set: { applyPreset($0) }
            )) {
                ForEach(Preset.allCases) { p in Text(p.label).tag(p) }
            }
            .pickerStyle(.segmented)

            TextField("Base URL", text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            TextField("模型", text: $model)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
        }

        ApiKeySection(
            placeholder: "sk-ant-…",
            account: .anthropic,
            apiKey: $apiKey,
            keySaved: $keySaved,
            revealed: $revealed
        )
    }

    private func applyPreset(_ p: Preset) {
        switch p {
        case .anthropic:
            baseURL = "https://api.anthropic.com"
            if model.hasPrefix("MiniMax") || model.isEmpty { model = "claude-sonnet-4-6" }
        case .minimax:
            baseURL = "https://api.minimaxi.com/anthropic"
            if model.hasPrefix("claude") || model.isEmpty { model = "MiniMax-M2.7" }
        case .custom:
            break
        }
    }
}

// MARK: - OpenAI

private struct OpenAIConfigSection: View {
    @AppStorage(OpenAIProvider.baseURLKey) private var baseURL: String = OpenAIProvider.defaultBaseURL
    @AppStorage(OpenAIProvider.modelKey) private var model: String = OpenAIProvider.defaultModel
    @State private var apiKey: String = ""
    @State private var keySaved: Bool = false
    @State private var revealed: Bool = false

    var body: some View {
        Section("接入点") {
            TextField("Base URL", text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            TextField("模型", text: $model)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            Text("请求打到 \(baseURL)/v1/chat/completions。推荐 `gpt-4.1-mini` / `gpt-4o-mini`。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        ApiKeySection(
            placeholder: "sk-…",
            account: .openai,
            apiKey: $apiKey,
            keySaved: $keySaved,
            revealed: $revealed
        )
    }
}

// MARK: - Ollama

private struct OllamaConfigSection: View {
    @AppStorage(OllamaProvider.baseURLKey) private var baseURL: String = OllamaProvider.defaultBaseURL
    @AppStorage(OllamaProvider.modelKey) private var model: String = OllamaProvider.defaultModel

    var body: some View {
        Section("接入点") {
            TextField("Base URL", text: $baseURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            TextField("模型", text: $model)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
            Text("先在终端 `ollama pull \(model)` 把模型拉下来。本地模型，无需 Key。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Shared key section

private struct ApiKeySection: View {
    let placeholder: String
    let account: KeychainStore.Account
    @Binding var apiKey: String
    @Binding var keySaved: Bool
    @Binding var revealed: Bool

    var body: some View {
        Section("API Key") {
            HStack {
                if revealed {
                    TextField(placeholder, text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField(placeholder, text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }
                Button(revealed ? "隐藏" : "显示") { revealed.toggle() }
                    .buttonStyle(.bordered)
            }
            HStack {
                Button("保存到 Keychain") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("清除") { clear() }
                    .buttonStyle(.bordered)
                if keySaved {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Spacer()
            }
            Text("保存在系统 Keychain（\(KeychainStore.hasKey(account) ? "已配置" : "未配置")）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onAppear { load() }
        .onChange(of: account) { _, _ in load() }
    }

    private func load() {
        apiKey = KeychainStore.get(account) ?? ""
        keySaved = !apiKey.isEmpty
    }

    private func save() {
        KeychainStore.set(apiKey, for: account)
        keySaved = true
    }

    private func clear() {
        apiKey = ""
        KeychainStore.set(nil, for: account)
        keySaved = false
    }
}

private struct SyncSettingsView: View {
    @AppStorage("remindersSyncEnabled") private var remindersEnabled = false
    @State private var folderPathDisplay: String = ""
    @State private var folderIsICloud: Bool = false
    @State private var remindersStatus: String = ""

    private var iCloudAvailable: Bool { MarkdownFolderStore.iCloudAvailable() }

    var body: some View {
        Form {
            Section("项目文件夹") {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if folderIsICloud {
                        Text("☁️")
                            .font(.system(size: 13))
                            .help("这个文件夹在 iCloud Drive 里——改动会自动跨设备同步")
                    }
                    Text(folderPathDisplay.isEmpty ? "尚未选择" : folderPathDisplay)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(folderPathDisplay.isEmpty ? .secondary : .primary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("选择…") { pickFolder() }
                        .buttonStyle(.borderedProminent)
                    if !folderPathDisplay.isEmpty {
                        Button("清除") { clearFolder() }
                            .buttonStyle(.bordered)
                    }
                }
                if iCloudAvailable && !folderIsICloud {
                    Button {
                        useICloudDefault()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "icloud.fill")
                            Text("使用 iCloud Drive 默认位置")
                        }
                    }
                    .buttonStyle(.bordered)
                    .help("把项目文件夹设为 iCloud Drive/NextStep/projects，自动跨设备同步")
                }
                Text("每个项目会保存为这个文件夹下的一个 `.md` 文件。你可以用任意编辑器打开它——修改会自动同步回便利贴。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Apple Reminders") {
                Toggle("与 Reminders 双向同步", isOn: $remindersEnabled)
                    .onChange(of: remindersEnabled) { _, newValue in
                        if newValue {
                            Task { @MainActor in
                                _ = await RemindersBridge.shared.ensureAccess(promptIfNeeded: true)
                                refreshRemindersStatus()
                            }
                        } else {
                            refreshRemindersStatus()
                        }
                    }
                HStack {
                    Text(remindersStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if RemindersBridge.shared.authorizationStatus != .fullAccess {
                        Button("授权 Reminders 访问") {
                            Task { @MainActor in
                                _ = await RemindersBridge.shared.ensureAccess(promptIfNeeded: true)
                                refreshRemindersStatus()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                Text("当前下一步会出现在 Reminders 的「NextStep」列表里。在 Reminders.app 勾选 → 便利贴自动推下一步。临时任务（⌥⌘N）双向同步。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("跨设备同步") {
                HStack(spacing: 6) {
                    Image(systemName: iCloudAvailable ? "checkmark.icloud.fill" : "xmark.icloud")
                        .foregroundStyle(iCloudAvailable ? .green : .secondary)
                    Text(iCloudAvailable ? "iCloud Drive 已启用" : "iCloud Drive 不可用（请在 系统设置 → Apple 账户 开启）")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Text("NextStep 不做 CloudKit 同步——把项目文件夹选到 iCloud Drive 下，macOS 会原生跨设备同步所有 `.md` 文件。便利贴位置、颜色等 UI 状态留在本机（本来就不跨设备也无所谓）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshFolderDisplay()
            refreshRemindersStatus()
        }
    }

    private func pickFolder() {
        if let url = MarkdownFolderStore.shared.pickFolder() {
            folderPathDisplay = url.path
            folderIsICloud = MarkdownFolderStore.isICloudURL(url)
            MarkdownBridge.shared.restartWatcher()
        }
    }

    private func useICloudDefault() {
        if let url = MarkdownFolderStore.shared.adoptICloudDefault() {
            folderPathDisplay = url.path
            folderIsICloud = true
            MarkdownBridge.shared.restartWatcher()
        }
    }

    private func clearFolder() {
        MarkdownFolderStore.shared.clearFolder()
        MarkdownBridge.shared.restartWatcher()
        folderPathDisplay = ""
        folderIsICloud = false
    }

    private func refreshFolderDisplay() {
        if let url = MarkdownFolderStore.shared.currentURL {
            folderPathDisplay = url.path
            folderIsICloud = MarkdownFolderStore.isICloudURL(url)
        } else {
            folderPathDisplay = ""
            folderIsICloud = false
        }
    }

    private func refreshRemindersStatus() {
        switch RemindersBridge.shared.authorizationStatus {
        case .fullAccess:
            remindersStatus = remindersEnabled ? "已授权 · 同步中" : "已授权 · 已关闭"
        case .writeOnly:
            remindersStatus = "权限不足（仅写入）— 请在系统设置中改为完全访问"
        case .denied, .restricted:
            remindersStatus = "Reminders 权限被拒 — 请在系统设置中开启"
        case .notDetermined:
            remindersStatus = "未授权"
        @unknown default:
            remindersStatus = "未知状态"
        }
    }
}

private struct AboutSettingsView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("NextStep").font(.title2).bold()
            Text("v\(version) · M3").foregroundStyle(.secondary)
            Text("ADHD 友好的「下一步」仪表盘").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview { SettingsView() }
