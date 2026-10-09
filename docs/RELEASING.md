# 自动发布

将代码推送到 GitHub 仓库的 `main` 分支后，`.github/workflows/release.yml` 自动执行：

1. 读取 `Info.plist` 基础版本和仓库已有的 `vX.Y.Z` 标签，取较大版本并递增 patch。当前基础版本 `1.0` 的首次发布为 `v1.0.1`。
2. 在 macOS runner 上编译 arm64 和 x86_64，合并为 Universal Binary，给应用包写入新版本并使用 长期保存的同一张自签证书签名，无需 Apple 开发者账户。
3. 验证架构、签名和版本，生成带拖拽安装窗口的 `Hola-vX.Y.Z-macOS-universal.dmg`、备用 ZIP 与 `SHA256SUMS.txt`。
4. 给触发推送的提交打标签，创建草稿 Release，上传完整附件后正式发布，并自动生成变更记录。

版本以 Git 标签和发布包中的 `CFBundleShortVersionString` / `CFBundleVersion` 为准，不回写 main 的 `Info.plist`，因此无需机器人绕过 main 分支保护，也不会产生版本提交触发循环。要调整主版本或次版本，可以修改 `Info.plist` 中的基础版本；例如设为 `2.0.0` 后，下次发布 `2.0.1`。

并发推送会串行排队（最多 100 个等待任务）。构建失败不会创建标签；发布阶段失败后重新运行会复用该提交已有标签并补全草稿。已正式发布的同一提交再次运行会跳过构建和上传。也可在 Actions 页面从 main 手动运行工作流。

## 仓库要求

- 必须托管或同步到 GitHub；仅推送到 `git.woa.com` 不会运行 GitHub Actions。
- 启用 GitHub Actions，并允许工作流申请 `contents: write` 权限。发布使用内置 `GITHUB_TOKEN`，无需额外 PAT；签名需要下方三个 Secrets。
- 若标签规则限制创建 `v*` 标签，需允许此工作流创建发布标签。
- DMG 和 ZIP 内的应用使用固定自签证书签名，未做 Apple 公证；首次安装可能被 Gatekeeper 拦截，升级后可能需要重新授权系统权限。

DMG 由 `scripts/package-dmg.sh` 构建，窗口包含应用、指向 `/Applications` 的链接、拖拽箭头，以及 macOS 13+ 和 macOS 12 的首次打开指引。脚本使用固定版本 `dmgbuild==1.6.7` 写入 Finder 布局，首次运行会在 `build/.dmg-venv` 中安装该工具。

## 固定签名证书

GitHub 仓库的 Actions Secrets 必须配置：

| Secret | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_BASE64` | 包含私钥的 `.p12` 文件的 Base64 |
| `MACOS_CERTIFICATE_PASSWORD` | `.p12` 导出密码 |
| `MACOS_CERTIFICATE_SHA1` | 证书 SHA-1 指纹，40 位大写十六进制，不含冒号 |

证书只生成一次，每次 CI 导入到临时钥匙串，按指纹选择身份并签名，结束后删除临时钥匙串。缺少 Secrets 或指纹不匹配会停止发布，不会生成新证书或降级为 ad-hoc。

当前发布证书名称为 `Hola Release`，有效期 10 年。证书包、密码和指纹备份在生成它的 Mac 上的 `~/.config/hola-release-signing/`（仓库之外，仅当前用户可访问）。请将该目录另行安全备份；GitHub Secrets 无法读回私钥。续期或换证会改变证书身份，需评估用户重新授权的影响。

固定的是证书身份和应用标识，不是每版二进制的签名内容或哈希。它不提供 Apple Developer ID 信任或公证，用户仍需按 README 允许打开；不要求用户安装或信任根证书，也不保证 macOS 永久保留权限。

## 本地验证构建

```bash
SIGN_ID='Hola Local' ARCHS='arm64 x86_64' APP_VERSION=1.0.1 \
  APP_PATH="$PWD/build/release-check/Hola.app" bash build.sh
xcrun lipo build/release-check/Hola.app/Contents/MacOS/Hola -verify_arch arm64 x86_64
codesign --verify --strict build/release-check/Hola.app
```

普通 `bash build.sh` 继续使用本机架构及 `Hola Local` 稳定签名身份。

参考：[GitHub 工作流并发队列](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)、[GitHub CLI Release 创建](https://cli.github.com/manual/gh_release_create)。
