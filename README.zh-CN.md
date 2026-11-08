# Realtek Audio Restart

[English](README.md) | **简体中文**

不重启电脑，一键把 Windows 音频驱动栈完整重新加载一次。

它解决的是一个极常见的 Windows 毛病：耳机插进 3.5mm 接口后毫无反应，声音还在从扬声器出来，或者系统直接说"没有音频设备"，只能重启才好。这个工具用 30 秒左右做完重启时会做的那次编解码器重新枚举，其余系统状态一概不动。

![status](https://img.shields.io/badge/platform-Windows%2010%20%2F%2011-0078D4) ![status](https://img.shields.io/badge/powershell-5.1%2B-5391FE)

## 为什么插上耳机不识别

大多数笔记本的编解码器（Realtek）挂在 Intel SST / HD Audio 控制器下面。系统靠编解码器驱动轮询"插孔在位检测"来判断耳机插入。当这条驱动链卡住时——休眠唤醒后、驱动更新后、音频引擎崩溃、设备枚举失败——这个触发就再也不会到来，Windows 于是维持旧的"扬声器"端点，无视耳机。重启会让编解码器重新枚举，轮询恢复，插孔又能被识别。

在设备管理器里"禁用/启用"设备通常不够：父级控制器仍然保持着原状态。这个工具重启的是**父级控制器**，它会连带拆掉并重建整条音频子设备链——这正是开机时发生的事。

## 快速开始

1. 下载对应语言目录：`zh/` 或 `en/`。
2. 双击 **`Start-AudioRestart.cmd`**，在 UAC 提示上点"是"（重载驱动必须管理员权限）。
3. 点 **开始重启 / Restart audio**，等 20~90 秒。期间音频会短暂中断，属正常现象。

不安装任何东西，不驻留后台服务，不改注册表。

## 文件说明

| 文件 | 作用 |
|---|---|
| `Start-AudioRestart.cmd` | 双击入口（隐藏控制台，只留图形界面） |
| `AudioRestartTool.ps1` | 图形界面：按钮、状态提示、实时日志 |
| `Restart-Audio.ps1` | 执行引擎，也可命令行直接调用 |

`zh/` 与 `en/` 是同一份代码的中英文版本，除文案外逐行一致，行为完全相同。

## 具体做了什么

| 步骤 | 动作 |
|---|---|
| 1 | 定位 Realtek 音频设备，沿设备树向上找到真正的父级控制器（Intel SST 平台为 `INTELAUDIO\DSP_CTLR_*`，传统平台为 HD Audio 总线控制器） |
| 2 | 按依赖逆序停服务：厂商服务 → `Audiosrv` → `AudioEndpointBuilder` |
| 3 | 结束用户态音频进程（`RtkAudUService64`、`RtkNGUI64`、`RtkUWP`、`audiodg`），释放设备占用 |
| 4 | 对父级控制器执行 `pnputil /restart-device`；失败则降级为 禁用 → 启用 |
| 5 | 按依赖顺序拉起服务，等待设备链重新枚举 |
| 6 | 校验：到达时间是否刷新、问题码是否为 0、服务是否全在运行、播放/录音端点是否活跃、默认端点是否可用 |
| 7 | 可选播放 0.5 秒低音量测试音，端到端验证音频链路 |

### 怎么确认"真的重载了"

`pnputil` 即使被传入空参数也会打印 "Device restarted successfully"，而设备 `Status = OK` 也不能证明重载发生过。所以本工具不看退出码，而是查三件事：

- `pnputil` 的回显里确实带上了完整 InstanceId；
- `DEVPKEY_Device_LastArrivalDate` 从旧时间跳到了当前时间；
- 端点集合处于活跃状态，且默认播放端点能正常响应。

## 命令行用法

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1 -TestTone
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1 -DryRun
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restart-Audio.ps1 -DeviceMatch VEN_10EC
```

| 参数 | 含义 |
|---|---|
| `-TestTone` | 完成后播放 0.5 秒低音量测试音 |
| `-DryRun` | 只探测设备与目标控制器，不改动系统 |
| `-DeviceMatch` | InstanceId 中用于识别厂商的片段，默认 `VEN_10EC`（Realtek）；其它声卡换对应的 `VEN_` 值 |

退出码：`0` 成功，`1` 环境/权限问题，`2` 执行或验证失败。

## 安全边界

- 只操作音频设备与音频服务，不改注册表、不改服务启动类型、不碰其它硬件。
- 若设备 25 秒内没有恢复，工具会自动尝试重新启用，并明确报错，而不是静默失败。
- 每次运行会在脚本目录生成 `audio_restart_*.log`，每一步都可事后追溯。
- 不安装、不注册计划任务、不设置开机自启。

## 常见问题

| 现象 | 处理 |
|---|---|
| 重载后插孔仍不识别 | 打开 Realtek Audio Console / 音频管理器检查插孔检测；若开了"前置面板插孔检测"相关的旧选项就关掉；仍不行则重装 Realtek 驱动包 |
| 提示"设备未能恢复" | 重启一次电脑，让驱动链干净启动 |
| 脚本被安全软件拦截 | 加白名单，或手动用 `-ExecutionPolicy Bypass` 运行 `.ps1` |
| 没找到 Realtek 设备 | 用 `-DeviceMatch` 传你的厂商 ID；或在 issue 里附上 `-DryRun` 的输出 |

## 运行要求

- Windows 10 1903 及以上 / Windows 11（需要 `pnputil /restart-device`）
- Windows PowerShell 5.1（系统自带），无需额外运行时
- 管理员权限

已在 Windows 10 22H2（10.0.19045）实测：Intel SST 控制器（`PCI\VEN_8086&DEV_06C8`，父设备 `INTELAUDIO\DSP_CTLR_DEV_06C8`）+ Realtek ALC245 编解码器（`DEV_0245`）。

## 备注

- 传统 `HDAUDIO` 编解码器通过 HD Audio 总线控制器路径同样支持。
- 图形界面按 125% 及以上 DPI 缩放适配。
- 日志文件已由 `.gitignore` 排除，可随时删除旧的。
