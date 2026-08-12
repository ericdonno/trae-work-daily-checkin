# CheckinBox

> 为 TRAE Work 自动领取每日积分的 Windows 小工具。一次校准，之后每天自动签到；不调用 AI，不消耗 Token，也不保存账号密码。

![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE?logo=powershell)
![Runtime](https://img.shields.io/badge/AI%20Token-0-success)

CheckinBox 面向已经在桌面客户端登录的用户。它在本机识别签到按钮、只点击一次、确认页面发生成功变化，然后关闭客户端。整个过程由 PowerShell 和 Windows 计划任务完成，不需要 Codex、Computer Use、Python、Node.js 或浏览器自动化。

## 当前支持情况

| 客户端 | 状态 | 说明 |
|---|---|---|
| TRAE Work CN | 已实机验证 | 已验证校准、领取、成功检测、关闭客户端和防重复执行 |
| 腾讯 WorkBuddy | 实验性适配 | 已预置客户端发现与校准流程，尚未完成 Windows 实机验收 |

这是一个可用的早期版本。客户端更新可能改变签到卡片的位置或样式；此时工具会停止点击，并要求重新校准。

## 为什么用它

- **0 Token**：日常运行不连接任何大模型。
- **不保存密码**：直接复用客户端已有登录状态，不处理密码、Cookie、验证码或扫码登录。
- **先核对再点击**：当前按钮必须与本机保存的模板匹配，才会点击一次。
- **防止重复领取**：成功后记录当天状态，再次运行会直接跳过。
- **自动补跑**：每天 14:00 执行；未成功时每小时重试，最晚到 22:00。
- **整个文件夹可搬走**：代码、配置和本机数据都在项目目录内，不把文件散落到用户目录。

## 3 分钟开始使用

### 1. 下载并登录客户端

下载仓库 ZIP 并解压，或使用 Git：

```powershell
git clone https://github.com/ericdonno/trae-work-daily-checkin.git
cd trae-work-daily-checkin
```

打开 TRAE Work，手动完成登录，并让尚未领取的每日签到卡片显示在窗口中。

### 2. 校准签到按钮

双击 `calibrate.cmd`。客户端被置于前台后，将鼠标停在“签到”或“领取”按钮的正中心，保持 8 秒。

校准只截取按钮附近的一小块图像作为本机模板，**不会点击签到**。模板保存在 `runtime/`，不会提交到 Git。

### 3. 测试并启用自动签到

依次双击：

1. `run.cmd`：立即执行一次真实签到；
2. `status.cmd`：确认今日状态；
3. `setup.cmd`：注册每日自动任务。

完成。之后 CheckinBox 会在每天 14:00 自动运行，失败时每小时补跑至 22:00。

> Windows 必须处于用户已登录、桌面未锁定的交互会话。工具不会自动解锁电脑，也不会代替用户处理登录或验证码。

## 它如何避免乱点

每次运行都会执行同一套保护流程：

1. 找到目标客户端及其真实窗口；
2. 恢复窗口并读取签到按钮区域；
3. 将当前画面与校准模板比较；
4. 只有差异低于安全阈值时才点击一次；
5. 点击后检查按钮区域是否发生明显变化；
6. 验证成功后记录当天状态并关闭客户端；
7. 页面不匹配、窗口尺寸变化或验证失败时停止，不进行第二次点击。

客户端若暴露 Windows UI Automation 控件，脚本也支持按控件名称操作；当前 TRAE Work CN 实测使用本地图像模板路径。

## 安全与隐私

- 所有识别和比较均在本机完成，没有截图上传功能。
- `runtime/` 可能包含本机名、日志、按钮模板和诊断截图，已被 `.gitignore` 排除。
- 未校准的已安装客户端不会被启动或点击，也不能安装计划任务。
- 登录页、验证码、陌生页面和不匹配按钮不会被当作签到按钮处理。
- 点击后若无法验证成功，脚本不会盲目重试点击。

公开分享或提交 Issue 前，请先检查并避免上传 `runtime/` 中的内容。

## 文件说明

| 文件 | 用途 |
|---|---|
| `checkin.ps1` | 校准、签到、验证、状态和计划任务的核心脚本 |
| `targets.json` | 客户端进程名、安装路径候选和安全匹配规则 |
| `calibrate.cmd` | 首次校准或客户端界面更新后重新校准 |
| `run.cmd` | 立即运行一次签到 |
| `setup.cmd` | 安装或更新每日计划任务 |
| `status.cmd` | 查看安装、校准和今日签到状态 |
| `runtime/` | 每台电脑的本地模板、状态和日志；不会进入 Git |

## 常见操作

移动或复制项目文件夹后，重新双击 `setup.cmd`，让计划任务指向新路径。

客户端更新、按钮样式变化或窗口尺寸变化后，重新双击 `calibrate.cmd`。

卸载自动任务但保留项目文件：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\checkin.ps1 -Mode Uninstall
```

运行脚本自检：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\checkin.ps1 -Mode SelfTest
```

运行日志位于 `runtime/<电脑名-用户名>/checkin.log`。

## 致谢

CheckinBox 在“复用现有登录状态、只点击明确匹配的领取控件、点击后验证结果、遇到陌生界面即停止”等安全原则上，参考了 Zoey Liew 的 [workbuddy-daily-checkin](https://github.com/zoeyliew192/workbuddy-daily-checkin)。该项目是面向 macOS 和 Computer Use 的 Agent Skill，采用 MIT 许可证。

CheckinBox 没有复制该项目的源码，也不是它的 Windows 移植版。本项目的 PowerShell 实现、本地图像校准、计划任务与失败补跑流程均针对 Windows 和 TRAE Work 独立实现。

## 项目边界

CheckinBox 不负责注册账号、自动登录、保存凭据、绕过验证码、解锁 Windows 或规避平台限制。同一平台多账号尚未支持。

本项目是非官方工具，与 TRAE 或腾讯无隶属关系。请遵守对应服务条款；积分数额、活动周期和领取规则以客户端实际展示为准。
