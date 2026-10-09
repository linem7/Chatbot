import ChatbotCore
import Foundation

/// 输入区里一个待发送的附件。图片缩放、PDF 抽文字可能要几百毫秒，处理完之前先显示一个占位。
struct DraftAttachment: Identifiable, Equatable {
    enum State: Equatable {
        case processing
        case ready(Attachment)
    }

    let id: UUID
    let name: String
    var state: State

    var attachment: Attachment? {
        if case .ready(let attachment) = state { return attachment }
        return nil
    }
}

/// Quick Panel 的附件：「+」、粘贴、拖放三个入口都走这里，规则由 ChatbotCore 的 `AttachmentIntake` 统一处理（SPEC §4）。
extension ChatStore {
    /// 「+」、拖放，或者从 Finder 复制后粘贴的文件。
    func addAttachments(fromFiles urls: [URL]) {
        for url in urls where url.isFileURL {
            process(name: url.lastPathComponent) { try AttachmentIntake().attachment(fromFile: url) }
        }
    }

    /// 剪贴板里的图片数据（例如截图工具复制的图片）。
    func addAttachment(imageData: Data) {
        let name = String(localized: "Pasted Image") + ".png"
        process(name: name) { try AttachmentIntake().attachment(fromImageData: imageData, name: name) }
    }

    func removeDraftAttachment(id: UUID) {
        draftAttachments.removeAll { $0.id == id }
    }

    /// 当前 Model 是否接受图片，以 Model Capabilities 为准（SPEC §4）。
    var currentModelAcceptsImages: Bool {
        currentModelCapabilities?.imageInput ?? false
    }

    /// 当前 Model 是否支持 Web Search；不支持时地球按钮置灰（SPEC §5）。
    var currentModelSupportsWebSearch: Bool {
        currentModelCapabilities?.webSearch ?? false
    }

    /// 地球按钮现在是不是开着：Model 支持搜索，并且这个 Conversation 没有关掉。
    var isWebSearchOn: Bool {
        currentModelSupportsWebSearch && (conversation?.webSearchEnabled ?? true)
    }

    private var currentModelCapabilities: ModelCapabilities? {
        guard let model = currentModel, let connection = connections.connection(id: model.connectionID) else { return nil }
        return connection.models.first { $0.id == model.modelID }?.capabilities
    }

    /// 草稿里有图片、而当前 Model 不接受图片时的提示。图片照样可以留着，但不会发给模型。
    var imageNotAcceptedWarning: String? {
        let hasImage = draftAttachments.contains { $0.attachment?.kind == .image }
        return hasImage && !currentModelAcceptsImages ? String(localized: "The current model can't accept images.") : nil
    }

    /// 草稿附件里有没有这次真的会发给模型的内容：不接受图片时，图片不算。
    var hasSendableAttachments: Bool {
        draftAttachments.contains { draft in
            guard let attachment = draft.attachment else { return false }
            return attachment.kind != .image || currentModelAcceptsImages
        }
    }

    var isProcessingAttachments: Bool {
        draftAttachments.contains { $0.state == .processing }
    }

    /// 发送时取走处理好的附件。
    func takeDraftAttachments() -> [Attachment] {
        let attachments = draftAttachments.compactMap(\.attachment)
        draftAttachments = []
        attachmentNotice = nil
        return attachments
    }

    /// 已经发出的附件，供消息气泡显示。
    func rememberAttachments(_ attachments: [Attachment]) {
        for attachment in attachments { attachmentsByID[attachment.id] = attachment }
    }

    /// 在后台处理（图片缩放、PDF 抽文字），完成后替换占位；出错时去掉占位并给出提示。
    private func process(name: String, _ work: @escaping @Sendable () throws -> Attachment) {
        let id = UUID()
        draftAttachments.append(DraftAttachment(id: id, name: name, state: .processing))
        attachmentNotice = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try work() } }.value
            guard let index = draftAttachments.firstIndex(where: { $0.id == id }) else { return }
            switch result {
            case .success(let attachment):
                draftAttachments[index].state = .ready(attachment)
            case .failure(let error):
                draftAttachments.remove(at: index)
                attachmentNotice = (error as? AttachmentError)?.displayText
                    ?? String(localized: "Couldn't read “\(name)”.")
            }
        }
    }
}

extension AttachmentError {
    /// 加入附件失败时的提示，显示在输入区上方。
    var displayText: String {
        switch self {
        case .unsupportedType(let name):
            String(localized: "“\(name)” isn't a supported file type.")
        case .unreadable(let name):
            String(localized: "Couldn't read “\(name)”.")
        case .scannedPDF(let name):
            String(localized: "“\(name)” has no text to extract. It may be a scanned PDF.")
        }
    }
}
