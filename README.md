<div align="center">

<img src="docs/currentflow-banner.svg" alt="CurrentFlow — native power monitoring for Mac" width="100%" />

# 电流脉动 · CurrentFlow

**看见功耗，也看懂流向。**

[**下载最新版 ↗**](https://github.com/kyox215/CurrentFlow/releases/latest) · [English](README.en.md) · [Changelog](CHANGELOG.md) · [MIT](LICENSE)

`macOS 13+` · `Apple Silicon` · `SwiftUI` · `Local only`

</div>

原生 SwiftUI 菜单栏应用，白色主题、420pt 宽的紧凑面板。菜单栏直接显示整机实时功耗，例如 `23.4W`；展开后，左侧电源、右上主板、右下电池通过带方向的流动动画连接。功率 W 用大字，电流 A 和电压 V 用小字，读数分清主次。

---

**最新版本 [v0.10.0](https://github.com/kyox215/CurrentFlow/releases/tag/v0.10.0)**：新增每秒本地记录、最近七天功耗历史与紧凑图形浏览。历史窗口默认 720 × 600，曲线、摘要、游标与时间控制集中呈现；较小窗口将概览收进弹出入口。[官网下载与介绍](https://www.chinatech.in/currentflow) · [本次中文更新介绍稿](docs/updates/0.10.0.zh-CN.txt)。

![紧凑功耗历史窗口，中文合成演示数据](docs/history-compact.jpg)

历史截图使用合成演示数据，包含可见缺口，不代表用户实际功耗。

![CurrentFlow 三节点面板，图中为演示数据](docs/preview.png)

> 预览图和动图使用明确标注的演示数据。安装后的 App 默认读取真实硬件。


<details>
<summary>查看详情页（演示数据）</summary>

![Wi-Fi 参考功耗、风扇转速和应用 CPU 估算功耗排行，演示数据](docs/details.png)

</details>

## 主要功能

- **秒级历史**：运行时独立于面板与显示刷新间隔，每秒最多保存一条整机功耗、可用分项和供电状态；本地 SQLite 滚动保留最近 7×24 小时，重启可读。详情中的“功耗历史”支持 5 分钟、15 分钟、1 小时、24 小时、7 天图表与秒级定位。
- **实时功耗**：菜单栏以小图标和紧凑 W 数显示整机功耗，宽度随文字调整；面板同时展示电源输入与电池充放电功率。
- **分项功耗**：CPU、GPU、屏幕背光集中在一行，跟随刷新间隔更新；缺失或过期时显示 `—`。
- **供电流向动画**：蓝色表示外接电源供电，绿色表示充入电池，橙色表示电池向电脑供电；支持共同供电状态。
- **电流和电压**：A/V 作为辅助信息，缺失读数显示 `—`，估算值有标注。
- **更多耗电**：详情显示 Wi-Fi 参考 W 数、风扇实际 RPM 和应用/进程 CPU 估算功耗前三名；排行只在详情可见时每 2 秒扫描。
- **可调刷新**：预设 0.5、1、2、5、10、30、60 秒，也可自定义 0.5–300 秒，重启后保留。
- **开机自启**：接入 macOS 登录项管理，可在 App 中开关，也可打开系统登录项设置。
- **静默启动**：默认后续启动只驻留菜单栏；可单独开启“启动时展开面板”。
- **按需展开**：点击“详情”自动增高，查看近一分钟整机功耗 W 趋势和电源功率上限；点击“收起”恢复紧凑面板。
- **紧凑与避让**：窗口避开刘海和屏幕边缘，屏幕空间不足时可在面板内滚动。
- **本地运行**：无账号、网络请求、广告或遥测；不需要 root 或额外驱动。

<details>
<summary>查看充电与放电动效</summary>

充电：

![充电动效，演示数据](docs/charging.gif)

电池供电：

![放电动效，演示数据](docs/discharging.gif)

</details>

## 下载与安装

发布包适用于 **Apple Silicon（M 系列芯片）和 macOS 13+**。

1. 在 [chinatech.in](https://www.chinatech.in/currentflow) 或 [Releases](https://github.com/kyox215/CurrentFlow/releases/latest) 下载 `.dmg` 或 `.zip`。
2. 将 `电流脉动.app` 放入“应用程序”，从那里打开。
3. 点击屏幕顶部菜单栏的电脑图标或 W 数，查看供电面板。

发布包使用 **本地 ad-hoc 签名，未做 Apple Developer ID 公证**，macOS 可能提示开发者尚未验证。可检查源码后自行构建。完整校验和随 Release 提供。

### 开机自启与静默启动

点击面板右下角齿轮：

- 勾选 **开机自启**，应用会在当前用户登录 macOS 后启动；默认关闭。
- 保持 **启动时展开面板** 未勾选，即可只显示菜单栏。
- 如果显示“等待系统允许”，点击系统设置入口，在 macOS 登录项中允许该 App。

请先安装到“应用程序”，再开启自启。首次打开会展开一次面板，便于找到应用。开关依据系统实际状态显示；在系统设置中关闭后，App 不会自行重新启用。

## 读数如何理解

| 位置 | W 数含义 | 辅助信息 |
| --- | --- | --- |
| 电源 | Mac 输入端的直流功率 | 输入电流 A、电压 V |
| 主板节点 | **整台电脑的功耗**，不是主板单独的电源轨 | 估算值会标注 |
| 电池 | 电池端充入或放出的功率大小 | 电流 A、电压 V、电量与方向 |
| CPU / GPU | 系统能耗计数器换算的采样区间平均功率 | `≈` 表示系统模型估算 |
| 屏幕背光 | 内置屏背光传感器功率 | 不含完整屏幕模块或外接显示器 |

CPU/GPU 不是利用率百分比，也不是整机剩余功耗分摊。分项未覆盖所有硬件，采样时间也不完全相同，因此三项之和不等于整机功耗。

这些不是墙上插座侧的交流读数。电源与电池处于不同电压域，安培数不能直接相减。电池待机时保持 `0W` 或 `0A` 是正常状态；稳定的真实读数不会被人为加入变化。

应用优先只读访问 AppleSMC 的 `B0AC`、`B0AV`、`ID0R`、`VD0R`、`PDTR`、`PSTR`、`PBwo`、`PDBR`，详情可见时再读取 `wiPm`、`F0Ac`、`F1Ac`；电源读数缺失时回退到 IOKit 电源属性。SMC 只实现键元数据查询和读取，**不写传感器、不控制风扇、不修改充电策略**。硬件字段不属于 Apple 稳定的公开接口契约，不同机型或系统可能缺失；缓存来源和采样时间会显示在面板内。

CPU/GPU 只读订阅 IOReport 聚合能耗报告，以能量差值除以实际采样时长得到 W。macOS 27.0/27.0.1 使用已知 CLPC 报告目录，其他系统或驱动不猜测报告 ID；不可用时保留空值。本机 M5 Pro 已验证，其他机型支持取决于系统实际暴露的计数器。来源见 [第三方说明](THIRD_PARTY_NOTICES.txt)。

详情中的 Wi-Fi 是传感器参考值。本机通过 Wi-Fi 进行约 4 MB 的传输时，`wiPm` 仍保持约 `0.033 W`，因此不承诺它反映准确的实时无线功耗。风扇只显示转速。应用排行使用 `rusage_info_v6.ri_energy_nj` 的增量计算 CPU 侧平均估算功率，合并同一应用的辅助进程，不把 CPU 能耗等同于整个 App 总耗电。接口不可用时显示缺失。

不同传感器可能在不同时刻更新，因此瞬间的输入功率、电池功率和整机功耗可能不能精确相加。显示刷新间隔不保证硬件以相同频率更新；历史采集至少每秒尝试一次，0.5 秒显示设置仍保持原频率，同一秒历史去重。

## 功耗历史与保存规则

展开“详情”，点击“功耗历史 · 秒级记录 / 最近 7 天”。主面板与历史窗口互斥显示，往返切换保留查询与窗口位置。历史页以平均功率、峰值、已覆盖耗电和数据覆盖紧凑摘要栏显示所选范围；大曲线有时间轴、功率单位和缺口，分项读数直接跟随游标。

- 快选 **5 分钟 / 15 分钟 / 1 小时 / 24 小时 / 7 天**；放大、缩小围绕游标，最短可看 15 秒。前移/后移移动半个时间窗口，七天概览和滑块可直接浏览旧时段。
- 鼠标悬停、点击或拖动曲线定位到秒；聚焦曲线后左右方向键逐秒移动，上下方向键缩放，也有按钮与无障碍操作。整机、CPU/GPU 估算、背光及供电来源随选中秒联动，缺失值显示 `—`。
- 检查旧时段会暂停跟随，刷新也保持原时段；点击“回到最新”才恢复跟随，显示期间约每 5 秒更新范围。关闭或最小化历史窗口会停止页面查询，后台原始采样继续。
- “定位”弹出完整日期、秒与 UTC 偏移输入，区分夏令时重复小时；“明细”按需弹出游标附近记录。细线表示区间最小/最大值，蓝线为完整区间均值，橙色区间含缺口；不跨缺口连线。长图最多 600 个区间，概览最多 280 个区间，原始秒记录保留。
- 页面支持浅深色，默认 720 × 600，最小 600 × 500。紧凑高度下使用“7 天概览”弹出入口，减少常驻内容并保留曲线。平均值按有效样本数加权；W 为功率，Wh/kWh 仅覆盖有效连续观测，存在缺口时不是整段完整耗电。读数来源和积分口径可在帮助中查看。

- 正式应用保存于 `~/Library/Application Support/CurrentFlow/history.sqlite3`，完全本地，无上传。SQLite WAL 增量写入；七天约 604,800 条，合成数据测试约 47 MB，实际大小取决于字段和 SQLite 空闲页。
- 每次采集与查询删除 `秒时间戳 ≤ 当前保留基准秒 − 604800` 的记录，最多 604,800 个不同秒；时钟后退不恢复已清除数据，未来时间记录在时钟追上前隐藏。采样每秒尽力进行，系统调度或传感器读取过慢时允许缺口，不补写。
- 应用退出或系统休眠时不记录，重新打开后只记录当下。不会用上次读数填补空档；演示数据不进入真实历史。系统不可用、无效或超过 2 秒的功耗来源保存为空值，真实 0 W 仍保留；记录同时保留传感器更新时间、缓存/直接采样来源和估算标记。
- **W 是功率，Wh 是耗电量**。累计耗电只对同一次运行中相邻且有效的秒记录，按实际观测时间做梯形积分；跳秒、无效值、休眠、重启、调时或演示切换均中断积分。显示积分有效秒数；存在缺口时，累计值仅代表已覆盖部分。1 kWh = 1000 Wh。
- **秒级是时间分辨率，不是传感器精度**。硬件可能复用或延迟更新读数；CPU/GPU 仍是系统模型的区间平均估算，屏幕只含背光，不能将分项相加视为整机总量。
- 为后台秒级采集避免 App Nap 节流，应用保持采样活动，但允许系统正常休眠。即使显示选择 60 或 300 秒，历史仍每秒尝试读取，因此比旧版慢刷新模式有额外采样开销。存储异常会在详情和历史窗口显示，实时面板仍可继续工作。正常退出等待当前写入完成；强制结束或断电可能丢失最后正在写入的记录。

本地评审候选可用 `bash scripts/build-history-candidate.sh` 构建，输出 `/private/tmp/currentflow-history-candidate.XXXXXXXX/CurrentFlow History.app`（脚本会打印实际路径；也可传入普通本地输出目录，避免 File Provider 自动附加扩展属性破坏签名）。该候选使用独立 bundle ID、偏好和 `~/Library/Application Support/CurrentFlow-History-Candidate/` 历史目录，可与安装版并存。可通过 `--history-directory /绝对路径` 改用隔离历史目录，`--history-window` 打开历史窗口；不修改正式安装版。

## 从源码构建

需要 macOS、Xcode / Command Line Tools 和 Swift 5.9+，无第三方依赖。

```sh
git clone https://github.com/kyox215/CurrentFlow.git
cd CurrentFlow
bash scripts/build.sh
```

输出为 `build/电流脉动.app`，ZIP 与 DMG 安装包位于 `artifacts/`。

构建脚本按本机架构编译，在临时目录生成图标、签名与安装包。公开预编译版本仅为 Apple Silicon；Intel 机型和其他硬件尚未全面验证。

### 检查与预览

```sh
bash scripts/test.sh
# 需图形会话：隔离验证状态栏、历史窗口、最小化、关闭和快速切换
bash scripts/test-windows.sh
# 历史图形导航、防抖及过期结果检查
bash scripts/test-history-ui.sh
build/电流脉动.app/Contents/MacOS/CurrentFlow --snapshot
build/电流脉动.app/Contents/MacOS/CurrentFlow --process-power
build/电流脉动.app/Contents/MacOS/CurrentFlow --startup-status
build/电流脉动.app/Contents/MacOS/CurrentFlow --render-preview artifacts
```

`scripts/test.sh` 覆盖数据解析、传感器解码、缓存回退、功率推算、窗口安全区域、刷新、启动设置及秒级历史、持久化、七天边界、时钟/夏令时、能耗积分和存储失败。图形历史和窗口交互分别使用上方专项脚本；检查数量与结果以本次实际运行日志为准。物理重启、七天实机耐久和跨硬件支持仍需对应环境验证。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `Sources/` | SwiftUI 界面、AppKit 菜单栏与窗口、硬件读取和登录项设置 |
| `Tests/` | 解析、布局、采样、刷新与启动行为检查 |
| `scripts/` | 构建、图标生成与测试脚本 |
| `Resources/` | 随 App 打包的使用说明 |
| `docs/` | 使用演示数据生成的预览、动图及更新介绍稿 |

欢迎提交 [Issue](https://github.com/kyox215/CurrentFlow/issues) 或 Pull Request，见 [贡献指南](CONTRIBUTING.md)。报告硬件兼容性时请提供 macOS 版本、芯片型号和数据来源标注，不要上传电池序列号或完整 IORegistry 导出。

参考：[Apple 电源信息 API](https://developer.apple.com/documentation/iokit/1523839-iopscopypowersourcesinfo)、[Apple 登录项管理](https://developer.apple.com/documentation/servicemanagement/smappservice)、[Stats 传感器定义](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift)、[SMC 协议资料](https://github.com/hholtmann/smcFanControl/blob/master/smc-command/smc.h)。

## 许可证

[MIT](LICENSE) © 2026 kyox215。

图形历史页的合成数据预览可用 `bash scripts/preview-history.sh` 构建，脚本会打印隔离路径。按输出路径执行 `History UI Preview.app/Contents/MacOS/HistoryPreview --data <预览目录>/demo/history.sqlite3`；可加 `--dark`、`--small`、`--empty` 或 `--error` 检查不同状态。演示窗口明确标注合成数据，时钟固定于样本末端，不读取传感器，不写正式历史。
