# emu-gamewindow-mac（繁體中文）

在 Apple Silicon Mac 上，為**官方 Android Emulator** 提供原生的「遊戲視窗」。
模擬器在背景執行，這個 App 用自己的視窗顯示畫面，並把鍵盤和滑鼠轉成多點觸控，
類似桌面 Android 播放器的鍵位功能，而且不需要在 Android 裡安裝任何東西。

- **畫面**：透過 gRPC `streamScreenshot` 取得。高效能路徑會用共享記憶體（MMAP）傳畫面，
  再用 Metal 繪製；在 M3 MacBook Air 上可以跟上 60 fps，遊戲視窗本身約占 5% CPU。
- **輸入**：左鍵與綁定的按鍵會透過 gRPC `sendTouch` 變成觸控，最多同時 5 點；
  WASD 可以當虛擬搖桿。在視窗內按 ⌘E 編輯按鍵，也能另存成多組設定。
- **視窗**：等比例縮放、全螢幕、旋轉、截圖、Android 返回／主畫面／最近使用／音量鍵，
  以及透過剪貼簿打字（可輸入中文，⌘T）。
- **日常使用**：Launcher App（啟動、遊玩、關機）與 `egw` 指令。
- **不使用 ADB、root 或 Guest agent**，USB 偵錯可以保持關閉。
  App 不需要任何 macOS 隱私權限（不需要輔助使用，也不需要螢幕錄影）。

> **狀態**：個人專案，只在一台 Mac 上測試過（MacBook Air M3、macOS 27），
> 搭配 Android Emulator 37.2.12 與 API 35 Google Play ARM64 映像。介面目前是繁體中文。

## 請自行遵守各遊戲條款

本工具只使用模擬器公開的 gRPC 控制介面，不讀寫任何 App 的記憶體或檔案。
有些遊戲的服務條款禁止模擬器或輸入工具，**是否遵守你所執行的軟體條款，由你自行負責。**
本專案與 Google 或任何遊戲營運商無關。

## 需求、安裝與指令

請見英文版 [README.md](README.md)。快速開始：

```bash
cp egw.config.example.json egw.config.json && chmod 600 egw.config.json
scripts/setup-runtime.sh      # 從 Google 下載 Android 工具、Emulator 37.2.12、API 35 映像
scripts/create-avd.sh         # 建立 1280×720 橫式 AVD
scripts/egw build             # 第一次建置會下載 Swift 套件
scripts/egw start --window    # 第一次開機：登入 Google Play、安裝你的 App
scripts/egw play              # 開啟遊戲視窗
scripts/egw stop              # 快速關機（送一次 SIGTERM）
scripts/egw app && scripts/egw install   # 打包並安裝到「應用程式」
```

## 授權

Apache License 2.0，見 [LICENSE](LICENSE) 與 [NOTICE](NOTICE)。
