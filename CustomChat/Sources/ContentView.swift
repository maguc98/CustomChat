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
    }
}

struct ContentView: View {
    @StateObject private var model = ChatModel()
    @Environment(\.openURL) private var openURL

    @State private var draft = ""
    @State private var editing: ChatMessage?
    @State private var editText = ""
    @State private var showIdentitySettings = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var myAvatarSelection: PhotosPickerItem?
    @State private var otherAvatarSelection: PhotosPickerItem?
    @State private var showContactAlert = false

    private let ink = Color(red: 0.25, green: 0.31, blue: 0.39)
    private let sky = Color(red: 0.78, green: 0.89, blue: 0.98)
    private let mint = Color(red: 0.82, green: 0.93, blue: 0.86)
    private let lavender = Color(red: 0.89, green: 0.85, blue: 0.96)
    private let peach = Color(red: 1.00, green: 0.89, blue: 0.79)
    private let rose = Color(red: 0.98, green: 0.86, blue: 0.90)

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.97, blue: 0.99),
                    Color(red: 0.94, green: 0.96, blue: 0.98),
                    Color(red: 0.98, green: 0.95, blue: 0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            dateDivider
                                .padding(.top, 18)

                            if model.messages.isEmpty {
                                emptyState
                                    .padding(.top, 72)
                            } else {
                                ForEach(model.messages) { message in
                                    MessageRow(
                                        message: message,
                                        name: model.name(for: message.role),
                                        avatarData: model.avatar(for: message.role),
                                        isMe: message.role == .me,
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
                        .padding(.horizontal, 16)
                        .padding(.bottom, 22)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: model.messages.count) { _, _ in
                        guard let last = model.messages.last else { return }
                        withAnimation(.easeOut(duration: 0.28)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }

                composer
            }
        }
        .sheet(isPresented: $showIdentitySettings) {
            identitySheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let compact = compactImageData(data) else { return }
                model.sendImage(compact)
                selectedPhoto = nil
            }
        }
        .onChange(of: myAvatarSelection) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let compact = compactImageData(data) else { return }
                model.identity.meAvatarData = compact
                myAvatarSelection = nil
            }
        }
        .onChange(of: otherAvatarSelection) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let compact = compactImageData(data) else { return }
                model.identity.otherAvatarData = compact
                otherAvatarSelection = nil
            }
        }
        .alert("还没有设置联系方式", isPresented: $showContactAlert) {
            Button("知道了", role: .cancel) {}
            Button("去设置") { showIdentitySettings = true }
        } message: {
            Text("请先在聊天设置中填写对方的手机号或 FaceTime 邮箱。")
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
        HStack(spacing: 11) {
            IdentityAvatar(
                data: model.identity.otherAvatarData,
                name: model.name(for: .other),
                size: 46,
                tint: lavender
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(model.name(for: .other))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                    .lineLimit(1)
                Text("CustomChat · 私人聊天空间")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(ink.opacity(0.52))
            }

            Spacer(minLength: 4)

            HeaderAction(symbol: "phone.fill", tint: mint, label: "语音通话") {
                startCall(video: false)
            }

            HeaderAction(symbol: "video.fill", tint: sky, label: "视频通话") {
                startCall(video: true)
            }

            HeaderAction(symbol: "slider.horizontal.3", tint: peach, label: "聊天设置") {
                showIdentitySettings = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 13)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.white.opacity(0.72))
                .frame(height: 1)
        }
    }

    private var dateDivider: some View {
        HStack(spacing: 10) {
            Capsule().fill(ink.opacity(0.10)).frame(height: 1)
            Text("今天")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.opacity(0.48))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.white.opacity(0.62), in: Capsule())
            Capsule().fill(ink.opacity(0.10)).frame(height: 1)
        }
        .padding(.horizontal, 42)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(rose.opacity(0.65))
                    .frame(width: 94, height: 94)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color(red: 0.71, green: 0.57, blue: 0.72))
            }

            Text("把聊天变成你喜欢的样子")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(ink)

            Text("从这里开始记录你们的对话。\\n可以切换身份、发送文字和图片。")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(ink.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineSpacing(4)

            Button {
                showIdentitySettings = true
            } label: {
                Label("设置昵称和头像", systemImage: "person.crop.circle")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.82))
                    .padding(.horizontal, 17)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.82), in: Capsule())
                    .overlay(Capsule().stroke(.white, lineWidth: 1))
            }
            .padding(.top, 3)
        }
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(spacing: 11) {
            HStack(spacing: 8) {
                Text("正在以")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(ink.opacity(0.52))

                ForEach(ChatRole.allCases, id: \\.self) { role in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.76)) {
                            model.activeRole = role
                        }
                    } label: {
                        HStack(spacing: 6) {
                            IdentityAvatar(
                                data: model.avatar(for: role),
                                name: model.name(for: role),
                                size: 22,
                                tint: role == .me ? sky : lavender
                            )
                            Text(model.name(for: role))
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundStyle(ink.opacity(model.activeRole == role ? 0.9 : 0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            Capsule()
                                .fill(model.activeRole == role ? .white : .white.opacity(0.28))
                                .shadow(color: .black.opacity(model.activeRole == role ? 0.05 : 0), radius: 5, y: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 0)
            }

            HStack(alignment: .bottom, spacing: 9) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.72))
                        .frame(width: 43, height: 46)
                        .background(peach.opacity(0.78), in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                }
                .accessibilityLabel("发送图片")

                HStack(alignment: .bottom, spacing: 8) {
                    TextField("发送一条消息…", text: $draft, axis: .vertical)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(ink)
                        .lineLimit(1...5)
                        .padding(.vertical, 12)
                        .onSubmit(sendText)

                    Button(action: sendText) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 0.55, green: 0.75, blue: 0.91), Color(red: 0.66, green: 0.72, blue: 0.91)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: Circle()
                            )
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.48 : 1)
                    .padding(.trailing, 6)
                    .padding(.bottom, 6)
                }
                .padding(.leading, 15)
                .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .stroke(.white, lineWidth: 1.2)
                }
                .shadow(color: ink.opacity(0.045), radius: 12, y: 4)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 12)
        .padding(.bottom, 9)
        .background(.regularMaterial)
    }

    private var identitySheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 17) {
                    identityEditor(
                        title: "我的资料",
                        subtitle: "你的昵称与头像",
                        name: $model.identity.me,
                        avatarData: model.identity.meAvatarData,
                        selection: $myAvatarSelection,
                        tint: sky
                    )

                    identityEditor(
                        title: "对方资料",
                        subtitle: "对方的昵称与头像",
                        name: $model.identity.other,
                        avatarData: model.identity.otherAvatarData,
                        selection: $otherAvatarSelection,
                        tint: lavender
                    )

                    VStack(alignment: .leading, spacing: 9) {
                        Label("通话联系方式", systemImage: "phone.badge.waveform")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(ink)
                        TextField("手机号或 FaceTime 邮箱", text: $model.identity.callContact)
                            .font(.system(size: 14, design: .rounded))
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(14)
                            .background(.white, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                        Text("语音按钮会拨打手机号，或通过 FaceTime 音频呼叫邮箱；视频按钮会打开 FaceTime。")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(ink.opacity(0.52))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(15)
                    .background(peach.opacity(0.42), in: RoundedRectangle(cornerRadius: 21, style: .continuous))

                    Text("昵称、头像和聊天记录保存在这台设备上。")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(ink.opacity(0.45))
                        .padding(.bottom, 10)
                }
                .padding(16)
            }
            .background(Color(red: 0.96, green: 0.97, blue: 0.99))
            .navigationTitle("聊天个性化")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showIdentitySettings = false }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func identityEditor(
        title: String,
        subtitle: String,
        name: Binding<String>,
        avatarData: Data?,
        selection: Binding<PhotosPickerItem?>,
        tint: Color
    ) -> some View {
        HStack(spacing: 13) {
            PhotosPicker(selection: selection, matching: .images) {
                ZStack(alignment: .bottomTrailing) {
                    IdentityAvatar(
                        data: avatarData,
                        name: name.wrappedValue,
                        size: 62,
                        tint: tint
                    )
                    Image(systemName: "camera.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color(red: 0.46, green: 0.64, blue: 0.79), in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("更换\\(title)头像")

            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(ink)
                TextField(subtitle, text: name)
                    .font(.system(size: 14, design: .rounded))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.white, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
        .padding(15)
        .background(tint.opacity(0.48), in: RoundedRectangle(cornerRadius: 21, style: .continuous))
    }

    private func sendText() {
        model.send(draft)
        draft = ""
    }

    private func startCall(video: Bool) {
        let contact = model.identity.callContact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contact.isEmpty else {
            showContactAlert = true
            return
        }

        let destination: URL?
        if video {
            destination = URL(string: "facetime://\\(contact)")
        } else if contact.contains("@") {
            destination = URL(string: "facetime-audio://\\(contact)")
        } else {
            let digits = contact.filter { $0.isNumber || $0 == "+" }
            destination = URL(string: "tel:\\(digits)")
        }

        guard let destination else {
            showContactAlert = true
            return
        }
        openURL(destination)
    }

    private func compactImageData(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longestSide = max(image.size.width, image.size.height)
        guard longestSide > 0 else { return nil }
        let scale = min(1, 1500 / longestSide)
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.78)
    }
}

private struct HeaderAction: View {
    let symbol: String
    let tint: Color
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(red: 0.29, green: 0.36, blue: 0.44).opacity(0.82))
                .frame(width: 37, height: 37)
                .background(tint.opacity(0.72), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
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
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(tint)
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.40, weight: .medium))
                        .foregroundStyle(Color(red: 0.48, green: 0.55, blue: 0.65).opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 2))
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    let name: String
    let avatarData: Data?
    let isMe: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    private let ink = Color(red: 0.25, green: 0.31, blue: 0.39)

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isMe { Spacer(minLength: 48) }

            if !isMe {
                IdentityAvatar(
                    data: avatarData,
                    name: name,
                    size: 34,
                    tint: Color(red: 0.89, green: 0.85, blue: 0.96)
                )
            }

            VStack(alignment: isMe ? .trailing : .leading, spacing: 5) {
                Text(name)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(ink.opacity(0.48))
                    .padding(.horizontal, 5)

                VStack(alignment: .leading, spacing: 7) {
                    if let data = message.imageData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 225, maxHeight: 290)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }

                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.system(size: 15, weight: .regular, design: .rounded))
                            .foregroundStyle(ink.opacity(0.92))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, message.imageData == nil ? 14 : 8)
                .padding(.vertical, message.imageData == nil ? 11 : 8)
                .background(
                    isMe
                        ? Color(red: 0.80, green: 0.90, blue: 0.98)
                        : Color(red: 0.84, green: 0.93, blue: 0.87),
                    in: RoundedRectangle(cornerRadius: 21, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 21, style: .continuous)
                        .stroke(.white.opacity(0.88), lineWidth: 1)
                }
                .shadow(color: ink.opacity(0.035), radius: 7, y: 3)
                .contextMenu {
                    if !message.text.isEmpty {
                        Button("编辑", systemImage: "pencil", action: onEdit)
                    }
                    Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
                }

                Text(message.time, format: .dateTime.hour().minute())
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(ink.opacity(0.35))
                    .padding(.horizontal, 5)
            }

            if isMe {
                IdentityAvatar(
                    data: avatarData,
                    name: name,
                    size: 34,
                    tint: Color(red: 0.78, green: 0.89, blue: 0.98)
                )
            } else {
                Spacer(minLength: 48)
            }
        }
        .frame(maxWidth: .infinity)
        .transition(.asymmetric(
            insertion: .move(edge: isMe ? .trailing : .leading).combined(with: .opacity),
            removal: .opacity
        ))
    }
}
