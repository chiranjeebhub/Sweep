import SwiftUI
import SweepCore

/// Ask questions about this Mac's storage. Optional: needs the user's own Claude API key.
struct AssistantView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: AssistantModel
    @State private var key = ""

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: "Ask Sweep", subtitle: "Questions about your storage, answered by Claude with read-only access to Sweep's results.") {
                if model.hasKey && !model.lines.isEmpty {
                    Button("New conversation") { model.reset() }.buttonStyle(OutlineButtonStyle()).disabled(model.isThinking)
                }
            }
            if model.hasKey { chat } else { setup }
        }
        .onAppear { model.refreshKey() }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            IconTile(symbol: "bubble.left.and.text.bubble.right", tint: Theme.accent, size: 40)
            Text("Add a Claude API key to ask questions").font(.system(size: 15, weight: .semibold))
            Text("Sweep sends your question and the parts of its scan results Claude asks for (folder names, sizes and suggestions) to Anthropic's API. File contents are never sent. Claude can select suggestions in Cleanup, but only you can remove anything. Usage is billed to your API account.")
                .font(.system(size: 13)).foregroundStyle(Theme.mutedText).fixedSize(horizontal: false, vertical: true)
            SecureField("sk-ant-…", text: $key)
                .textFieldStyle(.roundedBorder).frame(maxWidth: 420)
                .onSubmit { model.saveKey(key); key = "" }
            HStack(spacing: 10) {
                Button("Save to Keychain") { model.saveKey(key); key = "" }.buttonStyle(PillButtonStyle()).disabled(key.isEmpty)
                Link("Get a key", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.system(size: 12))
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var chat: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if model.lines.isEmpty { suggestions }
                        ForEach(model.lines) { line in row(line).id(line.id) }
                        if model.isThinking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Thinking…").font(.system(size: 12)).foregroundStyle(Theme.mutedText)
                            }
                            .id("thinking")
                        }
                    }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(.horizontal, 28).padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.lines.count) { _ in
                    withAnimation { proxy.scrollTo(model.isThinking ? AnyHashable("thinking") : AnyHashable(model.lines.last?.id), anchor: .bottom) }
                }
            }
            FooterBar {
                TextField("Ask about your storage", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                    .onSubmit { Task { await model.send() } }
                    .disabled(model.isThinking)
                Button("Send") { Task { await model.send() } }
                    .buttonStyle(PillButtonStyle())
                    .disabled(model.isThinking || model.draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faintText)
            ForEach(["What's using the most space?", "What can I safely clean up right now?",
                     "Which developer caches are worth clearing?", "Why is my Library folder so big?"], id: \.self) { question in
                Button(question) { model.draft = question; Task { await model.send() } }
                    .buttonStyle(OutlineButtonStyle())
            }
            if app.storage.result == nil {
                Text("Run a scan first for the most useful answers.").font(.system(size: 12)).foregroundStyle(Theme.caution)
            }
        }
    }

    @ViewBuilder private func row(_ line: AssistantModel.Line) -> some View {
        switch line.role {
        case .user:
            Text(line.text).font(.system(size: 13)).textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.selection))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Text((try? AttributedString(markdown: line.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line.text))
                .font(.system(size: 13)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label(line.text, systemImage: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.faintText)
        case .error:
            Text(line.text).font(.system(size: 12)).foregroundStyle(Theme.critical)
        }
        if line.role == .tool, line.text.hasPrefix("Selected") {
            Button("Review in Cleanup") { app.selection = .cleanup }.buttonStyle(LinkButtonStyle())
        }
    }
}
