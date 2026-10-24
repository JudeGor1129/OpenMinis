# OpenMinis 状态

## 当前项目

- Git 根：`/var/minis/workspace/10-minis/openminis`
- 分支：`ios15-port`
- 远端：`JudeGor1129/OpenMinis`
- 目标设备：iPhone 13 Pro Max / iOS 15.4.1 / XinaA15 rootless

## 最近状态

- `#123` / `5b38928`：Release IPA 构建成功；RootFS 编译工具与 iPhoneOS SDK 选择页、工具链状态页、`rea` 状态显示已加入。
- 最新 IPA artifact：以 GitHub Actions 页面实际查询结果为准。
- `#119` / `2abad1c`：Release IPA 构建成功；包含零滚动会话首屏、子代理窗口稳定化和锁屏后台保活修复。

## 开发约定

- 完整 IPA 构建：修改 workflow paths 内文件，并在 commit message 中带 `[ios15-full-build]`。
- 普通 push：只触发 navigation-check，不产生 IPA。
- 使用真实 Actions run ID 和 artifact ID，不猜测或把 run number 当 run ID。
- iOS 15 首屏使用倒置 legacy transcript，最新消息位于原生 offset 0；不要重新引入进入会话时的 scrollTo/contentOffset 动画。
- 现有源码守卫位于 `scripts/ios15/`，修改后先运行相关守卫。
- Theos 环境位于 `/opt/theos`，不随工作区迁移。
