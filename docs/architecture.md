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
      runtime/                 原生运行时的 Dart 侧（平台通道 + Riverpod 状态）
      state/                   应用状态：端点、会话、聊天、设置
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

## 本地连接

1. 原生层启动 `dsh web --host 127.0.0.1 --port 3080 --no-open`，从 stdout 解析 token。
2. Dart 侧 `dsh_client` 用 token 换 cookie，之后所有 HTTP / WebSocket 带 cookie，不带 `Origin`。
3. WebView 兜底直接打开 `http://127.0.0.1:3080/?token=…`。

## 细节

- 运行时解压方式与具体 proot 参数：`runtime/` 与 `app/android/` 的运行时代码
- API 细节：`packages/dsh_client/`
- 远程接入方式：`packages/dsh_remote/`
- 设计规范：`docs/design/`
