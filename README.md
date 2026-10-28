# HPlayer

把 115 网盘变成自己的在线影视库，在 iPhone 上直接播放。

iOS 端是原生 SwiftUI App，默认手机直连 115，无需运行电脑后端。也可选用 Windows / NAS / VPS 后端，使用原有的服务端转封装能力。

## 架构

```
iPhone（原生 SwiftUI App）
        ├─ 手机直连：登录、浏览、搜索和 115 在线画质
        │  （授权和 Cookie 只保存在手机 Keychain）
        └─ 可选服务器模式：
        │  HTTPS
        ▼
Cloudflare Tunnel（免费，自带域名和证书）
        │
        ▼
Node 后端
  ├─ 单用户密码登录（Bearer token / Cookie）
  ├─ 115 开放平台扫码授权、目录浏览（保留 Cookie 兼容方式）
  ├─ 直链签发：mp4/H.264 → 302 到 115 CDN
  └─ ffmpeg 实时转封装：mkv/DTS → HLS(fMP4)
```

- **手机直连**：使用 115 网页端在线播放画质；能否播放和画质受 115 账号权益、片源及接口状态影响。
- **服务器模式直连**：AVPlayer 原生支持的格式直接 302 到 115 CDN，不占服务器带宽。
- **播不了才转**：mkv、DTS/AC3 这类 AVPlayer 不支持的组合，后端用 ffmpeg 做 remux（视频流 `copy`，音频转 AAC），CPU 开销很小。

## 功能

- 115 目录浏览、面包屑导航
- 115 官方登录授权、BT 种子解析与云下载任务
- 磁力链接手机端解析和边缓冲边播放（无需 115 账号或服务器）
- 自动判断直连 / 转封装
- HLS 播放，支持拖动进度（已生成的片段）
- 单用户密码保护
- 原生 iOS App：本地视频导入、网络地址直接播放、最近播放
- Liquid Glass 界面（iOS 26），低版本自动降级毛玻璃

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

服务监听 `http://localhost:8787`，只提供 API，没有网页界面。打开 App，在「设置」里填这个地址、输入密码登录即可。

## 连接 115 开放平台

1. 手机直连浏览和在线播放：在「资源库」点击 115 并在应用内登录，不需要 AppID。Cookie 存在手机 Keychain，网页会话和非官方接口可能失效。
2. BT 云下载需要在 [115 开放平台](https://open.115.com/) 申请应用并开通文件列表、上传和云下载等所需接口权限。
3. 手机直连的 BT 页面选择「115 云下载授权」，填写审核通过的 AppID，并使用 115 扫码授权。令牌保存在手机 Keychain，PKCE 扫码不需要 AppSecret 或服务器。
4. 如需切换服务器模式，启动 HPlayer 后端，在「设置」选择「服务器」并填写地址和访问密码。服务器模式的网页登录还需要 AppSecret 和已登记的 HTTPS 回调域名。

## BT 种子和云下载

进入「资源库 → BT 种子与云下载」，先完成官方扫码授权，再从手机导入 `.torrent` 文件，或从 115 网盘中选择已有的种子。手机导入会先将种子上传到 115 网盘根目录（最大 4 MB）；解析后可勾选文件、设置目标文件夹 ID 和相对保存路径，提交云下载任务并查看状态。下载后的文件可以从资源库浏览、播放。此功能需要已获批的上传及云下载权限，并可能消耗 115 云下载配额。115 官方接口和实际播放需在凭证获批后实测。

## 磁力播放

「资源库 → 磁力在线播放」可粘贴磁力链接；从其他 App 交给 HPlayer 的 `magnet:` 链接也会进入此页面。链接由手机上的 BT 引擎解析，选择视频后按需缓冲，无需 115 凭证或外部后端。能否播放取决于节点、网络及视频编码；当前系统播放器支持 MP4、MOV、M4V 中 iOS 可解码的格式。磁力播放会使用网络流量和手机缓存。

磁力功能使用 [Nuvio Engine v0.1.6](https://github.com/NuvioMedia/nuvio-engine/tree/v0.1.6)（GPL-3.0），其授权及第三方许可文件包含在 App 中；分发包含此组件的应用时需遵守其许可证。此组件要求 iOS 16.1 及以上。构建脚本下载官方发布的 XCFramework 并校验 SHA-256。

后端数据目录包含授权令牌和登录密钥，应仅由服务器的使用者访问，不要提交到 Git 或发给其他人。外网访问建议使用 HTTPS。授权或接口权限尚未获批时，真实接口和播放效果需要获批后再验证。

## 兼容方式：获取 115 Cookie

手机直连模式在资源库点击 115 后，使用应用内的 115 网页登录。HPlayer 会读取该会话所需的 Cookie，在手机直接验证并保存。网页形式可能改变，若自动连接失败可在服务器模式使用下面的手动方式。Cookie 方式的浏览和播放使用非官方接口；BT 云下载单独使用上面的官方扫码授权。

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
bash scripts/prepare-nuvio.sh
xcodegen generate
open HPlayer.xcodeproj
```

## 已知限制

- **官方接入需要应用与接口权限获批**。扫码授权、文件和下载接口是否可用以 115 审核结果为准；保留的 Cookie 方式使用非官方接口，可能发生变化。
- **mkv 首次播放要等**。后端需要先 remux 出 HLS 分片，大文件可能等几十秒；之后拖动到已生成的部分是即时的。
- **AV1 / VP9 片源很慢**。这类编码 iOS 不支持硬解，需要真转码，CPU 占用高。当前实现是直接 `copy`，遇到这类片源会播不了，需要改成 `libx264`。
- **单用户**。没有多账号体系，也没做并发控制。
- **Cookie 兼容方式会过期**，需要手动更新。

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
├── ios-native/             iOS 原生 App（SwiftUI）
│   ├── project.yml         XcodeGen 工程描述
│   └── HPlayer/
│       ├── Models/         数据模型
│       ├── Services/       API 客户端、Keychain、全局状态
│       └── Views/          登录、文件库、播放器、设置
└── .github/workflows/      iOS 云构建（xcodegen + xcodebuild）
```
