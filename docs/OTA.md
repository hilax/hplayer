# HPlayer OTA 一键安装

把 GitHub Actions 产出的未签名 IPA，变成「发一条链接，别人点一下就装到 iPhone」。
整套链路不依赖全能签 App，也不要求每台手机各买一份证书。

## 目录结构与链接

| 内容 | 位置 | 说明 |
| --- | --- | --- |
| 安装页 | `docs/index.html` → `https://hilax.github.io/hplayer/` | GitHub Pages，HTTPS，Safari 打开 |
| OTA manifest | `docs/manifest.plist` → `https://hilax.github.io/hplayer/manifest.plist` | `itms-services` 协议读取 |
| 签名 IPA | Release 固定 tag `ota` → `https://github.com/hilax/hplayer/releases/download/ota/HPlayer-signed.ipa` | `--clobber` 覆盖，链接永不变 |
| 签名 workflow | `.github/workflows/ota.yml` | 从最新成功构建取未签名 IPA → zsign 签名 → 覆盖上传 |
| 本地工具 | `scripts/ota/ota.mjs` | 零依赖 Node CLI，Windows / macOS / Linux 都能跑 |

安装协议：

```
itms-services://?action=download-manifest&url=https%3A%2F%2Fhilax.github.io%2Fhplayer%2Fmanifest.plist
```

## 证书三件套

在 `signing/` 放三个文件（该目录已加入 `.gitignore`，`*.p12` / `*.mobileprovision` 也被忽略，**绝不会提交到仓库**）：

```
signing/cert.p12                  ← 你买的证书（含私钥）
signing/cert.mobileprovision      ← 配套描述文件
signing/password.txt              ← p12 密码（纯文本，一行）；也可改用环境变量 OTA_CERT_PASSWORD
```

只有 `cert.p12` 不够：决定「哪些手机能装」的是 `cert.mobileprovision`。判型：

| 描述文件字段 | 类型 | 效果 |
| --- | --- | --- |
| `ProvisionsAllDevices = true` | 企业签 / In-House | 不绑设备，任意 iPhone 点链接直接装 ✅ |
| `ProvisionedDevices` 数组 | 个人签 / 超签 / Ad Hoc | 只有数组里的 UDID 能装，别的手机报「完整性无法验证」 |
| `get-task-allow = true` | Development | iOS 16+ 还需打开「开发者模式」 |
| `application-identifier` 为显式 App ID | 如 `TEAMID.com.foo.bar` | 签名时必须用 `-b` 把 bundle id 改成这个值，否则 entitlements 对不上，装不上 |

`node scripts/ota/ota.mjs check` 会打印全部字段、到期时间、UDID 数量和最终使用的 bundle id，并自动生成匹配的 `manifest.plist` / `meta.json`。

## 两种模式

### A. 本机签名（p12 不上传 GitHub）

```bash
node scripts/ota/ota.mjs publish
```

流程：检查证书 → 部署安装页 + workflow + Pages + Release → 本机 `zsign` 签名 → 覆盖上传 IPA。
需要 `scripts/ota/bin/zsign.exe`（Windows）或 `zsign`（macOS/Linux），从
<https://github.com/zhlynn/zsign/releases/tag/v1.1.3> 下载后放进该目录。
未签名 IPA 默认取 `dist/input/HPlayer-unsigned.ipa`，没有则自动 `gh run download` 最新成功构建；
也可以用 `--ipa <路径>` 指定。以后每次出新包，重复这一条命令即可。

### B. CI 自动签名（推荐，一劳永逸）

```bash
node scripts/ota/ota.mjs setup
```

流程：检查证书 → 把三件套写入 GitHub Secrets → 部署站点与 workflow → 启用 Pages → 触发首次签名。

写入的 Secrets：

| Secret | 内容 |
| --- | --- |
| `OTA_CERT_P12_B64` | cert.p12 的 base64 |
| `OTA_CERT_PROV_B64` | cert.mobileprovision 的 base64 |
| `OTA_CERT_PASSWORD` | p12 密码 |
| `OTA_BUNDLE_ID` | 由描述文件推算出的最终 bundle id |

之后 `.github/workflows/ota.yml` 在每次 `Build unsigned iOS IPA` 成功时自动运行
（也可手动 `gh workflow run ota.yml -R hilax/hplayer --ref main`）：
下载 `HPlayer-unsigned-ipa` artifact → 下载/校验 zsign v1.1.3 静态二进制 →
`zsign -f -k ... -m ... -b ... -z 9 -o HPlayer-signed.ipa` → `gh release upload ota ... --clobber`。

`-z 9` 是必需的：默认压缩级别会让 36 MB 的包膨胀到 87 MB。

### 只部署页面（还没证书时）

```bash
node scripts/ota/ota.mjs site
```

不需要任何证书，就能把页面、manifest、workflow、Pages、Release 全部建好。此时页面显示
「尚未上传签名包」；拿到证书后跑 `publish` 或 `setup` 补上 IPA 即可，链接完全不用换。

## 用户侧操作

1. **用 Safari 打开发过去的链接**。微信 / QQ / 钉钉内置浏览器不支持 `itms-services`，需点右上角「···」→「在 Safari 中打开」。
2. 点「点此安装到 iPhone / iPad」→ 弹窗点「安装」。
3. 首次打开提示「未受信任的企业级开发者」：设置 → 通用 → VPN 与设备管理 → 企业级 App → 选开发者 → 信任。iOS 18+ 显示「允许并重启 (Allow & Restart)」，重启后完成。
4. 若提示「需要开发者模式」：设置 → 隐私与安全性 → 开发者模式 → 打开并重启（仅 Development 描述文件需要）。

## 排障

| 现象 | 原因 / 处理 |
| --- | --- |
| 「无法验证 App」/ 装完闪退 | 证书被吊销或过期。装 `NexRevokeDNS`（<https://sideloading.net/dns/>），安装与首次启动用 `Use during install`，跑通一次后切 `Use After Installing Apps`；同时重新签名上传 |
| 「此 App 无法安装，因为其完整性无法验证」 | 该设备 UDID 不在描述文件里；或 bundle id 与 `application-identifier` 不匹配。把 UDID 加进描述文件重签 |
| 点按钮无反应 | 不是 Safari；或 `github.io` / `github.com` 被网络拦。manifest 与 IPA 必须都是受信任 HTTPS，不能用 HTTP / 自签证书 |
| 弹「未受信任的企业级开发者」 | 首次安装必现，按上面第 3 步信任一次即可；同一开发者的后续 App 不用再点 |
| 证书到期 | `node scripts/ota/ota.mjs check` 会显示 `ExpirationDate`；到期前换新 p12 + 描述文件，重跑 `setup`/`publish` |
| 描述文件被换成本机没有的显式 App ID | `check` 会算出新的 bundle id 并重写 `manifest.plist`，无需手工改 |

## 安全与限制

- `signing/` 里的 p12 含私钥。只把**签名后的 IPA** 和**安装页链接**发给用户，不要发 p12。
- 企业签被 Apple 吊销时，所有已安装设备上的 App 会同时打不开；已装 App 在吊销发生后仍能启动一段时间，取决于本机是否缓存了校验结果，DNS 屏蔽 OCSP/CRL 可延长可用期。
- GitHub Pages 的 `source.path` 只接受 `/` 或 `/docs`，所以站点文件放在 `docs/` 根，`docs/.nojekyll` 用于禁用 Jekyll。
- Release tag `ota` 是固定的，每次覆盖同名资源，因此链接永久有效；不要删掉这个 Release。
- OTA 走系统级 `itms-services` 通道，与手机上是 iOS 16 还是 iOS 27、有没有装全能签无关。
