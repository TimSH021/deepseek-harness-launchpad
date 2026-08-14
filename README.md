# DeepSeek Harness 启动台

一键拉起 [DeepSeek dsh](https://www.npmjs.com/package/@deepseek-ai/dsh)（`npx @deepseek-ai/dsh web`）的本地启动台。深海荧光界面、粒子呼吸灯状态球，支持 **macOS / Linux / Windows** 三平台。

![icon](screenshots/icon.png)

![screenshot](screenshots/ui.png)

## 它做什么

- **一键启动**：后台拉起 `dsh web`（默认 127.0.0.1:3080），探测就绪后自动打开浏览器界面
- **已运行检测**：3080 上已有实例（包括你在终端手动跑的）时直接打开界面，不重复起进程
- **安全停止**：只停本启动台拉起的进程；外部实例一律拒绝操作，防误杀
- **实时日志**：dsh 输出实时滚动，完整日志落盘
- **检测更新**：比对 npx 本地缓存版本与 registry（自动读取你的 `.npmrc` 镜像源）最新版，一键更新
- **粒子呼吸灯**：运行中粒子环绕呼吸、启动中琥珀脉冲、停止后归于沉寂

## 安装使用

### macOS（原生 App）

```bash
git clone https://github.com/TimSH021/dsh-launchpad.git
cd dsh-launchpad/macos
./build.sh          # 需要 Xcode Command Line Tools（clang + AppKit + WebKit）
open "DeepSeek Harness 启动台.app"
```

App 内可「一键安装到应用程序」「开机自启」。也可用命令行自测：

```bash
"DeepSeek Harness 启动台.app/Contents/MacOS/DSH Launcher" --probe        # 查看状态
DSH_LAUNCHER_DSH_PORT=4895 "DeepSeek Harness 启动台.app/Contents/MacOS/DSH Launcher" --selftest
```

### Linux / Windows（跨平台版，零依赖 Node）

dsh 运行在 Node 上，所以凡能跑 dsh 的机器就能跑启动台：

```bash
git clone https://github.com/TimSH021/dsh-launchpad.git
cd dsh-launchpad/cross
./start.sh                 # Linux / macOS
```

Windows 双击 `DSH-Launcher.vbs`（无黑窗）或 `DSH-Launcher.bat`。

Linux 桌面集成：编辑 `dsh-launcher.desktop`，把 `%REPLACE_ME%` 替换为本仓库绝对路径，放到 `~/.local/share/applications/`。

## 架构

```
shared/index.html   统一界面（单文件；App 桥接 / HTTP 双模式自适应）
macos/main.m        原生 App（Objective-C + AppKit + WKWebView，进程管理 + 登录项 + 安装）
cross/server.js     跨平台版（Node 零依赖，macOS/Linux/Windows 进程分支）
```

界面通过 `bridge`（App 内 `WKScriptMessageHandlerWithReply`）或 `/api/*`（浏览器版）与后端通信，指令集一致：`status / start / stop / open / logs / update-check / update-apply`。

## 配置

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `DSH_PORT`（macOS `DSH_LAUNCHER_DSH_PORT`） | 3080 | dsh web 端口 |
| `LAUNCHER_PORT` | 4899 | 跨平台版控制台端口 |

## 说明

- 就绪判定：TCP 连接 + `GET /` 响应含 `__DSH_BOOT__`，3080 被其他程序占用不会误判
- 停止策略：macOS/Linux 杀整个进程组（spawn detached 建组）或进程树，Windows 用 `taskkill /T /F`；5 秒后 SIGKILL 兜底
- 重启认领：启动台重启后凭 `child.pid` 认领上次拉起的 dsh，继续可管
- 更新原理：清理 npx 缓存目录，下次启动自动拉取最新版（首次约需十几秒）

## License

[MIT](LICENSE)
