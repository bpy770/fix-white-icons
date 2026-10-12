# 更新日志

本项目的所有重要变更都会记录在此文件中。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [1.0.1] - 2026-10-12

### 修复

- `fix-white-icons.bat`：**双击后窗口不再瞬间关闭**。原实现靠 `%CMDCMDLINE%` 猜测调用方式，但 Explorer 同样用 `cmd /c` 启动批处理，导致双击时也跳过了等待，用户看不到任何结果。现在改为**默认等待按键**，自动化场景用新增的 `-NoPause` 显式跳过。

- `fix-white-icons.bat`：修复成功时不再误报「未做任何修改」。PowerShell 脚本修复成功同样返回 0，旧措辞会把修复当成「本来就正常」；现统一表述为「标签现在是正常的」。

### 新增

- `-NoPause` / `/NoPause` 开关：供脚本、计划任务、CI 等自动化调用，运行结束立即返回。

## [1.0.0] - 2026-10-12

首个公开版本。

### 新增

- `Fix-WhiteIcons.ps1`：核心修复脚本。通过 Windows 安全 API
  （`GetNamedSecurityInfo` / `SetNamedSecurityInfo`，P/Invoke）读写目录的强制完整性标签，
  不依赖解析本地化的 `icacls` 输出。
  - 以 `LABEL_SECURITY_INFORMATION` 访问标签，因此**普通用户权限即可修复自己的桌面**，
    且写入时只影响完整性标签这一条 ACE，DACL、所有者与审核 ACE 均保持不变。
  - 支持参数 `-Path`、`-CheckOnly`、`-NoRestart`、`-Log`、`-Quiet`、`-StatusOnly`、
    `-AllowIcaclsFallback`。
  - 退出码区分「本来正常 / 已修复（0）」「失败（1）」「需修复（2）」。
  - 在管道中输出结构化结果对象（当前标签、是否修改、修改后标签等）。
  - 可选地重启 `explorer.exe` 以触发桌面图标重画，含探活重试与任务栏丢失的兜底提示。
- `fix-white-icons.bat`：一键入口。调用上述 PowerShell 脚本完成检测与修复；
  脚本缺失时退回直接使用 `icacls`，并同样复核修改结果。
  文件保持纯 ASCII 且不切换控制台代码页，以免 `cmd.exe` 的按字节解析导致批处理被截断；
  面向用户的中文状态行由 UTF-8 的 PowerShell 脚本打印。
  支持 `-CheckOnly`、`-NoRestart`、`-AllowIcaclsFallback`。
- `README.md`：项目说明、原理图解（标签继承 → Shell 视作不可信 → 图标退化 → `iIcon=0`）、
  与清缓存类工具的差异、症状自查表、FAQ 与免责声明。
- `LICENSE`：MIT 许可证。
- `docs/screenshots/`：预留目录，用于放置修复前后的对比截图。

### 说明

- 本版本**不删除任何文件**：不清图标缓存、不清缩略图缓存、不删除快捷方式。
- 已实测确认：清空 iconcache/thumbcache 对本案无效；把目录标签改回 Medium 后，
  图标索引从 `0` 恢复正常。
