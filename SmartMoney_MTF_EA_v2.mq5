//+------------------------------------------------------------------+
//|                                SmartMoney_MTF_EA_v2.mq5          |
//|          Multi-Timeframe Smart Money Concepts EA - FIXED         |
//|          Enhanced: SL/TP execution, stronger signals, exits      |
//+------------------------------------------------------------------+
#property copyright "Smart Money EA v2"
#property link      ""
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                   |
//+------------------------------------------------------------------+
input group "=== Timeframe Configuration ==="
input ENUM_TIMEFRAMES InpHigherTF = PERIOD_H4;      // Higher TF (H4 or H1)
input ENUM_TIMEFRAMES InpMiddleTF = PERIOD_M15;     // Middle TF (M15 or M5)
input ENUM_TIMEFRAMES InpEntryTF  = PERIOD_M1;     // Entry TF (M1)

input group "=== Swing Detection Settings ==="
input int InpSwingBars = 5;                          // Bars to confirm swing
input int InpMaxSwingLookback = 150;                 // Max bars to look back for swings

input group "=== Premium/Discount Settings ==="
input double InpDiscountThreshold = 0.50;            // Discount zone threshold (0.5 = 50%)
input double InpFibEntryMin = 0.618;                 // Min Fib retracement for entry
input double InpFibEntryMax = 0.786;                 // Max Fib retracement for entry
input bool   InpRequireFibZone = false;              // Must be in Fib zone to enter

input group "=== Liquidity Sweep Settings ==="
input int InpSweepLookbackBars = 20;                 // Bars to look back for sweep levels
input int InpSweepConfirmationBars = 1;              // Bars to confirm sweep
input double InpSweepWickRatio = 0.5;                // Min wick ratio for sweep
input double InpSweepCloseRatio = 0.4;               // Close must be within this % of bar

input group "=== Consolidation Settings ==="
input int InpConsolidationBars = 6;                  // Bars for consolidation
input double InpConsolidationPips = 3.0;             // Max range for consolidation (pips)

input group "=== Structure Shift Settings ==="
input int InpStructureLookback = 15;                 // Bars for structure analysis
input bool InpRequireStructureShift = false;         // Require structure shift for entry

input group "=== Risk Management ==="
input double InpRiskPercent = 1.0;                   // Risk per trade (%)
input double InpMinRR = 2.0;                         // Minimum Risk:Reward
input double InpMaxRR = 10.0;                        // Maximum Risk:Reward for extended targets
input int InpSlBufferPips = 3;                       // SL buffer in pips
input bool InpUseExtendedTarget = true;              // Use extended targets on sweeps
input bool InpUseBreakeven = true;                   // Move to breakeven
input double InpBreakevenRR = 1.0;                   // RR to trigger breakeven
input bool InpUseTrailing = true;                    // Use trailing stop
input double InpTrailingRR = 2.0;                    // RR to start trailing
input double InpTrailingStep = 0.5;                  // Trail at this % of profit

input group "=== Trade Management ==="
input int InpMagicNumber = 123456;                   // Magic Number
input int InpSlippage = 50;                           // Max slippage (points)
input int InpMaxSpread = 30;                         // Max spread (points)
input int InpMaxDailyTrades = 10;                    // Max trades per day
input int InpMaxOpenPositions = 3;                   // Max open positions at once
input int InpTradeCooldownBars = 5;                  // Bars between trades on entry TF

input group "=== Session Filters ==="
input bool InpFilterSessions = true;                 // Filter by trading session
input bool InpTradeLondon = true;                    // Trade London session
input bool InpTradeNewYork = true;                   // Trade New York session
input bool InpTradeAsia = false;                     // Trade Asia session

input group "=== Debug & Logging ==="
input bool InpDebugMode = true;                      // Enable debug prints
input bool InpDrawZones = true;                      // Draw zones on chart

//+------------------------------------------------------------------+
//| Global Variables                                                   |
//+------------------------------------------------------------------+
CTrade      m_trade;
CSymbolInfo m_symbol;

struct SwingPoint
{
   datetime time;
   double   price;
   int      barIndex;
   bool     isValid;
};

struct MarketStructure
{
   SwingPoint swingHighs[];
   SwingPoint swingLows[];
   double     trendDirection;
   double     majorSwingHigh;
   double     majorSwingLow;
   datetime   majorSwingHighTime;
   datetime   majorSwingLowTime;
   double     prevSwingHigh;
   double     prevSwingLow;
};

struct PremiumDiscountZone
{
   double premiumTop;
   double premiumBottom;
   double discountTop;
   double discountBottom;
   double midpoint;
   double fib618;
   double fib786;
   bool   isValid;
};

struct TradeSignal
{
   bool     valid;
   int      type;
   double   entryPrice;
   double   stopLoss;
   double   takeProfit;
   double   rr;
   string   reason;
   double   confidence;
};

struct SessionTimes
{
   int startHour;
   int startMin;
   int endHour;
   int endMin;
};

MarketStructure m_higherMS;
MarketStructure m_middleMS;
PremiumDiscountZone m_pdZone;

int m_lastTradeBar = 0;
int m_dailyTradeCount = 0;
datetime m_lastTradeDay = 0;
datetime m_lastBarTime = 0;
bool m_initialized = false;

SessionTimes m_london = {8, 0, 17, 0};
SessionTimes m_newyork = {13, 0, 22, 0};
SessionTimes m_asia = {0, 0, 9, 0};

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!m_symbol.Name(Symbol()))
   {
      Print("ERROR: Failed to initialize symbol info");
      return INIT_FAILED;
   }

   if(!m_symbol.RefreshRates())
   {
      Print("ERROR: Failed to refresh rates");
      return INIT_FAILED;
   }

   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFilling(ORDER_FILLING_IOC);
   m_trade.SetAsyncMode(false);

   m_initialized = true;

   Print("=== Smart Money MTF EA v2.0 Initialized ===");
   Print("Symbol: ", Symbol(), " | Digits: ", m_symbol.Digits());
   Print("Point: ", m_symbol.Point(), " | TickSize: ", m_symbol.TickSize(), " | TickValue: ", m_symbol.TickValue());
   Print("Higher TF: ", EnumToString(InpHigherTF));
   Print("Middle TF: ", EnumToString(InpMiddleTF));
   Print("Entry TF:  ", EnumToString(InpEntryTF));

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                   |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(InpDrawZones)
      ObjectsDeleteAll(0, "SM_EA_");

   Print("=== Smart Money MTF EA v2.0 Deinitialized ===");
}

//+------------------------------------------------------------------+
//| Expert tick function                                               |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!m_initialized) return;

   if(!m_symbol.RefreshRates())
   {
      Print("ERROR: Failed to refresh rates in OnTick");
      return;
   }

   // Process on new bar only to avoid excessive calculations
   datetime currentBarTime = iTime(Symbol(), InpEntryTF, 0);
   if(currentBarTime == m_lastBarTime)
   {
      ManageOpenPositions();
      return;
   }
   m_lastBarTime = currentBarTime;

   if(!IsTradeAllowed())
   {
      if(InpDebugMode) Print("Trade not allowed at ", TimeToString(TimeCurrent()));
      return;
   }

   if(InpFilterSessions && !IsInAllowedSession())
   {
      if(InpDebugMode) Print("Outside allowed trading session");
      return;
   }

   if(CountOpenPositions() >= InpMaxOpenPositions)
   {
      if(InpDebugMode) Print("Max positions reached: ", CountOpenPositions());
      return;
   }

   int currentBar = iBars(Symbol(), InpEntryTF) - 1;
   if(currentBar - m_lastTradeBar < InpTradeCooldownBars && m_lastTradeBar > 0)
   {
      if(InpDebugMode) Print("Trade cooldown active");
      return;
   }

   // CORE STRATEGY LOGIC
   UpdateHigherTimeframeStructure();
   UpdateMiddleTimeframeStructure();
   CalculatePremiumDiscountZones();

   if(InpDrawZones)
      DrawAnalysis();

   TradeSignal signal = CheckEntrySignal();

   if(signal.valid)
   {
      if(InpDebugMode)
      {
         Print("SIGNAL DETECTED: ", signal.reason);
         Print("  Type: ", (signal.type == ORDER_TYPE_BUY ? "BUY" : "SELL"));
         Print("  Entry: ", signal.entryPrice, " | SL: ", signal.stopLoss, " | TP: ", signal.takeProfit);
         Print("  RR: ", StringFormat("%.2f", signal.rr), " | Confidence: ", StringFormat("%.0f", signal.confidence));
      }

      ExecuteTrade(signal);
   }

   ManageOpenPositions();
}

//+------------------------------------------------------------------+
//| Check if trading is allowed                                        |
//+------------------------------------------------------------------+
bool IsTradeAllowed()
{
   long spread = SymbolInfoInteger(Symbol(), SYMBOL_SPREAD);
   if(spread > InpMaxSpread)
   {
      if(InpDebugMode) Print("Spread too high: ", spread, " > ", InpMaxSpread);
      return false;
   }

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));

   if(today != m_lastTradeDay)
   {
      m_dailyTradeCount = 0;
      m_lastTradeDay = today;
      if(InpDebugMode) Print("New trading day. Reset trade count.");
   }

   if(m_dailyTradeCount >= InpMaxDailyTrades)
   {
      if(InpDebugMode) Print("Daily trade limit reached: ", m_dailyTradeCount);
      return false;
   }

   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(Symbol(), SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED)
   {
      if(InpDebugMode) Print("Trading disabled for symbol");
      return false;
   }

   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      if(InpDebugMode) Print("Algo trading not allowed");
      return false;
   }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      if(InpDebugMode) Print("Terminal trade not allowed");
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Check if in allowed trading session                                |
//+------------------------------------------------------------------+
bool IsInAllowedSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int currentHour = dt.hour;
   int currentMin = dt.min;
   int currentTime = currentHour * 60 + currentMin;

   if(InpTradeLondon)
   {
      int londonStart = m_london.startHour * 60 + m_london.startMin;
      int londonEnd = m_london.endHour * 60 + m_london.endMin;
      if(currentTime >= londonStart && currentTime <= londonEnd)
         return true;
   }

   if(InpTradeNewYork)
   {
      int nyStart = m_newyork.startHour * 60 + m_newyork.startMin;
      int nyEnd = m_newyork.endHour * 60 + m_newyork.endMin;
      if(currentTime >= nyStart && currentTime <= nyEnd)
         return true;
   }

   if(InpTradeAsia)
   {
      int asiaStart = m_asia.startHour * 60 + m_asia.startMin;
      int asiaEnd = m_asia.endHour * 60 + m_asia.endMin;
      if(currentTime >= asiaStart && currentTime <= asiaEnd)
         return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Count open positions for this EA                                   |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Update Higher Timeframe Market Structure                           |
//+------------------------------------------------------------------+
void UpdateHigherTimeframeStructure()
{
   ArrayResize(m_higherMS.swingHighs, 0);
   ArrayResize(m_higherMS.swingLows, 0);

   int bars = iBars(Symbol(), InpHigherTF);
   if(bars < InpSwingBars * 2 + 5)
   {
      if(InpDebugMode) Print("Not enough bars on higher TF: ", bars);
      return;
   }

   int maxBars = MathMin(InpMaxSwingLookback, bars - InpSwingBars - 1);

   for(int i = InpSwingBars; i < maxBars; i++)
   {
      if(IsSwingHigh(i, InpHigherTF, InpSwingBars))
      {
         SwingPoint sh;
         sh.price = iHigh(Symbol(), InpHigherTF, i);
         sh.time = iTime(Symbol(), InpHigherTF, i);
         sh.barIndex = i;
         sh.isValid = true;

         int size = ArraySize(m_higherMS.swingHighs);
         ArrayResize(m_higherMS.swingHighs, size + 1);
         m_higherMS.swingHighs[size] = sh;
      }

      if(IsSwingLow(i, InpHigherTF, InpSwingBars))
      {
         SwingPoint sl;
         sl.price = iLow(Symbol(), InpHigherTF, i);
         sl.time = iTime(Symbol(), InpHigherTF, i);
         sl.barIndex = i;
         sl.isValid = true;

         int size = ArraySize(m_higherMS.swingLows);
         ArrayResize(m_higherMS.swingLows, size + 1);
         m_higherMS.swingLows[size] = sl;
      }
   }

   DetermineTrend(m_higherMS);

   if(ArraySize(m_higherMS.swingHighs) > 0)
   {
      m_higherMS.majorSwingHigh = m_higherMS.swingHighs[0].price;
      m_higherMS.majorSwingHighTime = m_higherMS.swingHighs[0].time;
      if(ArraySize(m_higherMS.swingHighs) > 1)
         m_higherMS.prevSwingHigh = m_higherMS.swingHighs[1].price;
      else
         m_higherMS.prevSwingHigh = m_higherMS.majorSwingHigh;
   }

   if(ArraySize(m_higherMS.swingLows) > 0)
   {
      m_higherMS.majorSwingLow = m_higherMS.swingLows[0].price;
      m_higherMS.majorSwingLowTime = m_higherMS.swingLows[0].time;
      if(ArraySize(m_higherMS.swingLows) > 1)
         m_higherMS.prevSwingLow = m_higherMS.swingLows[1].price;
      else
         m_higherMS.prevSwingLow = m_higherMS.majorSwingLow;
   }

   if(InpDebugMode)
   {
      Print("HTF Analysis: Trend=", (m_higherMS.trendDirection == 1 ? "UP" : (m_higherMS.trendDirection == -1 ? "DOWN" : "RANGE")));
      Print("  Swing Highs: ", ArraySize(m_higherMS.swingHighs), " | Swing Lows: ", ArraySize(m_higherMS.swingLows));
      if(ArraySize(m_higherMS.swingHighs) > 0)
         Print("  Major High: ", m_higherMS.majorSwingHigh, " | Prev: ", m_higherMS.prevSwingHigh);
      if(ArraySize(m_higherMS.swingLows) > 0)
         Print("  Major Low: ", m_higherMS.majorSwingLow, " | Prev: ", m_higherMS.prevSwingLow);
   }
}

//+------------------------------------------------------------------+
//| Update Middle Timeframe Market Structure                           |
//+------------------------------------------------------------------+
void UpdateMiddleTimeframeStructure()
{
   ArrayResize(m_middleMS.swingHighs, 0);
   ArrayResize(m_middleMS.swingLows, 0);

   int bars = iBars(Symbol(), InpMiddleTF);
   if(bars < InpSwingBars * 2 + 5) return;

   int maxBars = MathMin(InpMaxSwingLookback, bars - InpSwingBars - 1);

   for(int i = InpSwingBars; i < maxBars; i++)
   {
      if(IsSwingHigh(i, InpMiddleTF, InpSwingBars))
      {
         SwingPoint sh;
         sh.price = iHigh(Symbol(), InpMiddleTF, i);
         sh.time = iTime(Symbol(), InpMiddleTF, i);
         sh.barIndex = i;
         sh.isValid = true;

         int size = ArraySize(m_middleMS.swingHighs);
         ArrayResize(m_middleMS.swingHighs, size + 1);
         m_middleMS.swingHighs[size] = sh;
      }

      if(IsSwingLow(i, InpMiddleTF, InpSwingBars))
      {
         SwingPoint sl;
         sl.price = iLow(Symbol(), InpMiddleTF, i);
         sl.time = iTime(Symbol(), InpMiddleTF, i);
         sl.barIndex = i;
         sl.isValid = true;

         int size = ArraySize(m_middleMS.swingLows);
         ArrayResize(m_middleMS.swingLows, size + 1);
         m_middleMS.swingLows[size] = sl;
      }
   }

   DetermineTrend(m_middleMS);
}

//+------------------------------------------------------------------+
//| Check if bar is a swing high                                       |
//+------------------------------------------------------------------+
bool IsSwingHigh(int bar, ENUM_TIMEFRAMES tf, int confirmationBars)
{
   double high = iHigh(Symbol(), tf, bar);

   for(int i = 1; i <= confirmationBars; i++)
   {
      if(bar + i >= iBars(Symbol(), tf)) return false;
      if(bar - i < 0) return false;

      if(iHigh(Symbol(), tf, bar + i) > high) return false;
      if(iHigh(Symbol(), tf, bar - i) >= high) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Check if bar is a swing low                                        |
//+------------------------------------------------------------------+
bool IsSwingLow(int bar, ENUM_TIMEFRAMES tf, int confirmationBars)
{
   double low = iLow(Symbol(), tf, bar);

   for(int i = 1; i <= confirmationBars; i++)
   {
      if(bar + i >= iBars(Symbol(), tf)) return false;
      if(bar - i < 0) return false;

      if(iLow(Symbol(), tf, bar + i) < low) return false;
      if(iLow(Symbol(), tf, bar - i) <= low) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Determine trend using HH/HL structure                              |
//+------------------------------------------------------------------+
void DetermineTrend(MarketStructure &ms)
{
   int highsCount = ArraySize(ms.swingHighs);
   int lowsCount = ArraySize(ms.swingLows);

   if(highsCount < 2 || lowsCount < 2)
   {
      ms.trendDirection = 0;
      return;
   }

   double lastHigh = ms.swingHighs[0].price;
   double prevHigh = ms.swingHighs[1].price;
   double lastLow = ms.swingLows[0].price;
   double prevLow = ms.swingLows[1].price;

   bool hh = lastHigh > prevHigh;
   bool hl = lastLow > prevLow;
   bool lh = lastHigh < prevHigh;
   bool ll = lastLow < prevLow;

   if(hh && hl)
      ms.trendDirection = 1;
   else if(lh && ll)
      ms.trendDirection = -1;
   else if(hh && !hl)
      ms.trendDirection = 1;
   else if(lh && !ll)
      ms.trendDirection = -1;
   else if(!hh && hl)
      ms.trendDirection = 1;
   else if(!lh && ll)
      ms.trendDirection = -1;
   else
      ms.trendDirection = 0;
}

//+------------------------------------------------------------------+
//| Calculate Premium/Discount Zones                                   |
//+------------------------------------------------------------------+
void CalculatePremiumDiscountZones()
{
   m_pdZone.isValid = false;

   if(ArraySize(m_middleMS.swingHighs) == 0 || ArraySize(m_middleMS.swingLows) == 0)
   {
      if(InpDebugMode) Print("Cannot calculate PD zones: no swings found");
      return;
   }

   double recentHigh = 0;
   double recentLow = DBL_MAX;

   for(int i = 0; i < ArraySize(m_middleMS.swingHighs); i++)
   {
      if(m_middleMS.swingHighs[i].price > recentHigh)
         recentHigh = m_middleMS.swingHighs[i].price;
   }

   for(int i = 0; i < ArraySize(m_middleMS.swingLows); i++)
   {
      if(m_middleMS.swingLows[i].price < recentLow)
         recentLow = m_middleMS.swingLows[i].price;
   }

   if(recentHigh <= recentLow || recentHigh == 0 || recentLow == DBL_MAX)
   {
      if(InpDebugMode) Print("Invalid swing range: High=", recentHigh, " Low=", recentLow);
      return;
   }

   double range = recentHigh - recentLow;

   m_pdZone.midpoint = recentLow + range * InpDiscountThreshold;
   m_pdZone.premiumBottom = m_pdZone.midpoint;
   m_pdZone.premiumTop = recentHigh;
   m_pdZone.discountTop = m_pdZone.midpoint;
   m_pdZone.discountBottom = recentLow;
   m_pdZone.fib618 = recentHigh - range * InpFibEntryMin;
   m_pdZone.fib786 = recentHigh - range * InpFibEntryMax;
   m_pdZone.isValid = true;

   if(InpDebugMode)
   {
      Print("PD Zones: Range=", range);
      Print("  Mid: ", m_pdZone.midpoint, " | Premium: ", m_pdZone.premiumBottom, "-", m_pdZone.premiumTop);
      Print("  Discount: ", m_pdZone.discountBottom, "-", m_pdZone.discountTop);
      Print("  Fib 61.8%: ", m_pdZone.fib618, " | Fib 78.6%: ", m_pdZone.fib786);
   }
}

//+------------------------------------------------------------------+
//| Check for Entry Signal                                             |
//+------------------------------------------------------------------+
TradeSignal CheckEntrySignal()
{
   TradeSignal signal;
   signal.valid = false;
   signal.confidence = 0;

   if(m_higherMS.trendDirection == 0)
   {
      if(InpDebugMode) Print("No trend detected on higher TF");
      return signal;
   }

   if(!m_pdZone.isValid)
   {
      if(InpDebugMode) Print("PD zones not valid");
      return signal;
   }

   double currentBid = m_symbol.Bid();
   double currentAsk = m_symbol.Ask();
   double currentPrice = (currentBid + currentAsk) / 2;

   // === UPTREND LOGIC ===
   if(m_higherMS.trendDirection == 1)
   {
      if(currentPrice > m_pdZone.discountTop)
      {
         if(InpDebugMode) Print("Price ", currentPrice, " above discount top ", m_pdZone.discountTop);
         return signal;
      }

      signal.confidence += 20;

      bool inFibZone = (currentPrice <= m_pdZone.fib618 && currentPrice >= m_pdZone.fib786);
      if(inFibZone) signal.confidence += 25;

      bool sweepDetected = DetectLiquiditySweep(ORDER_TYPE_BUY);
      if(sweepDetected) signal.confidence += 30;

      bool breakoutDetected = DetectConsolidationBreakout(ORDER_TYPE_BUY);
      if(breakoutDetected) signal.confidence += 20;

      bool structureShift = DetectInternalStructureShift(1);
      if(structureShift) signal.confidence += 25;

      bool hasEnoughConfirmation = false;

      if(InpRequireFibZone)
      {
         hasEnoughConfirmation = inFibZone && (sweepDetected || breakoutDetected || structureShift);
      }
      else
      {
         int confirmations = (inFibZone ? 1 : 0) + (sweepDetected ? 1 : 0) + 
                            (breakoutDetected ? 1 : 0) + (structureShift ? 1 : 0);
         hasEnoughConfirmation = confirmations >= 2;
      }

      if(InpRequireStructureShift && !structureShift)
         hasEnoughConfirmation = false;

      if(!hasEnoughConfirmation)
      {
         if(InpDebugMode) Print("Not enough confirmations. Confidence: ", signal.confidence);
         return signal;
      }

      double sl = CalculateStopLoss(ORDER_TYPE_BUY);
      double tp = CalculateTakeProfit(ORDER_TYPE_BUY, sl, currentAsk, sweepDetected);

      if(sl >= currentAsk || tp <= currentAsk)
      {
         if(InpDebugMode) Print("Invalid levels: SL=", sl, " Entry=", currentAsk, " TP=", tp);
         return signal;
      }

      double risk = MathAbs(currentAsk - sl);
      double reward = MathAbs(tp - currentAsk);
      double rr = (risk > 0) ? reward / risk : 0;

      if(rr < InpMinRR)
      {
         if(InpDebugMode) Print("RR too low: ", StringFormat("%.2f", rr), " < ", InpMinRR);
         return signal;
      }

      signal.valid = true;
      signal.type = ORDER_TYPE_BUY;
      signal.entryPrice = currentAsk;
      signal.stopLoss = sl;
      signal.takeProfit = tp;
      signal.rr = rr;

      if(sweepDetected && breakoutDetected)
         signal.reason = "SWEEP+BREAKOUT+DISCOUNT";
      else if(sweepDetected && structureShift)
         signal.reason = "SWEEP+STRUCTURE+DISCOUNT";
      else if(sweepDetected)
         signal.reason = "LIQUIDITY SWEEP+DISCOUNT";
      else if(breakoutDetected && structureShift)
         signal.reason = "BREAKOUT+STRUCTURE+DISCOUNT";
      else if(breakoutDetected)
         signal.reason = "CONSOLIDATION BREAKOUT+DISCOUNT";
      else if(structureShift)
         signal.reason = "STRUCTURE SHIFT+DISCOUNT";
      else if(inFibZone)
         signal.reason = "FIB ZONE ENTRY+DISCOUNT";
      else
         signal.reason = "MULTI-CONFIRMATION+DISCOUNT";
   }
   // === DOWNTREND LOGIC ===
   else if(m_higherMS.trendDirection == -1)
   {
      if(currentPrice < m_pdZone.premiumBottom)
      {
         if(InpDebugMode) Print("Price ", currentPrice, " below premium bottom ", m_pdZone.premiumBottom);
         return signal;
      }

      signal.confidence += 20;

      double range = m_pdZone.premiumTop - m_pdZone.premiumBottom;
      double fib618_sell = m_pdZone.premiumBottom + range * (1 - InpFibEntryMin);
      double fib786_sell = m_pdZone.premiumBottom + range * (1 - InpFibEntryMax);

      bool inFibZone = (currentPrice >= fib786_sell && currentPrice <= fib618_sell);
      if(inFibZone) signal.confidence += 25;

      bool sweepDetected = DetectLiquiditySweep(ORDER_TYPE_SELL);
      if(sweepDetected) signal.confidence += 30;

      bool breakoutDetected = DetectConsolidationBreakout(ORDER_TYPE_SELL);
      if(breakoutDetected) signal.confidence += 20;

      bool structureShift = DetectInternalStructureShift(-1);
      if(structureShift) signal.confidence += 25;

      bool hasEnoughConfirmation = false;

      if(InpRequireFibZone)
      {
         hasEnoughConfirmation = inFibZone && (sweepDetected || breakoutDetected || structureShift);
      }
      else
      {
         int confirmations = (inFibZone ? 1 : 0) + (sweepDetected ? 1 : 0) + 
                            (breakoutDetected ? 1 : 0) + (structureShift ? 1 : 0);
         hasEnoughConfirmation = confirmations >= 2;
      }

      if(InpRequireStructureShift && !structureShift)
         hasEnoughConfirmation = false;

      if(!hasEnoughConfirmation)
      {
         if(InpDebugMode) Print("Not enough confirmations. Confidence: ", signal.confidence);
         return signal;
      }

      double sl = CalculateStopLoss(ORDER_TYPE_SELL);
      double tp = CalculateTakeProfit(ORDER_TYPE_SELL, sl, currentBid, sweepDetected);

      if(sl <= currentBid || tp >= currentBid)
      {
         if(InpDebugMode) Print("Invalid levels: SL=", sl, " Entry=", currentBid, " TP=", tp);
         return signal;
      }

      double risk = MathAbs(sl - currentBid);
      double reward = MathAbs(currentBid - tp);
      double rr = (risk > 0) ? reward / risk : 0;

      if(rr < InpMinRR)
      {
         if(InpDebugMode) Print("RR too low: ", StringFormat("%.2f", rr), " < ", InpMinRR);
         return signal;
      }

      signal.valid = true;
      signal.type = ORDER_TYPE_SELL;
      signal.entryPrice = currentBid;
      signal.stopLoss = sl;
      signal.takeProfit = tp;
      signal.rr = rr;

      if(sweepDetected && breakoutDetected)
         signal.reason = "SWEEP+BREAKDOWN+PREMIUM";
      else if(sweepDetected && structureShift)
         signal.reason = "SWEEP+STRUCTURE+PREMIUM";
      else if(sweepDetected)
         signal.reason = "LIQUIDITY SWEEP+PREMIUM";
      else if(breakoutDetected && structureShift)
         signal.reason = "BREAKDOWN+STRUCTURE+PREMIUM";
      else if(breakoutDetected)
         signal.reason = "CONSOLIDATION BREAKDOWN+PREMIUM";
      else if(structureShift)
         signal.reason = "STRUCTURE SHIFT+PREMIUM";
      else if(inFibZone)
         signal.reason = "FIB ZONE ENTRY+PREMIUM";
      else
         signal.reason = "MULTI-CONFIRMATION+PREMIUM";
   }

   return signal;
}

//+------------------------------------------------------------------+
//| Detect Liquidity Sweep                                             |
//+------------------------------------------------------------------+
bool DetectLiquiditySweep(int orderType)
{
   int bars = iBars(Symbol(), InpEntryTF);
   if(bars < InpSweepLookbackBars + 5) return false;

   if(orderType == ORDER_TYPE_BUY)
   {
      double liquidityLow = DBL_MAX;
      int liquidityBar = -1;

      for(int i = 2; i < InpSweepLookbackBars + 2; i++)
      {
         double low = iLow(Symbol(), InpEntryTF, i);
         if(low < liquidityLow)
         {
            liquidityLow = low;
            liquidityBar = i;
         }
      }

      if(liquidityBar < 0) return false;

      for(int i = 1; i <= InpSweepConfirmationBars + 1; i++)
      {
         double low = iLow(Symbol(), InpEntryTF, i);
         double open = iOpen(Symbol(), InpEntryTF, i);
         double close = iClose(Symbol(), InpEntryTF, i);
         double high = iHigh(Symbol(), InpEntryTF, i);

         if(low < liquidityLow)
         {
            if(close > liquidityLow)
            {
               double barRange = high - low;
               double lowerWick = MathMin(open, close) - low;
               double body = MathAbs(close - open);
               double closePosition = (close - low) / barRange;

               bool strongRejection = (closePosition > 0.6) || 
                                      (body > 0 && lowerWick / body >= InpSweepWickRatio) ||
                                      (closePosition > InpSweepCloseRatio);

               if(strongRejection)
               {
                  if(InpDebugMode) Print("BUY SWEEP at bar ", i, " | Low:", low, " < Liq:", liquidityLow, " | Close:", close);
                  return true;
               }
            }
         }
      }
   }
   else
   {
      double liquidityHigh = 0;
      int liquidityBar = -1;

      for(int i = 2; i < InpSweepLookbackBars + 2; i++)
      {
         double high = iHigh(Symbol(), InpEntryTF, i);
         if(high > liquidityHigh)
         {
            liquidityHigh = high;
            liquidityBar = i;
         }
      }

      if(liquidityBar < 0) return false;

      for(int i = 1; i <= InpSweepConfirmationBars + 1; i++)
      {
         double high = iHigh(Symbol(), InpEntryTF, i);
         double open = iOpen(Symbol(), InpEntryTF, i);
         double close = iClose(Symbol(), InpEntryTF, i);
         double low = iLow(Symbol(), InpEntryTF, i);

         if(high > liquidityHigh)
         {
            if(close < liquidityHigh)
            {
               double barRange = high - low;
               double upperWick = high - MathMax(open, close);
               double body = MathAbs(close - open);
               double closePosition = (high - close) / barRange;

               bool strongRejection = (closePosition > 0.6) || 
                                      (body > 0 && upperWick / body >= InpSweepWickRatio) ||
                                      (closePosition > InpSweepCloseRatio);

               if(strongRejection)
               {
                  if(InpDebugMode) Print("SELL SWEEP at bar ", i, " | High:", high, " > Liq:", liquidityHigh, " | Close:", close);
                  return true;
               }
            }
         }
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Detect Consolidation Breakout                                      |
//+------------------------------------------------------------------+
bool DetectConsolidationBreakout(int orderType)
{
   int bars = iBars(Symbol(), InpEntryTF);
   if(bars < InpConsolidationBars + 3) return false;

   double highestHigh = 0;
   double lowestLow = DBL_MAX;

   for(int i = 1; i <= InpConsolidationBars; i++)
   {
      double high = iHigh(Symbol(), InpEntryTF, i);
      double low = iLow(Symbol(), InpEntryTF, i);
      if(high > highestHigh) highestHigh = high;
      if(low < lowestLow) lowestLow = low;
   }

   double range = highestHigh - lowestLow;
   double point = m_symbol.Point();
   double rangePips = range / (point * 10);

   if(rangePips > InpConsolidationPips)
   {
      if(InpDebugMode) Print("Consolidation range too wide: ", StringFormat("%.1f", rangePips), " pips");
      return false;
   }

   double currentClose = iClose(Symbol(), InpEntryTF, 0);
   double currentOpen = iOpen(Symbol(), InpEntryTF, 0);

   if(orderType == ORDER_TYPE_BUY)
   {
      if(currentClose > highestHigh && currentClose > currentOpen)
      {
         if(currentClose < m_pdZone.discountTop)
         {
            if(InpDebugMode) Print("BUY BREAKOUT: ConsHigh=", highestHigh, " | Close=", currentClose, " | Range=", StringFormat("%.1f", rangePips), "pips");
            return true;
         }
      }
   }
   else
   {
      if(currentClose < lowestLow && currentClose < currentOpen)
      {
         if(currentClose > m_pdZone.premiumBottom)
         {
            if(InpDebugMode) Print("SELL BREAKDOWN: ConsLow=", lowestLow, " | Close=", currentClose, " | Range=", StringFormat("%.1f", rangePips), "pips");
            return true;
         }
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Detect Internal Structure Shift                                    |
//+------------------------------------------------------------------+
bool DetectInternalStructureShift(int trendDirection)
{
   int bars = iBars(Symbol(), InpEntryTF);
   if(bars < InpStructureLookback + 5) return false;

   if(trendDirection == 1)
   {
      double low1 = DBL_MAX;
      int low1_idx = -1;
      double low2 = DBL_MAX;
      int low2_idx = -1;

      for(int i = 2; i < InpStructureLookback + 2; i++)
      {
         double low = iLow(Symbol(), InpEntryTF, i);
         if(low < low1)
         {
            low2 = low1;
            low2_idx = low1_idx;
            low1 = low;
            low1_idx = i;
         }
         else if(low < low2 && i != low1_idx)
         {
            low2 = low;
            low2_idx = i;
         }
      }

      if(low1_idx < 0 || low2_idx < 0) return false;

      if(low1_idx < low2_idx)
      {
         double currentLow = iLow(Symbol(), InpEntryTF, 0);
         double prevLow = iLow(Symbol(), InpEntryTF, 1);

         if(currentLow > low1 && prevLow > low1 && currentLow < m_pdZone.discountTop)
         {
            if(InpDebugMode) Print("STRUCTURE SHIFT BUY: LL at ", low1, " -> HL at ", currentLow);
            return true;
         }
      }
   }
   else
   {
      double high1 = 0;
      int high1_idx = -1;
      double high2 = 0;
      int high2_idx = -1;

      for(int i = 2; i < InpStructureLookback + 2; i++)
      {
         double high = iHigh(Symbol(), InpEntryTF, i);
         if(high > high1)
         {
            high2 = high1;
            high2_idx = high1_idx;
            high1 = high;
            high1_idx = i;
         }
         else if(high > high2 && i != high1_idx)
         {
            high2 = high;
            high2_idx = i;
         }
      }

      if(high1_idx < 0 || high2_idx < 0) return false;

      if(high1_idx < high2_idx)
      {
         double currentHigh = iHigh(Symbol(), InpEntryTF, 0);
         double prevHigh = iHigh(Symbol(), InpEntryTF, 1);

         if(currentHigh < high1 && prevHigh < high1 && currentHigh > m_pdZone.premiumBottom)
         {
            if(InpDebugMode) Print("STRUCTURE SHIFT SELL: HH at ", high1, " -> LH at ", currentHigh);
            return true;
         }
      }
   }

   return false;
}

//+------------------------------------------------------------------+
//| Calculate Stop Loss                                                |
//+------------------------------------------------------------------+
double CalculateStopLoss(int orderType)
{
   double point = m_symbol.Point();
   double slBuffer = InpSlBufferPips * 10 * point;
   int digits = (int)m_symbol.Digits();

   if(orderType == ORDER_TYPE_BUY)
   {
      double recentLow = DBL_MAX;
      for(int i = 1; i <= 20; i++)
      {
         double low = iLow(Symbol(), InpEntryTF, i);
         if(low < recentLow) recentLow = low;
      }

      double middleLow = DBL_MAX;
      if(ArraySize(m_middleMS.swingLows) > 0)
         middleLow = m_middleMS.swingLows[0].price;

      double sl = MathMin(recentLow, middleLow);

      double currentAsk = m_symbol.Ask();
      if(middleLow != DBL_MAX && (currentAsk - middleLow) > (currentAsk - recentLow) * 3)
         sl = recentLow;

      sl -= slBuffer;

      double maxSLDistance = currentAsk * 0.015;
      if(currentAsk - sl > maxSLDistance)
         sl = currentAsk - maxSLDistance;

      return NormalizeDouble(sl, digits);
   }
   else
   {
      double recentHigh = 0;
      for(int i = 1; i <= 20; i++)
      {
         double high = iHigh(Symbol(), InpEntryTF, i);
         if(high > recentHigh) recentHigh = high;
      }

      double middleHigh = 0;
      if(ArraySize(m_middleMS.swingHighs) > 0)
         middleHigh = m_middleMS.swingHighs[0].price;

      double sl = MathMax(recentHigh, middleHigh);

      double currentBid = m_symbol.Bid();
      if(middleHigh > 0 && (middleHigh - currentBid) > (recentHigh - currentBid) * 3)
         sl = recentHigh;

      sl += slBuffer;

      double maxSLDistance = currentBid * 0.015;
      if(sl - currentBid > maxSLDistance)
         sl = currentBid + maxSLDistance;

      return NormalizeDouble(sl, digits);
   }
}

//+------------------------------------------------------------------+
//| Calculate Take Profit                                              |
//+------------------------------------------------------------------+
double CalculateTakeProfit(int orderType, double sl, double entry, bool isSweep)
{
   double risk = MathAbs(entry - sl);
   int digits = (int)m_symbol.Digits();

   if(risk <= 0) return 0;

   if(orderType == ORDER_TYPE_BUY)
   {
      double minTP = entry + risk * InpMinRR;

      if(isSweep && InpUseExtendedTarget)
      {
         double extendedTP = m_higherMS.prevSwingHigh;

         if(extendedTP > entry)
         {
            double extendedRR = (extendedTP - entry) / risk;

            if(extendedRR >= InpMinRR && extendedRR <= InpMaxRR)
            {
               if(InpDebugMode) Print("Extended TP: ", extendedTP, " | RR: ", StringFormat("%.2f", extendedRR));
               return NormalizeDouble(extendedTP, digits);
            }
         }
      }

      return NormalizeDouble(minTP, digits);
   }
   else
   {
      double minTP = entry - risk * InpMinRR;

      if(isSweep && InpUseExtendedTarget)
      {
         double extendedTP = m_higherMS.prevSwingLow;

         if(extendedTP < entry && extendedTP > 0)
         {
            double extendedRR = (entry - extendedTP) / risk;

            if(extendedRR >= InpMinRR && extendedRR <= InpMaxRR)
            {
               if(InpDebugMode) Print("Extended TP: ", extendedTP, " | RR: ", StringFormat("%.2f", extendedRR));
               return NormalizeDouble(extendedTP, digits);
            }
         }
      }

      return NormalizeDouble(minTP, digits);
   }
}

//+------------------------------------------------------------------+
//| Execute Trade with proper SL/TP                                    |
//+------------------------------------------------------------------+
void ExecuteTrade(TradeSignal &signal)
{
   if(!m_symbol.RefreshRates())
   {
      Print("ERROR: Cannot refresh rates before trade");
      return;
   }

   double lotSize = CalculateLotSize(signal.entryPrice, signal.stopLoss);

   if(lotSize <= 0)
   {
      Print("ERROR: Invalid lot size calculated: ", lotSize);
      return;
   }

   if(signal.stopLoss <= 0 || signal.takeProfit <= 0)
   {
      Print("ERROR: Invalid SL/TP values: SL=", signal.stopLoss, " TP=", signal.takeProfit);
      return;
   }

   string comment = StringFormat("SMv2|%s|RR%.1f|Conf%.0f", 
      signal.reason, signal.rr, signal.confidence);

   bool result = false;
   ulong ticket = 0;

   if(signal.type == ORDER_TYPE_BUY)
   {
      double entry = m_symbol.Ask();

      if(signal.stopLoss >= entry)
      {
         Print("ERROR: BUY SL ", signal.stopLoss, " >= entry ", entry);
         return;
      }

      if(signal.takeProfit <= entry)
      {
         Print("ERROR: BUY TP ", signal.takeProfit, " <= entry ", entry);
         return;
      }

      double stopsLevel = SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) * m_symbol.Point();
      if(entry - signal.stopLoss < stopsLevel)
      {
         Print("WARNING: SL too close to entry. Adjusting...");
         signal.stopLoss = entry - stopsLevel - m_symbol.Point() * 5;
      }

      result = m_trade.Buy(lotSize, Symbol(), entry, 
                           signal.stopLoss, signal.takeProfit, comment);
      ticket = m_trade.ResultOrder();
   }
   else
   {
      double entry = m_symbol.Bid();

      if(signal.stopLoss <= entry)
      {
         Print("ERROR: SELL SL ", signal.stopLoss, " <= entry ", entry);
         return;
      }

      if(signal.takeProfit >= entry)
      {
         Print("ERROR: SELL TP ", signal.takeProfit, " >= entry ", entry);
         return;
      }

      double stopsLevel = SymbolInfoInteger(Symbol(), SYMBOL_TRADE_STOPS_LEVEL) * m_symbol.Point();
      if(signal.stopLoss - entry < stopsLevel)
      {
         Print("WARNING: SL too close to entry. Adjusting...");
         signal.stopLoss = entry + stopsLevel + m_symbol.Point() * 5;
      }

      result = m_trade.Sell(lotSize, Symbol(), entry,
                            signal.stopLoss, signal.takeProfit, comment);
      ticket = m_trade.ResultOrder();
   }

   if(result)
   {
      m_dailyTradeCount++;
      m_lastTradeBar = iBars(Symbol(), InpEntryTF) - 1;

      Print("=== TRADE EXECUTED ===");
      Print("Ticket: ", ticket);
      Print("Type: ", (signal.type == ORDER_TYPE_BUY ? "BUY" : "SELL"));
      Print("Lots: ", lotSize);
      Print("Entry: ", (signal.type == ORDER_TYPE_BUY ? m_symbol.Ask() : m_symbol.Bid()));
      Print("SL: ", signal.stopLoss, " | TP: ", signal.takeProfit);
      Print("RR: ", StringFormat("%.2f", signal.rr));
      Print("Reason: ", signal.reason);
      Print("Confidence: ", StringFormat("%.0f%%", signal.confidence));
      Print("======================");
   }
   else
   {
      int error = GetLastError();
      Print("=== TRADE FAILED ===");
      Print("Error Code: ", error);
      Print("Retcode: ", m_trade.ResultRetcode());
      Print("RetcodeDescription: ", m_trade.ResultRetcodeDescription());
      Print("====================");
   }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size based on risk percentage                        |
//+------------------------------------------------------------------+
double CalculateLotSize(double entry, double sl)
{
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double tickSize = m_symbol.TickSize();
   double tickValue = m_symbol.TickValue();
   double lotStep = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);

   if(tickSize == 0 || tickValue == 0)
   {
      Print("ERROR: Invalid tick data - Size:", tickSize, " Value:", tickValue);
      return 0;
   }

   double priceDistance = MathAbs(entry - sl);
   double ticksAtRisk = priceDistance / tickSize;

   if(ticksAtRisk == 0)
   {
      Print("ERROR: Zero ticks at risk");
      return 0;
   }

   double lotSize = riskAmount / (ticksAtRisk * tickValue);
   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

   if(InpDebugMode)
   {
      Print("Lot Calc: Risk$=", riskAmount, " | Ticks=", ticksAtRisk, 
            " | TickVal=", tickValue, " | Lot=", lotSize);
   }

   return NormalizeDouble(lotSize, 2);
}

//+------------------------------------------------------------------+
//| Manage Open Positions - Breakeven & Trailing                       |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;

      if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      if(!m_symbol.RefreshRates()) continue;

      double currentPrice = (posType == POSITION_TYPE_BUY) ? m_symbol.Bid() : m_symbol.Ask();

      double profit = 0;
      if(posType == POSITION_TYPE_BUY)
         profit = currentPrice - openPrice;
      else
         profit = openPrice - currentPrice;

      double initialRisk = MathAbs(openPrice - currentSL);
      if(initialRisk == 0) continue;

      double currentRR = profit / initialRisk;

      // BREAKEVEN
      if(InpUseBreakeven && currentRR >= InpBreakevenRR && currentSL != openPrice)
      {
         double beBuffer = m_symbol.Point() * 2;
         double newSL = (posType == POSITION_TYPE_BUY) ? openPrice + beBuffer : openPrice - beBuffer;

         bool shouldMove = false;
         if(posType == POSITION_TYPE_BUY && newSL > currentSL)
            shouldMove = true;
         if(posType == POSITION_TYPE_SELL && (newSL < currentSL || currentSL == 0))
            shouldMove = true;

         if(shouldMove)
         {
            if(m_trade.PositionModify(ticket, newSL, currentTP))
            {
               Print("BREAKEVEN: Ticket ", ticket, " | SL moved to ", newSL);
            }
            else
            {
               Print("BREAKEVEN FAILED: Ticket ", ticket, " | Error: ", GetLastError());
            }
         }
      }

      // TRAILING STOP
      if(InpUseTrailing && currentRR >= InpTrailingRR)
      {
         double trailDistance = initialRisk * InpTrailingStep;
         double newSL = 0;

         if(posType == POSITION_TYPE_BUY)
         {
            newSL = currentPrice - trailDistance;
            if(newSL > currentSL + m_symbol.Point() * 5)
            {
               if(m_trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("TRAILING: Ticket ", ticket, " | SL moved to ", newSL, 
                        " | Price: ", currentPrice, " | RR: ", StringFormat("%.2f", currentRR));
               }
            }
         }
         else
         {
            newSL = currentPrice + trailDistance;
            if(newSL < currentSL - m_symbol.Point() * 5 || currentSL == 0)
            {
               if(m_trade.PositionModify(ticket, newSL, currentTP))
               {
                  Print("TRAILING: Ticket ", ticket, " | SL moved to ", newSL,
                        " | Price: ", currentPrice, " | RR: ", StringFormat("%.2f", currentRR));
               }
            }
         }
      }

      // TIME-BASED EXIT (48 hours max for losers)
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      int hoursOpen = (int)((TimeCurrent() - openTime) / 3600);

      if(hoursOpen > 48 && profit < 0)
      {
         if(m_trade.PositionClose(ticket))
         {
            Print("TIME EXIT: Closed ticket ", ticket, " after ", hoursOpen, " hours");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Draw Analysis on Chart                                             |
//+------------------------------------------------------------------+
void DrawAnalysis()
{
   if(!InpDrawZones) return;

   ObjectsDeleteAll(0, "SM_EA_");

   datetime time0 = iTime(Symbol(), PERIOD_CURRENT, 0);
   if(time0 == 0) return;

   datetime timeEnd = time0 + PeriodSeconds(PERIOD_CURRENT) * 100;

   string trendText = "RANGING";
   color trendColor = clrYellow;
   if(m_higherMS.trendDirection == 1) { trendText = "UPTREND"; trendColor = clrLime; }
   if(m_higherMS.trendDirection == -1) { trendText = "DOWNTREND"; trendColor = clrRed; }

   ObjectCreate(0, "SM_EA_Trend", OBJ_LABEL, 0, 0, 0);
   ObjectSetString(0, "SM_EA_Trend", OBJPROP_TEXT, "HTF: " + trendText);
   ObjectSetInteger(0, "SM_EA_Trend", OBJPROP_COLOR, trendColor);
   ObjectSetInteger(0, "SM_EA_Trend", OBJPROP_FONTSIZE, 10);
   ObjectSetInteger(0, "SM_EA_Trend", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "SM_EA_Trend", OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, "SM_EA_Trend", OBJPROP_YDISTANCE, 20);

   ObjectCreate(0, "SM_EA_Trades", OBJ_LABEL, 0, 0, 0);
   ObjectSetString(0, "SM_EA_Trades", OBJPROP_TEXT, 
      "Trades Today: " + IntegerToString(m_dailyTradeCount) + "/" + IntegerToString(InpMaxDailyTrades));
   ObjectSetInteger(0, "SM_EA_Trades", OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, "SM_EA_Trades", OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, "SM_EA_Trades", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "SM_EA_Trades", OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, "SM_EA_Trades", OBJPROP_YDISTANCE, 40);

   int openPos = CountOpenPositions();
   ObjectCreate(0, "SM_EA_Positions", OBJ_LABEL, 0, 0, 0);
   ObjectSetString(0, "SM_EA_Positions", OBJPROP_TEXT, 
      "Open Positions: " + IntegerToString(openPos));
   ObjectSetInteger(0, "SM_EA_Positions", OBJPROP_COLOR, openPos > 0 ? clrLime : clrGray);
   ObjectSetInteger(0, "SM_EA_Positions", OBJPROP_FONTSIZE, 9);
   ObjectSetInteger(0, "SM_EA_Positions", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "SM_EA_Positions", OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, "SM_EA_Positions", OBJPROP_YDISTANCE, 55);

   if(m_pdZone.isValid)
   {
      ObjectCreate(0, "SM_EA_Premium", OBJ_RECTANGLE, 0, time0, m_pdZone.premiumTop, timeEnd, m_pdZone.premiumBottom);
      ObjectSetInteger(0, "SM_EA_Premium", OBJPROP_COLOR, C'64,0,0');
      ObjectSetInteger(0, "SM_EA_Premium", OBJPROP_FILL, true);
      ObjectSetInteger(0, "SM_EA_Premium", OBJPROP_BACK, true);

      ObjectCreate(0, "SM_EA_Discount", OBJ_RECTANGLE, 0, time0, m_pdZone.discountTop, timeEnd, m_pdZone.discountBottom);
      ObjectSetInteger(0, "SM_EA_Discount", OBJPROP_COLOR, C'0,64,0');
      ObjectSetInteger(0, "SM_EA_Discount", OBJPROP_FILL, true);
      ObjectSetInteger(0, "SM_EA_Discount", OBJPROP_BACK, true);

      ObjectCreate(0, "SM_EA_Mid", OBJ_HLINE, 0, 0, m_pdZone.midpoint);
      ObjectSetInteger(0, "SM_EA_Mid", OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, "SM_EA_Mid", OBJPROP_STYLE, STYLE_DASH);

      ObjectCreate(0, "SM_EA_Fib618", OBJ_HLINE, 0, 0, m_pdZone.fib618);
      ObjectSetInteger(0, "SM_EA_Fib618", OBJPROP_COLOR, clrGold);
      ObjectSetInteger(0, "SM_EA_Fib618", OBJPROP_STYLE, STYLE_DOT);

      ObjectCreate(0, "SM_EA_Fib786", OBJ_HLINE, 0, 0, m_pdZone.fib786);
      ObjectSetInteger(0, "SM_EA_Fib786", OBJPROP_COLOR, clrOrange);
      ObjectSetInteger(0, "SM_EA_Fib786", OBJPROP_STYLE, STYLE_DOT);
   }

   for(int i = 0; i < MathMin(ArraySize(m_higherMS.swingHighs), 5); i++)
   {
      string name = "SM_EA_HH_" + IntegerToString(i);
      ObjectCreate(0, name, OBJ_ARROW_DOWN, 0, m_higherMS.swingHighs[i].time, m_higherMS.swingHighs[i].price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrRed);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_BOTTOM);
   }

   for(int i = 0; i < MathMin(ArraySize(m_higherMS.swingLows), 5); i++)
   {
      string name = "SM_EA_HL_" + IntegerToString(i);
      ObjectCreate(0, name, OBJ_ARROW_UP, 0, m_higherMS.swingLows[i].time, m_higherMS.swingLows[i].price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrLime);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_TOP);
   }

   ChartRedraw();
}
//+------------------------------------------------------------------+
