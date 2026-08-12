# 桌面客户端每日签到

纯 PowerShell + Windows UI Automation/本地图像模板。日常运行不调用模型、不使用 Computer Use，消耗 0 token；代码、配置、校准结果和日志都留在本目录。

> 非官方工具，与 TRAE 或腾讯无隶属关系。自动化可能受客户端更新或活动规则变化影响，请遵守对应服务条款。

## 首次使用

1. 关闭 TRAE Work；安装 WorkBuddy 后也先关闭它。
2. 手动登录客户端，并让尚未领取的签到卡片可见。
3. 双击 `calibrate.cmd`；客户端被置前后，把鼠标停在“签到/领取”按钮正中心，保持 8 秒。校准只保存按钮模板，**不会点击领取**。
4. 双击 `run.cmd` 做一次真实签到测试。
5. 成功后双击 `setup.cmd`，注册每天 14:00、之后每小时至 22:00 的补跑任务。

复制整个文件夹到另一台电脑后，重新执行上述步骤。Windows 计划任务只能保存本机绝对路径，因此移动文件夹后也要重新运行 `setup.cmd`。

`runtime/` 含每台电脑的按钮模板、日志、截图和签到状态，已被 `.gitignore` 排除，不应提交到公开仓库。

## 安全行为

- 只点击唯一匹配且支持 UI Automation Invoke 的控件，不使用固定坐标。
- 未完成校准时不会启动客户端、不会点击，也不能安装计划任务。
- 遇到登录、验证码、多个候选或陌生界面时停止，不猜测。
- 点击后必须看到“今日已领/签到成功”等状态；验证失败时不会重复点击。
- 客户端已经运行但不可访问时不会自动重启，等待下一次补跑。
- 成功后关闭对应客户端。22:00 仍失败才通知，并写入 `runtime/本机-用户/checkin.log`。

## 命令

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\checkin.ps1 -Mode SelfTest
powershell -NoProfile -ExecutionPolicy Bypass -File .\checkin.ps1 -Mode Diagnose
powershell -NoProfile -ExecutionPolicy Bypass -File .\checkin.ps1 -Mode Uninstall
```

`Uninstall` 只删除计划任务，不删除项目文件、校准结果或日志。
