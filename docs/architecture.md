# dsh-app 架构

> 2026-10-23 定稿的实现约定。之后代码有扩展（插件、远程、手机操控等），细节以当前源码为准。

## 技术栈

| 层 | 选型 | 理由 |
|---|---|---|
| UI | Flutter 3.47（Dart 3.13）+ Riverpod 3 | 玻璃质感（`BackdropFilter`）在各 ROM 上表现一致；可直接移植 PiPilot（MIT）的聊天组件；未来 iOS / OpenHarmony 有路径 |
| 原生层 | Kotlin（Flutter 插件形式，写在 app 内） | 解压运行时、管理 proot 进程、前台服务 |
| DSH 客户端 | 纯 Dart 包 `packages/dsh_client` | 无 Flutter 依赖，可单测；本地与远程共用 |
| 本地运行时 | Ubuntu 24.04 base + Node + `@deepseek-ai/dsh`，经 proot 运行 | App 自带，免 Root、免 Termux |

## 目录

```
dsh-app/
  app/                         Flutter 应用（包名 dsh_app）
    lib/
      main.dart / app.dart     入口、主题、路由
      companion/               伙伴小屋的逻辑：状态与记忆的存取（主机桥或本机）、主动搭话、亲密度
      dev/                     开发用入口（探针、插件座位端到端），不进发行包
      diagnostics/             诊断包、错误日志、打码、输入法诊断
      forum/                   社区论坛（Discourse）的客户端、登录与状态
      l10n/                    界面文案：ARB 输入（parts/）与生成的本地化类
      launch/                  启动画面与自定义开屏（图片、视频、动效）
      links/                   深链、分享接收、桌面快捷入口、插件市场链接
      media/                   保存到相册、视频处理的原生通道
      notify/                  通知、实时活动、回合结束提醒
      performance/             性能档位与屏幕刷新率
      pets/                    桌宠：宠物包的导入校验、悬浮窗桥、情绪信号
      phone/                   手机操控：原生通道、审批、自检、技能录放
      plugins/                 原生插件（native/）与插件座位（seams/）的模型与状态
      remote/                  远程连接：中继、SSH、网络监测、密钥存储
      runtime/                 原生运行时的 Dart 侧（平台通道 + Riverpod 状态）
      share_code/              分享码与导出：对话、插件、配置，及其打码
      share_hosted/            托管分享链接的客户端与加密
      state/                   应用状态：端点、会话、聊天、设置
      ui_config/               ui.json：每台主机对原生界面的声明式布局
      update/                  App 更新：检查、增量包、下载与安装
      usage/                   匿名使用统计
      voice/                   语音输入模型的下载与校验
      wallpaper/               自定义壁纸的导入、取色与渲染
      ui/
        theme/  common/        设计系统
        shell/                 外壳：抽屉 + 导航
        onboarding/            首次引导：选择运行位置 → 本机（安装运行环境 → 登录 DeepSeek 或填 API Key）/ 远程主机
        chat/                  聊天页与组件（移植自 PiPilot）
        sessions/              会话抽屉
        settings/              设置
        engine/                引擎状态与日志
        web/                   官方 DSH Web 的 WebView 兜底
        remote/                远程
    android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/
      MainActivity.kt
      runtime/                 RuntimeInstaller / DshProcess / DshService / RuntimePlugin
  packages/dsh_client/         纯 Dart 的 DSH Web API 客户端
  runtime/                     运行时打包脚本与产物（out/<abi>/…）
  tooling/                     工具链安装脚本、env.sh
  docs/
```

依赖方向：`ui/` 可以 import 其他目录，`ui/` 以外的目录不 import `ui/`（入口 `main.dart`、`app.dart` 除外）。`app/test/arch/import_direction_test.dart` 守着这条，尚未清掉的旧边列在它的白名单里，白名单只减不增；现状用 `cd app && dart run tool/import_graph.dart` 查看。

## 平台通道约定（Dart ↔ Kotlin）

MethodChannel `dsh/runtime`：

| 方法 | 参数 | 返回 |
|---|---|---|
| `getStatus` | — | `RuntimeStatus` map（见下） |
| `install` | — | `null`；进度经事件流推送；已安装且版本一致时立即完成 |
| `start` | `{env: Map<String,String>}`（如 `DEEPSEEK_API_KEY`） | `null`；启动前台服务与进程 |
| `stop` | — | `null` |
| `getLogs` | `{lines: int}` | `List<String>` |
| `getLogSnapshot` | `{lines: int}`（默认 300，最多 2000） | `{entries: [LogEntry], throughSeq: int}`：内存里最后几行，`throughSeq` 是同一时刻已接收的最大序号 |
| `reset` | — | `null`；删除已解压运行时（保留 `/root` 用户数据需另行确认） |

`RuntimeStatus`：
```
{
  abi: "arm64-v8a" | "x86_64",
  bundledVersion: String,        // APK 内运行时版本（manifest.json）
  installedVersion: String?,     // 已解压版本
  phase: "notInstalled" | "installing" | "installed" | "starting" | "running" | "stopping" | "error",
  baseUrl: String?,              // 如 http://127.0.0.1:3080
  token: String?,                // dsh web 启动 token
  error: String?
}
```

EventChannel `dsh/runtime/events`，事件 map：
- `{type: "progress", step: "extract"|"verify"|"configure", done: int, total: int}`
- `{type: "status", status: RuntimeStatus}`
- `{type: "logs", entries: [LogEntry]}`：日志约每 100 ms 一批；`LogEntry` 为 `{seq: int, line: String, stream: "stdout"|"stderr"|"system"}`，`line` 已脱敏，`seq` 在进程内递增、重启引擎或重置都不归零。App 先订阅再取快照，只接 `seq > throughSeq` 的批次，批次与快照不重叠也不漏行。

## 打包

- Gradle 产品风味 `abi`：`arm64`（真机）、`x64`（模拟器测试）。各风味只带自己的 `runtime/out/<abi>/` 资产与 jniLibs，并设置对应 `abiFilters`；Flutter 插件默认的全架构过滤由 `gradle.properties` 的 `disable-abi-filtering` 关掉，`tooling/release_assets.py` 拒收带其他架构的包。
- 构建：`tooling/build-apk.sh`（默认 release arm64，`-f x64` / `-f all`）。脚本按构建时间生成 versionCode，见 `docs/release.md`「构建号」。
- proot 等可执行文件以 `lib*.so` 形式放 jniLibs，`useLegacyPackaging = true` 使其解压到 `nativeLibraryDir`（可执行）。
- `targetSdk = 28`（与 Termux 相同），避开 Android 10+ 对应用私有目录 `exec` 的限制；上架前再评估提升。
- Maven / Gradle / pub 走国内镜像（阿里云、腾讯云、flutter-io.cn）。

## 持久化系统与引擎更新

- 首次安装或用户明确确认的重置才允许激活整套 rootfs。普通更新不替换 rootfs，只替换打包器与 Android 安装器共同固定的精确引擎路径；不得扩大为整个 /usr、/usr/local 或 /opt。
- manifest 与归档内 runtime.json 共享 upgrade 元数据。baseId 由 ABI、Ubuntu 原始归档、额外 deb 与 Python 输入计算，不包含 DSH/Node/桥接/补丁或构建时间。Python 与用户 pip 包一起保留，不作为引擎目录替换。
- 旧运行时没有 upgrade 时，核对其 ABI、Ubuntu 版本、系统发行标识与 Python 二进制后采用；以后要求 baseId 匹配。基础身份变化、未知清单和旧版中断现场均返回 runtime_upgrade_blocked 错误，不进行破坏性兜底。此兼容门不等于对用户自行修改的动态库或第三方原生扩展作兼容保证。
- 升级前确认引擎及遗留进程已停止。新载荷先在 engine.prepare 落盘，再发布为 engine.upgrade；旧引擎临时保存在该事务中。按精确路径改名，数据屏障后原子提交 rootfs.version，最后把事务改名为 engine.done 再清理。启动不得将未完成事务当作可运行版本，重试必须先恢复事务，再清理 staging。
- 必须重新构建运行时资产，使归档与 manifest 都带新契约；只重建 Flutter APK、复用旧 runtime/out 不能启用分层升级。旧资产遇到已有环境会安全停止，而不是整根覆盖。
- 不兼容时原始系统保留在 App 私有目录。此实现不自动迁移基础系统，也不提供一键全环境备份；迁移或重置前应离线导出完整环境，保留模式、符号链接与包数据库，并验证备份，不能用诊断 ZIP 代替。

## 本地连接

1. 原生层启动 `dsh web --host 127.0.0.1 --port 3080 --no-open`，从 stdout 解析 token。
2. Dart 侧 `dsh_client` 用 token 换 cookie，之后所有 HTTP / WebSocket 带 cookie，不带 `Origin`。
3. WebView 兜底直接打开 `http://127.0.0.1:3080/?token=…`。

## 细节

- 运行时解压方式与具体 proot 参数：`runtime/` 与 `app/android/` 的运行时代码
- API 细节：`packages/dsh_client/`
- 远程接入方式：`packages/dsh_remote/`
- 设计规范：`docs/design/`
