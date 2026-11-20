import SwiftUI

private enum ChatRole: String, CaseIterable, Codable {
    case other = "对方"
    case me = "我"
}

private struct ChatMessage: Identifiable, Codable {
    var id: UUID
    var text: String
    var role: ChatRole
    var time: Date

    init(text: String, role: ChatRole, time: Date = .now) {
        self.id = UUID()
        self.text = text
        self.role = role
        self.time = time
    }
}

private struct ChatIdentity: Codable {
    var me = "我"
    var other = "对方"
}

@MainActor
final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = [] { didSet { save() } }
    @Published var activeRole: ChatRole = .me
    @Published var identity = ChatIdentity() { didSet { save() } }

    private let key = "customchat.messages.v1"
    private let identityKey = "customchat.identity.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = decoded
        }
        if let data = UserDefaults.standard.data(forKey: identityKey),
           let decoded = try? JSONDecoder().decode(ChatIdentity.self, from: data) {
            identity = decoded
        }
    }

    func send(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        messages.append(ChatMessage(text: value, role: activeRole))
    }

    func update(_ message: ChatMessage, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].text = text
    }

    func delete(_ message: ChatMessage) {
        messages.removeAll { $0.id == message.id }
    }

    func name(for role: ChatRole) -> String {
        role == .me ? identity.me : identity.other
    }

    private func save() {
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: key)
        }
        if let data = try? JSONEncoder().encode(identity) {
            UserDefaults.standard.set(data, forKey: identityKey)
        }
    }
}

struct ContentView: View {
    @StateObject private var model = ChatModel()
    @State private var draft = ""
    @State private var editing: ChatMessage?
    @State private var editText = ""
    @State private var showIdentitySettings = false

    private let canvas = Color(red: 0.965, green: 0.973, blue: 0.985)

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if model.messages.isEmpty {
                            emptyState
                                .padding(.top, 100)
                        } else {
                            Text("今天")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 8)
                            ForEach(model.messages) { message in
                                MessageRow(
                                    message: message,
                                    name: model.name(for: message.role),
                                    onEdit: {
                                        editing = message
                                        editText = message.text
                                    },
                                    onDelete: { model.delete(message) }
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 20)
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last {
                        withAnimation(.easeOut(duration: 0.25)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            composer
        }
        .background(canvas.ignoresSafeArea())
        .sheet(isPresented: $showIdentitySettings) {
            identitySheet
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert("编辑消息", isPresented: Binding(
            get: { editing != nil },
            set: { if !$0 { editing = nil } }
        )) {
            TextField("消息内容", text: $editText)
            Button("取消", role: .cancel) { editing = nil }
            Button("保存") {
                if let editing { model.update(editing, text: editText) }
                editing = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white)
                    .frame(width: 42, height: 42)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 0.40, green: 0.62, blue: 0.82))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("自定义聊天")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("CustomChat")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { showIdentitySettings = true } label: {
                Image(systemName: "person.2.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(.primary.opacity(0.75))
                    .frame(width: 42, height: 42)
                    .background(.white.opacity(0.8), in: Circle())
            }
            .accessibilityLabel("编辑双方身份")
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(Color.blue.opacity(0.55))
            Text("开始编写一段对话")
                .font(.headline)
                .foregroundStyle(.primary.opacity(0.8))
            Text("切换发送身份，消息就会显示在对应一侧。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("发送身份")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach(ChatRole.allCases, id: \.self) { role in
                        Button {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                                model.activeRole = role
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(role == .me ? Color(red: 0.48, green: 0.70, blue: 0.88) : Color(red: 0.76, green: 0.67, blue: 0.88))
                                    .frame(width: 7, height: 7)
                                Text(role.rawValue)
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(model.activeRole == role ? .primary : .secondary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background {
                                if model.activeRole == role {
                                    Capsule().fill(.white).shadow(color: .black.opacity(0.06), radius: 5, y: 2)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(Color.black.opacity(0.045), in: Capsule())
                Spacer()
                Text("以\(model.name(for: model.activeRole))的身份发送")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入消息…", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .font(.system(size: 16))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 22))
                    .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.black.opacity(0.045), lineWidth: 1))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray.opacity(0.35) : Color(red: 0.40, green: 0.63, blue: 0.82), in: Circle())
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 13)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
    }

    private func send() {
        model.send(draft)
        draft = ""
    }

    private var identitySheet: some View {
        NavigationStack {
            Form {
                Section("我的身份") {
                    TextField("我的昵称", text: $model.identity.me)
                }
                Section("对方身份") {
                    TextField("对方昵称", text: $model.identity.other)
                }
                Section {
                    Text("发送身份只决定新消息显示在哪一侧。切换身份不会改变已有消息。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("聊天身份")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showIdentitySettings = false }
                }
            }
        }
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let name: String
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var isMe: Bool { message.role == .me }

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            if isMe { Spacer(minLength: 55) }
            if !isMe { avatar }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 5) {
                Text(name)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                Text(message.text)
                    .font(.system(size: 16))
                    .foregroundStyle(isMe ? .white : Color.primary.opacity(0.88))
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(
                        isMe ? Color(red: 0.43, green: 0.66, blue: 0.84) : .white,
                        in: RoundedRectangle(cornerRadius: 19, style: .continuous)
                    )
                    .contextMenu {
                        Button("编辑", systemImage: "pencil", action: onEdit)
                        Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                    }
                Text(message.time, format: .dateTime.hour().minute())
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
            }
            if isMe { avatar }
            if !isMe { Spacer(minLength: 55) }
        }
        .transition(.asymmetric(
            insertion: .move(edge: isMe ? .trailing : .leading).combined(with: .opacity),
            removal: .opacity
        ))
    }

    private var avatar: some View {
        Text(String(name.prefix(1)))
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isMe ? Color.blue : Color.purple)
            .frame(width: 30, height: 30)
            .background(isMe ? Color.blue.opacity(0.12) : Color.purple.opacity(0.12), in: Circle())
    }
}
