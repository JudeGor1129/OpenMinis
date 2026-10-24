# 工作区重构记录

- `MinisSource` 已迁移为 `10-minis/openminis/`，Git 根目录和远程地址保持不变。
- 项目内保留 `scripts/`、`docs/`、`notes/`、`build/`、`artifacts/`。
- 构建状态脚本迁移到 `scripts/build-status.py`，输出元数据归入 `artifacts/`。
- 旧的构建日志、截图、临时补丁和下载文件归入 `99-temp/motion-work` 或 `90-archive/`，不复制第二份。
- `/opt/theos`、`/var/jb`、真实设备文件未修改。
- 当前工作区仍有一次已有的 `src/ios/Views/Chat/AIChatView.swift` 未提交修改；迁移没有覆盖或回退它，提交前需单独确认其归属。
