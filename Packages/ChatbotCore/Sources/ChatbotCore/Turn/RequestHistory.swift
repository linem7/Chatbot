extension Array where Element == Message {
    /// 拼请求前整理历史：去掉没有得到回答的用户 Message。
    ///
    /// 一次 Turn 失败或被取消、而且一点内容都没收到时，这条用户 Message 和那条空的回答一起去掉，
    /// 和 Retry「新回答替换旧的」一致。否则请求里会出现连续两条 user，有的 Provider 会拒绝，
    /// 这个 Conversation 之后每次发送都会失败。后面没有回答的用户 Message 也一样去掉。
    ///
    /// 「没有内容」按正文判断，不按内容块：Anthropic、Gemini 的回答可能只有 opaque 或 webSearch 块
    /// （例如还没出正文就取消了），adapter 会跳过这样的回答，所以它也算没有回答。
    /// 这样连「complete 但没有正文」的回答也会去掉，这种情况极少见，可以接受。
    func droppingUnansweredTurns() -> [Message] {
        var result: [Message] = []
        var index = startIndex
        while index < endIndex {
            let message = self[index]
            switch message.role {
            case .user:
                let next = index + 1 < endIndex ? self[index + 1] : nil
                if let next, next.role == .assistant {
                    if !next.markdownText.isEmpty { result += [message, next] }
                    index += 2
                } else {
                    index += 1
                }
            case .assistant:
                if !message.markdownText.isEmpty { result.append(message) }
                index += 1
            }
        }
        return result
    }
}
