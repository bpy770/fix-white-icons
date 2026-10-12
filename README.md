# 白色图标修复工具 / White Icon Fix

## English summary

A small Windows 10/11 tool that repairs **blank (white) desktop icons** caused by a
**Low mandatory integrity label** on the Desktop directory. Windows Mandatory
Integrity Control gives the desktop a Low label (`S-1-16-4096`) with the
No-Write-Up policy; every file inside then inherits that label, so the shell treats
the shortcuts as untrusted and refuses to resolve the target executable's icon.
This tool reads the real integrity label ACE through the Windows security APIs
(not by parsing localized `icacls` output) and restores the Medium label on the
directory, then restarts Explorer so the icons are repainted.

It does **not** delete the icon cache or thumbnail cache. Cache clearing is
irrelevant to this failure mode, which is why it does not help - see
[differences from cache-clearing tools](#与清缓存类工具的区别).

* `fix-white-icons.bat` - one-click repair (double-click it).
* `Fix-WhiteIcons.ps1` - the precise engine, with `-Path`, `-CheckOnly`,
  `-NoRestart`, `-Log`, `-Quiet` and `-StatusOnly`.

No file is ever deleted, and no permission entry other than the mandatory
integrity label is modified.

---

## 这是什么问题

桌面上的快捷方式（`.lnk`）全部或大部分变成了**白色空白图标**，双击却仍能正常打开程序，启动时还可能弹出「未知发布者」提示。

这不是图标缓存损坏，也不是快捷方式文件本身出了问题，而是**桌面目录被打上了「低完整性」标签**。

## 原理说明

Windows 的**强制完整性控制**（Mandatory Integrity Control, MIC）会为每个对象附加一个完整性级别：

| 级别 | RID | 说明 |
| --- | --- | --- |
| Untrusted | 0 | 不可信 |
| Low | 4096 | 低 |
| Medium | 8192 | 普通用户进程的默认级别 |
| High | 12288 | 高（管理员提权后） |
| System | 16384 | 系统 |

在 NTFS 目录上，这个级别表现为一条**强制标签 ACE**。用 `icacls` 查看时显示为：

```
Mandatory Label\Low Mandatory Level:(OI)(CI)(NW)
```

其中 `NW` 表示 **No-Write-Up**：低完整性进程不能向更高完整性的对象写入。

问题出在**标签会被子项继承**。一旦桌面目录本身被打上 Low 标签，目录里的**所有文件**（包括你原来那些完好的 `.lnk` 快捷方式）都会继承 Low 标签：

```
   桌面目录 %USERPROFILE%\Desktop
   Mandatory Label\Low Mandatory Level:(OI)(CI)(NW)
                    │
                    │  (OI)(CI) = 对象继承 + 容器继承
                    ▼
   ├── Chrome.lnk      ← 继承 Low
   ├── QQ.lnk          ← 继承 Low
   └── 我的文档.lnk     ← 继承 Low
                    │
                    ▼
   Windows Shell 把「低完整性来源」的快捷方式视为不可信
                    │
                    ▼
   不解析目标 exe 的图标资源，只回退到通用白纸图标
   （SHGetFileInfo(SHGFI_SYSICONINDEX) 返回 0，正常应为几十的索引）
                    │
                    ▼
   桌面显示一片白色图标；启动时还可能提示「未知发布者」
```

**为什么改父目录就能修好？** 因为子项上的 Low 标签是**继承**来的，而不是文件自己的。把桌面目录的标签改回 Medium 后，继承关系随之消失，快捷方式重新变回 Medium，Shell 恢复解析目标 exe 的图标。实测中 `iIcon` 从 `0` 恢复到 `50+`。

**为什么改完还要重启资源管理器？** 桌面图标是 Explorer 用系统图像列表画出来的位图，不是每次重绘都去重新读取 ACL。ACL 变化不会触发 Explorer 自动重画，所以需要重启 `explorer.exe` 让它重新解析图标。

## 适用症状自查

在命令提示符里执行（或直接看本工具第 1 步的输出）：

```cmd
icacls "%USERPROFILE%\Desktop"
```

| 输出里出现 | 含义 | 本工具是否适用 |
| --- | --- | --- |
| `Mandatory Label\Low Mandatory Level:(NW)` | 桌面被打成低完整性 | ✅ 适用，这就是本工具修的问题 |
| `S-1-16-4096` | 同上（SID 形式，不受系统语言影响） | ✅ 适用 |
| `低强制级别` | 同上（中文系统显示名） | ✅ 适用 |
| `Mandatory Label\Medium Mandatory Level` | 标签正常 | ❌ 不适用，图标发白另有原因 |
| 完全没有 `Mandatory Label` 行 | 没有强制标签 | ❌ 不适用 |
| 标签正常，但仍有个别白图标 | 单个快捷方式的目标 exe 被删除或移动 | ❌ 请检查该快捷方式属性里的目标路径 |

其它可能导致白图标、但**不是**本工具适用范围的原因：图标缓存本身损坏、目标程序被卸载或移动、`.lnk` 文件损坏、显卡驱动或缩放设置异常。这些情况请用系统「重建图标缓存」一类办法处理。

## 用法

### 方式一：双击运行（推荐给普通用户）

直接双击 `fix-white-icons.bat`。它会

1. 打印桌面目录当前的完整性标签；
2. 交给 `Fix-WhiteIcons.ps1` 精确判断，必要时把标签改回 Medium；
3. 重启 `explorer.exe` 重画桌面图标（任务栏会闪一下，约 10 秒）。

> ⚠️ **请把 `.bat` 和 `Fix-WhiteIcons.ps1` 放在同一个目录里运行。** `.bat` 会在自己所在目录查找 PowerShell 脚本，日志也写在该目录。

### 方式二：命令行

```cmd
fix-white-icons.bat                 修复，然后重启资源管理器
fix-white-icons.bat -CheckOnly      只检测、只报告，不修改任何东西
fix-white-icons.bat -NoRestart      修复，但不重启资源管理器
fix-white-icons.bat -NoPause       运行结束立即返回，不等按键（供自动化调用）
```

### 方式三：直接用 PowerShell 脚本（参数最全）

```powershell
# 只检测桌面标签，不修改任何东西，也绝不重启 explorer
.\Fix-WhiteIcons.ps1 -CheckOnly

# 检测并按需修复，然后重启 explorer
.\Fix-WhiteIcons.ps1

# 修复任意目录，且不重启 explorer
.\Fix-WhiteIcons.ps1 -Path 'D:\SomeFolder' -NoRestart -Log 'C:\Temp\fix.log'
```

| 参数 | 说明 |
| --- | --- |
| `-Path <目录>` | 要检查/修复的目录，默认为当前用户的桌面目录（由系统解析，桌面被移动到别处也正确） |
| `-CheckOnly` | 只报告当前标签，不做任何修改，也不重启 Explorer |
| `-NoRestart` | 修复标签但不重启 Explorer |
| `-Log <文件>` | 追加写入的日志文件，默认是脚本同目录的 `fix-log.txt` |
| `-Quiet` | 不打印人类可读报告，只输出结构化对象 |
| `-StatusOnly` | 只打印一行中文状态（供 `.bat` 调用） |
| `-AllowIcaclsFallback` | 允许在 API 失败时退回调用 `icacls`（默认关闭） |

### 退出码

| 退出码 | 含义 |
| --- | --- |
| `0` | 标签本来就是正常的（Medium 或更高），未做修改 |
| `0` | 发现 Low 标签并已成功修复（用 `-NoRestart` 时不重启 Explorer） |
| `1` | 失败：路径不存在、不是目录，或标签读写失败 |
| `2` | 仅 `-CheckOnly` 下：发现 Low 标签，需要修复 |

### 结构化输出

`Fix-WhiteIcons.ps1` 在管道里输出一个对象，便于脚本化处理：

```powershell
$r = .\Fix-WhiteIcons.ps1 -CheckOnly -Quiet
$r.CurrentLevel      # Medium
$r.CurrentRid        # 8192
$r.CurrentSddl       # S:(ML;;NW;;;S-1-16-8192)
$r.IsLowLabel        # False
$r.RepairSucceeded   # False
$r.ExitCode          # 0
```

## 与清缓存类工具的区别

GitHub 上解决白图标问题的工具，绝大多数是**清图标缓存派**：删除 `IconCache.db`、`iconcache_*.db`、`thumbcache_*.db`，然后重启 Explorer。

**在本问题的成因下，清缓存完全无效。** 原因很直接：

* 图标缓存里存的是「图标位图」，而这里坏掉的是**图标解析这一步**。Shell 因为快捷方式处于低完整性而**根本不去解析目标 exe 的图标资源**，返回的是索引 `0`（通用白纸图标）。缓存里被写进去的就是这张白纸，删掉缓存后**重新生成的仍然是白纸**——因为成因没有被消除。
* 本工具修的是**成因**（目录的完整性标签），标签改回 Medium 后，Shell 重新能够解析目标 exe 的图标，索引从 `0` 恢复到 `50+`。
* 实测中，清空 iconcache/thumbcache 之后白图标**依旧**；改回标签后图标**立即**恢复正常。

因此本工具与本仓库的定位是：**先纠正完整性标签，再重启 Explorer 触发重画**，全程不删除任何缓存文件、不删除任何文件。

## 为什么不需要管理员权限

本工具读写的是**完整性标签**，而不是完整的 SACL。

Windows 安全 API 用不同的访问权区分这两者：

* `SACL_SECURITY_INFORMATION`（`0x8`）请求整个系统访问控制列表，读取或写入它需要 **`SeSecurityPrivilege`** 特权，而普通用户进程的令牌里没有这个特权——本工具开发过程中实测确认：未提权的进程调用它会直接返回 `1314 (ERROR_PRIVILEGE_NOT_HELD)`。
* `LABEL_SECURITY_INFORMATION`（`0x10`）**只**选择完整性标签这一条 ACE，Windows 明确把它排除在上述特权要求之外，对象的所有者即可读写。

本工具两个方向（读和写）都使用 `LABEL_SECURITY_INFORMATION`，所以对**你自己的桌面目录**不需要管理员权限。这也带来一个额外好处：写入时影响的**只有**完整性标签，DACL（普通文件权限）、所有者、以及任何审核 ACE 都不会被触碰。

只有当目标目录属于**其他账户**或受保护的系统位置时，才需要以管理员身份运行。

## FAQ

**Q：为什么不用管理员权限？**
见上一节。读写完整性标签走的是 `LABEL_SECURITY_INFORMATION`，它的设计就不要求 `SeSecurityPrivilege`；对象所有者即可操作。只有目标目录不属于你时才需要提权。

**Q：为什么不删图标缓存？**
因为成因不是缓存。Shell 因为低完整性而拒绝解析目标 exe 的图标，缓存里存的就是那张白纸；删掉后重建的还是白纸。删缓存属于治标不治本，而且会顺带丢掉你自定义过的图标缓存。详见[与清缓存类工具的区别](#与清缓存类工具的区别)。

**Q：为什么改完标签还要重启 explorer？**
桌面图标是 Explorer 从系统图像列表里画出来的位图，ACL 变化不会让它自动重画。重启 `explorer.exe` 才会让它重新解析并绘制。重启期间任务栏会消失几秒，工具里有探活重试和任务栏丢失的兜底提示。

**Q：会不会影响别的权限（ACE）？**
不会。写入用的是 `LABEL_SECURITY_INFORMATION`，只替换完整性标签这一条 ACE。DACL、所有者、组、以及潜在的审核 ACE 都保持原样；工具也不创建、移动或删除任何文件。想自己核对，可以在运行前后各执行一次 `icacls "%USERPROFILE%\Desktop"` 对比——除了 `Mandatory Label` 那一行，其它行应当完全一致。

**Q：会不会把标签设太高，导致程序无法写桌面？**
不会。工具把标签设为 **Medium**，这正是普通用户目录应有的级别，也是桌面在正常系统上的默认级别。它不会设为 High 或 System。

**Q：`-CheckOnly` 安全吗？**
安全。它只读取标签，不写入任何东西，也绝不重启 Explorer。本仓库发布前的全部测试都是在 `-CheckOnly` 下完成的。

**Q：日志写在哪里？**
`.bat` 与 `.ps1` 默认都写在**脚本所在目录**的 `fix-log.txt`（`.bat` 用 `%~dp0`，`.ps1` 用 `$PSScriptRoot`）。日志是 UTF-8，追加写入，不会覆盖旧记录。

**Q：修复后个别图标还是白的？**
在桌面按 `F5` 刷新。若仍有个别图标是白的，多半是该快捷方式的目标程序已被卸载或移动，那属于另一类问题。

**Q：为什么 `.bat` 里全是英文提示？**
这是**刻意**的。`cmd.exe` 按字节解析批处理文件，并且会在代码页改变时改变解码方式；一个既要 `chcp 65001`、又含有中文的 UTF-8 批处理文件会被 `cmd.exe` 解析错误（命令会被从中间截断）。所以 `.bat` 保持纯 ASCII、不切换代码页，所有中文提示都由 UTF-8 的 `Fix-WhiteIcons.ps1` 打印——它自己设置输出编码，中文能正常显示。详见 `.bat` 顶部的编码说明。

**Q：这个工具会重启我的 explorer，会不会丢失未保存的工作？**
重启 `explorer.exe` 只影响桌面、任务栏和文件资源管理器窗口，不会关闭你正在编辑的文档或其它程序。不过为稳妥起见，建议先保存手上的工作。若不想重启，用 `-NoRestart`，之后自己手工重启或注销一次即可。

## 文件说明

| 文件 | 用途 |
| --- | --- |
| `fix-white-icons.bat` | 一键入口，纯 ASCII，中文状态由 PowerShell 脚本打印 |
| `Fix-WhiteIcons.ps1` | 核心逻辑：用 Windows 安全 API 读写完整性标签 |
| `fix-log.txt` | 运行后生成的操作日志（不纳入版本控制） |
| `docs/screenshots/` | 预留目录，用于放置修复前后的对比截图 |

### 关于文件编码

所有文件均为 **UTF-8**。两点值得说明：

* `Fix-WhiteIcons.ps1` 带有 **UTF-8 BOM**，这是**必要**的：Windows PowerShell 5.1 在读取**没有 BOM** 的 `.ps1` 时会按系统 ANSI 代码页（中文系统为 GBK）解码，脚本里的中文字符串会直接变成乱码并导致语法错误。加上 BOM 后 5.1 与 7.x 都能正确读取。**修改该文件时请保留 BOM。**
* `fix-white-icons.bat` **刻意保持纯 ASCII 且不带 BOM**：BOM 会让 `cmd.exe` 在首行报错，而含中文的 UTF-8 批处理会被 `cmd.exe` 错误解析（见下方 FAQ）。

## 免责声明

* 本工具按「现状」提供，不附带任何明示或暗示的担保。
* 它会修改**桌面目录的完整性标签**这一项系统设置。虽然实现上只触碰这一条 ACE、不删除任何文件，但你仍应自行评估风险，并在重要环境上先行备份。
* 作者不对因使用本工具而产生的任何数据丢失、系统异常或其它损害承担责任。
* 本工具只针对「桌面目录被打上 Low 完整性标签」这一种成因。如果你的白图标问题另有原因（缓存损坏、目标程序缺失等），本工具不会生效，也不会造成损害。

## 开发与反馈

- 遇到误判/漏判，或想补充其他病因的检测（图标缓存损坏、目标程序缺失等），欢迎提 [Issue](https://github.com/bpy770/fix-white-icons/issues) 或 Pull Request。
- 改动后建议先跑一次**干跑自检**（只读、不修改任何东西）：

```powershell
pwsh -File .\Fix-WhiteIcons.ps1 -CheckOnly -StatusOnly
```

- 提交信息建议遵循 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/)。

## 发布新版本（维护者）

```bash
git tag -a v1.0.1 -m "v1.0.1"
git push --tags
```

随后在 GitHub 的 Releases 页面写说明，并把 `fix-white-icons.bat` 与 `Fix-WhiteIcons.ps1` 作为附件上传，方便他人直接下载。

## 许可证

[MIT](LICENSE)
