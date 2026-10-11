# m30bridge

[English](README.md)

**8BitDo M30 Wired Controller for Xbox**(USB `2dc8:200a`)を、macOS上で仮想HIDゲームパッドとして使えるようにするアプリです。このコントローラーにはmacOSのネイティブドライバがないため、USBプロトコルを解析し、エミュレータやゲームから見える標準的なゲームパッドとして再公開します。

## 仕組み

macOS上でlibusbから直接読むと、定期的な「ハートビート」レポートしか届かず、本物のボタン状態が取得できません(同じコードがLinuxでは即座に動くため、macOS側の事情と思われますが、根本原因は未解明です)。そこで回避策として、USBの生データ読み取りをLinux VM側で行い、デコードした状態をUDPでMacへ転送しています。

```
M30 (USB) -> Linux VM (UTM)                         macOS
             m30_udp_sender.py  --- UDP / JSON --->  m30bridge (Swiftアプリ)
             (libusb1, デコード,    port 9999        IOHIDUserDevice
              初期化ハンドシェイク)                    -> 仮想ゲームパッド
```

- **`m30bridge`(Swift/SwiftUIアプリ)**: UDP 9999番で待ち受け、受信した状態からHIDレポートを作り、`IOHIDUserDeviceCreateWithProperties` / `IOHIDUserDeviceHandleReportWithTimeStamp` で送出します。
- **`m30_udp_sender.py`(Linux VM内で実行)**: libusb1の連続再投入型interrupt転送でコントローラーを読み、36バイトのレポートをデコードして、変化があるたびJSONで送信します。

## 必要なもの

- Apple Developer Programに加入しているMac(Apple Silicon / Intel)
- 制限付きentitlement **`com.apple.developer.hid.virtual.device`**。Appleへの申請と承認が必要です(Developer Portal → Identifiers → 対象のApp ID → Capability Requests → HID Virtual Device)
- Xcode。このentitlementはprovisioning profileが必要なため、**アプリターゲット**としてビルドする必要があります(SwiftPMの素の実行ファイルでは付与できず、起動時にkillされます)
- USBパススルーできるLinux VM(例: UTM + Ubuntu)、`python3`、`libusb1`(`pip install libusb1`)

## ビルドと実行(Mac側)

1. Xcodeでプロジェクトを開き、自分のTeamとBundle Identifierを設定します。
2. Signing & Capabilitiesで **HID Virtual Device** を追加します(Appleの承認後に選べるようになります)。**App Sandbox** は外すか、*Incoming Connections (Server)* を有効にしてください。そうしないとUDPポートの `bind()` が `Operation not permitted` で失敗します。
3. 実行すると、コンソールに次のように表示されます。
   ```
   Creating virtual HID gamepad device...
   Virtual device created and activated. It should now be visible to the system.
   Listening on UDP port 9999. Ctrl+C to stop.
   ```
4. OpenEmuなどのアプリで **8BitDo M30 (bridged)** という名前の入力デバイスとして見えます。

補足: 手元の検証では、物理コントローラーを接続していない状態だと仮想デバイスの作成が失敗し(`IOServiceOpen` エラー、`IOHIDUserDeviceCreateWithProperties returned NULL`)、接続してから実行すると成功しました。

## 送信側の実行(Linux VM)

1. M30をVMにパススルーします(UTMならUSBメニューから)。
2. root権限で実行します(カーネルの`xpad`ドライバはスクリプト側でデタッチします)。
   ```
   sudo python3 m30_udp_sender.py --host 192.168.64.1 --port 9999
   ```
   `192.168.64.1` はUTMの共有ネットワークでの通常のMacのアドレスです。VM内で `ip route | grep default` で確認できます。
3. 起動時に初期化ハンドシェイク(後述)を送信し、`Sent init/LED handshake.` と表示されます。これでコントローラー中央のLEDが点滅から固定点灯に変わります。

## UDPメッセージ形式

```json
{"type": "gamepad", "buttons": ["A", "dpad_up"], "trigA": 0, "trigB": 0, "axisX": 0, "axisY": 0}
{"type": "guide", "pressed": true}
```

ボタン名: `A B X Y menu view dpad_up dpad_down dpad_left dpad_right shoulder_bit4 shoulder_bit5`。`trigA` / `trigB` は16bit符号なしのトリガー値、`axisX` / `axisY` は16bit符号付きの十字キーのアナログ値です。

## デバイスについて分かったこと

- ベンダー固有のUSBクラス(`0xFF / 0x47 / 0xD0`)。Xbox 360系ですが、レポートの構造は独自です。インターフェース0のエンドポイントは `0x81` IN と `0x01 OUT`(interrupt、64バイト)です。
- メインの入力レポートは `20 00` で始まる36バイト。Xbox(ガイド)ボタンは別の6バイトのレポートで届きます。
- 列挙の直後、Linuxの`xpad`ドライバがエンドポイント`0x01`へinterrupt OUTレポートを3つ送ります(usbmonで取得)。これを再現するとLEDが固定点灯になります。
  ```
  05 20 00 01 00
  0a 20 01 03 00 01 14
  06 20 02 02 01 00
  ```
- 背面スイッチを左にするとLSB/RSBは反応しません。スイッチ位置によって使われるビットが変わります。
- Linuxでは、`/dev/input/js0` を何かが開くまで`xpad`はデバイスをポーリングしません。

## 制限と今後

- 現状はLinux VMが必須です。libusbではなくIOKit(`IOUSBHost`)でmacOS上から直接読む方法は未検証です。
- ガイドボタンの転送や、トリガー/軸のスケーリングには改善の余地があります。
- 入力は通常のOSのHID経路を通るため、タイミングは決定論的ではありません。フレーム単位で正確なTAS的再生には向きません。

## ライセンス

MIT
