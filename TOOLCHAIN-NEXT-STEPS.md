# 内置 iOS 工具链：剩余步骤与所需文件

## 当前状态

- GitHub Actions 的 arm64 + arm64e 工具链构建及链接检查已成功。
- Artifact 已上传，大小约 77.7 MB，ID：`12401257637`。
- Artifact 尚未下载并检查，因此包内文件、清单和哈希仍待核验。
- Minis 尚未链接这些库；内置编译器仍保持禁用，`EmbeddedToolchainBuildProvider` 仍不可执行。
- 完整 Minis Xcode 构建及设备运行时编译验证尚未完成。

## Artifact 下载

下载页面：

<https://github.com/JudeGor1129/OpenMinis/actions/runs/39717305630/artifacts/12401257637>

如网页无法下载，先确认浏览器登录了有仓库访问权限的 GitHub 账号；也可从该次运行的 `Upload toolchain artifacts` 日志底部点击 **Artifact download URL**。不要将 GitHub token 粘贴到聊天或提交进仓库。

## 解压后必须检查的文件

```text
libomllvm-arm64.a
libomllvm-arm64e.a
libomld64.a
clang-resource/
dev-headers/
toolchain.json
enabled-link-report.json
```

检查 `toolchain.json` 中的架构、固定源码 revision、文件清单和哈希是否与归档实际内容一致；查看 `enabled-link-report.json` 及日志，确认 arm64 和 arm64e 的桥接编译、静态链接检查都成功。

## 后续步骤

1. **下载并解压 artifact**，保存完整原始 ZIP 与解压目录。
2. **核验文件和哈希**，确认两种 LLVM 架构库、ld64、开发头文件、builtin headers、工具链清单和链接报告都存在且匹配。
3. **接入 Minis Xcode 工程**：按主程序架构链接对应 LLVM 库及 ld64，加入匹配头文件、Clang 资源目录和需要的链接依赖；保持 Minis 最低系统版本 iOS 16.0。
4. **构建完整 Minis App**，确认 Xcode 工程链接成功并检查产物架构。
5. **实现实际编译适配层**：将项目构建输入转换为 Clang `cc1` 参数，调用 in-process 编译和 ld64，处理临时目录、输出、诊断与失败状态。当前 Provider 只是状态检查，`build` 和 `test` 均返回不可用。
6. **运行时验证**：分别验证 arm64 和 arm64e 的真实源文件编译、链接、诊断、重复构建及 Mach-O 输出架构；继续验证内存增长、错误恢复和 arm64e/PAC 行为。
7. **全部必要门禁通过后**，再于正式集成中启用 `OM_TOOLCHAIN_ENABLED=1` 与 `OM_TOOLCHAIN_VERIFIED=1`，并开放 Provider 执行。不得仅凭 link-only probe 通过就开放运行时编译。

## 所需环境与文件

| 项目 | 用途 |
|---|---|
| GitHub Actions artifact ZIP | 双架构工具链构建产物与验证材料 |
| `libomllvm-arm64.a` | arm64 Minis 主进程的 LLVM/Clang 静态库 |
| `libomllvm-arm64e.a` | arm64e Minis 主进程的 LLVM/Clang 静态库 |
| `libomld64.a` | Mach-O 链接器静态库 |
| `dev-headers/` | 与固定 LLVM revision 匹配的开发及生成头文件 |
| `clang-resource/` | Clang builtin headers/resource 内容 |
| `toolchain.json` | 版本、架构、文件清单和哈希信息 |
| `enabled-link-report.json` 与日志 | 双架构 enabled bridge 静态链接检查证据 |
| Minis 源码、`Minis.xcodeproj` | 将已核验工具链集成进 App 并完整构建 |
| macOS + Xcode | 完整 App 编译、链接和后续 iOS 真机验证 |

## 重要限制

- 当前 Twork 环境没有 `xcodebuild`，不能在这里完成 Minis Xcode 构建。
- GitHub 的 link-only 检查不等于真实运行 `runCC1`/ld64，也不能证明设备运行安全。
- 不要使用 arm64e 归档替代 arm64 归档；必须按实际 App 主进程架构链接匹配库。
- 不要降低 Minis 当前 iOS 16.0 最低部署目标来绕过工具链问题。
