# OpenMinis iOS - Performance & Toolchain Status

## 当前分支: perf-toolchain-status

### 本次更新内容

#### 1. 性能优化

修复了多消息会话卡顿和键盘打字卡顿问题：

**ContentView.swift**
- 优化会话列表 memo key 比较：O(N) 深度比较 → O(1) 哈希比较
- 使用 `foldersHash`, `unreadHash`, `freshHash`, `activeHash` 替代完整数组

**FileMentionIndex.swift**
- 添加 mention 扫描节流（1秒间隔）
- 防止快速打字 `@` 时重复触发磁盘扫描

**ChatInputBar.swift**
- 光标更新批量化：`DispatchQueue.main.async` 延迟到下一个 runloop tick
- 同一 tick 内的多次光标变化合并为一次更新

#### 2. RootFS 管理页新增工具链状态

**ToolchainStatusView.swift** (新文件)
- 显示 iSH Alpine 环境中 18 个工具的状态
- 分类：核心工具、逆向工程、调试分析、系统工具
- 支持手动刷新和 60 秒自动刷新
- 显示版本号和安装状态

**工具列表：**
| 类别 | 工具 |
|------|------|
| 核心工具 | Node.js, npm, Python, pip, make, git |
| 逆向工程 | Theos, Clang, ldid, radare2, otool, strip, llvm-lipo |
| 调试分析 | Frida Server, strace, lsof |
| 系统工具 | dpkg, apt, procps, busybox |

### 构建 IPA

1. 确保 GitHub Actions 已启用
2. 推送分支触发自动构建
3. 从 Actions 页面下载生成的 `Minis.ipa`

### 验证清单

- [ ] 编译无错误
- [ ] 会话列表滚动流畅
- [ ] 打字键盘无卡顿
- [ ] RootFS 页面显示工具链状态
- [ ] 工具状态检测正常
- [ ] 60 秒自动刷新正常
