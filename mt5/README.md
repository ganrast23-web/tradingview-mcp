# MT5 Expert Advisor — Grid Straddle TP/SL

`Experts/GridStraddleTPSL.mq5`

EA MetaTrader 5 yang mereplikasi pola grid dari video referensi (XAUUSD M1): deretan
**Buy Stop** di atas harga dan **Sell Stop** di bawah harga, lot tetap 0.01 per level,
dengan tambahan **Take Profit & Stop Loss** per order plus **basket profit target**.

## Yang terlihat di video referensi

Dari panel *Trade* di video:

| Sisi | Harga pending | Jarak |
|------|---------------|-------|
| Buy Stop | 4219.86 · 4220.16 · 4220.46 · … · 4222.86 | 0.30 (= 30 point) |
| Sell Stop | 4219.16 · 4218.86 · 4218.56 · 4218.26 | 0.30 (= 30 point) |

- Lot 0.01 tiap level, ~11 level per sisi
- Celah antara Buy Stop terendah dan Sell Stop tertinggi ≈ 0.70
- Semua posisi ditutup bersamaan saat total profit mencapai **+10 $**

Nilai default EA ini disetel mengikuti angka tersebut (`InpStepPoints = 30`,
`InpFirstOffsetPoints = 35`, `InpLot = 0.01`, `InpBasketTargetMoney = 10`).

## Instalasi

1. Buka MetaTrader 5 → **File › Open Data Folder**
2. Salin `GridStraddleTPSL.mq5` ke `MQL5/Experts/`
3. Buka MetaEditor (F4) → pilih file → **Compile** (F7)
4. Kembali ke MT5, refresh Navigator, drag EA ke chart **XAUUSD M1**
5. Aktifkan **AutoTrading** dan centang *Allow Algo Trading* di dialog EA

## Cara kerja

1. Saat tidak ada posisi maupun pending, EA membangun grid: `InpLevels` Buy Stop di atas
   harga Ask dan `InpLevels` Sell Stop di bawah harga Bid, jarak antar level
   `InpStepPoints`, level pertama berjarak `InpFirstOffsetPoints` dari harga.
2. Tiap pending order dipasang lengkap dengan TP (`InpTakeProfitPoints`) dan SL
   (`InpStopLossPoints`) sehingga setiap posisi punya exit sendiri.
3. Saat harga bergerak, pending order tereksekusi menjadi posisi.
4. Total floating P/L semua posisi dipantau tiap detik:
   - `>= InpBasketTargetMoney` → tutup semua posisi + hapus semua pending
   - `<= -InpBasketMaxLossMoney` → tutup semua (proteksi)
   - equity turun `InpEquityStopPercent` % dari balance → tutup semua + hentikan EA
5. Setelah siklus ditutup, EA menunggu `InpRebuildDelaySec` detik lalu membangun grid baru
   di sekitar harga terkini (bila `InpAutoRebuild = true`).

## Parameter

### Umum
| Parameter | Default | Keterangan |
|---|---|---|
| `InpMagic` | 20250610 | Magic number, pisahkan bila menjalankan >1 EA |
| `InpComment` | GridTPSL | Komentar order |
| `InpSlippagePoints` | 30 | Slippage maksimum |

### Struktur grid
| Parameter | Default | Keterangan |
|---|---|---|
| `InpGridMode` | Dua arah | Buy+Sell / Buy saja / Sell saja |
| `InpLevels` | 10 | Jumlah level per sisi |
| `InpStepPoints` | 30 | Jarak antar level (point) |
| `InpFirstOffsetPoints` | 35 | Jarak level pertama dari harga |
| `InpAutoRebuild` | true | Bangun ulang grid setelah siklus selesai |
| `InpRebuildDelaySec` | 5 | Jeda sebelum grid baru |
| `InpDeleteOrdersOnDeinit` | false | Hapus pending saat EA dilepas dari chart |

### Lot
| Parameter | Default | Keterangan |
|---|---|---|
| `InpLot` | 0.01 | Lot level pertama |
| `InpLotMultiplier` | 1.0 | Pengali lot tiap level (1.0 = flat, seperti di video) |
| `InpMaxLot` | 1.0 | Batas atas lot per order |

### Take Profit / Stop Loss
| Parameter | Default | Keterangan |
|---|---|---|
| `InpTakeProfitPoints` | 200 | TP per order dalam point (0 = tanpa TP) |
| `InpStopLossPoints` | 400 | SL per order dalam point (0 = tanpa SL) |

### Trailing stop
| Parameter | Default | Keterangan |
|---|---|---|
| `InpUseTrailing` | false | Aktifkan trailing |
| `InpTrailStartPoints` | 150 | Profit minimum sebelum trailing jalan |
| `InpTrailDistPoints` | 100 | Jarak SL dari harga |
| `InpTrailStepPoints` | 20 | Langkah minimum penggeseran SL |

### Proteksi basket
| Parameter | Default | Keterangan |
|---|---|---|
| `InpUseBasketTP` | true | Tutup semua saat target profit |
| `InpBasketTargetMoney` | 10.0 | Target profit total (sesuai video: +10 $) |
| `InpUseBasketSL` | true | Tutup semua saat rugi basket |
| `InpBasketMaxLossMoney` | 100.0 | Batas rugi total |
| `InpUseEquityStop` | true | Equity stop |
| `InpEquityStopPercent` | 20.0 | Drawdown maksimum dari balance (%) |
| `InpStopAfterLoss` | false | Hentikan EA setelah basket SL kena |

### Filter
| Parameter | Default | Keterangan |
|---|---|---|
| `InpMaxSpreadPoints` | 50 | Grid tidak dipasang bila spread lebih lebar (0 = abaikan) |
| `InpMaxPositions` | 40 | Batas posisi terbuka (peringatan bila level melebihi) |
| `InpUseTimeFilter` | false | Filter jam server |
| `InpStartHour` / `InpEndHour` | 1 / 23 | Rentang jam (boleh melewati tengah malam) |
| `InpCloseAllFriday` | false | Tutup semua di akhir Jumat |
| `InpFridayCloseHour` | 21 | Jam tutup Jumat |
| `InpShowPanel` | true | Panel info di pojok chart |

## Konversi point

Semua jarak dinyatakan dalam **point** (satuan digit terakhir harga), bukan pip.

| Simbol | Digits | 1 point | 30 point |
|---|---|---|---|
| XAUUSD | 2 | 0.01 | 0.30 |
| XAUUSD | 3 | 0.001 | 0.030 |
| EURUSD | 5 | 0.00001 | 0.00030 (3 pip) |

Kalau broker Anda memakai XAUUSD 3 digit, kalikan semua nilai point dengan 10
(`InpStepPoints = 300`, `InpFirstOffsetPoints = 350`, `InpTakeProfitPoints = 2000`, dst).

Nilai uang di XAUUSD (contract 100 oz): lot 0.01 → 1 point ≈ 0.01 $, jadi TP 200 point
≈ 2 $ per posisi.

## Peringatan risiko

Ini strategi **grid/hedging tanpa arah**. Karakteristiknya:

- Saat harga sideways di dalam grid, posisi buy dan sell menumpuk berlawanan dan
  floating loss bisa membengkak lebih cepat daripada akumulasi target 10 $.
- Beberapa broker tidak mengizinkan hedging (akun netting) — di akun netting, buy dan
  sell akan saling menutup dan perilaku EA berbeda total.
- Wajib pakai `InpUseBasketSL` dan `InpUseEquityStop`. Jangan matikan keduanya.
- Uji dulu di **Strategy Tester** (mode *Every tick based on real ticks*) dan lanjut ke
  **akun demo** minimal beberapa minggu sebelum dipakai di akun real.
- Saldo di video (1 070 $) dengan grid 0.01 × 22 order termasuk sangat agresif untuk emas.

Tidak ada jaminan hasil. Gunakan atas risiko sendiri.
