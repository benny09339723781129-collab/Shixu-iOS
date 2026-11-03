# 拾序 iOS

原生 UIKit / WKWebView 外殼，載入既有正式網站，不複製分析引擎或儲存雲端金鑰。

- 行情、情報、持股、NEXA 與設定沿用正式站。
- Google 登入使用 iOS 的 ASWebAuthenticationSession；以 PKCE 綁定一次性授權交換，Google 與工作階段憑證不出現在回呼網址。
- 使用 WKWebView 的持久資料容器；與 Safari/PWA 分開。首次登入後沿用原有 Google 雲端還原與衝突檢查，保留原 PWA 資料。
- 原生啟動畫面使用既有拾序圖示；不新增 App extension。
- 簽署由現有 SideStore 在手機完成；建置端不接觸 Apple 帳號、P12、憑證或配對檔。
- 相容現有 SideStore 2026-09-11：簽署使用 ASCII 名稱 `Shixu`；繁體中文 iPhone 的主畫面名稱由 `zh-Hant/InfoPlist.strings` 顯示為「拾序」。Bundle ID 固定為 `app.shixu.studio`，不另占新的 App ID。

## 建置

在具有 Xcode Command Line Tools 與 iPhoneOS SDK 的 macOS：

```sh
bash scripts/build-ipa.sh
```

產物：`build/Shixu-unsigned.ipa`。這是 ad-hoc 打包檔，仍須 SideStore 的個人裝置簽署。不能把 Windows 簽署工具當成 iOS 編譯器，也不能把原始碼檢查當成真機安裝成功。

公開建置包只包含本目錄的原生外殼、圖示與建置腳本；不包含網站後台、使用者資料、API 金鑰或 Apple 簽署資料。
