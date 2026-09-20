# FallVault iOS

iPhone 上的本地加密密码管理器，与桌面版 **FallVault** 使用同一套 `.fvault` 加密备份格式，双向互通。

> 纯本地存储 · 无服务器 · 无账号 · 无云端明文

## 功能

**密码库**
- 账号密码管理（用户名 / 密码 / 网址 / 备注 / 分类 / 收藏）
- 标签筛选、搜索、左滑快速编辑与删除
- 密码强度提示、密码历史

**验证码（TOTP）**
- 标准 RFC 6238 实现（base32 → HMAC-SHA1 → 动态截断），与 Google Authenticator、桌面版同码
- 支持 `otpauth://` 链接导入 / 导出
- 30 秒倒计时圆环、点击复制、时间偏移校正（±30 秒）

**银行卡卡片**
- 卡面配色 / 自定义卡面图（裁剪时支持缩放、拖动、水平/垂直翻转）
- 卡号分组显示、CVV 隐藏、账单地址（地址 / 城市 / 省州 / 国家地区 / 邮编，选填）
- 上下滑动切换的 3D 卡片画廊

**隐私与安全**
- 主密码解锁，支持 Face ID（人脸特征只存本机，不存原图）
- 应用内截图防护、自动锁定、连错锁定
- 加密备份（.fvault）与 GitHub 云备份（上传的永远是 AES-256-GCM 密文）

## 安全设计

| 项目 | 实现 |
|---|---|
| 主密码 | 只存摘要（不存明文），可修改 / 重置 |
| 备份加密 | AES-256-GCM，密钥由 PBKDF2-SHA256（150,000 次迭代，16 字节 salt）派生；数据密钥再被密码密钥包裹（信封加密） |
| 备份文件 | `.fvault`，与桌面版 FallVault 完全同格式，双向可恢复 |
| 云端备份 | 仅上传密文；令牌只存本机，不写入备份、不上传 |
| 人脸识别 | 128 维特征向量仅存本机 localStorage，原图不落盘 |
| 存储 | 全部数据留在设备沙盒（`Documents/fvdata.json`），不经过任何服务器 |

> ⚠️ 主密码一旦遗忘无法找回（没有找回通道、没有后门），请务必牢记或保存在安全的地方。

## 与桌面版互通

`iOS 导出` → 桌面版可直接恢复；`桌面版导出` → iOS 可直接恢复。

字段映射：桌面版 `entries[].totp_secret` ↔ iOS 验证码密钥；`tags` ↔ 标签；银行卡为 iOS 独有（桌面版忽略，不参与备份）。

## 构建

项目使用 GitHub Actions 在 macOS runner 上编译**未签名 IPA**（`ios-app/.github/workflows/build-ipa.yml`）：

```bash
git push            # 触发 Actions
gh run download <run-id> --dir out   # 下载产物
# 得到 FallVault-unsigned.ipa → 用 Sideloadly / AltStore 自签安装
```

本地构建需要 macOS + Xcode（`project.yml` 为 XcodeGen 配置）：

```bash
cd ios-app && xcodegen generate && xcodebuild -project FallVault.xcodeproj -scheme FallVault -sdk iphoneos -configuration Release CODE_SIGNING_ALLOWED=NO build
```

## 目录结构

```
ios-app/                 iOS 应用（SwiftUI + WKWebView 壳）
  Sources/FallVaultApp.swift   原生桥：沙盒文件读写、相机、Face ID、分享面板
  Resources/web/007-screens/   界面实现（HTML/CSS/JS）
  .github/workflows/           自动打包未签名 IPA
sketches/007-screens/    界面原型（与 Resources/web 同源，桌面浏览器可直接打开调试）
docs/                    开发笔记
```

界面与逻辑全部由 `Resources/web/007-screens/` 下的 HTML/CSS/JS 实现，Swift 只提供原生能力桥接，便于在桌面浏览器里调试同一套代码。

## 说明

- 本项目仅供个人学习与自用，不上架 App Store（自签 IPA 安装）。
- 请仅管理**你自己**的账号信息，不要用于存储他人凭据。
- 因遗忘主密码、设备丢失、误删数据造成的损失，作者不承担责任。
- 界面与实现参考了个人使用习惯与公开的 iOS 设计规范；桌面版 FallVault 为独立项目。

## License

MIT