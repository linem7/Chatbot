# 用自签名证书签名，不做公证

用户没有 Apple Developer 付费账号，没法用 Developer ID 签名，也没法公证。所以本地构建和 CI 发布都用**同一张长期有效的自签名代码签名证书**。CI 里的证书以 GitHub secret 的形式保存。

**为什么一定要固定证书**：API key 存在 Keychain 里，Keychain 按签名身份判断访问权限。ad hoc 签名每次构建身份都会变，app 每次重新构建或升级后读 key 时都可能弹窗。

**代价**：没有公证，下载的人第一次打开时会被 Gatekeeper 拦下。从 macOS 15 开始，右键「打开」已经绕不过去，必须到「系统设置 → 隐私与安全性」里点「仍要打开」。README 要写明这一步。

## Considered Options

- **免费 Apple ID 的 Apple Development 证书**：否决。证书一年后过期，换证书后 Keychain 会重新弹窗，而且这张证书不方便放进 CI。
- **每次都用 ad hoc 签名**：否决。原因就是上面说的 Keychain 反复弹窗。

## Consequences

- 以后如果买了付费账号，改用 Developer ID 签名并加上公证即可。但签名身份一变，所有用户在升级后的第一次启动时都会弹一次 Keychain 授权。
- 证书的私钥丢失，效果等同于更换证书，所以要备份好。
