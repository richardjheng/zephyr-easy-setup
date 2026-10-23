# Zephyr RTOS One-Click Setup for Windows

此專案提供 Windows 上的一鍵線上安裝、既有環境離線打包、離線安裝與確認後卸載。預設板卡為 `it51xxx_evb`，失敗時嘗試 `it51xxx_evb/it51526aw`，工具鏈為 `riscv64-zephyr-elf`。

v0.1.6 支援選擇 ITE 精簡封裝或全部平台封裝；兩種模式的 `app` 都只攜帶 Blinky sample code 與設定檔，不含建置產物。另修正 Windows PowerShell 5.1 長路徑處理與離線 Python requirements 的版本驗證。

所有 `.bat` 入口共用 `scripts/zephyr-manager.ps1`，必要步驟失敗時回傳 exit code 1；只有安裝及 Blinky 編譯都成功，才會顯示安裝完成。

四個 `.bat` 結束時都會顯示總執行時間，例如 `[TIME] Total elapsed: 00:12:34 (754.32 seconds)`。計時包含目錄詢問、安裝、打包、解壓縮或編譯，成功、失敗與取消都會顯示；不包含最後 `pause` 等待按鍵的時間。使用單調計時器，跨午夜或執行期間調整系統時間不影響結果，超過 24 小時仍顯示累計小時。原有退出碼會保留。

| 用途 | 入口 | 範例 |
| --- | --- | --- |
| 線上安裝並編譯 Blinky | `zephyr-easy-setup.bat` | `zephyr-easy-setup.bat -InstallDir D:\` |
| 將既有環境打包成離線封裝 | `zephyr-pack-offline.bat` | `zephyr-pack-offline.bat -InstallDir D:\` |
| 檢查已解壓縮的離線包 | `zephyr-offline-install.bat` | `zephyr-offline-install.bat -InstallDir D:\ -CheckOnly` |
| 安裝 7-Zip、解壓縮、離線安裝並編譯 Blinky | `zephyr-offline-install.bat` | `zephyr-offline-install.bat -BundlePath D:\zephyr-offline-bundle.7z -InstallDir D:\` |
| 確認後卸載，保留 app 與快取 | `zephyr-uninstall.bat` | `zephyr-uninstall.bat -InstallDir D:\` |

以上指令從完整專案資料夾執行；PowerShell 中請在 `.bat` 名稱前加上 `.\`。離線安裝會先安裝或辨識 7-Zip，再將完整離線 7z 封裝解壓縮到 `-InstallDir` 指定的位置。

## 系統需求

- Windows 10 / 11 **x64**，64 位元 Windows PowerShell 5.1。
- 專案、來源工作區與解壓縮路徑不含空白，例如 `D:\zephyr-easy-setup`。
- 使用 **Python 3.12 x64**；離線 wheels 固定給相同 Python 次版本與平台使用。
- 線上安裝與首次補齊離線安裝檔需要網路及支援 `winget download` 的 WinGet。
- 打包端需有可執行的 `7z.exe`；安裝檔、來源虛擬環境與 SDK 也會在打包前檢查。
- 需有容納來源、wheels、SDK、暫存副本及 7z 封裝的磁碟空間，通常為數 GB 以上。
- CMake、Git、7-Zip 安裝可能需要系統管理員權限；在乾淨目標電腦上可從系統管理員命令提示字元執行安裝。移除使用者環境設定時，請使用原安裝者的帳號。

## 一鍵線上安裝

```cmd
git clone https://github.com/richardjheng/zephyr-easy-setup.git
cd zephyr-easy-setup
zephyr-easy-setup.bat
```

請保留完整專案資料夾，入口需要同一資料夾下的 `scripts\zephyr-manager.ps1`。使用 Release ZIP 時，先完整解壓縮再執行；缺少共用腳本時會顯示路徑與錯誤，不會自動下載補齊。

啟動後會先詢問安裝根目錄，按 Enter 使用安裝腳本所在的專案資料夾。例如輸入 `D:\zephyr`，Zephyr 工作區會建立在 `D:\zephyr\zephyrproject`。也可以直接指定目錄，略過這個詢問：

```cmd
zephyr-easy-setup.bat -InstallDir D:\
```

在目前 checkout 的 PowerShell 中執行：

```powershell
Set-Location D:\github\zephyr-easy-setup
.\zephyr-easy-setup.bat -InstallDir D:\
```

四個 `.bat`、共用腳本、README 與測試都留在原專案資料夾，不會複製到安裝目錄。從原專案執行各入口，使用相同的 `-InstallDir` 指定要操作的安裝根目錄。現有 `zephyrproject\app` 會保留。

線上安裝未提供 `-InstallDir` 時會詢問安裝根目錄；打包、離線安裝與卸載未提供時，預設使用入口所在的專案資料夾，不會自動沿用上一次選擇。安裝在其他位置時，後續操作請明確指定該位置。

安裝根目錄可以是 `D:\zephyr` 等資料夾，也可以直接是磁碟根目錄 `D:\`。例如 `-InstallDir D:\` 的工作區就是 `D:\zephyrproject`；`-InstallDir D:\zephyr` 的工作區則是 `D:\zephyr\zephyrproject`。路徑不能包含空白或 junction / symlink。

安裝流程：安裝並檢查 Python、Git、CMake、7-Zip、Ninja、dtc、gperf；整理主機工具 PATH；啟用 Git 長路徑；建立 `zephyrproject\.venv`；安裝 west；執行 `west init`、`west update`；安裝 Zephyr 與模組 Python 依賴；下載指定 SDK 工具鏈；註冊 CMake；建立並編譯 `app\blinky`。

執行期間會將終端機與外部程式管線設為 UTF-8，處理 WinGet 中文輸出的亂碼；結束時恢復原本的終端機編碼。

SDK 使用 `west sdk install -b <workspace> -t <toolchain>`，安裝到 `zephyr-sdk-<version>` 子目錄。若 west 重用其他位置的既有 SDK，腳本會尋找並記錄該 SDK；卸載時只清理本專案內的 SDK。

主機工具目錄會補入使用者 PATH。日常開發時，SDK 與 `.venv` 的載入由使用者自行設定。

### 安裝位置

工作區固定在所選安裝根目錄的 `zephyrproject` 子目錄。未指定 `-InstallDir` 時先顯示目錄詢問；按 Enter 的預設值為安裝腳本所在的專案目錄，不隨啟動命令時的工作目錄改變。目前 checkout 的預設工作區是 `D:\github\zephyr-easy-setup\zephyrproject`；若選擇 `D:\zephyr`，配置如下：

```text
D:\zephyr\zephyrproject\
  zephyr\                    Zephyr 原始碼
  modules\                   west manifest 指定的相依模組
  .west\                     west 工作區設定
  .venv\                     Python 套件與 west
  zephyr-sdk-<version>\       新下載的 SDK 與目標工具鏈
  .zephyr-setup.json          板卡、qualifier、工具鏈與 SDK 位置
  app\blinky\                範例程式
  app\blinky\build\zephyr\   範例編譯輸出
```

相依倉庫的實際子目錄由所選 Zephyr 的 west manifest 決定。搬移工作區與快取到新的安裝根目錄後，從原專案各入口指定新的 `-InstallDir`。重用的外部 SDK 保留在原位置；設定檔的 `SdkDirectory` 對本工作區 SDK 使用相對路徑，對外部 SDK 使用絕對路徑。

Python、Git、CMake、7-Zip 等主機工具由 WinGet 安裝到各自的 Windows 安裝目錄，實際位置依套件與安裝範圍而定。離線安裝時，Ninja、dtc、gperf 則解壓縮到所選安裝根目錄的 `tools\<工具名稱>`，其可執行檔目錄會加入 PATH。

選擇磁碟根目錄時，例如 `-InstallDir D:\`，工作區位於 `D:\zephyrproject`，安裝快取位於 `D:\zephyr_installers`，打包輸出為 `D:\zephyr-offline-bundle.7z`。入口與文件仍留在原專案資料夾。此配置的離線 portable tools 放在 `D:\zephyrproject\.host-tools`，卸載只清理該工作區，不移除其他用途的 `D:\tools`。

### 自訂板卡、工具鏈與版本

```cmd
zephyr-easy-setup.bat [BOARD] [BOARD_QUALIFIER] [SDK_TOOLCHAIN] [ZEPHYR_REVISION]
zephyr-easy-setup.bat -InstallDir <DIRECTORY> [-Board <BOARD>] [-Qualifier <QUALIFIER>] [-Toolchain <TOOLCHAIN>] [-Revision <REVISION>]

zephyr-easy-setup.bat stm32f4_disco "" arm-zephyr-eabi
zephyr-easy-setup.bat it51xxx_evb it51xxx_evb/it51526aw riscv64-zephyr-elf v4.1.0
zephyr-easy-setup.bat -InstallDir D:\zephyr-arm -Board stm32f4_disco -Toolchain arm-zephyr-eabi
```

使用具名參數時，`-InstallDir` 放在批次檔參數的第一個位置。舊的板卡位置參數仍可使用，執行時會詢問安裝根目錄。若只要檢查所選安裝路徑，可以執行 `zephyr-easy-setup.bat -InstallDir D:\zephyr -CheckOnly`；它不複製檔案或安裝工具。

明確提供 BOARD 時，會先清除既有 qualifier；只有同時提供 QUALIFIER 才重新設定。未提供的板卡與工具鏈參數會沿用 `zephyrproject\.zephyr-setup.json`；沒有設定檔時才使用 ITE 預設值。該設定檔供後續離線打包及安裝使用。REVISION 只用於建立新工作區；若既有 `.west` 工作區仍傳入 REVISION，腳本會回報錯誤，不會切換版本。

建立新工作區時，未指定 `-Revision` 就使用 `west init` 的預設 manifest revision；若需要固定 Zephyr 版本，請在首次安裝時明確指定 tag 或 commit。

自動 SDK 安裝需要所選 Zephyr 提供 `west sdk`。對於沒有該指令的舊版本，先準備相容的 SDK，再使用共用 PowerShell 入口指定它：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts\zephyr-manager.ps1 -Mode Online -Revision v3.7.0 -SdkPath D:\sdk\zephyr-sdk-0.16.8
```

Blinky 需要板卡支援其 GPIO / LED 配置；不支援的板卡會回報驗證失敗。

## 日常開發

開發環境啟動腳本由使用者自行建立。請載入工作區的 `.venv`，依 `zephyrproject\.zephyr-setup.json` 中的 `SdkDirectory` 設定 SDK，並切換到工作區。SDK 的相對路徑以工作區為基準。環境設定完成後，常用指令：

```cmd
cd app\blinky
west build -p always -b it51xxx_evb/it51526aw
west build -t clean
```

安裝流程會在自己的 PowerShell 程序中補齊工具 PATH；啟用 `.venv` 只會載入 Python 環境。若新 terminal 顯示 `CMake is not installed or cannot be found`，請先將目前程序的 PATH 補入最新的機器與使用者 PATH：

```powershell
$env:Path += ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
cmake --version
```

VS Code 的新 terminal 可能繼承仍在執行的 VS Code 程序所保留的舊環境；可關閉所有 VS Code 視窗，再從開始功能表重新啟動。此情況也可用上述指令刷新目前 terminal，保留已啟用的 `.venv`。

PowerShell 也可以直接呼叫工作區的 Python，讀取已儲存的 SDK 與板卡設定。以下以 `-InstallDir D:\` 的安裝為例：

```powershell
$workspaceDir = 'D:\zephyrproject'
$env:Path += ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
# Drive-root offline installations keep portable host tools in this workspace.
if (Test-Path -LiteralPath "$workspaceDir\.host-tools") {
    Get-ChildItem -LiteralPath "$workspaceDir\.host-tools" -Recurse -File -Filter '*.exe' |
        Where-Object BaseName -In @('ninja', 'dtc', 'gperf') |
        ForEach-Object { $env:Path += ';' + $_.DirectoryName }
}
$settings = Get-Content -LiteralPath "$workspaceDir\.zephyr-setup.json" -Raw | ConvertFrom-Json
$sdkDir = $settings.SdkDirectory
if (-not [IO.Path]::IsPathRooted($sdkDir)) {
    $sdkDir = Join-Path $workspaceDir $sdkDir
}
$env:ZEPHYR_BASE = Join-Path $workspaceDir 'zephyr'
$env:ZEPHYR_TOOLCHAIN_VARIANT = 'zephyr'
$env:ZEPHYR_SDK_INSTALL_DIR = $sdkDir
$targetBoard = if ($settings.Qualifier) { $settings.Qualifier } else { $settings.Board }
Set-Location -LiteralPath "$workspaceDir\app\blinky"
& "$workspaceDir\.venv\Scripts\python.exe" -m west build -p always -b $targetBoard
```

## 打包目前已下載的環境

安裝完成後執行：

```cmd
zephyr-pack-offline.bat -InstallDir D:\
```

也可以直接從其他既有工作區打包，不必重新下載 Zephyr 程式碼或 SDK：

```cmd
zephyr-pack-offline.bat -InstallDir D:\ -SourceWorkspace D:\existing\zephyrproject -SdkPath D:\sdk\zephyr-sdk-0.17.0
```

`-SourceWorkspace` 指定要打包的來源，`-InstallDir` 指定快取、暫存目錄與輸出封裝的位置；兩者可不同。上例仍輸出到 `D:\zephyr-offline-bundle.7z`。

### ITE 精簡封裝與後續更新

打包預設使用 `-BundleProfile Ite`，保留全部 ITE 平台（it51xxx、it8xxx2、it82xx2）、RISC-V 與 Zephyr 共用核心。其他廠商的 board、SoC、架構與平台 DTS 不放進工作目錄；west 模組只保留明確列出的共用函式庫與 ITE HAL，SDK 只保留目前設定的 `riscv64-zephyr-elf` 工具鏈。篩選只修改打包暫存副本，不改動來源工作區。

共用 drivers、devicetree bindings、shields 與必要的 Kconfig 設定檔仍保留。例如 ITE 板上可能使用 TI 充電 IC 或 ST 感測器，這些周邊支援不能只依廠商名稱刪除。這是 ITE **平台**封裝，沒有針對單一 app 裁切到最少檔案；共用函式庫清單位於 `scripts/ite-bundle.py` 的 `SHARED_PROJECTS`，新增未列入的外部模組前需檢查依賴並更新清單。

封裝包含持續生效的設定：

| 操作 | ITE 封裝安裝後的行為 |
| --- | --- |
| `git fetch` | 下載 Git 物件，不展開其他平台的工作目錄檔案 |
| `git pull`／切換版本 | Zephyr 的 sparse checkout 規則繼續限制平台目錄，包括新加入的其他廠商目錄；衝突處理可能暫時展開檔案，處理後可執行 `git sparse-checkout reapply` |
| `west update`（不帶專案名稱） | `.west/config` 的 `manifest.project-filter` 只啟用封裝所選模組，其他廠商 HAL 不會自動重新下載 |

保留的 `.git` 歷史仍可能包含其他平台的物件，因此 sparse checkout **不會**把 Git 歷史中的其他廠商內容移除，也不保證減少後續 fetch 的下載量。要降低 Git 物件下載量需另外設計 partial clone；目前封裝保留既有 Git 歷史。手動關閉 sparse checkout、修改 west filter，或明確指定其他模組更新，都可能恢復其他平台資料。

若要保留全部平台、模組與工具鏈（例如打包非 ITE 平台），請明確指定；`app` 同樣只打包 Blinky sample code：

```cmd
zephyr-pack-offline.bat -InstallDir D:\ -BundleProfile Full
```

### 打包驗證與內容

來源必須包含 west 工作區（`.west`、Zephyr 與封裝 profile 要保留的模組 Git 倉庫）、Python 3.12 x64 的 `.venv`，以及已解壓縮且包含目標 GCC 的 SDK。SDK 不在工作區內或有多個候選版本時，可用 `-SdkPath` 明確指定。來源沒有設定檔時使用 ITE 預設值；其他板卡請加上 `-BundleProfile Full`、`-Board`、`-Qualifier`、`-Toolchain`。

Windows PowerShell 5.1 下，工作區內超過 260 字元的深層路徑可進行掃描、複製、雜湊驗證、7z 封裝及解壓縮驗證，並可清除打包暫存；不需要修改系統長路徑登錄設定。封裝清單仍使用可攜的相對路徑。

`Ite` 與 `Full` 模式的 `app` 都只打包來源 `app\blinky` 的 sample code 與設定檔，排除 `app\blinky\build`。其他 app、app 根目錄檔案及歷史建置／驗證資料皆不掃描、不複製，其中的 junction 也不會被跟隨。這只影響封裝內容，原始工作區完整保留，不需要額外的排除參數。來源沒有 `app\blinky` 時，離線安裝會沿用既有流程，從封裝內的 Zephyr Blinky sample 建立它。

打包會：

1. 讀取來源 `.venv` 的 `pip freeze --all`，固定目前實際套件版本並建立可直接安裝的 wheels。HTTP(S) 來源套件（例如 `reuse @ https://...`）會從原始 URL 建立 wheel，保留 URL 內的 hash 驗證；離線 requirements 改用已安裝版本，原始來源另存於 `requirements-source.txt`。只有原始碼的套件也會嘗試建立 wheel，可能需要額外的編譯工具。
2. 重用 `zephyr_installers\tools\<package-id>` 中符合副檔名的安裝檔；缺少時透過 WinGet 下載 x64 EXE、MSI 或 ZIP。每項工具都明確指定 `--installer-type`：Python 為 `burn`、Git 為 `inno`、CMake 為 `wix`、7-Zip 為 `exe`，其餘 portable tools 為 `zip`，與離線安裝流程一致；既有不同格式的檔案可保留，但不會當成所需安裝檔使用。這些主機工具下載沒有指定 `--version`，不保證與來源電腦已安裝的工具版本相同；Python 套件則固定來源 `.venv` 的實際版本。
3. 在乾淨的暫存 `.venv` 使用 `--no-index` 安裝全部固定版本、執行 `pip check`，並驗證 Zephyr / 模組 requirements。驗證使用暫存副本，將 HTTP(S) 套件引用改成來源環境的固定版本，避免 pip 在驗證時存取 URL。來源安裝紀錄有 URL 時必須符合該網址；一般版本安裝沒有 URL 紀錄時，使用 `pip freeze` 與離線清單一致的版本，並顯示提示，不宣稱與上游網址同源。原始 requirements 不會修改。
4. 依封裝 profile 複製程式碼、`.west`、`.git`、SDK 與安裝檔到暫存目錄，不加入本專案的入口、共用腳本、README 或測試。預設 ITE 模式排除其他 MCU 平台、HAL 與未使用的 SDK 工具鏈；`Full` 模式保留全部平台、模組與工具鏈。兩種模式皆排除來源 `.venv`，且 `app` 只複製 Blinky sample code 與設定檔，不含其 `build`。
5. 建立逐檔 SHA-256 的 `bundle-manifest.json`，使用離線安裝檔內的 `7z.exe` 製作並測試 `zephyr-offline-bundle.7z`，確保打包與配套安裝檔使用同一版本。成功後在專案資料夾輸出 `7zip-x64.exe` 與 `7zip-x64.json`，清除已包含在封裝內的 `zephyr_installers`，以及舊版留下、版本相符的 `zephyr-offline-bootstrap`。

打包採速度優先：7-Zip 使用 `a -t7z -mx=0`，以 Copy 模式直接將檔案存入 7z，不進行壓縮運算。7z 體積會接近所有打包檔案的總容量，但可省去壓縮與解壓縮運算；實際耗時仍取決於磁碟讀寫與檔案數量。來源驗證、暫存複製、逐檔 SHA-256 與 7z 完整性測試仍會執行。新設定只套用於重新啟動的打包流程，既有 ZIP 不會自動轉成 7z。

打包完成後，請將封裝與完整專案資料夾一起帶到離線電腦；專案資料夾需包含這次打包輸出的 7-Zip 安裝檔與雜湊資訊：

```text
D:\
  zephyr-offline-bundle.7z
  zephyr-easy-setup\
    zephyr-offline-install.bat
    scripts\
    7zip-x64.exe
    7zip-x64.json
```

打包會逐行顯示九個階段與百分比；階段比例不代表剩餘時間。掃描、複製、SHA-256 計算、壓縮及 7z 測試每十秒新增一行進度，階段開始與 7z 完成時立即顯示；不覆寫行首、不補滿整行空白，也不使用 PowerShell 浮動進度區塊。進度訊息依視窗寬度截短，使用原本底色，避免終端機折行、縮放或其他訊息輸出時互相覆蓋。掃描時顯示檔案數，複製時顯示已寫入容量、估計百分比與經過時間，SHA-256 計算顯示已完成檔案數。壓縮及 7z 測試擷取 7-Zip 百分比，只顯示進度條與經過時間，不顯示逐檔動作或檔名；警告、錯誤與失敗退出碼仍會回報。重新導向輸出採相同記錄頻率，不含游標控制字元。若系統無法提供複製程序的讀寫計數，仍會更新經過時間，百分比顯示為 `--%`。複製、壓縮與 7z 測試期間可按 Ctrl+C 中斷；腳本會結束此次啟動的外部程序並清理打包暫存目錄，大型暫存目錄的清理可能需要時間。已啟動的舊版流程不會套用腳本修改。

解壓縮同樣顯示 7-Zip 的整數百分比。大量小檔案寫入較慢，百分比可能長時間不變；經過時間持續增加本身不能證明解壓縮有進展。可從工作管理員／資源監視器確認 7-Zip 的讀寫量、CPU 與目的地新增檔案是否持續變化；若仍在變化，可讓程序繼續執行。解壓縮完成後還要驗證 SHA-256、安裝工具與 Python 套件、設定 SDK 並編譯 Blinky，才算完成整個離線安裝。

**已安裝的工具不等於仍保留安裝檔。** 若原電腦沒有 Python、Git 等離線安裝程式或缺少 wheels，首次打包需連網補齊。已有完整快取時，可讓 pip 下載使用 `--no-index`，並禁止下載缺少的主機工具安裝檔：

```cmd
zephyr-pack-offline.bat -InstallDir D:\ -CacheOnly
```

`-CacheOnly` 仍會驗證來源 `.venv` 與 Zephyr / 模組 requirements，並建立及測試封裝。快取不足時直接回報錯誤，不會自動改成連網下載。

快取的目錄格式如下，每個工具目錄應只有一個符合副檔名的安裝檔（WinGet 產生的 YAML 可以保留）：

```text
zephyr_installers/
  requirements-frozen.txt
  requirements-source.txt
  wheels/*.whl
  tools/Python.Python.3.12/*.exe
  tools/Git.Git/*.exe
  tools/Kitware.CMake/*.msi
  tools/7zip.7zip/*.exe
  tools/Ninja-build.Ninja/*.zip
  tools/oss-winget.gperf/*.zip
  tools/oss-winget.dtc/*.zip
```

wheel 無法取得或建立、SDK / 模組不完整、local / editable 或 VCS Python dependency、外部 Git objects、Git worktree 或保留內容中的 junction / symlink 都會中止打包，避免產生無法搬移的套件。`-CacheOnly` 只使用已建立的 wheels，不會存取套件的原始 URL。封裝內含 Blinky sample 的本地設定與保留倉庫的 Git 歷史，請依實際需求分享封裝。

### 打包後保留哪些目錄？

以 `-InstallDir D:\` 為例：

| 路徑 | 用途 | 打包結束後的處理 |
| --- | --- | --- |
| `D:\zephyr_installers` | 主機工具安裝檔、Python wheels 與固定版本 requirements | 成功發布封裝後，核對內容與封裝的 SHA-256，再刪除；打包失敗時保留以便重試 |
| `D:\offline_bundle\<隨機識別碼>` | 本次打包的驗證虛擬環境、工作區副本與暫存 7z 封裝 | 在清理階段刪除；失敗或可處理的取消也會執行清理 |
| `D:\offline_bundle` | 所有打包暫存子目錄的父目錄 | 此次建立且清空時刪除；原有檔案保留 |
| `D:\zephyr-offline-bundle.7z` | 已通過 7z 完整性測試的離線包 | 成功後保留；新 7z 通過測試才替換舊檔 |
| `D:\zephyr-offline-bootstrap` | 舊版流程留下的 7-Zip 安裝檔副本 | 不再產生；成功打包後清除版本相符且僅含 bootstrap 檔案的資料夾 |
| 專案資料夾的 `7zip-x64.exe`、`7zip-x64.json` | 與封裝一致的離線 7-Zip 安裝檔及雜湊資訊 | 保留，與完整專案一起帶到離線電腦 |

安裝檔、wheels 與 requirements 已包含在封裝內，成功打包後不另留 `zephyr_installers`。下次打包會重新取得這些檔案；若要使用 `-CacheOnly`，需先從既有封裝還原 `zephyr_installers`，或使用失敗打包留下的完整快取。清理若發現檔案在打包後變更，或 bootstrap 含其他檔案，會保留資料並回報錯誤。

若強制終止 PowerShell、關閉視窗或關機，清理可能來不及執行而留下暫存子目錄。手動移除前，請先確認沒有其他打包程序正在使用該目錄。

## 完全離線安裝

將完整專案資料夾另行帶到離線電腦，保留四個 `.bat`、`scripts`、`7zip-x64.exe` 與 `7zip-x64.json`。將 `zephyr-offline-bundle.7z` 放在目標安裝根目錄，例如 `D:\`，或放在專案資料夾。舊版封裝旁的 `zephyr-offline-bootstrap` 仍可用來安裝 7-Zip。**不用先手動解壓縮大型 7z 封裝**，從專案資料夾執行：

```cmd
zephyr-offline-install.bat -BundlePath D:\zephyr-offline-bundle.7z -InstallDir D:\
```

`-BundlePath` 指定 7z 或 ZIP 封裝路徑，`-InstallDir` 指定安裝根目錄；上例會解壓縮到 `D:\`，工作區位於 `D:\zephyrproject`。封裝路徑若包含空白，請加上引號。可加上 `-Board`、`-Qualifier`、`-Toolchain` 或 `-CheckOnly` 等選項；`-CheckOnly` 仍只檢查已解壓縮的離線包，不安裝工具或解壓縮。

省略 `-BundlePath` 時會自動尋找封裝，例如 `zephyr-offline-install.bat -InstallDir D:\`。優先尋找 `.7z`，也支援舊的 `zephyr-offline-bundle.zip`。

來源安裝位置與目標安裝位置可以不同。例如從 `D:\` 打包，再安裝到 `C:\`：

```cmd
zephyr-offline-install.bat -BundlePath D:\zephyr-offline-bundle.7z -InstallDir C:\
```

此時工作區位於 `C:\zephyrproject`；在新位置建立 `.venv`、從本地 wheels 安裝套件、重新註冊 Zephyr／SDK，再重新編譯 Blinky。SDK 設定使用相對於目標工作區的路徑，來源的 `.venv` 與 Blinky `build` 不會帶入，原本 `D:\` 的工作區仍保留。若封裝已搬到隨身碟，只要將 `-BundlePath` 改成實際位置即可。自訂的 `.vscode/settings.json`、腳本或其他設定若寫死來源磁碟路徑，仍需自行改成目標位置或專案相對路徑；安裝流程不會改寫這些使用者設定。

流程依序為：

1. 尋找離線封裝，顯示目的地路徑掃描、7-Zip 準備、manifest 讀取與完整性驗證階段。目的地用 .NET 掃描一次，顯示已檢查項目數；若未安裝 7-Zip，優先驗證並使用專案資料夾的 `7zip-x64.exe`，其次找封裝旁的同名安裝檔，最後找 `zephyr-offline-bootstrap`。ZIP 可在安裝前核對配套版本；7z 會在 7-Zip 可執行後、完整解壓縮前核對安裝檔與封裝內的 SHA-256。
2. 目的地已有工作區或 manifest 時，先依指定封裝的 manifest 檢查檔案與 SHA-256。內容完整且一致時，顯示 `skipping extraction` 並繼續安裝，不重複解壓縮或驗證，也不列出完整 7z 的所有路徑。需要補解壓縮時才檢查 7z 全部路徑，再解壓縮到 `-InstallDir`；解壓縮失敗或取消時停止，不繼續安裝其他套件。
3. 檢查解壓縮後的 manifest、逐檔 SHA-256 與必要檔案。
4. 安裝或辨識其他主機工具、解壓縮 portable tools、建立 `.venv`、從固定版本 wheels 安裝 Python 套件、註冊 Zephyr / SDK 並編譯 Blinky。

封裝預設先尋找 `-InstallDir` 與專案資料夾中的 `.7z`，再尋找同位置的舊 ZIP。使用 `zephyr-offline-bootstrap` 時，該資料夾必須與封裝放在一起。若封裝放在其他位置，可明確指定，封裝路徑可以包含空白：

```cmd
zephyr-offline-install.bat -BundlePath E:\offline\zephyr-offline-bundle.7z -InstallDir D:\zephyr
zephyr-offline-install.bat -BundlePath "E:\offline media\zephyr-offline-bundle.7z" -InstallDir D:\zephyr
```

目的地已有 `bundle-manifest.json` 且未指定 `-BundlePath` 時，直接使用已解壓縮的離線包。已安裝的 7-Zip 會重用；若手動解壓縮了舊版離線包，腳本會先驗證離線包，再從內部安裝檔安裝 7-Zip，最後安裝其他套件。

解壓縮會跳過目的地既有檔案，以保留使用者 app；若既有檔案與離線包雜湊不符，驗證會停止。明確指定 `-BundlePath` 時，會使用該封裝的 manifest；舊的 `bundle-manifest.json` 不會決定新封裝的驗證結果。完整目的地會跳過解壓縮，缺少檔案則補解壓縮。若目的地含有與離線包不同的檔案，請改用新的空目錄或先備份並處理差異。

若已有 Python 3.12 x64 的相容 `.venv`，會重用並安裝固定版本套件；不會自動刪除該環境。此流程不執行 `winget install`、`west update` 或 `west sdk install`，pip 使用 `--isolated --no-index`。

離線包已解壓縮後，可只檢查內容：

```cmd
zephyr-offline-install.bat -InstallDir D:\ -CheckOnly
```

`-CheckOnly` 檢查 manifest 格式、列出的檔案雜湊、必要工作區檔案、SDK 版本檔、wheels 是否存在及主機安裝檔清單；它不安裝 7-Zip、不解壓縮封裝，也不執行套件安裝、Python 相依性驗證、SDK 編譯器或 Blinky 編譯。僅有封裝而尚未解壓縮時，會回報需要先解壓縮，且不變更檔案。

兩個離線流程結束前會清理此次建立的暫存資料。打包在成功、失敗或取消時清除暫存工作區、驗證用 `.venv`、7-Zip 執行檔副本與未發布的封裝；若 `offline_bundle` 是此次建立且已空，也會刪除。成功發布後再清除 `zephyr_installers` 與舊的 bootstrap 副本，保留輸出封裝及專案資料夾的配套 7-Zip 安裝檔。離線安裝的清單與 manifest 檢查在記憶體中進行，不留下暫存檔；安裝解壓縮後的工作區及安裝檔會保留，解壓縮中斷後可用 `-BundlePath` 接續。

可用 `-Board`、`-Qualifier`、`-Toolchain` 覆寫目標；SDK 必須已包含對應工具鏈。例如：

```cmd
zephyr-offline-install.bat -InstallDir D:\ -Board stm32f4_disco -Toolchain arm-zephyr-eabi
```

安裝程式若要求重新啟動，腳本會停止，重啟後再執行。覆寫目標會更新設定檔，之後若要再次通過原 manifest 的雜湊檢查，需先備份變更，再將完整 封裝解壓縮到乾淨目錄；卸載後保留的 app 若仍與離線包一致，可使用 `-BundlePath` 補回其餘檔案。

### Release ZIP 與完整離線包

Release 的 `zephyr-easy-setup-v<version>.zip` 提供腳本、文件與測試。包含 Zephyr 原始碼、SDK、Python wheels 及主機工具安裝檔的 `zephyr-offline-bundle.7z`，需由 `zephyr-pack-offline.bat` 在完整來源環境中產生，輸出到所選安裝根目錄；例如 `-InstallDir D:\` 會輸出到 `D:\zephyr-offline-bundle.7z`。配套的 `7zip-x64.exe` 與 `7zip-x64.json` 會輸出到專案資料夾。

完整離線包只包含 manifest、安裝快取與工作區，不包含本專案的四個 `.bat`、`scripts`、README 或測試。離線電腦需要另外準備完整專案資料夾或解壓縮 Release 腳本 ZIP，並從該資料夾操作離線包。下方隔離測試指令適用於原始碼 checkout 或 Release 腳本 ZIP。

## 確認後卸載

```cmd
zephyr-uninstall.bat -InstallDir D:\
```

開始移除前會詢問：

```text
Remove this Zephyr installation? (y/N):
Also uninstall shared Python, Git, CMake, Ninja, dtc, gperf and 7-Zip? (y/N):
```

第一題只有 `y`（不分大小寫）會繼續；直接 Enter、N 或其他輸入都取消且不變更檔案。第二題預設保留共用工具；選 y 時使用 WinGet 移除列出的工具，可能影響其他開發專案，且需要目標電腦有可用的 WinGet。

卸載會保留所選工作區的 `zephyrproject\app` 原位，移除其餘工作區內容、本地 portable tools 與安裝根目錄的舊 `bundle-manifest.json`，只清理指向本工作區的使用者環境設定與 CMake 登錄。遇到 junction / symlink 會在刪除前停止。`zephyr_installers`、離線封裝、`zephyr-offline-bootstrap`、其他位置的工作區與 SDK 都保留。卸載失敗會回傳 exit code 1，不會顯示完整成功。

共用工具若沒有符合的 WinGet 已安裝套件，會顯示 `[SKIP]` 並繼續；這不代表手動安裝或其他位置的 portable 工具已被移除。真正的卸載錯誤仍會回傳失敗。

## 專案結構

下方資料目錄顯示預設安裝在專案資料夾的情況；指定其他 `-InstallDir` 時，安裝快取、portable tools、工作區與打包暫存目錄會放在所選安裝根目錄。

```text
zephyr-easy-setup/
  zephyr-easy-setup.bat       線上安裝
  zephyr-pack-offline.bat     打包來源工作區
  zephyr-offline-install.bat  離線安裝
  zephyr-uninstall.bat        確認後卸載
  scripts/zephyr-manager.ps1  共用流程與錯誤檢查
  scripts/ite-bundle.py       ITE 平台／模組篩選與 sparse checkout 設定
  tests/verify-workflows.ps1  隔離驗證
  tests/verify-launcher-timing.ps1  四個入口的執行時間與退出碼驗證
  tests/verify-offline-bootstrap.ps1  7-Zip 安裝順序與離線解壓縮驗證
  tests/verify-pack-archive.ps1   7z 整合驗證
  tests/verify-pack-cleanup.ps1   7z 發布、配套版本與暫存清理驗證
  tests/verify-pack-progress.ps1  打包進度與取消驗證
  tests/verify-long-paths.ps1  Windows PowerShell 5.1 長路徑完整流程驗證
  tests/verify-ite-bundle.py   ITE 篩選及 Git／west 後續更新驗證
  tests/verify-pack-terminal.ps1  終端機進度顯示驗證
  tests/verify-uninstall-tools.ps1  共用工具卸載回傳碼驗證
  zephyr_installers/          離線安裝快取（Git 忽略）
  offline_bundle/            打包暫存（Git 忽略）
  zephyr-offline-bootstrap/   離線 7-Zip 安裝檔與雜湊資訊（Git 忽略）
  tools/                     portable tools（Git 忽略）
  zephyrproject/             工作區（Git 忽略）
```

## 驗證

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-workflows.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-launcher-timing.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-offline-bootstrap.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-pack-archive.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-pack-cleanup.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-pack-progress.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-long-paths.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-pack-terminal.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\verify-uninstall-tools.ps1
```

ITE 平台篩選與後續更新測試使用已安裝 west 的 Python 環境，例如：

```cmd
D:\zephyrproject\.venv\Scripts\python.exe tests\verify-ite-bundle.py
```

測試以本機 Git 倉庫驗證平台／模組篩選、共用周邊保留、本地修改保留、fetch 後合併新版本仍排除其他廠商平台，以及 west update 只更新所選模組，不連網或修改原安裝。

測試使用專案內的暫存資料，涵蓋取消卸載、保留 app、限制刪除範圍、拒絕 junction、保留隱藏 metadata、SHA-256 / 安裝檔檢查、各入口的 `-InstallDir` 與錯誤碼、磁碟根目錄選擇、中文 UTF-8 外部程式輸出，以及編譯失敗處理。編譯結果處理使用 native stub，未執行實際 Zephyr 編譯；測試不安裝／移除系統工具，也不寫入使用者登錄。

`verify-launcher-timing.ps1` 以延遲的共用腳本模擬流程，驗證四個批次入口在成功、失敗、取消與缺少腳本時顯示總耗時，並保留原本的退出碼，不執行實際安裝或卸載。

`verify-pack-archive.ps1` 需要已安裝 7-Zip，會實際壓縮、檢查及解壓縮小型測試封裝，驗證檔案內容、隱藏檔、空目錄與錯誤回報；另以 native stub 驗證即時進度、跨次讀取的百分比、警告輸出與取消清理。

`verify-offline-bootstrap.ps1` 需要可執行的 7-Zip，會實際解壓縮小型 7z 與 ZIP；系統安裝以 stub 模擬。驗證本地安裝檔與封裝版本一致、7-Zip 安裝順序、bootstrap 雜湊、自動尋找、既有 app 保留及錯誤處理，不會真的安裝系統工具。

`verify-pack-cleanup.ps1` 需要可執行的 7-Zip 與專案目錄中的 `7zip-x64.exe`。模擬 Python 驗證，實際使用安裝檔內的 7-Zip 製作小型 7z，驗證 app 只包含 Blinky 原始碼與設定、不含其他 app／循環 junction／建置產物，並驗證成功、失敗與取消時清除暫存，保留已發布封裝和原有檔案。

`verify-pack-progress.ps1` 驗證掃描與雜湊結果、複製進度、無法取得 I/O 計數時的顯示，以及取消後結束本次外部程序；可處理的打包取消會回傳 exit code 130。`verify-pack-terminal.ps1` 驗證完整換行、窄視窗截短、視窗縮放和一般訊息交錯時的排列、保留終端機顏色、立即顯示完成百分比，以及一般終端機與重新導向輸出的記錄頻率。

`verify-long-paths.ps1` 需要已安裝 7-Zip，在超過 350 字元的測試路徑實際驗證掃描與排除、Robocopy、SHA-256、7z 封裝與解壓縮、損毀偵測、唯讀檔案清理，以及來源保留與路徑越界拒絕；也驗證明確排除含 junction 的 app 歷史目錄時，不複製該目錄且保留連結目標，未排除的連結仍會被拒絕。測試只操作專案內的暫存資料。

完整驗收還需要：在線上機器完成安裝及編譯、產生 7z 封裝，再於沒有相關工具且斷網的 Windows x64 機器解壓縮安裝與編譯。隔離測試通過不代表上述完整驗收已完成。

自動化執行時，可設定 `ZEPHYR_NO_PAUSE=1` 省略批次檔最後的 pause；線上安裝請同時指定 `-InstallDir` 以略過目錄詢問。卸載的 y/N 確認仍會保留。

參考：[Zephyr Getting Started](https://docs.zephyrproject.org/latest/develop/getting_started/)、[WinGet download](https://learn.microsoft.com/windows/package-manager/winget/download)、[SDK 安裝參數定義](https://github.com/zephyrproject-rtos/zephyr/blob/main/scripts/west_commands/sdk.py)。
