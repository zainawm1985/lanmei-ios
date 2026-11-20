# 蓝莓视频 · iOS 版（自建 IPA）

安卓 APK **无法**转成 IPA，这里是同一站点的 iOS 原生重写版：外观、播放、下载功能与安卓版对齐。

- 站点：`https://www.lanmei.me`（可在 `Sources/BrowserViewController.swift` 的 `kSiteURL` 改）
- 内核：WKWebView + 原生下载引擎
- 功能：网页全屏浏览、注入「下载」按钮、抓取 m3u8/mp4、多线程分片下载、导出 MP4、写入系统相册、下载中心（进度/取消/重试）

---

## 一、最快能用：桌面图标描述文件（不用签任何东西）

用 iPhone 打开 `蓝莓视频_iPhone桌面图标.mobileconfig`
→ 设置 → 通用 → VPN与设备管理（或「已下载描述文件」）→ 安装
→ 桌面出现「蓝莓视频」图标，点开即全屏运行站点。

适合"先能用起来"。缺点：没有原生下载按钮（依赖网页自身能力）。

---

## 二、要真正的 IPA：GitHub Actions 云端编译（不需要 Mac）

本目录已包含 `project.yml`（XcodeGen）和 `.github/workflows/build-ipa.yml`。

1. 新建一个 GitHub 仓库，把本目录内容推上去（`main` 分支）。
2. 进入 **Actions → build-ipa → Run workflow**。
3. 约 5–8 分钟后，在该次运行页面底部下载产物 `LanmeiVideo-unsigned-ipa`（里面是 `LanmeiVideo-unsigned.ipa`）。
4. 这个 ipa 是**未签名**的，用下面任一方式装进 iPhone。

> 想改站点：编辑 `Sources/BrowserViewController.swift` 里的 `kSiteURL`，推送后重新跑 Actions。

---

## 三、把未签名 IPA 装进 iPhone

| 方式 | 需要 | 有效期 | 说明 |
|---|---|---|---|
| **Sideloadly**（Win/Mac） | 一根数据线 + 免费 Apple ID | 7 天，到期重签 | 最省事，Windows 也能做 |
| **AltStore / SideStore** | 同一 WiFi + 免费 Apple ID | 7 天，自动续签 | 需装 AltServer |
| **TrollStore** | iOS 14.0–16.6.1（部分 17.0） | 永久 | 免签名，最省心 |
| **付费开发者账号** | $99/年 | 1 年 | 可长期自用 |

Sideloadly 步骤：手机连电脑 → 拖入 `LanmeiVideo-unsigned.ipa` → 填 Apple ID → Start
→ 手机上 设置 → 通用 → VPN与设备管理 → 信任该开发者证书 → 打开 App。
首次打开会要「照片」权限（保存视频到相册用）。

> 免费 Apple ID 每 7 天要重签一次，且最多同时 3 个自签 App。

---

## 四、本地编译（有 Mac 时）

```bash
brew install xcodegen
cd ios-shell
xcodegen generate
open LanmeiVideo.xcodeproj     # 选真机，配好 Team，直接 Run
```

命令行出包：

```bash
xcodebuild -project LanmeiVideo.xcodeproj -scheme LanmeiVideo \
  -configuration Release -sdk iphoneos -derivedDataPath build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO build

mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/LanmeiVideo.app Payload/
zip -qry LanmeiVideo-unsigned.ipa Payload
```

---

## 五、已知限制（老实说）

1. **不是 APK 转换**：DEX/ART 不能在 iOS 上跑，这是 Swift 重写。
2. 网页里如果用了「App 内跳转协议」（如 `lanmeiapp://`），iOS 侧不会响应，可能需要补 URL Scheme 处理。
3. HLS 转 MP4 走 `AVAssetExportSession`(passthrough→重编码兜底)；极少数加密流（AES-128）未实现解密，会失败并提示。
4. 站点有 360 WAF 的 JS 挑战页，真实浏览器会自动通过；若长期拿不到内容，改 `kSiteURL` 到可用线路。
5. 上架 App Store 不可能（内容合规），只能自签侧载。
