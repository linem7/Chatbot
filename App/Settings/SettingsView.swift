import ChatbotCore
import KeyboardShortcuts
import SwiftUI

/// 设置窗口，三个标签页：通用、Connection、高级（SPEC §9）。
struct SettingsView: View {
    let chat: ChatStore
    let history: HistoryModel
    @Bindable var navigation: SettingsNavigation
    let launchAtLogin: LaunchAtLogin
    let hotkey: HotkeyController

    var body: some View {
        TabView(selection: $navigation.tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsView(connections: chat.connections, launchAtLogin: launchAtLogin, hotkey: hotkey)
            }
            Tab("Connections", systemImage: "network", value: SettingsTab.connections) {
                ConnectionsSettingsView(chat: chat, history: history, navigation: navigation)
            }
            Tab("Advanced", systemImage: "slider.horizontal.3", value: SettingsTab.advanced) {
                AdvancedSettingsView(history: history)
            }
        }
        .frame(width: 680, height: 500)
        .regularWindow(.settings)
    }
}

// MARK: - 通用

private struct GeneralSettingsView: View {
    @Bindable var connections: ConnectionStore
    let launchAtLogin: LaunchAtLogin
    let hotkey: HotkeyController
    @AppStorage(WebSearchDefault.defaultsKey) private var webSearchOnByDefault = false

    var body: some View {
        Form {
            Section {
                Picker("Hotkey", selection: Binding(
                    get: { hotkey.trigger },
                    set: { hotkey.select($0) }
                )) {
                    ForEach(HotkeyTrigger.allCases) { trigger in
                        Text(trigger.label).tag(trigger)
                    }
                }
                if hotkey.trigger == .shortcut {
                    // 改键时和系统快捷键冲突，Recorder 自己会提示（SPEC §2.1）
                    LabeledContent("Combination") {
                        KeyboardShortcuts.Recorder(for: .toggleQuickPanel)
                    }
                    Text(Hotkey.otherAppsHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    doubleCommandRows
                }
            }

            Section {
                Picker("Default Model", selection: $connections.defaultModel) {
                    Text("None").tag(ModelRef?.none)
                    ForEach(connections.connections) { connection in
                        ForEach(connections.visibleModels(of: connection)) { model in
                            Text(verbatim: "\(connection.name) / \(model.displayName ?? model.id)")
                                .tag(Optional(ModelRef(connectionID: connection.id, modelID: model.id)))
                        }
                    }
                }
                .disabled(connections.connections.isEmpty)
                if connections.defaultModel == nil, !connections.connections.isEmpty {
                    // Default Model 所在的 Connection 被删掉之后，要求用户重新选（SPEC §9）
                    Text("Choose a Default Model for new conversations.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                // 新对话默认不联网（SPEC §5、#68）
                Toggle("Search the Web in New Conversations", isOn: $webSearchOnByDefault)
                Text("Only for models that can search. The globe button still turns it on or off for the current conversation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin.isEnabled || launchAtLogin.requiresApproval },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if launchAtLogin.requiresApproval {
                    HStack {
                        Text("Allow Chatbot in System Settings › General › Login Items & Extensions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { launchAtLogin.openSystemSettings() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin.refresh()
            // 用户可能刚在 System Settings 里把权限打开，设置窗一露面就重看一次（#64）
            hotkey.refreshPermission()
        }
    }

    /// ⌘ 双击读的是全系统的修饰键状态，先得有「辅助功能」权限（SPEC §2.1、#64）。
    @ViewBuilder private var doubleCommandRows: some View {
        if hotkey.isTrusted {
            Text("A double ⌘ opens the Quick Panel from anywhere. The key combination no longer works while this is on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            HStack {
                Text("Allow Chatbot in System Settings › Privacy & Security › Accessibility. Until then the key combination above still works.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer()
                Button("Open Accessibility") { hotkey.openSystemSettings() }
            }
        }
    }
}

// MARK: - 高级

private struct AdvancedSettingsView: View {
    let history: HistoryModel
    @AppStorage(SystemPrompt.defaultsKey) private var systemPrompt = SystemPrompt.defaultText
    @State private var isConfirmingClear = false
    @State private var isClearing = false

    var body: some View {
        Form {
            Section("System Prompt") {
                TextEditor(text: $systemPrompt)
                    .font(.body)
                    .frame(minHeight: 160)
                HStack {
                    Text("Today's date is added at the start automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Default") { systemPrompt = SystemPrompt.defaultText }
                        .disabled(systemPrompt == SystemPrompt.defaultText)
                }
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Clear All History")
                        Text("Deletes every conversation and its attachments.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isClearing { ProgressView().controlSize(.small) }
                    Button("Clear…", role: .destructive) { isConfirmingClear = true }
                        .disabled(isClearing)
                }
            }
        }
        .formStyle(.grouped)
        // 清空全部历史要二次确认（SPEC §9）
        .confirmationDialog("Clear all history?", isPresented: $isConfirmingClear) {
            Button("Clear All History", role: .destructive) {
                isClearing = true
                Task {
                    await history.deleteAll()
                    isClearing = false
                }
            }
        } message: {
            Text("All conversations and their attachments will be deleted. This can't be undone.")
        }
    }
}
