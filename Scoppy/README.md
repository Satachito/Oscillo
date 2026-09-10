# PiLyzer for PL2407AFE

購入したpicoLABO **PL2407AFE + Raspberry Pi Pico 2** 用のPiLyzer構成です。
ScoppyのAndroidアプリやファームウェアのコピーではありません。基板のAFEを利用し、PiLyzerのmacOS／Webアプリで測定します。

## 構成

- `firmware/board_config.h`: PL2407AFE専用GPIO・2ch・3レンジ換算値（board ID 3）。
- `firmware/build.sh`: 共通PiLyzerファームウェアをこの基板用にビルド。
- `Web/`: `../Pico2/Web`へのリンク。同じWebUSBアプリを使用。
- macOS: `../Pico2`のアプリを使用。入力レンジ記述子に対応した最新版が必要です。`cd ../Pico2 && ./Scripts/make-app.sh`でビルド。

アプリは接続したファームウェアから2ch・3レンジを取得します。Webのテスト出力ピン表示はboard IDで選択します。既存Pico2用ファームウェアのビルド設定は変わりません。

## ビルドと書き込み

```sh
./Scoppy/firmware/build.sh
```

出力: `Scoppy/firmware/build/PiLyzer-PL2407AFE-Pico2.uf2`

Pico 2をBOOTSELで接続し、このUF2をコピーします。元のScoppyファームウェアは置き換わります。Scoppy Androidアプリへ戻す場合はScoppy用UF2を書き戻します。
このビルドはRP2350のPico 2用です。初代Pico/RP2040用ではありません。

## 配線・制御

| 機能 | GPIO |
|---|---|
| CH1 / CH2 | 26 / 27 |
| CH1レンジ制御 | 2, 3 |
| CH2レンジ制御 | 4, 5 |
| Logic D0–D7 | 6–13 |
| SG OUT | 22（基板上1kΩ経由） |

CH3のAFEはありません。AC/DCは基板上スイッチで操作します。
各CHの制御ピンをA/Bとすると、±30Vは00、±6Vは01、±1.5Vは10です。
レンジ切替時には一旦00に戻し、両方のバイパスを同時に有効にしません。

## 電圧換算と検証状況

[メーカー回路図・説明](https://picolabo.org/pl2407afe/)のrev.1cを基準にしています。
rev.1dはメーカー説明上仕様変更なしですが、届いた基板のリビジョンと実測は未確認です。

公称抵抗値からのDC計算（アナログスイッチのオン抵抗・部品誤差は未補正）:

- 初段反転増幅器の利得は−0.1。
- 後段の基準電圧は `3.3 × 1 / 25 = 0.132 V`。
- レンジ別の直列抵抗Rsは24230 / 4230 / 330 Ω。
- `gain = 1.2 / (1 + Rs/1000 + Rs/10000)`。
- `offset = 13×0.132 − 12×(0.132/10000)/(1/Rs + 1/1000 + 1/10000)`。
- `Vinput = (Vadc − offset) / gain`。

ADC電源基準とAFE電源の差、抵抗誤差、スイッチ抵抗があるため、到着後に各CH・各レンジで0Vと既知電圧を確認し校正します。最初はDC結合・±30VレンジでGND、続いて既知の小さい信号を確認してください。
AFEの帯域はADCサンプリング速度とは別です。このファームウェアはADCをオーバークロックせず、1ch約495kSa/s、2ch約247kSa/sです。

USB実機での測定・レンジ切替・校正は基板到着後に実施します。

## 自動チェック

`./Scoppy/tests/run.sh`でGPIO・各レンジのADC範囲・2ch取得とCH3拒否を検証します。共通ファームウェアの回帰テストは`./Pico2/firmware/pilyzer/tests/run.sh`です。
