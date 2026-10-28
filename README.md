# HPlayer

把 115 网盘变成自己的在线影视库，在 iPhone 上直接播放。

后端跑在你的 Windows 电脑 / NAS / VPS 上，前端既可以当网页用，也可以打包成 iOS App（未签名 IPA + 全能签自签）。

## 架构

```
iPhone（原生 SwiftUI App / Safari PWA）
        │  HTTPS
        ▼
Cloudflare Tunnel（免费，自带域名和证书）
        │
        ▼
Node 后端
  ├─ 单用户密码登录（Bearer token / Cookie）
  ├─ 115 Cookie 管理、目录浏览
  ├─ 直链签发：mp4/H.264 → 302 到 115 CDN
  └─ ffmpeg 实时转封装：mkv/DTS → HLS(fMP4)
```

- **能直连就直连**：Safari 原生支持的格式直接 302 到 115 CDN，不占服务器带宽。
- **播不了才转**：mkv、DTS/AC3 这类 Safari 不支持的组合，后端用 ffmpeg 做 remux（视频流 `copy`，音频转 AAC），CPU 开销很小。

## 功能

- 115 目录浏览、面包屑导航
- 自动判断直连 / 转封装
- HLS 播放，支持拖动进度（已生成的片段）
- 单用户密码保护
- PWA：Safari「添加到主屏幕」全屏使用
- Capacitor 打包 iOS App

## 前置要求

- Node.js 20+（当前环境是 24，没问题）
- ffmpeg（必须）

Windows 安装 ffmpeg：

```bash
winget install Gyan.FFmpeg
```

或者从 <https://www.gyan.dev/ffmpeg/builds/> 下载，解压后把 `bin` 目录加进 PATH，或在 `server/.env` 里写 `FFMPEG_PATH`。

## 本地启动

```bash
npm install
cp server/.env.example server/.env
```

编辑 `server/.env`，至少改掉 `HPLAYER_PASSWORD`。然后：

```bash
npm run start
```

打开 <http://localhost:8787>，用密码登录。

开发模式（前端热更新）：

```bash
npm run dev
```

前端在 <http://localhost:5173>，API 自动代理到 8787。

## 获取 115 Cookie

1. 电脑浏览器打开 <https://115.com> 并登录
2. 按 F12 打开开发者工具，切到 **Network（网络）**
3. 刷新页面，随便点一个发往 `webapi.115.com` 的请求
4. 在 **Request Headers** 里找到 `Cookie`，整行复制
5. 粘贴到 App 的「设置 → 更新 Cookie」

Cookie 里必须包含这四项：`UID`、`CID`、`SEID`、`KID`。

> Cookie 等同于账号登录态，泄露就等于把网盘交出去。只填在自己的服务器上，不要发给别人。

Cookie 会过期（通常几周到几个月）。失效后页面会提示，重新复制一次即可。

## 公网部署（Cloudflare Tunnel）

推荐用 Cloudflare Tunnel：免费、不用公网 IP、不用开路由器端口、自带 HTTPS。

### 临时试用

```bash
cloudflared tunnel --url http://localhost:8787
```

会输出一个 `https://xxx.trycloudflare.com` 地址。重启就变，只适合测试。

### 长期使用

```bash
cloudflared tunnel login
cloudflared tunnel create hplayer
cloudflared tunnel route dns hplayer hplayer.你的域名.com
```

`%USERPROFILE%\.cloudflared\config.yml`：

```yaml
tunnel: <上一步输出的 TUNNEL_ID>
credentials-file: C:\Users\<你的用户名>\.cloudflared\<TUNNEL_ID>.json

ingress:
  - hostname: hplayer.你的域名.com
    service: http://localhost:8787
  - service: http_status:404
```

```bash
cloudflared tunnel run hplayer
```

想开机自启，用 `cloudflared service install`，或者把 `cloudflared tunnel run hplayer` 和 `npm run start` 都做成计划任务。

## 打包 iOS App

iOS 端是 **SwiftUI 原生实现**（`ios-native/`），不是 WebView 套壳。工程文件用 XcodeGen 从 `project.yml` 生成，所以 `HPlayer.xcodeproj` 不入库，避免手写 pbxproj。

Windows 上无法编译 iOS，用 GitHub Actions 的 macOS runner 云构建：

1. 把项目推到 GitHub（公开/私有都行）
2. 打开仓库的 **Actions → Build unsigned iOS IPA → Run workflow**
3. 等几分钟，下载 artifact `HPlayer-unsigned-ipa`
4. 解压得到 `HPlayer-unsigned.ipa`
5. 用全能签导入、签名、安装

首次打开 App 会让你填服务器地址（就是上面的 Cloudflare Tunnel 域名，比如 `https://hplayer.你的域名.com`）。

> 构建产物是**未签名** IPA，不需要 Apple 开发者账号。签名和有效期取决于你的全能签证书。
>
> 原生版 Bundle ID 是 `app.hplayer.native`。如果全能签证书不支持，改 `ios-native/project.yml` 里的 `PRODUCT_BUNDLE_IDENTIFIER` 后重新构建。

### 本地有 Mac 时

```bash
cd ios-native
brew install xcodegen
xcodegen generate
open HPlayer.xcodeproj
```

## 已知限制

- **115 接口是非官方的**。官方开放平台已于 2026-08 暂停服务，这里用的是社区维护的 webapi。接口随时可能变，有账号风控风险，只建议自用，不要做成公开服务。
- **mkv 首次播放要等**。后端需要先 remux 出 HLS 分片，大文件可能等几十秒；之后拖动到已生成的部分是即时的。
- **AV1 / VP9 片源很慢**。这类编码 iOS 不支持硬解，需要真转码，CPU 占用高。当前实现是直接 `copy`，遇到这类片源会播不了，需要改成 `libx264`。
- **单用户**。没有多账号体系，也没做并发控制。
- **Cookie 会过期**，需要手动更新。

## 目录结构

```
HPlayer/
├── server/                 后端
│   └── src/
│       ├── index.ts        Fastify 入口
│       ├── auth.ts         登录与凭据校验
│       ├── config.ts       环境变量
│       ├── p115/           115 客户端（含私有加密协议）
│       ├── media/          ffprobe 探测、ffmpeg 转封装
│       └── routes/api.ts   全部 API
├── web/                    Web 前端（React + Vite，可作 PWA）
│   └── src/
│       ├── pages/          登录、文件库、播放器、设置
│       └── lib/api.ts      请求封装、token、服务器地址
├── ios-native/             iOS 原生 App（SwiftUI）
│   ├── project.yml         XcodeGen 工程描述
│   └── HPlayer/
│       ├── Models/         数据模型
│       ├── Services/       API 客户端、Keychain、全局状态
│       └── Views/          登录、文件库、播放器、设置
└── .github/workflows/      iOS 云构建（xcodegen + xcodebuild）
```
