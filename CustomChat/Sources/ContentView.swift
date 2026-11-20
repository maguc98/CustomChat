import SwiftUI
import PhotosUI
import UIKit
import AudioToolbox

enum ChatRole: String, CaseIterable, Codable {
    case other = "对方"
    case me = "我"
}

struct ChatMessage: Identifiable, Codable {
    var id: UUID
    var text: String
    var role: ChatRole
    var time: Date
    var imageData: Data?

    init(text: String = "", role: ChatRole, time: Date = .now, imageData: Data? = nil) {
        self.id = UUID()
        self.text = text
        self.role = role
        self.time = time
        self.imageData = imageData
    }
}

struct ChatIdentity: Codable {
    var me = "我"
    var other = "对方"
    var meAvatarData: Data?
    var otherAvatarData: Data?
}

struct CallRecord: Identifiable, Codable {
    var id: UUID
    var isVideo: Bool
    var date: Date
    var duration: Int

    init(isVideo: Bool, duration: Int) {
        id = UUID()
        self.isVideo = isVideo
        date = .now
        self.duration = duration
    }
}

@MainActor
private final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = [] { didSet { save() } }
    @Published var activeRole: ChatRole = .me
    @Published var identity = ChatIdentity() { didSet { save() } }
    @Published var calls: [CallRecord] = [] { didSet { save() } }

    private let messagesKey = "customchat.messages.v1"
    private let identityKey = "customchat.identity.v1"
    private let callsKey = "customchat.calls.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: messagesKey),
           let value = try? JSONDecoder().decode([ChatMessage].self, from: data) {
            messages = value
        }
        if let data = UserDefaults.standard.data(forKey: identityKey),
           let value = try? JSONDecoder().decode(ChatIdentity.self, from: data) {
            identity = value
        }
        if let data = UserDefaults.standard.data(forKey: callsKey),
           let value = try? JSONDecoder().decode([CallRecord].self, from: data) {
            calls = value
        }
    }

    func send(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        messages.append(ChatMessage(text: value, role: activeRole))
    }

    func sendImage(_ data: Data) {
        messages.append(ChatMessage(role: activeRole, imageData: data))
    }

    func update(_ message: ChatMessage, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].text = text
    }

    func delete(_ message: ChatMessage) {
        messages.removeAll { $0.id == message.id }
    }

    func addCall(isVideo: Bool, duration: Int) {
        calls.insert(CallRecord(isVideo: isVideo, duration: duration), at: 0)
        if calls.count > 100 { calls = Array(calls.prefix(100)) }
    }

    func name(for role: ChatRole) -> String {
        let value = role == .me ? identity.me : identity.other
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? role.rawValue : value
    }

    func avatar(for role: ChatRole) -> Data? {
        role == .me ? identity.meAvatarData : identity.otherAvatarData
    }

    private func save() {
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: messagesKey)
        }
        if let data = try? JSONEncoder().encode(identity) {
            UserDefaults.standard.set(data, forKey: identityKey)
        }
        if let data = try? JSONEncoder().encode(calls) {
            UserDefaults.standard.set(data, forKey: callsKey)
        }
    }
}

private enum AppTab: String, CaseIterable {
    case chats = "聊天"
    case calls = "通话"
    case album = "相册"
    case profile = "我的"

    var symbol: String {
        switch self {
        case .chats: return "bubble.left.and.bubble.right"
        case .calls: return "phone"
        case .album: return "photo"
        case .profile: return "person"
        }
    }
}

private enum Macaron {
    static let background = Color(hex: 0xF5F7FB)
    static let card = Color(hex: 0xFFFFFF)
    static let ink = Color(hex: 0x202A3A)
    static let secondary = Color(hex: 0x788397)
    static let blue = Color(hex: 0xD8EAFF)
    static let blueStrong = Color(hex: 0x8FC7FF)
    static let pink = Color(hex: 0xF9DDEB)
    static let mint = Color(hex: 0xDDF2E8)
    static let lavender = Color(hex: 0xE9E2FA)
    static let line = Color(hex: 0xE9EDF3)
}

private struct SimulatedCall: Identifiable {
    let id = UUID()
    let isVideo: Bool
}

private struct SelectedPhoto: Identifiable {
    let id = UUID()
    let data: Data
}

struct ContentView: View {
    @StateObject private var model = ChatModel()
    @State private var selectedTab: AppTab = .chats
    @State private var showConversation = false
    @State private var showIdentitySettings = false
    @State private var searchText = ""
    @State private var draft = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var myAvatarSelection: PhotosPickerItem?
    @State private var otherAvatarSelection: PhotosPickerItem?
    @State private var editing: ChatMessage?
    @State private var editText = ""
    @State private var activeCall: SimulatedCall?
    @State private var previewPhoto: SelectedPhoto?
    @State private var showClearConfirmation = false
    @State private var showBackgroundPicker = false
    @State private var showThemePicker = false
    @State private var showFontPicker = false
    @State private var showSoundPicker = false

    @AppStorage("customchat.preference.background") private var backgroundOption = "雾蓝白"
    @AppStorage("customchat.preference.theme") private var themeOption = "浅蓝"
    @AppStorage("customchat.preference.font") private var fontOption = "标准"
    @AppStorage("customchat.preference.sound") private var soundOption = "轻柔"

    private var accentColor: Color {
        switch themeOption {
        case "樱花粉": return Color(hex: 0xF0B8D2)
        case "薄荷绿": return Color(hex: 0xA9DCC5)
        case "薰衣草紫": return Color(hex: 0xC9B9ED)
        default: return Macaron.blueStrong
        }
    }

    private var messageFontSize: CGFloat {
        switch fontOption {
        case "偏小": return 14
        case "偏大": return 18
        default: return 16
        }
    }

    private var conversationBackground: Color {
        switch backgroundOption {
        case "奶油白": return Color(hex: 0xFBF8F1)
        case "淡粉": return Color(hex: 0xFCF1F6)
        case "薄荷绿": return Color(hex: 0xF0F8F3)
        default: return Macaron.background
        }
    }

    var body: some View {
        ZStack {
            Macaron.background.ignoresSafeArea()
            if showConversation {
                conversationView
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                mainTabView
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(.light)
        .sheet(isPresented: $showIdentitySettings) { settingsSheet }
        .sheet(item: $previewPhoto) { photo in
            PhotoPreviewView(data: photo.data)
        }
        .fullScreenCover(item: $activeCall) { call in
            SimulatedCallView(
                name: model.name(for: .other),
                meName: model.name(for: .me),
                avatarData: model.identity.otherAvatarData,
                isVideo: call.isVideo
            ) { duration in
                model.addCall(isVideo: call.isVideo, duration: duration)
                activeCall = nil
            }
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let compact = compactImageData(data) {
                    model.sendImage(compact)
                    playMessageSound()
                }
                selectedPhoto = nil
            }
        }
        .onChange(of: myAvatarSelection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let compact = compactImageData(data) {
                    model.identity.meAvatarData = compact
                }
                myAvatarSelection = nil
            }
        }
        .onChange(of: otherAvatarSelection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let compact = compactImageData(data) {
                    model.identity.otherAvatarData = compact
                }
                otherAvatarSelection = nil
            }
        }
        .confirmationDialog("聊天背景", isPresented: $showBackgroundPicker, titleVisibility: .visible) {
            ForEach(["雾蓝白", "奶油白", "淡粉", "薄荷绿"], id: \.self) { option in
                Button(option) { backgroundOption = option }
            }
        }
        .confirmationDialog("主题颜色", isPresented: $showThemePicker, titleVisibility: .visible) {
            ForEach(["浅蓝", "樱花粉", "薄荷绿", "薰衣草紫"], id: \.self) { option in
                Button(option) { themeOption = option }
            }
        }
        .confirmationDialog("字体大小", isPresented: $showFontPicker, titleVisibility: .visible) {
            ForEach(["偏小", "标准", "偏大"], id: \.self) { option in
                Button(option) { fontOption = option }
            }
        }
        .confirmationDialog("消息提示音", isPresented: $showSoundPicker, titleVisibility: .visible) {
            ForEach(["轻柔", "清脆", "关闭"], id: \.self) { option in
                Button(option) {
                    soundOption = option
                    if option != "关闭" { playPreviewSound() }
                }
            }
        }
        .alert("清空聊天记录？", isPresented: $showClearConfirmation) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                model.messages.removeAll()
            }
        } message: {
            Text("此操作会删除本机保存的全部消息和图片，无法撤销。")
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

    private var mainTabView: some View {
        VStack(spacing: 0) {
            Group {
                switch selectedTab {
                case .chats: chatListView
                case .calls: callsView
                case .album: albumView
                case .profile: profileView
                }
            }
            tabBar
        }
    }

    private var chatListView: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Text("CustomChat")
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(Macaron.ink)
                Spacer()
                Button { showIdentitySettings = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Color(hex: 0x438FDC))
                        .frame(width: 46, height: 46)
                        .background(Macaron.blue, in: Circle())
                }
                .accessibilityLabel("编辑当前聊天资料")
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 18)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Macaron.secondary)
                TextField("搜索聊天", text: $searchText)
                    .font(.system(size: 15))
                    .foregroundStyle(Macaron.ink)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Color(hex: 0xEEF1F6), in: Capsule())
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近聊天")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Macaron.secondary)
                        .padding(.horizontal, 5)

                    if model.name(for: .other).localizedCaseInsensitiveContains(searchText)
                        || "聊天".localizedCaseInsensitiveContains(searchText)
                        || searchText.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) { showConversation = true }
                        } label: {
                            ChatListRow(
                                name: model.name(for: .other),
                                preview: model.messages.last.map {
                                    $0.imageData == nil ? $0.text : "发来了一张图片"
                                } ?? "开始你们的第一段对话",
                                time: model.messages.last?.time.formatted(date: .omitted, time: .shortened) ?? "现在",
                                avatarData: model.identity.otherAvatarData,
                                tint: Macaron.pink,
                                isOnline: true,
                                accentColor: accentColor
                            )
                        }
                        .buttonStyle(.plain)
                    } else {
                        EmptyHint(symbol: "magnifyingglass", title: "没有找到聊天", subtitle: "试试对方的昵称。")
                            .padding(.top, 50)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            Spacer(minLength: 0)
        }
    }

    private var conversationView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { showConversation = false }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Macaron.ink)
                        .frame(width: 30, height: 42)
                }
                IdentityAvatar(data: model.identity.otherAvatarData, name: model.name(for: .other), size: 48, tint: Macaron.pink)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name(for: .other))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Macaron.ink)
                    HStack(spacing: 6) {
                        Circle().fill(Color(hex: 0x58C994)).frame(width: 7, height: 7)
                        Text("本地模拟聊天").font(.system(size: 13, weight: .medium)).foregroundStyle(Macaron.secondary)
                    }
                }
                Spacer()
                Button { beginCall(video: false) } label: {
                    Image(systemName: "phone").font(.system(size: 19)).foregroundStyle(Macaron.ink).frame(width: 34, height: 40)
                }
                .accessibilityLabel("模拟语音通话")
                Button { beginCall(video: true) } label: {
                    Image(systemName: "video").font(.system(size: 20)).foregroundStyle(Macaron.ink).frame(width: 34, height: 40)
                }
                .accessibilityLabel("模拟视频通话")
                Button { showIdentitySettings = true } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold)).foregroundStyle(Macaron.ink).frame(width: 30, height: 40)
                }
            }
            .padding(.horizontal, 19)
            .padding(.top, 10)
            .padding(.bottom, 13)
            .background(Macaron.card)

            Rectangle().fill(Macaron.line).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 23) {
                        Text("今天")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Macaron.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color(hex: 0xEEF1F6), in: Capsule())
                            .padding(.top, 18)

                        if model.messages.isEmpty {
                            EmptyHint(symbol: "bubble.left", title: "从这里开始聊天", subtitle: "切换发送身份，发送文字或图片。")
                                .padding(.top, 100)
                        } else {
                            ForEach(model.messages) { message in
                                MessageRow(
                                    message: message,
                                    name: model.name(for: message.role),
                                    avatarData: model.avatar(for: message.role),
                                    isMe: message.role == .me,
                                    fontSize: messageFontSize,
                                    outgoingColor: accentColor,
                                    onEdit: { editing = message; editText = message.text },
                                    onDelete: { model.delete(message) },
                                    onImageTap: { data in previewPhoto = SelectedPhoto(data: data) }
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last {
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .background(conversationBackground)

            composer
        }
        .background(conversationBackground)
    }

    private var composer: some View {
        VStack(spacing: 11) {
            HStack(spacing: 9) {
                Text("发送身份")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Macaron.secondary)
                    .padding(.trailing, 2)
                ForEach(ChatRole.allCases, id: \.self) { role in
                    Button { withAnimation(.easeOut(duration: 0.16)) { model.activeRole = role } } label: {
                        Text(model.name(for: role))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                            .padding(.horizontal, 17)
                            .frame(height: 34)
                            .background(
                                model.activeRole == role
                                    ? (role == .me ? accentColor.opacity(0.72) : Macaron.pink.opacity(0.85))
                                    : Color(hex: 0xF0F1F5),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 11) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "plus")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(Color(hex: 0x5799D9))
                        .frame(width: 54, height: 54)
                        .background(accentColor.opacity(0.68), in: Circle())
                }
                .accessibilityLabel("发送图片")

                HStack(spacing: 8) {
                    TextField("输入消息...", text: $draft, axis: .vertical)
                        .font(.system(size: fontOption == "偏大" ? 17 : 16))
                        .foregroundStyle(Macaron.ink)
                        .lineLimit(1...4)
                        .padding(.vertical, 12)
                        .onSubmit(sendText)
                    Button(action: sendText) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(accentColor.opacity(0.9), in: Circle())
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.38 : 1)
                }
                .padding(.leading, 17)
                .padding(.trailing, 8)
                .frame(minHeight: 54)
                .background(Macaron.card, in: Capsule())
                .overlay(Capsule().stroke(Color(hex: 0xE5E8EF), lineWidth: 1))
            }
        }
        .padding(.horizontal, 17)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Macaron.card)
    }

    private var profileView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                Text("我的设置")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(Macaron.ink)
                    .padding(.top, 22)

                VStack(spacing: 10) {
                    ProfileIdentityCard(
                        title: "我的昵称",
                        name: model.name(for: .me),
                        avatarData: model.identity.meAvatarData,
                        tint: Macaron.blue
                    ) { showIdentitySettings = true }

                    ProfileIdentityCard(
                        title: "对方昵称",
                        name: model.name(for: .other),
                        avatarData: model.identity.otherAvatarData,
                        tint: Macaron.pink
                    ) { showIdentitySettings = true }
                }
                .padding(.horizontal, 18)

                VStack(spacing: 0) {
                    SettingsRow(symbol: "photo", title: "聊天背景", value: backgroundOption, tint: Color(hex: 0x83B9EF)) {
                        showBackgroundPicker = true
                    }
                    Divider().overlay(Macaron.line).padding(.leading, 54)
                    SettingsRow(symbol: "paintpalette", title: "主题色", value: themeOption, tint: Color(hex: 0xC18AD8)) {
                        showThemePicker = true
                    }
                    Divider().overlay(Macaron.line).padding(.leading, 54)
                    SettingsRow(symbol: "textformat.size", title: "字体大小", value: fontOption, tint: Color(hex: 0x83B9EF)) {
                        showFontPicker = true
                    }
                    Divider().overlay(Macaron.line).padding(.leading, 54)
                    SettingsRow(symbol: "bell", title: "消息提示音", value: soundOption, tint: Color(hex: 0xE6A5C7)) {
                        showSoundPicker = true
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
                .background(Macaron.card, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                .padding(.horizontal, 18)

                VStack(spacing: 0) {
                    Button { showIdentitySettings = true } label: {
                        SettingsLine(symbol: "person.crop.circle", title: "编辑双方资料")
                    }
                    Divider().overlay(Macaron.line).padding(.leading, 54)
                    Button { showClearConfirmation = true } label: {
                        SettingsLine(symbol: "trash", title: "清空聊天记录", tint: Color(hex: 0xD9829F))
                    }
                }
                .padding(.horizontal, 18)
                .background(Macaron.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .padding(.horizontal, 18)

                Text("CustomChat · 本地双身份聊天")
                    .font(.system(size: 11))
                    .foregroundStyle(Macaron.secondary)
                    .padding(.top, 3)
                    .padding(.bottom, 18)
            }
        }
    }

    private var callsView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                Text("通话")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(Macaron.ink)
                    .padding(.top, 22)

                VStack(spacing: 12) {
                    Image(systemName: "phone.badge.waveform")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color(hex: 0x5D9FE2))
                        .frame(width: 72, height: 72)
                        .background(Macaron.blue, in: Circle())
                    Text("模拟通话")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Macaron.ink)
                    Text("所有通话只在 App 内演示，不会拨打真实电话，也不会调用摄像头或麦克风。")
                        .font(.system(size: 12))
                        .foregroundStyle(Macaron.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 10) {
                        Button { beginCall(video: false) } label: {
                            Label("语音", systemImage: "phone")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Macaron.blue, in: Capsule())
                        }
                        Button { beginCall(video: true) } label: {
                            Label("视频", systemImage: "video")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Macaron.pink, in: Capsule())
                        }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Macaron.ink)
                }
                .padding(18)
                .background(Macaron.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 18)

                HStack {
                    Text("最近通话")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Macaron.ink)
                    Spacer()
                    Text("仅本机保存")
                        .font(.system(size: 11))
                        .foregroundStyle(Macaron.secondary)
                }
                .padding(.horizontal, 22)
                .padding(.top, 5)

                if model.calls.isEmpty {
                    EmptyHint(symbol: "clock", title: "还没有模拟通话", subtitle: "完成一次 App 内模拟通话后，会显示在这里。")
                        .padding(.top, 18)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.calls) { call in
                            CallHistoryRow(record: call, name: model.name(for: .other))
                            if call.id != model.calls.last?.id {
                                Divider().overlay(Macaron.line).padding(.leading, 70)
                            }
                        }
                    }
                    .background(Macaron.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 18)
                }
                Spacer(minLength: 20)
            }
        }
    }

    private var albumView: some View {
        VStack(spacing: 0) {
            Text("相册")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(Macaron.ink)
                .padding(.top, 22)
                .padding(.bottom, 18)

            let imageMessages = model.messages.filter { $0.imageData != nil }
            if imageMessages.isEmpty {
                EmptyHint(symbol: "photo", title: "还没有图片", subtitle: "在聊天中发送的图片会自动收录到这里。")
                    .padding(.top, 100)
                Spacer()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                        ForEach(imageMessages) { message in
                            if let data = message.imageData, let image = UIImage(data: data) {
                                Button { previewPhoto = SelectedPhoto(data: data) } label: {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(height: 112)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button { selectedTab = tab } label: {
                    VStack(spacing: 5) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 21, weight: selectedTab == tab ? .semibold : .regular))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(selectedTab == tab ? Color(hex: 0x4F9DE8) : Macaron.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(accentColor.opacity(0.38))
                                .padding(.horizontal, 5)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 6)
        .background(Macaron.card)
        .overlay(alignment: .top) { Rectangle().fill(Macaron.line).frame(height: 1) }
    }

    private var settingsSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    identityEditor(
                        title: "我的资料",
                        name: $model.identity.me,
                        avatarData: model.identity.meAvatarData,
                        selection: $myAvatarSelection,
                        tint: Macaron.blue
                    )
                    identityEditor(
                        title: "对方资料",
                        name: $model.identity.other,
                        avatarData: model.identity.otherAvatarData,
                        selection: $otherAvatarSelection,
                        tint: Macaron.pink
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        Text("通话功能说明")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                        Text("语音和视频通话仅为界面模拟，不会连接系统电话、FaceTime，也不会访问设备摄像头或麦克风。")
                            .font(.system(size: 12))
                            .foregroundStyle(Macaron.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(15)
                    .background(Macaron.card, in: RoundedRectangle(cornerRadius: 18))
                    Text("昵称、头像、消息和模拟通话记录均保存在这台设备上。")
                        .font(.system(size: 12))
                        .foregroundStyle(Macaron.secondary)
                }
                .padding(18)
            }
            .background(Macaron.background)
            .navigationTitle("个人资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showIdentitySettings = false }
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func identityEditor(
        title: String,
        name: Binding<String>,
        avatarData: Data?,
        selection: Binding<PhotosPickerItem?>,
        tint: Color
    ) -> some View {
        HStack(spacing: 14) {
            PhotosPicker(selection: selection, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    IdentityAvatar(data: avatarData, name: name.wrappedValue, size: 64, tint: tint)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color(hex: 0x83B9EF), in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Macaron.secondary)
                TextField("输入昵称", text: name)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Macaron.ink)
                    .padding(12)
                    .background(Macaron.background, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(15)
        .background(Macaron.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func beginCall(video: Bool) {
        activeCall = SimulatedCall(isVideo: video)
    }

    private func sendText() {
        let previousCount = model.messages.count
        model.send(draft)
        draft = ""
        if model.messages.count > previousCount { playMessageSound() }
    }

    private func playMessageSound() {
        guard soundOption != "关闭" else { return }
        AudioServicesPlaySystemSound(soundOption == "清脆" ? 1104 : 1103)
    }

    private func playPreviewSound() {
        AudioServicesPlaySystemSound(soundOption == "清脆" ? 1104 : 1103)
    }

    private func compactImageData(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, 1500 / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.78)
    }
}

private struct ChatListRow: View {
    let name: String
    let preview: String
    let time: String
    let avatarData: Data?
    let tint: Color
    var isOnline = false
    let accentColor: Color

    var body: some View {
        HStack(spacing: 13) {
            ZStack(alignment: .bottomTrailing) {
                IdentityAvatar(data: avatarData, name: name, size: 61, tint: tint)
                if isOnline {
                    Circle()
                        .fill(Color(hex: 0x55C987))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(name)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Macaron.ink)
                Text(preview.isEmpty ? " " : preview)
                    .font(.system(size: 13))
                    .foregroundStyle(Macaron.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 8) {
                Text(time)
                    .font(.system(size: 12))
                    .foregroundStyle(Macaron.secondary)
                Circle()
                    .fill(accentColor)
                    .frame(width: 8, height: 8)
                    .opacity(isOnline ? 1 : 0)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 15)
        .background(Macaron.card, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
    }
}

private struct ProfileIdentityCard: View {
    let title: String
    let name: String
    let avatarData: Data?
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IdentityAvatar(data: avatarData, name: name, size: 66, tint: tint)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(size: 13)).foregroundStyle(Macaron.secondary)
                    Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Macaron.ink)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Macaron.secondary)
            }
            .padding(17)
            .background(Macaron.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsRow: View {
    let symbol: String
    let title: String
    let value: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 19))
                    .foregroundStyle(tint)
                    .frame(width: 28)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Macaron.ink)
                Spacer()
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(Macaron.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Macaron.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 57)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsLine: View {
    let symbol: String
    let title: String
    var tint: Color = Color(hex: 0x83B9EF)

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 28)
            Text(title).foregroundStyle(Macaron.ink)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Macaron.secondary)
        }
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 55)
        .contentShape(Rectangle())
    }
}

private struct CallHistoryRow: View {
    let record: CallRecord
    let name: String

    var body: some View {
        HStack(spacing: 13) {
            Image(systemName: record.isVideo ? "video" : "phone")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(record.isVideo ? Color(hex: 0xD99ABF) : Color(hex: 0x74AEE3))
                .frame(width: 42, height: 42)
                .background(record.isVideo ? Macaron.pink : Macaron.blue, in: Circle())
            VStack(alignment: .leading, spacing: 5) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Macaron.ink)
                Text("\(record.isVideo ? "模拟视频通话" : "模拟语音通话") · \(durationText(record.duration))")
                    .font(.system(size: 12))
                    .foregroundStyle(Macaron.secondary)
            }
            Spacer()
            Text(record.date, format: .dateTime.month(.twoDigits).day().hour().minute())
                .font(.system(size: 11))
                .foregroundStyle(Macaron.secondary)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
    }

    private func durationText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private struct EmptyHint: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 29, weight: .light))
                .foregroundStyle(Color(hex: 0x91B8DE))
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Macaron.ink)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Macaron.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 28)
    }
}

private struct IdentityAvatar: View {
    let data: Data?
    let name: String
    let size: CGFloat
    let tint: Color

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(tint)
                    Text(String(name.prefix(1)))
                        .font(.system(size: size * 0.39, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x55718E))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white, lineWidth: 2))
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let name: String
    let avatarData: Data?
    let isMe: Bool
    let fontSize: CGFloat
    let outgoingColor: Color
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onImageTap: (Data) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 9) {
            if isMe {
                Spacer(minLength: 58)
            } else {
                IdentityAvatar(data: avatarData, name: name, size: 38, tint: Macaron.pink)
            }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 6) {
                messageBubble
                    .contextMenu {
                        if !message.text.isEmpty {
                            Button("编辑", systemImage: "pencil", action: onEdit)
                        }
                        Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                    }

                Text(message.time, format: .dateTime.hour().minute())
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: 0x8791A3))
                    .padding(.horizontal, 7)
            }

            if isMe {
                IdentityAvatar(data: avatarData, name: name, size: 38, tint: Macaron.blue)
            } else {
                Spacer(minLength: 58)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var messageBubble: some View {
        if let data = message.imageData, let image = UIImage(data: data) {
            Button { onImageTap(data) } label: {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 285, maxHeight: 270)
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .padding(7)
                    .background(
                        isMe ? outgoingColor.opacity(0.78) : Macaron.card,
                        in: RoundedRectangle(cornerRadius: 25, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 25, style: .continuous)
                            .stroke(Color.white.opacity(0.95), lineWidth: 1.4)
                    )
            }
            .buttonStyle(.plain)
        } else {
            Text(message.text)
                .font(.system(size: fontSize))
                .foregroundStyle(Macaron.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .background(
                    isMe ? outgoingColor.opacity(0.78) : Macaron.card,
                    in: RoundedRectangle(cornerRadius: 27, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 27, style: .continuous)
                        .stroke(Color.white.opacity(0.9), lineWidth: 1)
                )
        }
    }
}

private struct PhotoPreviewView: View {
    let data: Data
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black)
                } else {
                    ContentUnavailableView("无法显示图片", systemImage: "photo")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct SimulatedCallView: View {
    let name: String
    let meName: String
    let avatarData: Data?
    let isVideo: Bool
    let onEnd: (Int) -> Void

    @State private var isConnected = false
    @State private var isMuted = false
    @State private var isSpeakerOn = true
    @State private var isCameraOn = true
    @State private var connectedAt: Date?
    @State private var didEnd = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0xF4F7FC), Color(hex: 0xE8F1FB), Color(hex: 0xF9EFF5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Text(isVideo ? "模拟视频通话" : "模拟语音通话")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Macaron.secondary)
                    Spacer()
                    Text("仅 App 内演示")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Macaron.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.75), in: Capsule())
                }
                .padding(.horizontal, 22)
                .padding(.top, 18)

                Spacer()

                if isVideo {
                    VStack(spacing: 14) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 32, style: .continuous)
                                .fill(Color(hex: 0xDDEAF7))
                            if isCameraOn {
                                VStack(spacing: 14) {
                                    IdentityAvatar(data: avatarData, name: name, size: 118, tint: Macaron.pink)
                                    Text(name)
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(Macaron.ink)
                                    Text("模拟视频画面")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Macaron.secondary)
                                }
                            } else {
                                VStack(spacing: 10) {
                                    Image(systemName: "video.slash")
                                        .font(.system(size: 34, weight: .light))
                                    Text("摄像头画面已关闭")
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundStyle(Macaron.secondary)
                            }
                        }
                        .frame(height: 390)
                        .overlay(alignment: .bottomTrailing) {
                            VStack(spacing: 6) {
                                IdentityAvatar(data: nil, name: meName, size: 44, tint: Macaron.blue)
                                Text("我")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Macaron.ink)
                            }
                            .padding(12)
                            .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 18))
                            .padding(14)
                        }
                    }
                    .padding(.horizontal, 18)
                } else {
                    VStack(spacing: 18) {
                        IdentityAvatar(data: avatarData, name: name, size: 126, tint: Macaron.pink)
                            .shadow(color: Color(hex: 0xA8C8E8).opacity(0.35), radius: 22, y: 8)
                        Text(name)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                    }
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 8) {
                        Text(isConnected ? callDurationText(at: context.date) : "正在呼叫…")
                            .font(.system(size: 17, weight: .medium, design: .rounded))
                            .foregroundStyle(Macaron.ink)
                        Text(isConnected ? "模拟通话已接通" : "等待模拟接通")
                            .font(.system(size: 12))
                            .foregroundStyle(Macaron.secondary)
                    }
                }
                .padding(.top, 26)

                Spacer()

                HStack(spacing: 24) {
                    CallControlButton(symbol: isMuted ? "mic.slash.fill" : "mic.fill", title: "静音", isActive: isMuted) {
                        isMuted.toggle()
                    }
                    CallControlButton(symbol: isSpeakerOn ? "speaker.wave.2.fill" : "speaker.slash.fill", title: "扬声器", isActive: isSpeakerOn) {
                        isSpeakerOn.toggle()
                    }
                    if isVideo {
                        CallControlButton(symbol: isCameraOn ? "video.fill" : "video.slash.fill", title: "摄像头", isActive: isCameraOn) {
                            isCameraOn.toggle()
                        }
                    }
                }
                .padding(.bottom, 28)

                Button(action: endCall) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 68, height: 68)
                        .background(Color(hex: 0xE8788D), in: Circle())
                }
                .accessibilityLabel("结束模拟通话")
                .padding(.bottom, 35)
            }
        }
        .task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !didEnd else { return }
            connectedAt = .now
            withAnimation(.easeInOut(duration: 0.25)) { isConnected = true }
        }
    }

    private func callDurationText(at date: Date) -> String {
        guard let connectedAt else { return "00:00" }
        let seconds = max(0, Int(date.timeIntervalSince(connectedAt)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func endCall() {
        guard !didEnd else { return }
        didEnd = true
        let duration = connectedAt.map { max(0, Int(Date.now.timeIntervalSince($0))) } ?? 0
        onEnd(duration)
    }
}

private struct CallControlButton: View {
    let symbol: String
    let title: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Macaron.ink)
                    .frame(width: 58, height: 58)
                    .background(isActive ? Macaron.blue : Color.white.opacity(0.88), in: Circle())
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Macaron.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

private extension Color {
    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

