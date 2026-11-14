# 拾序 iOS 2.0

使用 UIKit 原生畫面：首頁、行情、自選、K 線與均線、情報、個股筆記、研究庫、研究報告、NEXA 持股計畫、持股／資金帳與設定。主要介面不載入網站。

- 系統導覽列、分頁列、搜尋、選單、表單、分享與檔案匯入；iOS 26 以上的按鈕使用原生 clear Liquid Glass，較舊版本使用系統按鈕備援。
- 公開行情與研究仍使用既有 JSON API；沒有在 APP 放置雲端金鑰或更動後端模型。來源失敗不補造價格，美元與台幣分別計算。
- AI 研究及 NEXA 只在使用者明確按開始後提出一次請求，先保存 UUID；中斷後 GET 查詢原請求，不自動付費重跑、不下單。
- 原始研究封存保持不變。NEXA 的條件觸發只要求重新研究，原模型的減碼／出場文字不是使用者的操作授權。
- 原生 JSON 儲存採原子寫入與裝置資料保護；手動匯出、匯入及 Google 雲端備份／還原，版本衝突不直接覆寫。
- 舊版資料沒有可驗證的帳號歸屬，因此首次升級僅提示移轉入口。使用者到設定預覽紀錄數量與目標工作區，確認後才複製。隱藏 WebKit 僅讀取舊版可信 `/privacy.html` origin 的白名單 localStorage；不自動匯入或刪除舊版資料。WebKit 不用於主要 APP 頁面。
- 舊研究 owner Cookie 與帳號 Cookie 使用既有資料容器移轉；Google 登入沿用 ASWebAuthenticationSession + PKCE。沒有讀取或保存 Apple 密碼、憑證或配對檔。
- Bundle ID 固定 `app.shixu.studio`。原始顯示名為 ASCII `Shixu`，繁體中文標籤為「拾序」；沿用同一簽署身分升級，避免刪除 APP 造成資料遺失。

## 建置與驗證

macOS、Xcode 與 iPhoneOS SDK：

```sh
bash scripts/build-ipa.sh
```

產物 `build/Shixu-unsigned.ipa` 仍須個人裝置簽署；編譯不需要 Apple 帳號、P12 或 provisioning profile。

原生模擬器隔離測試：

```sh
node scripts/generate-fixtures.mjs
bash scripts/verify-simulator.sh
```

模擬器選擇 iOS 26 以上，啟動真實原生 APP、執行儲存／還原／帳本／封存等檢查，輸出畫面與 `native-self-test.json`。測試資料只包含在 DEBUG 模擬器版本；裝置 IPA 不含 fixture 資源或啟動入口。測試不呼叫正式付費模型。

GitHub Actions 僅建置獨立 iOS 原始碼，不發布網站、不修改後端、不接觸 Apple 簽署資料。模擬器通過不能取代真機登入、舊資料移轉與安裝驗收。
