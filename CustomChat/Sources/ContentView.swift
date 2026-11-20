import SwiftUI
import PhotosUI
import UIKit

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
    var callContact = ""
}

@MainActor
private final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = [] { didSet { save() } }
    @Published var activeRole: ChatRole = .me
    @Published var identity = ChatIdentity() { didSet { save() } }

    private let messagesKey = "customchat.messages.v1"
    private let identityKey = "customchat.identity.v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: messagesKey),
           let value = try? JSONDecoder().decode([ChatMessage].self, from: data) { messages = value }
        if let data = UserDefaults.standard.data(forKey: identityKey),
           let value = try? JSONDecoder().decode(ChatIdentity.self, from: data) { identity = value }
    }

    func send(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        messages.append(ChatMessage(text: value, role: activeRole))
    }

    func sendImage(_ data: Data) { messages.append(ChatMessage(role: activeRole, imageData: data)) }

    func update(_ message: ChatMessage, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].text = text
    }

    func delete(_ message: ChatMessage) { messages.removeAll { $0.id == message.id } }

    func name(for role: ChatRole) -> String {
        let value = role == .me ? identity.me : identity.other
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? role.rawValue : value
    }

    func avatar(for role: ChatRole) -> Data? { role == .me ? identity.meAvatarData : identity.otherAvatarData }

    private func save() {
        if let data = try? JSONEncoder().encode(messages) { UserDefaults.standard.set(data, forKey: messagesKey) }
        if let data = try? JSONEncoder().encode(identity) { UserDefaults.standard.set(data, forKey: identityKey) }
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
    @State private var showContactAlert = false
    @Environment(\.openURL) private var openURL

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
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let compact = compactImageData(data) { model.sendImage(compact) }
                selectedPhoto = nil
            }
        }
        .onChange(of: myAvatarSelection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let compact = compactImageData(data) { model.identity.meAvatarData = compact }
                myAvatarSelection = nil
            }
        }
        .onChange(of: otherAvatarSelection) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let compact = compactImageData(data) { model.identity.otherAvatarData = compact }
                otherAvatarSelection = nil
            }
        }
        .alert("还没有设置联系方式", isPresented: $showContactAlert) {
            Button("取消", role: .cancel) {}
            Button("去设置") { showIdentitySettings = true }
        } message: {
            Text("请先填写对方的手机号或 FaceTime 邮箱。")
        }
        .alert("编辑消息", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
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
                .accessibilityLabel("新建聊天")
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
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(Color(hex: 0xEEF1F6), in: Capsule())
            .padding(.horizontal, 20)
            .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 10) {
                    Button { withAnimation(.easeInOut(duration: 0.22)) { showConversation = true } } label: {
                        ChatListRow(
                            name: model.name(for: .other),
                            preview: model.messages.last.map { $0.imageData == nil ? $0.text : "发来了一张图片" } ?? "开始你们的第一段对话",
                            time: model.messages.last?.time.formatted(date: .omitted, time: .shortened) ?? "现在",
                            unread: 0,
                            avatarData: model.identity.otherAvatarData,
                            tint: Macaron.pink,
                            isOnline: true
                        )
                    }
                    .buttonStyle(.plain)

                    ChatListRow(name: "阿辰", preview: "视频通话已结束 · 12 分钟", time: "08:52", unread: 0, avatarData: nil, tint: Macaron.blue, icon: "video")
                    ChatListRow(name: "甜甜", preview: "发来了一张图片", time: "昨天", unread: 0, avatarData: nil, tint: Macaron.mint, icon: "photo")
                    ChatListRow(name: "旅行计划", preview: "周末去海边吧！", time: "周二", unread: 0, avatarData: nil, tint: Macaron.lavender, icon: "airplane")
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
                Button { withAnimation(.easeInOut(duration: 0.22)) { showConversation = false } } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Macaron.ink)
                        .frame(width: 30, height: 42)
                }
                IdentityAvatar(data: model.identity.otherAvatarData, name: model.name(for: .other), size: 43, tint: Macaron.pink)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.name(for: .other))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Macaron.ink)
                    HStack(spacing: 5) {
                        Circle().fill(Color(hex: 0x55C987)).frame(width: 7, height: 7)
                        Text("在线").font(.system(size: 12)).foregroundStyle(Macaron.secondary)
                    }
                }
                Spacer()
                Button { startCall(video: false) } label: { Image(systemName: "phone").font(.system(size: 19)).foregroundStyle(Macaron.ink).frame(width: 34, height: 40) }
                Button { startCall(video: true) } label: { Image(systemName: "video").font(.system(size: 20)).foregroundStyle(Macaron.ink).frame(width: 34, height: 40) }
                Button { showIdentitySettings = true } label: { Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold)).foregroundStyle(Macaron.ink).frame(width: 30, height: 40) }
            }
            .padding(.horizontal, 17)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .background(Macaron.card)

            Rectangle().fill(Macaron.line).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 17) {
                        Text("今天")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Macaron.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color(hex: 0xEEF1F6), in: Capsule())
                            .padding(.top, 18)

                        if model.messages.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: "bubble.left")
                                    .font(.system(size: 30, weight: .light))
                                    .foregroundStyle(Color(hex: 0x9ABFE4))
                                Text("从这里开始聊天")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(Macaron.secondary)
                            }
                            .padding(.top, 110)
                        } else {
                            ForEach(model.messages) { message in
                                MessageRow(
                                    message: message,
                                    name: model.name(for: message.role),
                                    avatarData: model.avatar(for: message.role),
                                    isMe: message.role == .me,
                                    onEdit: { editing = message; editText = message.text },
                                    onDelete: { model.delete(message) }
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last {
                        withAnimation(.easeOut(duration: 0.22)) { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            composer
        }
        .background(Macaron.background)
    }

    private var composer: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Text("发送身份")
                    .font(.system(size: 11))
                    .foregroundStyle(Macaron.secondary)
                ForEach(ChatRole.allCases, id: \.self) { role in
                    Button { model.activeRole = role } label: {
                        Text(model.name(for: role))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Macaron.ink)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(model.activeRole == role ? (role == .me ? Macaron.blue : Macaron.pink) : Color(hex: 0xF0F2F6), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Color(hex: 0x5D9FE2))
                        .frame(width: 42, height: 44)
                        .background(Macaron.blue, in: Circle())
                }
                HStack(spacing: 8) {
                    TextField("输入消息...", text: $draft, axis: .vertical)
                        .font(.system(size: 15))
                        .foregroundStyle(Macaron.ink)
                        .lineLimit(1...4)
                        .onSubmit(sendText)
                    Button(action: sendText) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 31, height: 31)
                            .background(Color(hex: 0x8FC7FF), in: Circle())
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
                }
                .padding(.leading, 15)
                .padding(.trailing, 7)
                .frame(minHeight: 46)
                .background(Macaron.card, in: Capsule())
                .overlay(Capsule().stroke(Macaron.line, lineWidth: 1))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Macaron.card)
    }

    private var profileView: some View {
        VStack(spacing: 20) {
            Text("我的设置")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(Macaron.ink)
                .padding(.top, 22)

            VStack(spacing: 10) {
                ProfileIdentityCard(title: "我的昵称", name: model.name(for: .me), avatarData: model.identity.meAvatarData, tint: Macaron.blue) {
                    showIdentitySettings = true
                }
                ProfileIdentityCard(title: "对方昵称", name: model.name(for: .other), avatarData: model.identity.otherAvatarData, tint: Macaron.pink) {
                    showIdentitySettings = true
                }
            }
            .padding(.horizontal, 18)

            VStack(spacing: 0) {
                SettingsRow(symbol: "photo", title: "聊天背景", value: "默认", tint: Color(hex: 0x83B9EF)) { }
                Divider().overlay(Macaron.line).padding(.leading, 54)
                SettingsRow(symbol: "paintpalette", title: "主题色", value: "浅蓝", tint: Color(hex: 0xC18AD8)) { }
                Divider().overlay(Macaron.line).padding(.leading, 54)
                SettingsRow(symbol: "textformat.size", title: "字体大小", value: "标准", tint: Color(hex: 0x83B9EF)) { }
                Divider().overlay(Macaron.line).padding(.leading, 54)
                SettingsRow(symbol: "bell", title: "消息提示音", value: "默认", tint: Color(hex: 0xE6A5C7)) { }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 4)
            .background(Macaron.card, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
            .padding(.horizontal, 18)

            Button { showIdentitySettings = true } label: {
                HStack {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Color(hex: 0x83B9EF))
                    Text("更多设置")
                        .foregroundStyle(Macaron.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Macaron.secondary)
                }
                .font(.system(size: 15, weight: .medium))
                .padding(18)
                .background(Macaron.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            Spacer()
        }
    }

    private var callsView: some View {
        VStack(spacing: 18) {
            Text("通话")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(Macaron.ink)
                .padding(.top, 22)
            Image(systemName: "phone")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Color(hex: 0x78B6EF))
                .frame(width: 76, height: 76)
                .background(Macaron.blue, in: Circle())
                .padding(.top, 90)
            Text("还没有通话记录")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Macaron.secondary)
            Button("呼叫 \(model.name(for: .other))") { startCall(video: false) }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(hex: 0x438FDC))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Macaron.blue, in: Capsule())
            Spacer()
        }
    }

    private var albumView: some View {
        VStack(spacing: 16) {
            Text("相册")
                .font(.system(size: 25, weight: .bold))
                .foregroundStyle(Macaron.ink)
                .padding(.top, 22)
            if model.messages.contains(where: { $0.imageData != nil }) {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                        ForEach(model.messages.filter { $0.imageData != nil }) { message in
                            if let data = message.imageData, let image = UIImage(data: data) {
                                Image(uiImage: image).resizable().scaledToFill().frame(height: 112).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    .padding(16)
                }
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(Color(hex: 0x83B9EF))
                    .frame(width: 76, height: 76)
                    .background(Macaron.blue, in: Circle())
                    .padding(.top, 100)
                Text("聊天中的图片会显示在这里")
                    .font(.system(size: 14))
                    .foregroundStyle(Macaron.secondary)
                Spacer()
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
                        Text(tab.rawValue).font(.system(size: 11, weight: selectedTab == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(selectedTab == tab ? Color(hex: 0x4F9DE8) : Macaron.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .background {
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Macaron.blue.opacity(0.68)).padding(.horizontal, 5)
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
                    identityEditor(title: "我的资料", name: $model.identity.me, avatarData: model.identity.meAvatarData, selection: $myAvatarSelection, tint: Macaron.blue)
                    identityEditor(title: "对方资料", name: $model.identity.other, avatarData: model.identity.otherAvatarData, selection: $otherAvatarSelection, tint: Macaron.pink)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("通话联系方式").font(.system(size: 14, weight: .semibold)).foregroundStyle(Macaron.ink)
                        TextField("手机号或 FaceTime 邮箱", text: $model.identity.callContact)
                            .font(.system(size: 14))
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(14)
                            .background(Macaron.background, in: RoundedRectangle(cornerRadius: 13))
                    }
                    .padding(15)
                    .background(Macaron.card, in: RoundedRectangle(cornerRadius: 20))
                    Text("昵称、头像和聊天记录保存在这台设备上。")
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
                    Button("完成") { showIdentitySettings = false }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func identityEditor(title: String, name: Binding<String>, avatarData: Data?, selection: Binding<PhotosPickerItem?>, tint: Color) -> some View {
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
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Macaron.secondary)
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

    private func sendText() { model.send(draft); draft = "" }

    private func startCall(video: Bool) {
        let contact = model.identity.callContact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contact.isEmpty else { showContactAlert = true; return }
        let url: URL?
        if video { url = URL(string: "facetime://\(contact)") }
        else if contact.contains("@") { url = URL(string: "facetime-audio://\(contact)") }
        else {
            let digits = contact.filter { $0.isNumber || $0 == "+" }
            url = URL(string: "tel:\(digits)")
        }
        if let url { openURL(url) } else { showContactAlert = true }
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
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }.jpegData(compressionQuality: 0.78)
    }
}

private struct ChatListRow: View {
    let name: String
    let preview: String
    let time: String
    let unread: Int
    let avatarData: Data?
    let tint: Color
    var isOnline = false
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 13) {
            ZStack(alignment: .bottomTrailing) {
                IdentityAvatar(data: avatarData, name: name, size: 61, tint: tint)
                if isOnline {
                    Circle().fill(Color(hex: 0x55C987)).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Macaron.ink)
                Text(preview.isEmpty ? " " : preview).font(.system(size: 13)).foregroundStyle(Macaron.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 8) {
                Text(time).font(.system(size: 12)).foregroundStyle(Macaron.secondary)
                if unread > 0 {
                    Text("\(unread)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 21, height: 21).background(Color(hex: 0xF28AB6), in: Circle())
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 17)).foregroundStyle(Color(hex: 0x9AA8BC))
                }
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
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(Macaron.secondary)
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
                Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(tint).frame(width: 28)
                Text(title).font(.system(size: 15, weight: .medium)).foregroundStyle(Macaron.ink)
                Spacer()
                Text(value).font(.system(size: 13)).foregroundStyle(Macaron.secondary)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Macaron.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 57)
        }
        .buttonStyle(.plain)
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
                    Text(String(name.prefix(1))).font(.system(size: size * 0.39, weight: .semibold)).foregroundStyle(Color(hex: 0x55718E))
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
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMe { Spacer(minLength: 55) }
            if !isMe {
                IdentityAvatar(data: avatarData, name: name, size: 34, tint: Macaron.pink)
            }
            VStack(alignment: isMe ? .trailing : .leading, spacing: 5) {
                VStack(alignment: isMe ? .trailing : .leading, spacing: 7) {
                    if let data = message.imageData, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 230, maxHeight: 290)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    if !message.text.isEmpty {
                        Text(message.text).font(.system(size: 16)).foregroundStyle(Macaron.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, message.imageData == nil ? 15 : 8)
                .padding(.vertical, message.imageData == nil ? 12 : 8)
                .background(isMe ? Macaron.blue : Macaron.card, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(Color.white.opacity(0.9), lineWidth: 1))
                .frame(maxWidth: 275, alignment: isMe ? .trailing : .leading)
                .contextMenu {
                    if !message.text.isEmpty { Button("编辑", systemImage: "pencil", action: onEdit) }
                    Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                }
                Text(message.time, format: .dateTime.hour().minute())
                    .font(.system(size: 10)).foregroundStyle(Macaron.secondary).padding(.horizontal, 5)
            }
            if isMe { IdentityAvatar(data: avatarData, name: name, size: 34, tint: Macaron.blue) }
            else { Spacer(minLength: 55) }
        }
        .frame(maxWidth: .infinity)
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
