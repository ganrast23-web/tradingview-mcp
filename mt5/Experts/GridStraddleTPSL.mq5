//+------------------------------------------------------------------+
//|                                          GridStraddleTPSL.mq5    |
//|                                                                  |
//|  Grid Straddle EA (Buy Stop + Sell Stop ladder) untuk MetaTrader5|
//|                                                                  |
//|  Cara kerja:                                                     |
//|   1. EA memasang deretan pending order BUY STOP di atas harga    |
//|      dan SELL STOP di bawah harga, dengan jarak tetap (step).    |
//|   2. Setiap order punya Take Profit dan Stop Loss sendiri.       |
//|   3. Selain TP/SL per order, ada Basket Target (total profit     |
//|      semua posisi) dan Basket Stop Loss / Equity Stop.           |
//|   4. Saat basket target/SL tercapai -> semua posisi ditutup,     |
//|      semua pending dihapus, lalu grid dibangun ulang.            |
//|                                                                  |
//|  Catatan point: XAUUSD 2 desimal -> 1 point = 0.01               |
//|                 jadi step 30 point = 0.30 harga emas.            |
//+------------------------------------------------------------------+
#property copyright "TradingView MCP - MT5 tools"
#property link      "https://github.com/ganrast23-web/tradingview-mcp"
#property version   "1.00"
#property description "Grid straddle EA: ladder Buy Stop + Sell Stop dengan TP/SL per order dan basket profit target."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Enum                                                             |
//+------------------------------------------------------------------+
enum ENUM_GRID_MODE
  {
   GRID_BOTH = 0,   // Dua arah (Buy Stop + Sell Stop)
   GRID_BUY  = 1,   // Buy Stop saja
   GRID_SELL = 2    // Sell Stop saja
  };

//+------------------------------------------------------------------+
//| Input - Umum                                                     |
//+------------------------------------------------------------------+
input long   InpMagic               = 20250610;   // Magic number
input string InpComment             = "GridTPSL"; // Komentar order
input int    InpSlippagePoints      = 30;         // Slippage (point)

//--- Struktur grid ---------------------------------------------------
input ENUM_GRID_MODE InpGridMode    = GRID_BOTH;  // Mode grid
input int    InpLevels              = 10;         // Jumlah level per sisi
input int    InpStepPoints          = 30;         // Jarak antar level (point)
input int    InpFirstOffsetPoints   = 35;         // Jarak level pertama dari harga (point)
input bool   InpAutoRebuild         = true;       // Bangun ulang grid tiap siklus selesai
input int    InpRebuildDelaySec     = 5;          // Jeda sebelum bangun ulang (detik)
input bool   InpDeleteOrdersOnDeinit= false;      // Hapus pending saat EA dilepas

//--- Lot -------------------------------------------------------------
input double InpLot                 = 0.01;       // Lot per level
input double InpLotMultiplier       = 1.0;        // Pengali lot per level (1.0 = tetap)
input double InpMaxLot              = 1.0;        // Batas lot maksimum per order

//--- Take Profit / Stop Loss per order -------------------------------
input int    InpTakeProfitPoints    = 200;        // Take Profit per order (point, 0 = off)
input int    InpStopLossPoints      = 400;        // Stop Loss per order (point, 0 = off)

//--- Trailing stop ---------------------------------------------------
input bool   InpUseTrailing         = false;      // Aktifkan trailing stop
input int    InpTrailStartPoints    = 150;        // Mulai trailing setelah profit (point)
input int    InpTrailDistPoints     = 100;        // Jarak trailing dari harga (point)
input int    InpTrailStepPoints     = 20;         // Langkah minimum geser SL (point)

//--- Proteksi basket -------------------------------------------------
input bool   InpUseBasketTP         = true;       // Tutup semua saat target profit
input double InpBasketTargetMoney   = 10.0;       // Target profit basket (mata uang akun)
input bool   InpUseBasketSL         = true;       // Tutup semua saat rugi basket
input double InpBasketMaxLossMoney  = 100.0;      // Maksimum rugi basket (mata uang akun)
input bool   InpUseEquityStop       = true;       // Aktifkan equity stop
input double InpEquityStopPercent   = 20.0;       // Equity stop (% drawdown dari balance)
input bool   InpStopAfterLoss       = false;      // Hentikan EA setelah basket SL kena

//--- Filter ----------------------------------------------------------
input int    InpMaxSpreadPoints     = 50;         // Spread maksimum (point, 0 = abaikan)
input int    InpMaxPositions        = 40;         // Maksimum posisi terbuka
input bool   InpUseTimeFilter       = false;      // Aktifkan filter jam
input int    InpStartHour           = 1;          // Jam mulai (server)
input int    InpEndHour             = 23;         // Jam selesai (server)
input bool   InpCloseAllFriday      = false;      // Tutup semua hari Jumat
input int    InpFridayCloseHour     = 21;         // Jam tutup Jumat (server)
input bool   InpShowPanel           = true;       // Tampilkan panel info di chart

//+------------------------------------------------------------------+
//| Global                                                           |
//+------------------------------------------------------------------+
CTrade   g_trade;
double   g_point      = 0.0;
int      g_digits     = 0;
double   g_volStep    = 0.01;
double   g_volMin     = 0.01;
double   g_volMax     = 100.0;
int      g_volDigits  = 2;
bool     g_halted     = false;      // EA dihentikan (setelah basket SL)
datetime g_nextBuild  = 0;          // waktu paling awal boleh membangun grid
datetime g_lastTick   = 0;          // throttle: proses berat 1x per detik
int      g_cycles     = 0;          // jumlah siklus grid selesai
double   g_realized   = 0.0;        // akumulasi profit siklus yang ditutup EA
bool     g_gridBuilt  = false;      // grid pernah dibangun pada sesi ini

//+------------------------------------------------------------------+
//| Helper: hitung jumlah desimal dari volume step                   |
//+------------------------------------------------------------------+
int VolumeDigits(const double step)
  {
   double s = step;
   int    d = 0;
   while(d < 8 && MathAbs(s - MathRound(s)) > 1e-9)
     {
      s *= 10.0;
      d++;
     }
   return d;
  }

//+------------------------------------------------------------------+
//| Helper: normalisasi lot sesuai spesifikasi simbol                |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
  {
   if(g_volStep <= 0.0)
      return NormalizeDouble(lot, 2);

   lot = MathFloor(lot / g_volStep + 1e-9) * g_volStep;

   if(InpMaxLot > 0.0 && lot > InpMaxLot)
      lot = InpMaxLot;
   if(lot > g_volMax)
      lot = g_volMax;
   if(lot < g_volMin)
      lot = g_volMin;

   return NormalizeDouble(lot, g_volDigits);
  }

//+------------------------------------------------------------------+
//| Helper: jarak minimum stop/pending yang diizinkan broker (point) |
//+------------------------------------------------------------------+
int MinStopDistance()
  {
   int stopLevel   = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freezeLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(stopLevel, freezeLevel);
  }

//+------------------------------------------------------------------+
//| Helper: spread saat ini dalam point                              |
//+------------------------------------------------------------------+
int CurrentSpread()
  {
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
  }

//+------------------------------------------------------------------+
//| Helper: hitung posisi milik EA ini                               |
//+------------------------------------------------------------------+
int CountPositions()
  {
   int total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      total++;
     }
   return total;
  }

//+------------------------------------------------------------------+
//| Helper: hitung pending order milik EA ini                        |
//+------------------------------------------------------------------+
int CountPendings()
  {
   int total = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      total++;
     }
   return total;
  }

//+------------------------------------------------------------------+
//| Helper: total floating P/L basket (profit + swap)                |
//+------------------------------------------------------------------+
double BasketProfit()
  {
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return profit;
  }

//+------------------------------------------------------------------+
//| Tutup semua posisi milik EA                                      |
//+------------------------------------------------------------------+
int CloseAllPositions()
  {
   int closed = 0;
   for(int attempt = 0; attempt < 3; attempt++)
     {
      bool again = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
            continue;

         if(g_trade.PositionClose(ticket, (ulong)InpSlippagePoints))
            closed++;
         else
           {
            again = true;
            PrintFormat("Gagal menutup posisi #%I64u: %d - %s",
                        ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
           }
        }
      if(!again)
         break;
      Sleep(200);
     }
   return closed;
  }

//+------------------------------------------------------------------+
//| Hapus semua pending order milik EA                               |
//+------------------------------------------------------------------+
int DeleteAllPendings()
  {
   int deleted = 0;
   for(int attempt = 0; attempt < 3; attempt++)
     {
      bool again = false;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0)
            continue;
         if(OrderGetString(ORDER_SYMBOL) != _Symbol)
            continue;
         if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
            continue;

         if(g_trade.OrderDelete(ticket))
            deleted++;
         else
           {
            again = true;
            PrintFormat("Gagal menghapus pending #%I64u: %d - %s",
                        ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
           }
        }
      if(!again)
         break;
      Sleep(200);
     }
   return deleted;
  }

//+------------------------------------------------------------------+
//| Tutup satu siklus penuh (posisi + pending)                       |
//+------------------------------------------------------------------+
void CloseCycle(const string reason, const double basket)
  {
   PrintFormat("[%s] Menutup siklus. Basket P/L = %.2f %s",
               reason, basket, AccountInfoString(ACCOUNT_CURRENCY));

   CloseAllPositions();
   DeleteAllPendings();

   g_realized  += basket;
   g_cycles++;
   g_gridBuilt = false;
   g_nextBuild = TimeCurrent() + InpRebuildDelaySec;
  }

//+------------------------------------------------------------------+
//| Bangun grid pending order di sekitar harga saat ini              |
//+------------------------------------------------------------------+
void BuildGrid()
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return;

   int minDist = MinStopDistance();
   int offset  = MathMax(InpFirstOffsetPoints, minDist + 1);
   int placed  = 0;

   for(int i = 0; i < InpLevels; i++)
     {
      double lot      = NormalizeLot(InpLot * MathPow(InpLotMultiplier, i));
      int    distance = offset + i * InpStepPoints;

      //--- sisi BUY STOP (di atas harga) ---------------------------
      if(InpGridMode == GRID_BOTH || InpGridMode == GRID_BUY)
        {
         double price = NormalizeDouble(ask + distance * g_point, g_digits);
         double tp    = (InpTakeProfitPoints > 0)
                        ? NormalizeDouble(price + InpTakeProfitPoints * g_point, g_digits) : 0.0;
         double sl    = (InpStopLossPoints > 0)
                        ? NormalizeDouble(price - InpStopLossPoints * g_point, g_digits) : 0.0;

         if(g_trade.BuyStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpComment))
            placed++;
         else
            PrintFormat("BuyStop level %d gagal @ %s: %d - %s", i + 1,
                        DoubleToString(price, g_digits),
                        g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
        }

      //--- sisi SELL STOP (di bawah harga) -------------------------
      if(InpGridMode == GRID_BOTH || InpGridMode == GRID_SELL)
        {
         double price = NormalizeDouble(bid - distance * g_point, g_digits);
         double tp    = (InpTakeProfitPoints > 0)
                        ? NormalizeDouble(price - InpTakeProfitPoints * g_point, g_digits) : 0.0;
         double sl    = (InpStopLossPoints > 0)
                        ? NormalizeDouble(price + InpStopLossPoints * g_point, g_digits) : 0.0;

         if(g_trade.SellStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpComment))
            placed++;
         else
            PrintFormat("SellStop level %d gagal @ %s: %d - %s", i + 1,
                        DoubleToString(price, g_digits),
                        g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
        }
     }

   if(placed > 0)
      g_gridBuilt = true;

   PrintFormat("Grid dibangun: %d pending order (step %d point, offset %d point).",
               placed, InpStepPoints, offset);
  }

//+------------------------------------------------------------------+
//| Trailing stop untuk posisi yang sudah profit                     |
//+------------------------------------------------------------------+
void ManageTrailing()
  {
   if(!InpUseTrailing || InpTrailDistPoints <= 0)
      return;

   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int    minDist = MinStopDistance();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      long   type    = PositionGetInteger(POSITION_TYPE);
      double open    = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL   = PositionGetDouble(POSITION_SL);
      double curTP   = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_BUY)
        {
         double gain = (bid - open) / g_point;
         if(gain < InpTrailStartPoints)
            continue;

         double newSL = NormalizeDouble(bid - InpTrailDistPoints * g_point, g_digits);
         if(newSL >= bid - minDist * g_point)
            continue;
         if(curSL > 0.0 && newSL - curSL < InpTrailStepPoints * g_point)
            continue;
         if(newSL <= curSL)
            continue;

         if(!g_trade.PositionModify(ticket, newSL, curTP))
            PrintFormat("Trailing buy #%I64u gagal: %d", ticket, g_trade.ResultRetcode());
        }
      else
         if(type == POSITION_TYPE_SELL)
           {
            double gain = (open - ask) / g_point;
            if(gain < InpTrailStartPoints)
               continue;

            double newSL = NormalizeDouble(ask + InpTrailDistPoints * g_point, g_digits);
            if(newSL <= ask + minDist * g_point)
               continue;
            if(curSL > 0.0 && curSL - newSL < InpTrailStepPoints * g_point)
               continue;
            if(curSL > 0.0 && newSL >= curSL)
               continue;

            if(!g_trade.PositionModify(ticket, newSL, curTP))
               PrintFormat("Trailing sell #%I64u gagal: %d", ticket, g_trade.ResultRetcode());
           }
     }
  }

//+------------------------------------------------------------------+
//| Filter waktu perdagangan                                         |
//+------------------------------------------------------------------+
bool TimeAllowed()
  {
   if(!InpUseTimeFilter)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);

   if(InpStartHour <= InpEndHour)
      return (dt.hour >= InpStartHour && dt.hour < InpEndHour);

   // rentang melewati tengah malam, mis. 22 -> 5
   return (dt.hour >= InpStartHour || dt.hour < InpEndHour);
  }

//+------------------------------------------------------------------+
//| Cek jadwal tutup hari Jumat                                      |
//+------------------------------------------------------------------+
bool FridayCloseTime()
  {
   if(!InpCloseAllFriday)
      return false;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.day_of_week == 5 && dt.hour >= InpFridayCloseHour);
  }

//+------------------------------------------------------------------+
//| Panel info di chart                                              |
//+------------------------------------------------------------------+
void UpdatePanel(const double basket)
  {
   if(!InpShowPanel)
      return;

   string cur = AccountInfoString(ACCOUNT_CURRENCY);
   string txt = StringFormat(
                   "=== Grid Straddle TP/SL ===\n"
                   "Simbol      : %s   Spread: %d pt\n"
                   "Status      : %s\n"
                   "Posisi      : %d   Pending: %d\n"
                   "Basket P/L  : %.2f %s  (target %.2f / stop -%.2f)\n"
                   "TP/SL order : %d / %d point\n"
                   "Grid        : %d level x %d point (offset %d)\n"
                   "Siklus      : %d   Akumulasi: %.2f %s\n"
                   "Balance     : %.2f   Equity: %.2f",
                   _Symbol, CurrentSpread(),
                   (g_halted ? "DIHENTIKAN" : "AKTIF"),
                   CountPositions(), CountPendings(),
                   basket, cur, InpBasketTargetMoney, InpBasketMaxLossMoney,
                   InpTakeProfitPoints, InpStopLossPoints,
                   InpLevels, InpStepPoints, InpFirstOffsetPoints,
                   g_cycles, g_realized, cur,
                   AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY));

   Comment(txt);
  }

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_volStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_volMin   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volMax   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_volDigits= VolumeDigits(g_volStep);

   if(g_point <= 0.0)
     {
      Print("Gagal membaca SYMBOL_POINT.");
      return INIT_FAILED;
     }

   //--- validasi input -------------------------------------------------
   if(InpLevels < 1)
     {
      Print("InpLevels minimal 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpStepPoints < 1)
     {
      Print("InpStepPoints minimal 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpLot <= 0.0)
     {
      Print("InpLot harus > 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpLotMultiplier < 1.0)
      Print("Peringatan: InpLotMultiplier < 1.0, lot akan mengecil tiap level.");

   int minDist = MinStopDistance();
   if(InpTakeProfitPoints > 0 && InpTakeProfitPoints <= minDist)
      PrintFormat("Peringatan: TP %d point <= stop level broker %d point, order bisa ditolak.",
                  InpTakeProfitPoints, minDist);
   if(InpStopLossPoints > 0 && InpStopLossPoints <= minDist)
      PrintFormat("Peringatan: SL %d point <= stop level broker %d point, order bisa ditolak.",
                  InpStopLossPoints, minDist);

   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      Print("Peringatan: AutoTrading dinonaktifkan di terminal/akun.");

   //--- setup CTrade ---------------------------------------------------
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   g_halted    = false;
   g_gridBuilt = false;
   g_nextBuild = 0;

   PrintFormat("GridStraddleTPSL siap. %s digits=%d point=%s stopLevel=%d",
               _Symbol, g_digits, DoubleToString(g_point, g_digits), minDist);

   UpdatePanel(0.0);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(InpDeleteOrdersOnDeinit && reason != REASON_CHARTCHANGE && reason != REASON_PARAMETERS)
     {
      int deleted = DeleteAllPendings();
      PrintFormat("EA dilepas: %d pending order dihapus (posisi terbuka tidak disentuh).", deleted);
     }
   Comment("");
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   //--- throttle: cukup proses sekali per detik ------------------------
   datetime now = TimeCurrent();
   if(now == g_lastTick)
      return;
   g_lastTick = now;

   double basket = BasketProfit();
   int    pos    = CountPositions();
   int    pend   = CountPendings();

   UpdatePanel(basket);

   if(g_halted)
      return;

   //--- 1. proteksi basket ---------------------------------------------
   if(pos > 0)
     {
      if(InpUseBasketTP && InpBasketTargetMoney > 0.0 && basket >= InpBasketTargetMoney)
        {
         CloseCycle("TARGET PROFIT", basket);
         return;
        }

      if(InpUseBasketSL && InpBasketMaxLossMoney > 0.0 && basket <= -InpBasketMaxLossMoney)
        {
         CloseCycle("BASKET STOP LOSS", basket);
         if(InpStopAfterLoss)
           {
            g_halted = true;
            Print("EA dihentikan karena basket stop loss (InpStopAfterLoss = true).");
           }
         return;
        }

      if(InpUseEquityStop && InpEquityStopPercent > 0.0)
        {
         double balance = AccountInfoDouble(ACCOUNT_BALANCE);
         double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
         if(balance > 0.0 && equity <= balance * (1.0 - InpEquityStopPercent / 100.0))
           {
            CloseCycle("EQUITY STOP", basket);
            g_halted = true;
            PrintFormat("EA dihentikan: equity %.2f <= %.1f%% drawdown dari balance %.2f",
                        equity, InpEquityStopPercent, balance);
            return;
           }
        }
     }

   //--- 2. jadwal tutup Jumat -------------------------------------------
   if(FridayCloseTime())
     {
      if(pos > 0 || pend > 0)
         CloseCycle("TUTUP JUMAT", basket);
      return;
     }

   //--- 3. trailing stop -------------------------------------------------
   ManageTrailing();

   //--- 4. bangun / bangun ulang grid ------------------------------------
   if(pos != 0 || pend != 0)
      return;                          // siklus masih berjalan

   if(g_gridBuilt && !InpAutoRebuild)
      return;                          // sekali jalan saja

   if(now < g_nextBuild)
      return;                          // masih dalam jeda

   if(!TimeAllowed())
      return;

   if(InpMaxSpreadPoints > 0 && CurrentSpread() > InpMaxSpreadPoints)
      return;

   if(InpMaxPositions > 0 && InpLevels * ((InpGridMode == GRID_BOTH) ? 2 : 1) > InpMaxPositions)
      PrintFormat("Peringatan: total level (%d) melebihi InpMaxPositions (%d).",
                  InpLevels * ((InpGridMode == GRID_BOTH) ? 2 : 1), InpMaxPositions);

   if((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
      return;                          // simbol close only / disabled

   BuildGrid();
  }
//+------------------------------------------------------------------+
