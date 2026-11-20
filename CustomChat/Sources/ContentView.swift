import SwiftUI
import PhotosUI
import UIKit
import AVKit
import UniformTypeIdentifiers
import AudioToolbox

private extension Notification.Name {
    static let customChatScrollToBottom = Notification.Name("customchat.scrollToBottom")
}

enum ChatRole: String, CaseIterable, Codable {
    case other = "对方"
    case me = "我"
}

enum ChatMessageKind: String, Codable { case text, image, redPacket, transfer, call }

struct ChatMessage: Identifiable, Codable {
    var id: UUID
    var text: String
    var role: ChatRole
    var time: Date
    var imageData: Data?
    var kind: ChatMessageKind
    var amount: Double?
    var note: String
    var isWithdrawn: Bool
    var isReceived: Bool

    init(text: String = "", role: ChatRole, time: Date = .now, imageData: Data? = nil,
         kind: ChatMessageKind? = nil, amount: Double? = nil, note: String = "", isWithdrawn: Bool = false, isReceived: Bool = false) {
        id = UUID(); self.text = text; self.role = role; self.time = time; self.imageData = imageData
        self.kind = kind ?? (imageData == nil ? .text : .image)
        self.amount = amount; self.note = note; self.isWithdrawn = isWithdrawn; self.isReceived = isReceived
    }

    enum CodingKeys: String, CodingKey { case id, text, role, time, imageData, kind, amount, note, isWithdrawn, isReceived }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        role = try values.decode(ChatRole.self, forKey: .role)
        time = try values.decode(Date.self, forKey: .time)
        imageData = try values.decodeIfPresent(Data.self, forKey: .imageData)
        kind = try values.decodeIfPresent(ChatMessageKind.self, forKey: .kind) ?? (imageData == nil ? .text : .image)
        amount = try values.decodeIfPresent(Double.self, forKey: .amount)
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        isWithdrawn = try values.decodeIfPresent(Bool.self, forKey: .isWithdrawn) ?? false
        isReceived = try values.decodeIfPresent(Bool.self, forKey: .isReceived) ?? false
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

struct MomentPost: Identifiable, Codable {
    var id: UUID
    var text: String
    var date: Date
    var mediaData: Data?
    var mediaType: String?

    init(text: String, date: Date = .now, mediaData: Data? = nil, mediaType: String? = nil) {
        id = UUID()
        self.text = text
        self.date = date
        self.mediaData = mediaData
        self.mediaType = mediaType
    }
}

struct ChatContact: Identifiable, Codable {
    var id: UUID
    var name: String
    var avatarData: Data?
    var bio: String
    var notes: String
    var moments: [MomentPost]

    init(id: UUID = UUID(), name: String, avatarData: Data? = nil,
         bio: String = "分享生活，记录日常。", notes: String = "", moments: [MomentPost] = []) {
        self.id = id
        self.name = name
        self.avatarData = avatarData
        self.bio = bio
        self.notes = notes
        self.moments = moments
    }
}

@MainActor
private final class ChatModel: ObservableObject {
    @Published var messages: [ChatMessage] = [] {
        didSet { persistCurrentThread() }
    }
    @Published var activeRole: ChatRole = .me
    @Published var identity = ChatIdentity() { didSet { persistIdentity() } }
    @Published var calls: [CallRecord] = [] { didSet { saveCalls() } }
    @Published var contacts: [ChatContact] = [] { didSet { persistContacts() } }
    @Published var selectedContactID: UUID?
    @Published var myMoments: [MomentPost] = [] { didSet { persistMyMoments() } }
    @Published var walletBalance: Double = 1000 {
        didSet { UserDefaults.standard.set(walletBalance, forKey: walletKey) }
    }

    private let messagesKey = "customchat.messages.v1"
    private let threadsKey = "customchat.threads.v1"
    private let identityKey = "customchat.identity.v1"
    private let callsKey = "customchat.calls.v1"
    private let contactsKey = "customchat.contacts.v1"
    private let myMomentsKey = "customchat.myMoments.v1"
    private let walletKey = "customchat.wallet.balance.v1"
    private var threadMessages: [String: [ChatMessage]] = [:]
    private var isSwitchingThread = false

    init() {
        if let fileURL = Self.identityFileURL(),
           let data = try? Data(contentsOf: fileURL),
           let value = try? JSONDecoder().decode(ChatIdentity.self, from: data) {
            identity = value
            UserDefaults.standard.set(data, forKey: identityKey)
        } else if let data = UserDefaults.standard.data(forKey: identityKey),
                  let value = try? JSONDecoder().decode(ChatIdentity.self, from: data) {
            identity = value
        }

        if let data = UserDefaults.standard.data(forKey: contactsKey),
           let value = try? JSONDecoder().decode([ChatContact].self, from: data),
           !value.isEmpty {
            contacts = value
        } else {
            contacts = [ChatContact(name: identity.other, avatarData: identity.otherAvatarData)]
        }
        selectedContactID = contacts.first?.id

        if let data = UserDefaults.standard.data(forKey: threadsKey),
           let value = try? JSONDecoder().decode([String: [ChatMessage]].self, from: data) {
            threadMessages = value
        } else if let legacyData = UserDefaults.standard.data(forKey: messagesKey),
                  let legacyMessages = try? JSONDecoder().decode([ChatMessage].self, from: legacyData),
                  let firstContactID = contacts.first?.id {
            // Migrate the original single-chat history into the first contact's thread.
            threadMessages[firstContactID.uuidString] = legacyMessages
        }

        isSwitchingThread = true
        messages = selectedContactID.flatMap { threadMessages[$0.uuidString] } ?? []
        isSwitchingThread = false

        if let data = UserDefaults.standard.data(forKey: callsKey),
           let value = try? JSONDecoder().decode([CallRecord].self, from: data) {
            calls = value
        }
        if let data = UserDefaults.standard.data(forKey: myMomentsKey),
           let value = try? JSONDecoder().decode([MomentPost].self, from: data) {
            myMoments = value
        }
        if let storedBalance = UserDefaults.standard.object(forKey: walletKey) as? Double {
            walletBalance = max(0, storedBalance)
        }
        persistContacts()
        persistCurrentThread()
    }

    var currentContact: ChatContact? {
        contacts.first(where: { $0.id == selectedContactID }) ?? contacts.first
    }

    func selectContact(_ id: UUID) {
        guard selectedContactID != id else { return }
        persistCurrentThread()
        selectedContactID = id
        isSwitchingThread = true
        messages = threadMessages[id.uuidString] ?? []
        isSwitchingThread = false
    }

    @discardableResult
    func addContact(name: String, bio: String, avatarData: Data?) -> UUID {
        let cleanedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let contact = ChatContact(
            name: cleanedName.isEmpty ? "新好友" : cleanedName,
            avatarData: avatarData,
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "分享生活，记录日常。" : bio
        )
        contacts.append(contact)
        selectContact(contact.id)
        return contact.id
    }

    func updateContact(_ updated: ChatContact) {
        guard let index = contacts.firstIndex(where: { $0.id == updated.id }) else { return }
        contacts[index] = updated
    }

    func preview(for contact: ChatContact) -> String {
        let last = threadMessages[contact.id.uuidString]?.last
        guard let last else { return "开始你们的第一段对话" }
        if last.isWithdrawn { return "撤回了一条消息" }
        switch last.kind {
        case .image: return "发来了一张图片"
        case .redPacket: return "发送了一个虚拟红包"
        case .transfer: return "发送了一笔虚拟转账"
        case .call: return last.note
        case .text: return last.text
        }
    }

    func send(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        messages.append(ChatMessage(text: value, role: activeRole))
    }

    func sendImage(_ data: Data) {
        messages.append(ChatMessage(role: activeRole, imageData: data, kind: .image))
    }

    @discardableResult
    func sendPayment(kind: ChatMessageKind, amount: Double, note: String) -> Bool {
        guard amount > 0 else { return false }
        if kind == .transfer {
            if activeRole == .me {
                guard walletBalance >= amount else { return false }
                walletBalance -= amount
            }
        }
        messages.append(ChatMessage(role: activeRole, kind: kind, amount: amount, note: note))
        return true
    }

    func receiveTransfer(_ message: ChatMessage) {
        guard message.kind == .transfer, message.role == .other, !message.isReceived,
              let amount = message.amount, amount > 0,
              let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        walletBalance += amount
        messages[index].isReceived = true
    }

    func addCallMessage(isVideo: Bool, duration: Int) {
        let label = isVideo ? "视频通话" : "语音通话"
        let time = String(format: "%02d:%02d", duration / 60, duration % 60)
        messages.append(ChatMessage(role: .me, kind: .call, note: "\(label) · \(time)"))
    }

    func update(_ message: ChatMessage, text: String) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].text = text
    }

    func changeRole(_ message: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].role = messages[index].role == .me ? .other : .me
    }

    func updateTime(_ message: ChatMessage, time: Date) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].time = time
        messages.sort { $0.time < $1.time }
    }

    func withdraw(_ message: ChatMessage) {
        guard let index = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[index].isWithdrawn = true
        messages[index].text = ""
        messages[index].imageData = nil
        messages[index].amount = nil
        messages[index].note = ""
    }

    func delete(_ message: ChatMessage) {
        messages.removeAll { $0.id == message.id }
    }

    func addCall(isVideo: Bool, duration: Int) {
        calls.insert(CallRecord(isVideo: isVideo, duration: duration), at: 0)
        if calls.count > 100 { calls = Array(calls.prefix(100)) }
    }

    func updateAvatar(for role: ChatRole, data: Data) {
        if role == .me {
            var updated = identity
            updated.meAvatarData = data
            identity = updated
        } else if var contact = currentContact {
            contact.avatarData = data
            updateContact(contact)
        }
    }

    func name(for role: ChatRole) -> String {
        let value = role == .me ? identity.me : (currentContact?.name ?? identity.other)
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? role.rawValue : value
    }

    func avatar(for role: ChatRole) -> Data? {
        role == .me ? identity.meAvatarData : currentContact?.avatarData
    }

    private static func identityFileURL() -> URL? {
        guard let supportDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return supportDirectory
            .appendingPathComponent("CustomChat", isDirectory: true)
            .appendingPathComponent("identity-v1.json", isDirectory: false)
    }

    func persistIdentity() {
        guard let fileURL = Self.identityFileURL(),
              let data = try? JSONEncoder().encode(identity) else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
            UserDefaults.standard.set(data, forKey: identityKey)
        } catch {
            NSLog("CustomChat: failed to persist identity: %@", error.localizedDescription)
        }
    }

    private func persistContacts() {
        guard let data = try? JSONEncoder().encode(contacts) else { return }
        UserDefaults.standard.set(data, forKey: contactsKey)
    }

    private func persistCurrentThread() {
        guard !isSwitchingThread, let selectedContactID else { return }
        threadMessages[selectedContactID.uuidString] = messages
        if let data = try? JSONEncoder().encode(threadMessages) {
            UserDefaults.standard.set(data, forKey: threadsKey)
        }
        // Keep the legacy key current for backwards compatibility with older builds.
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: messagesKey)
        }
    }

    private func saveCalls() {
        if let data = try? JSONEncoder().encode(calls) {
            UserDefaults.standard.set(data, forKey: callsKey)
        }
    }

    private func persistMyMoments() {
        if let data = try? JSONEncoder().encode(myMoments) {
            UserDefaults.standard.set(data, forKey: myMomentsKey)
        }
    }

    private func save() {
        persistIdentity()
        persistContacts()
        persistCurrentThread()
        saveCalls()
        persistMyMoments()
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: AppTab = .chats
    @State private var showConversation = false
    @State private var showMyProfileEditor = false
    @State private var showAddContact = false
    @State private var showFriendProfile = false
    @State private var showChatSettings = false
    @FocusState private var messageFocused: Bool
    @State private var showBalanceEditor = false
    @State private var showInsufficientBalance = false
    @State private var walletBalanceDraft = ""
    @State private var showMyMomentEditor = false
    @State private var myMomentDraft = ""
    @State private var editingMyMomentID: UUID?
    @State private var searchText = ""
    @State private var draft = ""
    @State private var isComposerVisible = true
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showAddMenu = false
    @State private var showRedPacketInput = false
    @State private var showTransferInput = false
    @State private var paymentAmountDraft = ""
    @State private var paymentNoteDraft = ""
    @State private var timeEditingMessage: ChatMessage?
    @State private var editedMessageTime = Date()
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

    private var pageContent: some View {
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
    }

    var body: some View {
        preferenceDialogs
    }

    // Keep the modifier groups small so Swift's type checker does not have to
    // infer one enormous SwiftUI expression for the entire screen.
    private var basePresentation: some View {
        pageContent
            .preferredColorScheme(.light)
            .onChange(of: scenePhase) { _, phase in
                if phase == .inactive || phase == .background {
                    model.persistIdentity()
                }
            }
            .sheet(isPresented: $showMyProfileEditor) { myProfileEditor }
            .sheet(isPresented: $showChatSettings) { chatSettingsSheet }
            .sheet(isPresented: $showAddContact) {
                AddContactSheet { name, bio, avatarData in
                    model.addContact(name: name, bio: bio, avatarData: avatarData)
                    showAddContact = false
                    showConversation = true
                }
            }
            .sheet(isPresented: $showFriendProfile) {
                if let contact = model.currentContact {
                    FriendProfileSheet(contact: contact) { updated in
                        model.updateContact(updated)
                    }
                }
            }
            .sheet(item: $previewPhoto) { photo in
                PhotoPreviewView(data: photo.data)
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
            .overlay {
                if showAddMenu {
                    AddContentMenu(
                        onDismiss: { showAddMenu = false },
                        onPhoto: {
                            showAddMenu = false
                            showPhotoPicker = true
                        },
                        onRedPacket: {
                            showAddMenu = false
                            paymentAmountDraft = ""
                            paymentNoteDraft = "恭喜发财"
                            showRedPacketInput = true
                        },
                        onTransfer: {
                            showAddMenu = false
                            paymentAmountDraft = ""
                            paymentNoteDraft = "转账"
                            showTransferInput = true
                        }
                    )
                    .transition(.opacity)
                    .zIndex(20)
                }
            }
            .animation(.easeOut(duration: 0.18), value: showAddMenu)
    }

    private var paymentPresentation: some View {
        basePresentation
            .alert("创建虚拟红包", isPresented: $showRedPacketInput) {
                TextField("金额，例如 8.88", text: $paymentAmountDraft).keyboardType(.decimalPad)
                TextField("红包标题", text: $paymentNoteDraft)
                Button("取消", role: .cancel) {}
                Button("发送") { sendPaymentMessage(kind: .redPacket) }
            } message: {
                Text("仅用于聊天界面演示，不涉及真实支付。")
            }
            .alert("创建虚拟转账", isPresented: $showTransferInput) {
                TextField("金额，例如 66.00", text: $paymentAmountDraft).keyboardType(.decimalPad)
                TextField("转账说明", text: $paymentNoteDraft)
                Button("取消", role: .cancel) {}
                Button("发送") { sendPaymentMessage(kind: .transfer) }
            } message: {
                Text("使用本地模拟钱包记录，不涉及真实资金交易。")
            }
            .sheet(isPresented: Binding(
                get: { timeEditingMessage != nil },
                set: { if !$0 { timeEditingMessage = nil } }
            )) {
                NavigationStack {
                    Form {
                        DatePicker("发送时间", selection: $editedMessageTime, displayedComponents: [.date, .hourAndMinute])
                    }
                    .navigationTitle("修改消息时间")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { timeEditingMessage = nil }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("保存") {
                                if let message = timeEditingMessage {
                                    model.updateTime(message, time: editedMessageTime)
                                }
                                timeEditingMessage = nil
                            }
                        }
                    }
                }
                .presentationDetents([.medium])
            }
            .fullScreenCover(item: $activeCall) { call in
                SimulatedCallView(
                    name: model.name(for: .other),
                    meName: model.name(for: .me),
                    avatarData: model.avatar(for: .other),
                    isVideo: call.isVideo
                ) { duration in
                    model.addCall(isVideo: call.isVideo, duration: duration)
                    model.addCallMessage(isVideo: call.isVideo, duration: duration)
                    activeCall = nil
                }
            }
    }

    private var photoHandlingPresentation: some View {
        paymentPresentation
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
                        model.updateAvatar(for: .me, data: compact)
                    }
                    myAvatarSelection = nil
                }
            }
            .onChange(of: otherAvatarSelection) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let compact = compactImageData(data) {
                        model.updateAvatar(for: .other, data: compact)
                    }
                    otherAvatarSelection = nil
                }
            }
    }

    private var preferenceDialogs: some View {
        photoHandlingPresentation
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
            .alert("余额不足", isPresented: $showInsufficientBalance) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("你的钱包余额不足，请先在“我的”页面调整模拟余额。")
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
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .tracking(-0.8)
                    .foregroundStyle(Macaron.ink)
                Spacer()
                Button { showAddContact = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(Color(hex: 0x438FDC))
                        .frame(width: 42, height: 42)
                        .background(Macaron.blue, in: Circle())
                }
                .accessibilityLabel("添加好友")
            }
            .padding(.horizontal, 19)
            .padding(.top, 10)
            .padding(.bottom, 13)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Macaron.secondary)
                TextField("搜索聊天", text: $searchText)
                    .font(.system(size: 15))
                    .foregroundStyle(Macaron.ink)
                    .autocorrectionDisabled()
            }
            .padding(.horizontal, 16)
            .frame(height: 45)
            .background(Color(hex: 0xEEF1F6), in: Capsule())
            .padding(.horizontal, 18)
            .padding(.bottom, 15)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("最近聊天")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Macaron.secondary)
                        .padding(.horizontal, 5)

                    let filteredContacts = model.contacts.filter {
                        searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
                    }
                    if filteredContacts.isEmpty {
                        EmptyHint(
                            symbol: "person.crop.circle.badge.plus",
                            title: model.contacts.isEmpty ? "还没有好友" : "没有找到好友",
                            subtitle: model.contacts.isEmpty ? "点击右上角加号，添加第一个联系人。" : "试试其他昵称。"
                        )
                        .padding(.top, 50)
                    } else {
                        ForEach(filteredContacts) { contact in
                            Button {
                                model.selectContact(contact.id)
                                withAnimation(.easeInOut(duration: 0.22)) { showConversation = true }
                            } label: {
                                ChatListRow(
                                    name: contact.name,
                                    preview: model.preview(for: contact),
                                    time: " ",
                                    avatarData: contact.avatarData,
                                    tint: Macaron.pink,
                                    isOnline: true,
                                    accentColor: accentColor
                                )
                            }
                            .buttonStyle(.plain)
                        }
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
                Button { showFriendProfile = true } label: { IdentityAvatar(data: model.avatar(for: .other), name: model.name(for: .other), size: 42, tint: Macaron.pink) }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.name(for: .other))
                        .font(.system(size: 16, weight: .semibold))
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
                Button { showChatSettings = true } label: {
                    Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold)).foregroundStyle(Macaron.ink).frame(width: 30, height: 40)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 7)
            .padding(.bottom, 7)
            .background(Macaron.card)

            Rectangle().fill(Macaron.line).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 15) {
                        Text("今天")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Macaron.secondary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Color(hex: 0xEEF1F6), in: Capsule())
                            .padding(.top, 12)

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
                                    onChangeRole: { model.changeRole(message) },
                                    onChangeTime: { editedMessageTime = message.time; timeEditingMessage = message },
                                    onWithdraw: { model.withdraw(message) },
                                    onImageTap: { data in previewPhoto = SelectedPhoto(data: data) },
                                    onReceiveTransfer: { model.receiveTransfer(message) }
                                )
                                .id(message.id)
                            }
                        }
                    }
                    .padding(.horizontal, 13)
                    .padding(.bottom, 13)
                }
                // Keep the composer anchored above the keyboard. The message list
                // owns the remaining height and must not dismiss the keyboard
                // or hide the composer as a side effect of a drag gesture.
                .scrollDismissesKeyboard(.interactively)
                .onAppear {
                    if let last = model.messages.last {
                        DispatchQueue.main.async {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: UIResponder.keyboardWillChangeFrameNotification
                )) { _ in
                    // Wait for SwiftUI to apply the keyboard's new safe-area
                    // size before scrolling, otherwise the final bubble can
                    // land underneath the composer or keyboard.
                    guard let lastID = model.messages.last?.id else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        withAnimation(.easeOut(duration: 0.20)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
                .onChange(of: model.messages.count) { _, _ in
                    if let last = model.messages.last {
                        withAnimation(.easeOut(duration: 0.22)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .customChatScrollToBottom)) { _ in
                    guard let last = model.messages.last else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .background(
                conversationBackground,
                in: RoundedRectangle(cornerRadius: 28, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1)
                    .allowsHitTesting(false)
            )
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 6)

            composer
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .background(Macaron.card)
    }

    private var composer: some View {
        VStack(spacing: 11) {
            HStack(spacing: 8) {
                Text("发送身份")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Macaron.secondary)
                    .padding(.trailing, 1)
                ForEach(ChatRole.allCases, id: \.self) { role in
                    Button { withAnimation(.easeOut(duration: 0.16)) { model.activeRole = role } } label: {
                        Text(model.name(for: role))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 30)
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
                Button { messageFocused = false } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Macaron.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(hex: 0xF0F1F5), in: Circle())
                }
                .accessibilityLabel("收起键盘")
                Button {
                    NotificationCenter.default.post(name: .customChatScrollToBottom, object: nil)
                    messageFocused = false
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Macaron.secondary)
                        .frame(width: 30, height: 30)
                        .background(Color(hex: 0xF0F1F5), in: Circle())
                }
                .accessibilityLabel("滚动到聊天底部")
            }

            HStack(spacing: 11) {
                Button {
                    messageFocused = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { showAddMenu = true }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(Color(hex: 0x5799D9))
                        .frame(width: 46, height: 46)
                        .background(accentColor.opacity(0.68), in: Circle())
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加聊天内容")

                HStack(spacing: 8) {
                    TextField("输入消息...", text: $draft, axis: .vertical)
                        .font(.system(size: fontOption == "偏大" ? 16 : 15))
                        .foregroundStyle(Macaron.ink)
                        .lineLimit(1...4)
                        .padding(.vertical, 12)
                        .focused($messageFocused)
                        .onSubmit(sendText)
                    Button(action: sendText) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(accentColor.opacity(0.9), in: Circle())
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.38 : 1)
                }
                .padding(.leading, 17)
                .padding(.trailing, 8)
                .frame(minHeight: 48)
                .background(Macaron.card, in: Capsule())
                .overlay(Capsule().stroke(Color(hex: 0xE5E8EF), lineWidth: 1))
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .background(Macaron.card)
    }

    private var profileView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                HStack {
                    Text("我的")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(Macaron.ink)
                    Spacer()
                    Button { showMyProfileEditor = true } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x4F91D2))
                            .frame(width: 40, height: 40)
                            .background(Macaron.blue, in: Circle())
                    }
                    .accessibilityLabel("编辑我的资料")
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)

                Button { showMyProfileEditor = true } label: {
                    HStack(spacing: 14) {
                        IdentityAvatar(data: model.identity.meAvatarData, name: model.name(for: .me), size: 66, tint: Macaron.blue)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.name(for: .me))
                                .font(.system(size: 19, weight: .semibold))
                                .foregroundStyle(Macaron.ink)
                            Text("编辑头像与个人资料")
                                .font(.system(size: 12))
                                .foregroundStyle(Macaron.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Macaron.secondary)
                    }
                    .padding(17)
                    .background(Macaron.card, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18)

                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Label("我的钱包", systemImage: "wallet.pass.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                        Spacer()
                        Button("修改余额") {
                            walletBalanceDraft = String(format: "%.2f", model.walletBalance)
                            showBalanceEditor = true
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0x4F91D2))
                    }
                    Text("账户余额")
                        .font(.system(size: 12))
                        .foregroundStyle(Macaron.secondary)
                    Text("¥\(model.walletBalance, specifier: "%.2f")")
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Macaron.ink)
                    Text("仅为本地模拟钱包。你向好友转账时扣款，好友向你转账时余额增加，不会扣款。")
                        .font(.system(size: 11))
                        .foregroundStyle(Macaron.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color(hex: 0xE8F3FF), Color(hex: 0xF2EDFC)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .padding(.horizontal, 18)
                .alert("修改钱包余额", isPresented: $showBalanceEditor) {
                    TextField("输入余额", text: $walletBalanceDraft)
                        .keyboardType(.decimalPad)
                    Button("取消", role: .cancel) {}
                    Button("保存") {
                        if let value = Double(walletBalanceDraft), value >= 0 {
                            model.walletBalance = value
                        }
                    }
                } message: {
                    Text("余额仅保存在本机，用于模拟聊天转账。")
                }

                VStack(spacing: 12) {
                    HStack {
                        Text("我的朋友圈")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                        Spacer()
                        Button {
                            editingMyMomentID = nil
                            myMomentDraft = ""
                            showMyMomentEditor = true
                        } label: {
                            Label("发布", systemImage: "plus")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color(hex: 0x4F91D2))
                        }
                    }
                    .padding(.horizontal, 20)

                    if model.myMoments.isEmpty {
                        EmptyHint(symbol: "text.bubble", title: "还没有朋友圈", subtitle: "记录生活，发布第一条动态吧。")
                            .padding(.vertical, 20)
                    } else {
                        ForEach(model.myMoments) { post in
                            VStack(alignment: .leading, spacing: 9) {
                                Text(post.text)
                                    .font(.system(size: 14))
                                    .foregroundStyle(Macaron.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(post.date, format: .dateTime.year().month().day().hour().minute())
                                    .font(.system(size: 10))
                                    .foregroundStyle(Macaron.secondary)
                            }
                            .padding(15)
                            .background(Macaron.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .contextMenu {
                                Button("编辑动态", systemImage: "pencil") {
                                    editingMyMomentID = post.id
                                    myMomentDraft = post.text
                                    showMyMomentEditor = true
                                }
                                Button("删除动态", systemImage: "trash", role: .destructive) {
                                    model.myMoments.removeAll { $0.id == post.id }
                                }
                            }
                            .padding(.horizontal, 18)
                        }
                    }
                }
                .sheet(isPresented: $showMyMomentEditor) {
                    MomentEditorSheet(
                        title: editingMyMomentID == nil ? "发布朋友圈" : "编辑朋友圈",
                        initialText: myMomentDraft
                    ) { text in
                        if let id = editingMyMomentID,
                           let index = model.myMoments.firstIndex(where: { $0.id == id }) {
                            model.myMoments[index].text = text
                        } else {
                            model.myMoments.insert(MomentPost(text: text), at: 0)
                        }
                    }
                }

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
                    Divider().overlay(Macaron.line).padding(.leading, 54)
                    Button { showClearConfirmation = true } label: {
                        SettingsLine(symbol: "trash", title: "清空当前好友聊天记录", tint: Color(hex: 0xD9829F))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
                .background(Macaron.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 18)

                Text("CustomChat · 本地社交模拟")
                    .font(.system(size: 11))
                    .foregroundStyle(Macaron.secondary)
                    .padding(.bottom, 18)
            }
        }
    }

    private var callsView: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 16) {
                Text("通话")
                    .font(.system(size: 23, weight: .bold))
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
                .font(.system(size: 23, weight: .bold))
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
                    .frame(height: 56)
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
        .padding(.top, 4)
        .background(Macaron.card)
        .overlay(alignment: .top) { Rectangle().fill(Macaron.line).frame(height: 1) }
    }

    private var chatSettingsSheet: some View {
        NavigationStack {
            Form {
                Section("聊天外观") {
                    Picker("聊天背景", selection: $backgroundOption) {
                        ForEach(["雾蓝白", "奶油白", "淡粉", "薄荷绿"], id: \.self) { Text($0) }
                    }
                    Picker("主题颜色", selection: $themeOption) {
                        ForEach(["浅蓝", "樱花粉", "薄荷绿", "薰衣草紫"], id: \.self) { Text($0) }
                    }
                    Picker("文字大小", selection: $fontOption) {
                        ForEach(["偏小", "标准", "偏大"], id: \.self) { Text($0) }
                    }
                }
                Section("消息提醒") {
                    Picker("消息提醒", selection: $soundOption) {
                        ForEach(["轻柔", "清脆", "关闭"], id: \.self) { Text($0) }
                    }
                }
                Section("聊天记录") {
                    Button(role: .destructive) { showClearConfirmation = true } label: {
                        Label("清空当前好友聊天记录", systemImage: "trash")
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showChatSettings = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var myProfileEditor: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    identityEditor(
                        title: "我的资料",
                        name: identityNameBinding(for: .me),
                        avatarData: model.identity.meAvatarData,
                        selection: $myAvatarSelection,
                        tint: Macaron.blue
                    )
                    Text("这里只编辑你自己的昵称和头像，不会修改任何好友资料。")
                        .font(.system(size: 12))
                        .foregroundStyle(Macaron.secondary)
                }
                .padding(18)
            }
            .background(Macaron.background)
            .navigationTitle("我的资料")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        model.persistIdentity()
                        showMyProfileEditor = false
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func identityNameBinding(for role: ChatRole) -> Binding<String> {
        Binding(
            get: { role == .me ? model.identity.me : model.identity.other },
            set: { newValue in
                var updated = model.identity
                if role == .me {
                    updated.me = newValue
                } else {
                    updated.other = newValue
                }
                model.identity = updated
            }
        )
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

    private func sendPaymentMessage(kind: ChatMessageKind) {
        guard let amount = Double(paymentAmountDraft), amount > 0 else { return }
        let sent = model.sendPayment(
            kind: kind,
            amount: amount,
            note: paymentNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        paymentAmountDraft = ""; paymentNoteDraft = ""
        if sent {
            playMessageSound()
        } else {
            showInsufficientBalance = true
        }
    }

    private func playMessageSound() {
        // Replace the loud system alert tone with a subtle, low-intensity haptic.
        guard soundOption != "关闭" else { return }
        let feedback = UIImpactFeedbackGenerator(style: .soft)
        feedback.prepare()
        feedback.impactOccurred(intensity: 0.22)
    }

    private func playPreviewSound() {
        guard soundOption != "关闭" else { return }
        let feedback = UIImpactFeedbackGenerator(style: .soft)
        feedback.prepare()
        feedback.impactOccurred(intensity: 0.22)
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
                IdentityAvatar(data: avatarData, name: name, size: 54, tint: tint)
                if isOnline {
                    Circle()
                        .fill(Color(hex: 0x55C987))
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
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
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(Macaron.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
            .frame(height: 52)
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
        .frame(height: 50)
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
    let onChangeRole: () -> Void
    let onChangeTime: () -> Void
    let onWithdraw: () -> Void
    let onImageTap: (Data) -> Void
    let onReceiveTransfer: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            if isMe { Spacer(minLength: 58) }
            else { IdentityAvatar(data: avatarData, name: name, size: 33, tint: Macaron.pink) }

            messageBubble
                .contextMenu {
                    if !message.isWithdrawn && message.kind == .text {
                        Button("编辑文本", systemImage: "pencil", action: onEdit)
                    }
                    if !message.isWithdrawn {
                        Button(isMe ? "显示为对方发送" : "显示为我发送", systemImage: "arrow.left.arrow.right", action: onChangeRole)
                        Button("修改发送时间", systemImage: "clock", action: onChangeTime)
                        Button("撤回消息", systemImage: "arrow.uturn.backward", role: .destructive, action: onWithdraw)
                    }
                    Button("删除消息", systemImage: "trash", role: .destructive, action: onDelete)
                }

            if isMe { IdentityAvatar(data: avatarData, name: name, size: 33, tint: Macaron.blue) }
            else { Spacer(minLength: 58) }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var messageBubble: some View {
        if message.isWithdrawn {
            Text("你撤回了一条消息")
                .font(.system(size: 12))
                .foregroundStyle(Macaron.secondary)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(Color.white.opacity(0.72), in: Capsule())
        } else if message.kind == .call {
            HStack(spacing: 11) {
                Image(systemName: message.note.contains("视频") ? "video.fill" : "phone.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color(hex: 0x8AB7E8), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text(message.note.contains("视频") ? "视频通话" : "语音通话")
                        .font(.system(size: 14, weight: .semibold))
                    Text(message.note.replacingOccurrences(of: "视频通话 · ", with: "").replacingOccurrences(of: "语音通话 · ", with: ""))
                        .font(.system(size: 12))
                        .opacity(0.75)
                }
                .foregroundStyle(Macaron.ink)
            }
            .padding(12)
            .frame(width: 225, alignment: .leading)
            .background(Color(hex: 0xE7F0FC), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        } else if message.kind == .redPacket {
            HStack(spacing: 11) {
                Image(systemName: "gift.fill").font(.system(size: 25)).foregroundStyle(.white)
                    .frame(width: 45, height: 45).background(Color(hex: 0xE97868), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("虚拟红包").font(.system(size: 15, weight: .semibold))
                    Text(message.note.isEmpty ? "恭喜发财" : message.note).font(.system(size: 12)).opacity(0.8)
                    Text("¥\(message.amount ?? 0, specifier: "%.2f")").font(.system(size: 13, weight: .bold))
                }.foregroundStyle(Macaron.ink)
            }
            .padding(12).frame(width: 225, alignment: .leading)
            .background(Color(hex: 0xFCE7E2), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white, lineWidth: 1))
        } else if message.kind == .transfer {
            HStack(spacing: 11) {
                Image(systemName: "yensign.circle.fill").font(.system(size: 30)).foregroundStyle(.white)
                    .frame(width: 45, height: 45).background(Color(hex: 0xE7A65B), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    Text("虚拟转账").font(.system(size: 15, weight: .semibold))
                    Text(message.note.isEmpty ? "转账" : message.note).font(.system(size: 12)).opacity(0.8)
                    Text("¥\(message.amount ?? 0, specifier: "%.2f")").font(.system(size: 13, weight: .bold))
                    if !isMe && !message.isReceived {
                        Button("收款") { onReceiveTransfer() }
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x2C8A5A))
                            .padding(.top, 3)
                    } else if !isMe && message.isReceived {
                        Text("已收款")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(hex: 0x2C8A5A))
                    }
                }.foregroundStyle(Macaron.ink)
            }
            .padding(12).frame(width: 225, alignment: .leading)
            .background(Color(hex: 0xFFF1D9), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white, lineWidth: 1))
        } else if let data = message.imageData, let image = UIImage(data: data) {
            Button { onImageTap(data) } label: {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 285, maxHeight: 270)
                    .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous)).padding(7)
                    .background(isMe ? outgoingColor.opacity(0.78) : Macaron.card, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 25, style: .continuous).stroke(Color.white.opacity(0.95), lineWidth: 1.4))
            }.buttonStyle(.plain)
        } else {
            Text(message.text).font(.system(size: fontSize)).foregroundStyle(Macaron.ink)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 15).padding(.vertical, 11)
                .background(isMe ? outgoingColor.opacity(0.78) : Macaron.card, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).stroke(Color.white.opacity(0.9), lineWidth: 1))
        }
    }
}


private struct AddContentMenu: View {
    let onDismiss: () -> Void
    let onPhoto: () -> Void
    let onRedPacket: () -> Void
    let onTransfer: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 14) {
                Capsule()
                    .fill(Color(hex: 0xD9DEE8))
                    .frame(width: 34, height: 4)
                    .padding(.top, 10)

                HStack {
                    Text("添加内容")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Macaron.ink)
                    Spacer()
                    Button("取消", action: onDismiss)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Macaron.secondary)
                }

                HStack(spacing: 12) {
                    AddContentMenuItem(symbol: "photo", title: "照片", tint: Color(hex: 0xDCEBFA), action: onPhoto)
                    AddContentMenuItem(symbol: "gift", title: "虚拟红包", tint: Color(hex: 0xF9E2DF), action: onRedPacket)
                    AddContentMenuItem(symbol: "yensign.circle", title: "虚拟转账", tint: Color(hex: 0xFBEBD2), action: onTransfer)
                }
                .padding(.bottom, 8)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .stroke(Color(hex: 0xE9EDF3), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .ignoresSafeArea()
    }
}

private struct AddContentMenuItem: View {
    let symbol: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Macaron.ink)
                    .frame(width: 54, height: 54)
                    .background(tint, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Macaron.ink)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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


private struct AddContactSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var bio = ""
    @State private var avatarSelection: PhotosPickerItem?
    @State private var avatarData: Data?
    let onAdd: (String, String, Data?) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("好友资料") {
                    HStack(spacing: 14) {
                        IdentityAvatar(data: avatarData, name: name.isEmpty ? "新" : name, size: 62, tint: Macaron.pink)
                        PhotosPicker(selection: $avatarSelection, matching: .images) {
                            Label("选择头像", systemImage: "photo")
                        }
                    }
                    TextField("好友昵称", text: $name)
                    TextField("个性签名（可选）", text: $bio)
                }
                Section {
                    Text("新增好友会建立独立聊天记录，之后可以在好友主页编辑资料和朋友圈。")
                        .font(.system(size: 12))
                        .foregroundStyle(Macaron.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Macaron.background)
            .navigationTitle("添加好友")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        onAdd(name, bio, avatarData)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .fontWeight(.semibold)
                }
            }
            .onChange(of: avatarSelection) { _, item in
                guard let item else { return }
                Task {
                    avatarData = try? await item.loadTransferable(type: Data.self)
                    avatarSelection = nil
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct FriendProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var contact: ChatContact
    @State private var avatarSelection: PhotosPickerItem?
    @State private var showMomentEditor = false
    @State private var momentDraft = ""
    @State private var editingMomentID: UUID?
    let onUpdate: (ChatContact) -> Void

    init(contact: ChatContact, onUpdate: @escaping (ChatContact) -> Void) {
        _contact = State(initialValue: contact)
        self.onUpdate = onUpdate
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    VStack(spacing: 10) {
                        PhotosPicker(selection: $avatarSelection, matching: .images) {
                            ZStack(alignment: .bottomTrailing) {
                                IdentityAvatar(data: contact.avatarData, name: contact.name, size: 82, tint: Macaron.pink)
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 25, height: 25)
                                    .background(Color(hex: 0x83B9EF), in: Circle())
                                    .overlay(Circle().stroke(.white, lineWidth: 2))
                            }
                        }
                        .buttonStyle(.plain)
                        TextField("好友昵称", text: $contact.name)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(Macaron.ink)
                            .multilineTextAlignment(.center)
                        TextField("好友个性签名", text: $contact.bio, axis: .vertical)
                            .font(.system(size: 13))
                            .foregroundStyle(Macaron.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(Macaron.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))

                    VStack(alignment: .leading, spacing: 9) {
                        Text("好友笔记")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Macaron.ink)
                        TextEditor(text: $contact.notes)
                            .font(.system(size: 13))
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 90)
                            .padding(8)
                            .background(Macaron.background, in: RoundedRectangle(cornerRadius: 14))
                        Text("这里只是本机保存的好友备注和记录。")
                            .font(.system(size: 10))
                            .foregroundStyle(Macaron.secondary)
                    }
                    .padding(15)
                    .background(Macaron.card, in: RoundedRectangle(cornerRadius: 21, style: .continuous))

                    VStack(spacing: 12) {
                        HStack {
                            Text("他的朋友圈")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Macaron.ink)
                            Spacer()
                            Button {
                                editingMomentID = nil
                                momentDraft = ""
                                showMomentEditor = true
                            } label: {
                                Label("发布动态", systemImage: "plus")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0x4F91D2))
                            }
                        }
                        .padding(.horizontal, 4)

                        if contact.moments.isEmpty {
                            EmptyHint(symbol: "text.bubble", title: "暂时没有动态", subtitle: "可以在这里记录这位好友的朋友圈内容。")
                                .padding(.vertical, 20)
                        } else {
                            ForEach(contact.moments) { post in
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(post.text)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Macaron.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let mediaData = post.mediaData {
                                        MomentMediaView(data: mediaData, mediaType: post.mediaType)
                                    }
                                    Text(post.date, format: .dateTime.year().month().day().hour().minute())
                                        .font(.system(size: 10))
                                        .foregroundStyle(Macaron.secondary)
                                }
                                .padding(15)
                                .background(Macaron.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .contextMenu {
                                    Button("编辑动态", systemImage: "pencil") {
                                        editingMomentID = post.id
                                        momentDraft = post.text
                                        showMomentEditor = true
                                    }
                                    Button("删除动态", systemImage: "trash", role: .destructive) {
                                        contact.moments.removeAll { $0.id == post.id }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Macaron.background)
            .navigationTitle("好友主页")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onUpdate(contact)
                        dismiss()
                    }
                }
            }
            .onChange(of: contact.name) { _, _ in onUpdate(contact) }
            .onChange(of: contact.bio) { _, _ in onUpdate(contact) }
            .onChange(of: contact.notes) { _, _ in onUpdate(contact) }
            .onChange(of: avatarSelection) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        contact.avatarData = data
                        onUpdate(contact)
                    }
                    avatarSelection = nil
                }
            }
            .sheet(isPresented: $showMomentEditor) {
                MomentEditorSheet(
                    title: editingMomentID == nil ? "发布好友动态" : "编辑好友动态",
                    initialText: momentDraft,
                    initialMediaData: editingMomentID.flatMap { id in contact.moments.first(where: { $0.id == id })?.mediaData },
                    initialMediaType: editingMomentID.flatMap { id in contact.moments.first(where: { $0.id == id })?.mediaType }
                ) { text, mediaData, mediaType in
                    if let id = editingMomentID,
                       let index = contact.moments.firstIndex(where: { $0.id == id }) {
                        contact.moments[index].text = text
                        contact.moments[index].date = .now
                        contact.moments[index].mediaData = mediaData
                        contact.moments[index].mediaType = mediaType
                    } else {
                        contact.moments.insert(MomentPost(text: text, mediaData: mediaData, mediaType: mediaType), at: 0)
                    }
                    onUpdate(contact)
                }
            }
            .onChange(of: contact.moments.count) { _, _ in onUpdate(contact) }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct MomentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var mediaSelection: PhotosPickerItem?
    @State private var mediaData: Data?
    @State private var mediaType: String?
    let title: String
    let onSave: (String, Data?, String?) -> Void

    init(title: String, initialText: String, initialMediaData: Data? = nil, initialMediaType: String? = nil,
         onSave: @escaping (String, Data?, String?) -> Void) {
        self.title = title
        _text = State(initialValue: initialText)
        _mediaData = State(initialValue: initialMediaData)
        _mediaType = State(initialValue: initialMediaType)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 130)
                    .background(Macaron.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                PhotosPicker(selection: $mediaSelection, matching: .any(of: [.images, .videos])) {
                    Label(mediaData == nil ? "添加照片或视频" : "更换照片或视频", systemImage: "photo.on.rectangle.angled")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color(hex: 0x4F91D2))
                        .padding(12)
                        .background(Macaron.blue, in: Capsule())
                }
                if let mediaData {
                    MomentMediaView(data: mediaData, mediaType: mediaType)
                        .frame(maxHeight: 170)
                    Button("移除媒体", role: .destructive) {
                        self.mediaData = nil
                        mediaType = nil
                    }
                    .font(.system(size: 12))
                }
                Text("动态只保存在本机，可以随时再次编辑或删除。")
                    .font(.system(size: 11))
                    .foregroundStyle(Macaron.secondary)
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Macaron.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !value.isEmpty || mediaData != nil else { return }
                        onSave(value, mediaData, mediaType)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && mediaData == nil)
                }
            }
            .onChange(of: mediaSelection) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        mediaData = data
                        mediaType = item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) ? "video" : "image"
                    }
                    mediaSelection = nil
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct MomentMediaView: View {
    let data: Data
    let mediaType: String?
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if mediaType == "video" {
                VideoPlayer(player: player)
                    .frame(maxWidth: .infinity)
                    .frame(height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onAppear { preparePlayer() }
                    .onDisappear { player?.pause(); player = nil }
            } else if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func preparePlayer() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moment-\(UUID().uuidString).mov")
        do {
            try data.write(to: url, options: .atomic)
            player = AVPlayer(url: url)
        } catch {
            NSLog("CustomChat: unable to prepare moment video: %@", error.localizedDescription)
        }
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