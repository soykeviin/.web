//+------------------------------------------------------------------+
//|                                            GG_LondonSweepFVG.mq5  |
//|                                                                    |
//|  Versión mecánica aprobada de la estrategia de Gerard García:      |
//|   - Sesgo: cierre M15 vs EMA20 M15 (se reevalúa en cada vela).     |
//|   - Setup: FVG M15 (últimas 3 h) situado entero más allá del       |
//|     último swing high (ventas) / swing low (compras).              |
//|   - Ejecución: L1 en el borde cercano del FVG + L2 (promediada)    |
//|     en el borde lejano, mismo volumen.                             |
//|   - Riesgo: SL único en el servidor, volumen calculado para que    |
//|     la pérdida total (ambas llenas + comisión) sea <= 800 USD.     |
//|   - Salida: TP +500 USD en total (servidor), cierre de todo al     |
//|     tocar SL/TP y en la llegada de Nueva York.                     |
//|   - Máximo un setup por día. Solo ventana de Londres.              |
//|                                                                    |
//|  Referencias de requisitos (R/D/T/P) en docs/TRAZABILIDAD.md.      |
//+------------------------------------------------------------------+
#property copyright   "soykeviin"
#property version     "1.00"
#property description "Barrida + FVG M15 con sesgo EMA20 M15, sesión de Londres."
#property description "Dos limits (L1 + promediada), SL -800 / TP +500 USD en total."
#property description "Máximo un setup por día. Cierre total en la llegada de NY."

#include <Trade\Trade.mqh>

//--- Horario de verano que aplica el servidor del bróker
enum ENUM_SERVER_DST
  {
   SERVER_DST_NONE = 0, // Sin horario de verano
   SERVER_DST_US   = 1, // Horario de verano de EE. UU.
   SERVER_DST_EU   = 2  // Horario de verano europeo
  };

//+------------------------------------------------------------------+
//| Parámetros                                                         |
//+------------------------------------------------------------------+
input group "Riesgo (D08, D11, P4, P5, P7)"
input double InpRiskMoney             = 800.0; // Pérdida máxima total por setup (divisa de la cuenta)
input double InpTakeProfitMoney       = 500.0; // Beneficio objetivo total (divisa de la cuenta)
input double InpSlDistance            = 66.7;  // Distancia del SL desde el precio medio (en precio)
input double InpCommissionPerLotSide  = 0.0;   // Comisión por lote y lado (para el cálculo del volumen)

input group "Señal (D04, D05, D13, P3)"
input int    InpEmaPeriod             = 20;    // Periodo EMA (M15)
input int    InpPivotK                = 3;     // Velas a cada lado para el swing (M15)
input int    InpSwingLookbackBars     = 200;   // Velas M15 máximas para buscar el swing
input int    InpFvgMaxAgeHours        = 3;     // Antigüedad máxima del FVG (horas)
input double InpLimit2Buffer          = 0.0;   // Margen de L2 más allá del borde lejano del FVG (en precio)

input group "Horario (D03, D07, D10, P1, P2)"
input int    InpStartHourMadrid       = 9;     // Inicio de la ventana: hora (Madrid)
input int    InpStartMinuteMadrid     = 0;     // Inicio de la ventana: minuto (Madrid)
input int    InpSetupEndHourMadrid    = 11;    // Fin de creación de setups: hora (Madrid)
input int    InpSetupEndMinuteMadrid  = 0;     // Fin de creación de setups: minuto (Madrid)
input int    InpNyCutoffHour          = 9;     // Llegada de NY: hora (Nueva York)
input int    InpNyCutoffMinute        = 30;    // Llegada de NY: minuto (Nueva York)
input int    InpServerGmtOffsetWinter = 2;     // Offset GMT del servidor en invierno (horas)
input ENUM_SERVER_DST InpServerDst    = SERVER_DST_US; // Horario de verano del servidor

input group "Ejecución (P8, T5)"
input double InpMaxSpread             = 0.0;   // Spread máximo para colocar el setup (en precio, 0 = desactivado)
input ulong  InpDeviationPoints       = 50;    // Desviación máxima en cierres a mercado (puntos)
input ulong  InpMagic                 = 20261010; // Número mágico

//+------------------------------------------------------------------+
//| Tipos                                                              |
//+------------------------------------------------------------------+
struct SessionInfo
  {
   int               dayKey;       // AAAAMMDD en hora de Madrid
   bool              tradingDay;   // lunes a viernes (Madrid)
   datetime          startSrv;     // inicio de la ventana (hora servidor)
   datetime          setupEndSrv;  // fin de creación de setups (hora servidor)
   datetime          cutoffSrv;    // llegada de NY (hora servidor)
  };

struct FvgZone
  {
   double            low;
   double            high;
   datetime          formed;       // cierre de la tercera vela del FVG (hora servidor)
  };

struct SignalState
  {
   bool              ready;
   int               bias;         // +1 compras, -1 ventas, 0 sin sesgo
   double            close;
   double            ema;
   double            swing;
   datetime          swingTime;
  };

struct SetupPlan
  {
   int               dir;          // +1 compra, -1 venta
   double            l1;
   double            l2;
   double            sl;
   double            tp1;          // TP si solo entra L1
   double            tp2;          // TP combinado si entran L1 y L2
   double            volume;       // volumen de CADA orden
   double            risk;         // pérdida estimada si ambas llenas tocan SL (incluye comisión)
   double            zoneLow;
   double            zoneHigh;
  };

//+------------------------------------------------------------------+
//| Estado global                                                      |
//+------------------------------------------------------------------+
CTrade      g_trade;
int         g_emaHandle      = INVALID_HANDLE;
double      g_tickSize       = 0.0;

int         g_dayKey         = 0;
bool        g_dirty          = true;   // hay que releer órdenes, posiciones e historial
bool        g_placedToday    = false;  // ya se colocó el setup del día
bool        g_exitToday      = false;  // una posición del setup de hoy ya se cerró
bool        g_setupKnown     = false;  // se conocen SL/TP del setup de hoy
int         g_setupDir       = 0;
double      g_setupSL        = 0.0;
double      g_setupTP1       = 0.0;
double      g_setupTP2       = 0.0;

SignalState g_signal;
FvgZone     g_zones[];
datetime    g_lastSignalBar  = 0;

datetime    g_lastFlattenTry = 0;
datetime    g_lastModifyTry  = 0;
datetime    g_lastLogBar     = 0;
string      g_lastLogMsg     = "";

//+------------------------------------------------------------------+
//| Registro                                                           |
//+------------------------------------------------------------------+
void Log(const string msg)
  {
   PrintFormat("[GGA %s] %s", _Symbol, msg);
  }

//--- Evita repetir el mismo mensaje informativo en cada tick de una vela
void LogOncePerBar(const string msg)
  {
   datetime bar = iTime(_Symbol, PERIOD_M15, 0);
   if(bar == g_lastLogBar && msg == g_lastLogMsg)
      return;
   g_lastLogBar = bar;
   g_lastLogMsg = msg;
   Log(msg);
  }

bool TradeOk()
  {
   uint rc = g_trade.ResultRetcode();
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
  }

void LogTradeFailure(const string action)
  {
   Log(StringFormat("ERROR %s: retcode=%u (%s) %s", action, g_trade.ResultRetcode(),
                    g_trade.ResultRetcodeDescription(), g_trade.ResultComment()));
  }

string Px(const double price)
  {
   return DoubleToString(price, _Digits);
  }

//+------------------------------------------------------------------+
//| Tiempo: servidor <-> UTC <-> Madrid / Nueva York (C11, P1, P2)     |
//+------------------------------------------------------------------+
datetime MakeTime(const int year, const int mon, const int day, const int hour, const int minute)
  {
   MqlDateTime t;
   ZeroMemory(t);
   t.year = year;
   t.mon  = mon;
   t.day  = day;
   t.hour = hour;
   t.min  = minute;
   t.sec  = 0;
   return StructToTime(t);
  }

int DayOfWeek(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.day_of_week;
  }

//--- n-ésimo domingo (1 = primero) del mes, 00:00
datetime NthSunday(const int year, const int mon, const int n)
  {
   datetime first = MakeTime(year, mon, 1, 0, 0);
   int offsetDays = (7 - DayOfWeek(first)) % 7;
   return first + (offsetDays + 7 * (n - 1)) * 86400;
  }

//--- último domingo del mes, 00:00
datetime LastSunday(const int year, const int mon)
  {
   int y = year;
   int m = mon + 1;
   if(m > 12)
     {
      m = 1;
      y++;
     }
   datetime firstNext = MakeTime(y, m, 1, 0, 0);
   int dow  = DayOfWeek(firstNext);
   int back = (dow == 0) ? 7 : dow;
   return firstNext - back * 86400;
  }

//--- EE. UU.: segundo domingo de marzo 02:00 local -> primer domingo de noviembre 02:00 local
bool IsUsDst(const datetime utc)
  {
   MqlDateTime s;
   TimeToStruct(utc, s);
   datetime start = NthSunday(s.year, 3, 2) + 7 * 3600;   // 02:00 EST = 07:00 UTC
   datetime end   = NthSunday(s.year, 11, 1) + 6 * 3600;  // 02:00 EDT = 06:00 UTC
   return (utc >= start && utc < end);
  }

//--- UE: último domingo de marzo 01:00 UTC -> último domingo de octubre 01:00 UTC
bool IsEuDst(const datetime utc)
  {
   MqlDateTime s;
   TimeToStruct(utc, s);
   datetime start = LastSunday(s.year, 3) + 3600;
   datetime end   = LastSunday(s.year, 10) + 3600;
   return (utc >= start && utc < end);
  }

int ServerOffsetFromUtc(const datetime utc)
  {
   bool dst = false;
   if(InpServerDst == SERVER_DST_US)
      dst = IsUsDst(utc);
   else
      if(InpServerDst == SERVER_DST_EU)
         dst = IsEuDst(utc);
   return InpServerGmtOffsetWinter * 3600 + (dst ? 3600 : 0);
  }

//--- No se usa TimeGMT(): en el Strategy Tester no devuelve el GMT real
datetime ServerToUtc(const datetime srv)
  {
   datetime approxUtc = srv - InpServerGmtOffsetWinter * 3600;
   return srv - ServerOffsetFromUtc(approxUtc);
  }

datetime UtcToServer(const datetime utc)
  {
   return utc + ServerOffsetFromUtc(utc);
  }

int MadridOffset(const datetime utc)
  {
   return 3600 + (IsEuDst(utc) ? 3600 : 0);
  }

int NewYorkOffset(const datetime utc)
  {
   return -5 * 3600 + (IsUsDst(utc) ? 3600 : 0);
  }

//--- Ventanas del día de Madrid que contiene serverNow
void ComputeSession(const datetime serverNow, SessionInfo &s)
  {
   datetime utcNow    = ServerToUtc(serverNow);
   datetime madridNow = utcNow + MadridOffset(utcNow);
   MqlDateTime md;
   TimeToStruct(madridNow, md);

   s.dayKey     = md.year * 10000 + md.mon * 100 + md.day;
   s.tradingDay = (md.day_of_week >= 1 && md.day_of_week <= 5);

   //--- Los cambios de hora ocurren en domingo de madrugada: el offset a mediodía vale para todo el día
   datetime noonUtc = MakeTime(md.year, md.mon, md.day, 12, 0);
   int madridOff    = MadridOffset(noonUtc);
   int newYorkOff   = NewYorkOffset(noonUtc + 5 * 3600);

   datetime startUtc    = MakeTime(md.year, md.mon, md.day, InpStartHourMadrid, InpStartMinuteMadrid) - madridOff;
   datetime setupEndUtc = MakeTime(md.year, md.mon, md.day, InpSetupEndHourMadrid, InpSetupEndMinuteMadrid) - madridOff;
   datetime cutoffUtc   = MakeTime(md.year, md.mon, md.day, InpNyCutoffHour, InpNyCutoffMinute) - newYorkOff;
   if(setupEndUtc > cutoffUtc)
      setupEndUtc = cutoffUtc;

   s.startSrv    = UtcToServer(startUtc);
   s.setupEndSrv = UtcToServer(setupEndUtc);
   s.cutoffSrv   = UtcToServer(cutoffUtc);
  }

int MadridDayKeyFromServer(const datetime srv)
  {
   datetime utc = ServerToUtc(srv);
   MqlDateTime md;
   TimeToStruct(utc + MadridOffset(utc), md);
   return md.year * 10000 + md.mon * 100 + md.day;
  }

//+------------------------------------------------------------------+
//| Variables globales del terminal (persisten tras reinicios)         |
//+------------------------------------------------------------------+
string GvName(const string key)
  {
   return "GGA_" + _Symbol + "_" + IntegerToString((long)InpMagic) + "_" + key;
  }

bool IsDayBlocked(const int dayKey)
  {
   string name = GvName("blocked");
   return (GlobalVariableCheck(name) && (int)GlobalVariableGet(name) == dayKey);
  }

void BlockDay(const int dayKey, const string reason)
  {
   GlobalVariableSet(GvName("blocked"), dayKey);
   Log("Día " + IntegerToString(dayKey) + " terminado sin más intentos: " + reason);
  }

//+------------------------------------------------------------------+
//| Precios y volúmenes                                                |
//+------------------------------------------------------------------+
double RoundToTick(const double price)
  {
   return NormalizeDouble(MathRound(price / g_tickSize) * g_tickSize, _Digits);
  }

double FloorToTick(const double price)
  {
   return NormalizeDouble(MathFloor(price / g_tickSize + 1e-9) * g_tickSize, _Digits);
  }

double CeilToTick(const double price)
  {
   return NormalizeDouble(MathCeil(price / g_tickSize - 1e-9) * g_tickSize, _Digits);
  }

//--- Distancia mínima entre precio actual y órdenes/stops (stops level y freeze level)
double MinStopDistance()
  {
   long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long level  = (stops > freeze) ? stops : freeze;
   return (double)level * _Point;
  }

int VolumeDigits(const double step)
  {
   int digits = 0;
   while(digits < 8)
     {
      double scaled = step * MathPow(10.0, digits);
      if(MathAbs(scaled - MathRound(scaled)) < 1e-8)
         break;
      digits++;
     }
   return digits;
  }

//--- Volumen por orden redondeado HACIA ABAJO; 0 si no alcanza el mínimo
double NormalizeVolumeDown(const double raw)
  {
   double step  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double limit = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);
   if(step <= 0.0 || raw <= 0.0)
      return 0.0;

   double cap = raw;
   if(vmax > 0.0 && cap > vmax)
      cap = vmax;
   if(limit > 0.0 && cap * 2.0 > limit) // dos órdenes en la misma dirección
      cap = limit / 2.0;

   double v = MathFloor(cap / step + 1e-9) * step;
   v = NormalizeDouble(v, VolumeDigits(step));
   if(v < vmin - 1e-12)
      return 0.0;
   return v;
  }

//+------------------------------------------------------------------+
//| Órdenes y posiciones del EA                                        |
//+------------------------------------------------------------------+
bool IsOurSelectedOrder()
  {
   return (OrderGetString(ORDER_SYMBOL) == _Symbol && (ulong)OrderGetInteger(ORDER_MAGIC) == InpMagic);
  }

bool IsOurSelectedPosition()
  {
   return (PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == InpMagic);
  }

int CountOurOrders()
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket != 0 && IsOurSelectedOrder())
         n++;
     }
   return n;
  }

int CountOurPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket != 0 && IsOurSelectedPosition())
         n++;
     }
   return n;
  }

//--- Órdenes o posiciones del EA creadas antes del inicio de la ventana de hoy
bool HasStaleItems(const datetime startSrv)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket != 0 && IsOurSelectedOrder() && (datetime)OrderGetInteger(ORDER_TIME_SETUP) < startSrv)
         return true;
     }
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket != 0 && IsOurSelectedPosition() && (datetime)PositionGetInteger(POSITION_TIME) < startSrv)
         return true;
     }
   return false;
  }

//--- Cancela todas las pendientes y cierra todas las posiciones del EA (R23, R24, D07, D10)
bool FlattenAll(const string reason)
  {
   bool ok = true;
   Log("Cerrar todo: " + reason);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurSelectedOrder())
         continue;
      if(g_trade.OrderDelete(ticket) && TradeOk())
         Log(StringFormat("Orden pendiente #%I64u cancelada", ticket));
      else
        {
         LogTradeFailure(StringFormat("cancelar orden #%I64u", ticket));
         ok = false;
        }
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurSelectedPosition())
         continue;
      if(g_trade.PositionClose(ticket, InpDeviationPoints) && TradeOk())
         Log(StringFormat("Posición #%I64u cerrada a %s", ticket, Px(g_trade.ResultPrice())));
      else
        {
         LogTradeFailure(StringFormat("cerrar posición #%I64u", ticket));
         ok = false;
        }
     }

   g_dirty = true;
   return ok;
  }

//--- FlattenAll con reintento limitado a uno cada 2 s (desconexiones, mercado cerrado)
void RequestFlatten(const string reason)
  {
   datetime now = TimeCurrent();
   if(now - g_lastFlattenTry < 2)
      return;
   g_lastFlattenTry = now;
   FlattenAll(reason);
  }

//+------------------------------------------------------------------+
//| Estado del día reconstruido desde el terminal (T5)                 |
//+------------------------------------------------------------------+
void AccumulateSetupOrder(const ENUM_ORDER_TYPE type, const double price, const double sl, const double tp,
                          int &dir, double &l1, double &tp1, double &l2, double &tp2, double &slOut, int &found)
  {
   int d = (type == ORDER_TYPE_SELL_LIMIT) ? -1 : 1;
   if(found == 0)
     {
      dir   = d;
      l1    = price;
      tp1   = tp;
      l2    = price;
      tp2   = tp;
      slOut = sl;
      found = 1;
      return;
     }
   if(d != dir)
      return;
   found++;
   bool farther = (d < 0) ? (price > l2) : (price < l2);
   bool closer  = (d < 0) ? (price < l1) : (price > l1);
   if(farther)
     {
      l2  = price;
      tp2 = tp;
     }
   if(closer)
     {
      l1  = price;
      tp1 = tp;
     }
   if(sl != 0.0)
      slOut = sl;
  }

bool ContainsId(const ulong &ids[], const ulong id)
  {
   for(int i = ArraySize(ids) - 1; i >= 0; i--)
      if(ids[i] == id)
         return true;
   return false;
  }

//--- IDs de posición de las entradas del EA en el historial seleccionado
void CollectEntryPositionIds(ulong &ids[])
  {
   ArrayResize(ids, 0);
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ulong)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
         continue;
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry != DEAL_ENTRY_IN && entry != DEAL_ENTRY_INOUT)
         continue;
      ulong posId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      if(!ContainsId(ids, posId))
        {
         int n = ArraySize(ids);
         ArrayResize(ids, n + 1);
         ids[n] = posId;
        }
     }
  }

void RefreshDayState(const SessionInfo &s)
  {
   g_placedToday = false;
   g_exitToday   = false;
   g_setupKnown  = false;

   int    dir = 0, found = 0;
   double l1 = 0.0, l2 = 0.0, tp1 = 0.0, tp2 = 0.0, sl = 0.0;

   //--- Pendientes activas de hoy
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurSelectedOrder())
         continue;
      if((datetime)OrderGetInteger(ORDER_TIME_SETUP) < s.startSrv)
         continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT)
         continue;
      g_placedToday = true;
      AccumulateSetupOrder(type, OrderGetDouble(ORDER_PRICE_OPEN), OrderGetDouble(ORDER_SL),
                           OrderGetDouble(ORDER_TP), dir, l1, tp1, l2, tp2, sl, found);
     }

   //--- Posiciones abiertas hoy
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket != 0 && IsOurSelectedPosition() && (datetime)PositionGetInteger(POSITION_TIME) >= s.startSrv)
         g_placedToday = true;
     }

   //--- Historial desde el inicio de la ventana de hoy
   if(HistorySelect(s.startSrv, TimeCurrent() + 86400))
     {
      int totalOrders = HistoryOrdersTotal();
      for(int i = 0; i < totalOrders; i++)
        {
         ulong ticket = HistoryOrderGetTicket(i);
         if(ticket == 0)
            continue;
         if(HistoryOrderGetString(ticket, ORDER_SYMBOL) != _Symbol)
            continue;
         if((ulong)HistoryOrderGetInteger(ticket, ORDER_MAGIC) != InpMagic)
            continue;
         if((datetime)HistoryOrderGetInteger(ticket, ORDER_TIME_SETUP) < s.startSrv)
            continue;
         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)HistoryOrderGetInteger(ticket, ORDER_TYPE);
         if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT)
            continue;
         g_placedToday = true;
         AccumulateSetupOrder(type, HistoryOrderGetDouble(ticket, ORDER_PRICE_OPEN),
                              HistoryOrderGetDouble(ticket, ORDER_SL), HistoryOrderGetDouble(ticket, ORDER_TP),
                              dir, l1, tp1, l2, tp2, sl, found);
        }

      //--- Una salida de una posición abierta hoy (SL, TP o cierre del EA) termina el día
      ulong ids[];
      CollectEntryPositionIds(ids);
      int totalDeals = HistoryDealsTotal();
      for(int i = 0; i < totalDeals && !g_exitToday; i++)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0)
            continue;
         long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
            continue;
         if(ContainsId(ids, (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID)))
            g_exitToday = true;
        }
     }
   else
      Log("AVISO: HistorySelect falló; se reintentará en el siguiente tick");

   if(found >= 2 && dir != 0 && sl != 0.0)
     {
      g_setupKnown = true;
      g_setupDir   = dir;
      g_setupSL    = sl;
      g_setupTP1   = tp1;
      g_setupTP2   = tp2;
     }
  }

//+------------------------------------------------------------------+
//| Señal (D04, D05, T1, T2, T4)                                       |
//+------------------------------------------------------------------+
bool FindSwingHigh(const MqlRates &r[], const int count, const int k, double &level, datetime &when)
  {
   //--- r[] en serie: r[0] = última vela cerrada. Pivote confirmado: k velas cerradas a cada lado.
   for(int i = k; i < count - k; i++)
     {
      bool pivot = true;
      for(int j = 1; j <= k && pivot; j++)
         if(!(r[i].high > r[i - j].high && r[i].high > r[i + j].high))
            pivot = false;
      if(pivot)
        {
         level = r[i].high;
         when  = r[i].time;
         return true;
        }
     }
   return false;
  }

bool FindSwingLow(const MqlRates &r[], const int count, const int k, double &level, datetime &when)
  {
   for(int i = k; i < count - k; i++)
     {
      bool pivot = true;
      for(int j = 1; j <= k && pivot; j++)
         if(!(r[i].low < r[i - j].low && r[i].low < r[i + j].low))
            pivot = false;
      if(pivot)
        {
         level = r[i].low;
         when  = r[i].time;
         return true;
        }
     }
   return false;
  }

//--- Se ejecuta una vez por vela M15 cerrada
void ComputeSignal()
  {
   g_signal.ready = false;
   g_signal.bias  = 0;
   ArrayResize(g_zones, 0);

   if(BarsCalculated(g_emaHandle) < InpEmaPeriod + 1)
     {
      LogOncePerBar("EMA M15 aún sin calcular; se reintentará");
      return;
     }

   MqlRates r[];
   ArraySetAsSeries(r, true);
   int copied = CopyRates(_Symbol, PERIOD_M15, 1, InpSwingLookbackBars, r);
   if(copied < 2 * InpPivotK + 3)
     {
      LogOncePerBar(StringFormat("Datos M15 insuficientes (%d velas); se reintentará", copied));
      return;
     }

   double ema[];
   ArraySetAsSeries(ema, true);
   if(CopyBuffer(g_emaHandle, 0, 1, 1, ema) != 1)
     {
      LogOncePerBar("No se pudo leer la EMA M15; se reintentará");
      return;
     }

   g_signal.close = r[0].close;
   g_signal.ema   = ema[0];
   if(g_signal.close > g_signal.ema)
      g_signal.bias = 1;
   else
      if(g_signal.close < g_signal.ema)
         g_signal.bias = -1;

   g_signal.ready = true;
   if(g_signal.bias == 0)
     {
      Log(StringFormat("Sesgo: ninguno (cierre M15 %s = EMA%d %s)", Px(g_signal.close), InpEmaPeriod, Px(g_signal.ema)));
      return;
     }

   double   level = 0.0;
   datetime when  = 0;
   bool found = (g_signal.bias < 0) ? FindSwingHigh(r, copied, InpPivotK, level, when)
                                    : FindSwingLow(r, copied, InpPivotK, level, when);
   if(!found)
     {
      Log(StringFormat("Sesgo %s: no hay swing confirmado en %d velas M15 → no hay setup",
                       (g_signal.bias < 0 ? "BAJISTA" : "ALCISTA"), copied));
      g_signal.bias = 0;
      return;
     }
   g_signal.swing     = level;
   g_signal.swingTime = when;

   int      barSeconds = PeriodSeconds(PERIOD_M15);
   long     maxAge     = (long)InpFvgMaxAgeHours * 3600;
   datetime now        = TimeCurrent();

   for(int i = 0; i + 2 < copied; i++)
     {
      datetime formed = r[i].time + barSeconds;
      if((long)(now - formed) > maxAge)
         break;

      double zLow = 0.0, zHigh = 0.0;
      bool   isFvg = false;
      if(r[i + 2].low > r[i].high)        // FVG bajista
        {
         zLow  = r[i].high;
         zHigh = r[i + 2].low;
         isFvg = true;
        }
      else
         if(r[i + 2].high < r[i].low)     // FVG alcista
           {
            zLow  = r[i + 2].high;
            zHigh = r[i].low;
            isFvg = true;
           }
      if(!isFvg)
         continue;

      //--- T1: el FVG entero más allá del swing
      bool beyond = (g_signal.bias < 0) ? (zLow > level) : (zHigh < level);
      if(!beyond)
         continue;

      int n = ArraySize(g_zones);
      ArrayResize(g_zones, n + 1);
      g_zones[n].low    = zLow;
      g_zones[n].high   = zHigh;
      g_zones[n].formed = formed;
     }

   Log(StringFormat("Sesgo %s (cierre %s vs EMA%d %s) | swing %s %s @ %s | FVG válidos: %d",
                    (g_signal.bias < 0 ? "BAJISTA" : "ALCISTA"), Px(g_signal.close), InpEmaPeriod, Px(g_signal.ema),
                    (g_signal.bias < 0 ? "high" : "low"), Px(level), TimeToString(when), ArraySize(g_zones)));
  }

//+------------------------------------------------------------------+
//| Riesgo y plan de órdenes (D08, D09, D11, P4–P7, T3)                |
//+------------------------------------------------------------------+
bool BuildPlan(const int dir, const FvgZone &z, const MqlTick &tick, const double minDist, SetupPlan &p, string &why)
  {
   p.dir      = dir;
   p.zoneLow  = z.low;
   p.zoneHigh = z.high;

   ENUM_ORDER_TYPE side = (dir < 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double avg = 0.0;
   if(dir < 0)
     {
      p.l1 = RoundToTick(z.low);
      p.l2 = RoundToTick(z.high + InpLimit2Buffer);
      avg  = (p.l1 + p.l2) / 2.0;
      p.sl = FloorToTick(avg + InpSlDistance);           // redondeo hacia la entrada: riesgo <= objetivo
      if(p.l2 <= p.l1)
        {
         why = "L2 no queda por encima de L1";
         return false;
        }
      if(p.sl - p.l2 < minDist || p.sl <= p.l2)
        {
         why = StringFormat("FVG demasiado ancho: el SL (%s) no queda por encima de L2 (%s)", Px(p.sl), Px(p.l2));
         return false;
        }
     }
   else
     {
      p.l1 = RoundToTick(z.high);
      p.l2 = RoundToTick(z.low - InpLimit2Buffer);
      avg  = (p.l1 + p.l2) / 2.0;
      p.sl = CeilToTick(avg - InpSlDistance);
      if(p.l2 >= p.l1)
        {
         why = "L2 no queda por debajo de L1";
         return false;
        }
      if(p.l2 - p.sl < minDist || p.sl >= p.l2)
        {
         why = StringFormat("FVG demasiado ancho: el SL (%s) no queda por debajo de L2 (%s)", Px(p.sl), Px(p.l2));
         return false;
        }
     }

   //--- Pérdida por lote de cada orden hasta el SL, según las especificaciones del símbolo
   double profitL1 = 0.0, profitL2 = 0.0, profitUnit = 0.0;
   if(!OrderCalcProfit(side, _Symbol, 1.0, p.l1, p.sl, profitL1) ||
      !OrderCalcProfit(side, _Symbol, 1.0, p.l2, p.sl, profitL2))
     {
      why = StringFormat("OrderCalcProfit falló (error %d)", GetLastError());
      return false;
     }
   double lossPerLotPair = -(profitL1 + profitL2);        // una unidad de volumen en cada orden
   double commissionPair = 4.0 * InpCommissionPerLotSide;  // 2 órdenes x apertura y cierre
   if(lossPerLotPair <= 0.0)
     {
      why = "pérdida por lote calculada <= 0";
      return false;
     }

   p.volume = NormalizeVolumeDown(InpRiskMoney / (lossPerLotPair + commissionPair));
   if(p.volume <= 0.0)
     {
      why = StringFormat("volumen por debajo del mínimo del bróker (%.2f lotes) para un riesgo de %.2f",
                         SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), InpRiskMoney);
      return false;
     }
   p.risk = p.volume * (lossPerLotPair + commissionPair);

   //--- Beneficio por lote y por unidad de precio
   double unitClose = (dir < 0) ? p.l1 - 1.0 : p.l1 + 1.0;
   if(!OrderCalcProfit(side, _Symbol, 1.0, p.l1, unitClose, profitUnit) || profitUnit <= 0.0)
     {
      why = "no se pudo calcular el valor por punto";
      return false;
     }

   double d1 = InpTakeProfitMoney / (p.volume * profitUnit);        // solo L1
   double d2 = InpTakeProfitMoney / (2.0 * p.volume * profitUnit);  // L1 + L2 desde el precio medio
   if(dir < 0)
     {
      p.tp1 = FloorToTick(p.l1 - d1);   // redondeo alejándose: beneficio >= objetivo
      p.tp2 = FloorToTick(avg - d2);
      if(p.l1 - p.tp1 < minDist || p.l2 - p.tp2 < minDist)
        {
         why = "TP demasiado cerca de las entradas para el stops level del bróker";
         return false;
        }
      if(p.l1 - tick.bid < minDist || p.l1 <= tick.bid)
        {
         why = "L1 no queda por encima del Bid";
         return false;
        }
     }
   else
     {
      p.tp1 = CeilToTick(p.l1 + d1);
      p.tp2 = CeilToTick(avg + d2);
      if(p.tp1 - p.l1 < minDist || p.tp2 - p.l2 < minDist)
        {
         why = "TP demasiado cerca de las entradas para el stops level del bróker";
         return false;
        }
      if(tick.ask - p.l1 < minDist || p.l1 >= tick.ask)
        {
         why = "L1 no queda por debajo del Ask";
         return false;
        }
     }

   //--- Margen para ambas órdenes
   double margin = 0.0;
   if(!OrderCalcMargin(side, _Symbol, 2.0 * p.volume, p.l1, margin))
     {
      why = StringFormat("OrderCalcMargin falló (error %d)", GetLastError());
      return false;
     }
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > freeMargin)
     {
      why = StringFormat("margen insuficiente: necesita %.2f, libre %.2f", margin, freeMargin);
      return false;
     }
   return true;
  }

bool TradingPermitted(const int dir)
  {
   if(!MQLInfoInteger(MQL_TESTER))
     {
      if(!TerminalInfoInteger(TERMINAL_CONNECTED))
         return false;
      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
        {
         LogOncePerBar("Trading algorítmico desactivado en el terminal");
         return false;
        }
     }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      LogOncePerBar("Trading no permitido para este EA (Propiedades > Común)");
      return false;
     }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
     {
      LogOncePerBar("La cuenta no permite operar con EAs");
      return false;
     }
   long mode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY ||
      (dir > 0 && mode == SYMBOL_TRADE_MODE_SHORTONLY) || (dir < 0 && mode == SYMBOL_TRADE_MODE_LONGONLY))
     {
      LogOncePerBar("El símbolo no admite nuevas órdenes en esta dirección");
      return false;
     }
   return true;
  }

void PlaceSetup(const SessionInfo &s, const SetupPlan &p)
  {
   //--- La cancelación en la llegada de NY la hace el EA; la expiración en el servidor es un respaldo
   ENUM_ORDER_TYPE_TIME timeType   = ORDER_TIME_GTC;
   datetime             expiration = 0;
   long expMode = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   if((expMode & SYMBOL_EXPIRATION_SPECIFIED) != 0 && s.cutoffSrv > TimeCurrent() + 120)
     {
      timeType   = ORDER_TIME_SPECIFIED;
      expiration = s.cutoffSrv;
     }
   else
      if((expMode & SYMBOL_EXPIRATION_GTC) == 0 && (expMode & SYMBOL_EXPIRATION_DAY) != 0)
         timeType = ORDER_TIME_DAY;

   string side = (p.dir < 0) ? "VENTA" : "COMPRA";
   Log(StringFormat("SETUP %s | FVG [%s - %s] | L1 %s, L2 %s, %.2f lotes cada una | SL %s | TP1 %s | TP2 %s | riesgo estimado %.2f",
                    side, Px(p.zoneLow), Px(p.zoneHigh), Px(p.l1), Px(p.l2), p.volume, Px(p.sl), Px(p.tp1), Px(p.tp2), p.risk));

   bool ok1 = (p.dir < 0) ? g_trade.SellLimit(p.volume, p.l1, _Symbol, p.sl, p.tp1, timeType, expiration, "GGA L1")
                          : g_trade.BuyLimit(p.volume, p.l1, _Symbol, p.sl, p.tp1, timeType, expiration, "GGA L1");
   if(!ok1 || !TradeOk())
     {
      LogTradeFailure("colocar L1");
      BlockDay(s.dayKey, "L1 rechazada por el servidor (T7)");
      g_dirty = true;
      return;
     }
   Log(StringFormat("L1 colocada: orden #%I64u", g_trade.ResultOrder()));

   bool ok2 = (p.dir < 0) ? g_trade.SellLimit(p.volume, p.l2, _Symbol, p.sl, p.tp2, timeType, expiration, "GGA L2")
                          : g_trade.BuyLimit(p.volume, p.l2, _Symbol, p.sl, p.tp2, timeType, expiration, "GGA L2");
   if(!ok2 || !TradeOk())
     {
      LogTradeFailure("colocar L2");
      FlattenAll("L2 rechazada: se cancela L1 (T7)");
      BlockDay(s.dayKey, "L2 rechazada por el servidor (T7)");
      g_dirty = true;
      return;
     }
   Log(StringFormat("L2 colocada: orden #%I64u", g_trade.ResultOrder()));

   g_placedToday = true;
   g_setupKnown  = true;
   g_setupDir    = p.dir;
   g_setupSL     = p.sl;
   g_setupTP1    = p.tp1;
   g_setupTP2    = p.tp2;
   g_dirty       = true;
  }

//--- Elige el FVG colocable más cercano al precio (T2, T3) y coloca el setup
void TryPlaceSetup(const SessionInfo &s)
  {
   if(!g_signal.ready || g_signal.bias == 0 || ArraySize(g_zones) == 0)
      return;
   if(!TradingPermitted(g_signal.bias))
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0 || tick.ask < tick.bid)
      return;

   if(InpMaxSpread > 0.0 && tick.ask - tick.bid > InpMaxSpread)
     {
      LogOncePerBar(StringFormat("Spread %s > máximo %s: setup en espera", Px(tick.ask - tick.bid), Px(InpMaxSpread)));
      return;
     }

   double   minDist = MinStopDistance();
   long     maxAge  = (long)InpFvgMaxAgeHours * 3600;
   datetime now     = TimeCurrent();
   int      best    = -1;
   double   bestL1  = 0.0;

   for(int i = 0; i < ArraySize(g_zones); i++)
     {
      if((long)(now - g_zones[i].formed) > maxAge)
         continue;
      if(g_signal.bias < 0)
        {
         double l1 = RoundToTick(g_zones[i].low);
         if(l1 <= tick.bid || l1 - tick.bid < minDist)
            continue;
         if(best < 0 || l1 < bestL1)
           {
            best   = i;
            bestL1 = l1;
           }
        }
      else
        {
         double l1 = RoundToTick(g_zones[i].high);
         if(l1 >= tick.ask || tick.ask - l1 < minDist)
            continue;
         if(best < 0 || l1 > bestL1)
           {
            best   = i;
            bestL1 = l1;
           }
        }
     }

   if(best < 0)
     {
      LogOncePerBar("Ningún FVG válido queda al otro lado del precio actual: sin setup por ahora");
      return;
     }

   SetupPlan plan;
   string    why = "";
   if(!BuildPlan(g_signal.bias, g_zones[best], tick, minDist, plan, why))
     {
      LogOncePerBar("Setup descartado: " + why);
      return;
     }
   PlaceSetup(s, plan);
  }

//+------------------------------------------------------------------+
//| Gestión de la posición abierta (D12, Q12-B)                        |
//+------------------------------------------------------------------+
//--- Con L2 pendiente, el TP debe ser TP1; con L2 llena, todas las posiciones pasan a TP2.
//--- También repone el SL/TP si el servidor no los hubiese asociado.
void ManageOpenPositions(const int pendingCount)
  {
   if(!g_setupKnown)
     {
      LogOncePerBar("AVISO: posición abierta sin datos del setup de hoy; se mantiene el SL/TP del servidor");
      return;
     }
   datetime now = TimeCurrent();
   if(now - g_lastModifyTry < 2)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0.0 || tick.ask <= 0.0)
      return;

   double desiredTP = (pendingCount > 0) ? g_setupTP1 : g_setupTP2;
   double minDist   = MinStopDistance();
   double halfTick  = g_tickSize * 0.5;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurSelectedPosition())
         continue;

      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      if(MathAbs(curSL - g_setupSL) <= halfTick && MathAbs(curTP - desiredTP) <= halfTick)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_SELL)
        {
         if(tick.ask <= desiredTP)
           {
            FlattenAll("TP ya alcanzado antes de poder modificarlo");
            return;
           }
         if(tick.ask >= g_setupSL)
           {
            FlattenAll("SL ya alcanzado antes de poder modificarlo");
            return;
           }
         if(tick.ask - desiredTP < minDist || g_setupSL - tick.ask < minDist)
            continue;   // dentro del stops/freeze level: se reintenta en el siguiente tick
        }
      else
        {
         if(tick.bid >= desiredTP)
           {
            FlattenAll("TP ya alcanzado antes de poder modificarlo");
            return;
           }
         if(tick.bid <= g_setupSL)
           {
            FlattenAll("SL ya alcanzado antes de poder modificarlo");
            return;
           }
         if(desiredTP - tick.bid < minDist || tick.bid - g_setupSL < minDist)
            continue;
        }

      g_lastModifyTry = now;
      if(g_trade.PositionModify(ticket, g_setupSL, desiredTP) && TradeOk())
         Log(StringFormat("Posición #%I64u: SL %s, TP %s (%s)", ticket, Px(g_setupSL), Px(desiredTP),
                          (pendingCount > 0 ? "solo L1" : "L1 + L2, TP combinado")));
      else
         LogTradeFailure(StringFormat("modificar posición #%I64u", ticket));
     }
  }

//+------------------------------------------------------------------+
//| Registro de resultados: racha y consistencia (P9: solo registro)   |
//+------------------------------------------------------------------+
double DealNet(const ulong deal)
  {
   return HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_COMMISSION) +
          HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_FEE);
  }

void LogConsistency()
  {
   if(!HistorySelect(0, TimeCurrent() + 86400))
      return;
   ulong ids[];
   CollectEntryPositionIds(ids);

   int    keys[];
   double sums[];
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0 || !ContainsId(ids, (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID)))
         continue;
      int key = MadridDayKeyFromServer((datetime)HistoryDealGetInteger(deal, DEAL_TIME));
      int idx = -1;
      for(int k = ArraySize(keys) - 1; k >= 0; k--)
         if(keys[k] == key)
           {
            idx = k;
            break;
           }
      if(idx < 0)
        {
         idx = ArraySize(keys);
         ArrayResize(keys, idx + 1);
         ArrayResize(sums, idx + 1);
         keys[idx] = key;
         sums[idx] = 0.0;
        }
      sums[idx] += DealNet(deal);
     }

   double totalNet = 0.0, bestDay = 0.0;
   int    bestKey  = 0;
   for(int k = 0; k < ArraySize(sums); k++)
     {
      totalNet += sums[k];
      if(sums[k] > bestDay)
        {
         bestDay = sums[k];
         bestKey = keys[k];
        }
     }
   if(totalNet <= 0.0)
     {
      Log(StringFormat("Consistencia: beneficio neto acumulado %.2f (no aplica)", totalNet));
      return;
     }
   double ratio = bestDay / totalNet;
   Log(StringFormat("Consistencia: mejor día %d = %.2f (%.1f%% del beneficio neto %.2f)%s",
                    bestKey, bestDay, ratio * 100.0, totalNet, (ratio > 0.5 ? " | AVISO: supera el 50%" : "")));
  }

void MaybeLogDailySummary(const SessionInfo &s)
  {
   if(!s.tradingDay || TimeCurrent() < s.cutoffSrv)
      return;
   string gv = GvName("summary");
   if(GlobalVariableCheck(gv) && (int)GlobalVariableGet(gv) == s.dayKey)
      return;
   GlobalVariableSet(gv, s.dayKey);

   if(!g_placedToday)
     {
      Log(StringFormat("Resumen %d: sin setup", s.dayKey));
      return;
     }
   if(!HistorySelect(s.startSrv, TimeCurrent() + 86400))
      return;

   ulong ids[];
   CollectEntryPositionIds(ids);
   double net = 0.0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal != 0 && ContainsId(ids, (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID)))
         net += DealNet(deal);
     }

   string gvStreak = GvName("streak");
   int streak = GlobalVariableCheck(gvStreak) ? (int)GlobalVariableGet(gvStreak) : 0;
   if(ArraySize(ids) == 0)
     {
      Log(StringFormat("Resumen %d: setup colocado sin llenado | racha de días en pérdida: %d", s.dayKey, streak));
      return;
     }
   if(net < 0.0)
      streak++;
   else
      if(net > 0.0)
         streak = 0;
   GlobalVariableSet(gvStreak, streak);
   Log(StringFormat("Resumen %d: resultado neto %.2f | racha de días en pérdida: %d", s.dayKey, net, streak));
   LogConsistency();
  }

//+------------------------------------------------------------------+
//| Inicialización                                                     |
//+------------------------------------------------------------------+
bool InputError(const string msg)
  {
   Log("Parámetro inválido: " + msg);
   return false;
  }

bool ValidHourMinute(const int hour, const int minute)
  {
   return (hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59);
  }

bool ValidateInputs()
  {
   if(InpRiskMoney <= 0.0)
      return InputError("InpRiskMoney debe ser > 0");
   if(InpTakeProfitMoney <= 0.0)
      return InputError("InpTakeProfitMoney debe ser > 0");
   if(InpSlDistance <= 0.0)
      return InputError("InpSlDistance debe ser > 0");
   if(InpCommissionPerLotSide < 0.0)
      return InputError("InpCommissionPerLotSide no puede ser negativo");
   if(InpEmaPeriod < 1)
      return InputError("InpEmaPeriod debe ser >= 1");
   if(InpPivotK < 1)
      return InputError("InpPivotK debe ser >= 1");
   if(InpSwingLookbackBars < 2 * InpPivotK + 3)
      return InputError("InpSwingLookbackBars demasiado pequeño para InpPivotK");
   if(InpFvgMaxAgeHours < 1)
      return InputError("InpFvgMaxAgeHours debe ser >= 1");
   if(InpLimit2Buffer < 0.0)
      return InputError("InpLimit2Buffer no puede ser negativo");
   if(InpMaxSpread < 0.0)
      return InputError("InpMaxSpread no puede ser negativo");
   if(!ValidHourMinute(InpStartHourMadrid, InpStartMinuteMadrid) ||
      !ValidHourMinute(InpSetupEndHourMadrid, InpSetupEndMinuteMadrid) ||
      !ValidHourMinute(InpNyCutoffHour, InpNyCutoffMinute))
      return InputError("hora o minuto fuera de rango");
   if(InpStartHourMadrid * 60 + InpStartMinuteMadrid >= InpSetupEndHourMadrid * 60 + InpSetupEndMinuteMadrid)
      return InputError("el inicio de la ventana debe ser anterior al fin de creación de setups");
   if(InpServerGmtOffsetWinter < -12 || InpServerGmtOffsetWinter > 14)
      return InputError("InpServerGmtOffsetWinter fuera de rango");
   return true;
  }

void LogConfiguration()
  {
   long   marginMode = AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   string modeText   = (marginMode == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING) ? "hedging" : "netting";
   double unitProfit = 0.0;
   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid > 0.0 && !OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, 1.0, bid, bid + 1.0, unitProfit))
     {
      Log(StringFormat("AVISO: OrderCalcProfit falló al calcular el valor por punto (error %d)", GetLastError()));
      unitProfit = 0.0;
     }

   Log(StringFormat("Símbolo: dígitos %d, tick %s, tick value %.5f, contrato %.2f, valor por 1.0 de precio y lote %.4f %s",
                    _Digits, DoubleToString(g_tickSize, _Digits), SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE),
                    SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE), unitProfit, AccountInfoString(ACCOUNT_CURRENCY)));
   Log(StringFormat("Volumen: min %.2f, paso %.2f, max %.2f | stops level %d, freeze level %d | cuenta %s",
                    SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
                    SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                    (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL), modeText));

   SessionInfo s;
   ComputeSession(TimeCurrent(), s);
   Log(StringFormat("Hora servidor %s (GMT%+d) | día Madrid %d | ventana %s → setups hasta %s → cierre NY %s (hora servidor)",
                    TimeToString(TimeCurrent()), ServerOffsetFromUtc(ServerToUtc(TimeCurrent())) / 3600, s.dayKey,
                    TimeToString(s.startSrv), TimeToString(s.setupEndSrv), TimeToString(s.cutoffSrv)));
   if(s.cutoffSrv <= s.startSrv)
      Log("AVISO: la llegada de NY es anterior al inicio de la ventana; el EA no operará");
  }

int OnInit()
  {
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_tickSize <= 0.0)
      g_tickSize = _Point;
   if(g_tickSize <= 0.0)
     {
      Log("Tamaño de tick inválido");
      return INIT_FAILED;
     }

   long orderMode = SymbolInfoInteger(_Symbol, SYMBOL_ORDER_MODE);
   if((orderMode & SYMBOL_ORDER_LIMIT) == 0 || (orderMode & SYMBOL_ORDER_SL) == 0 || (orderMode & SYMBOL_ORDER_TP) == 0)
     {
      Log("El símbolo no admite órdenes limit con SL y TP");
      return INIT_FAILED;
     }

   if(AccountInfoString(ACCOUNT_CURRENCY) != "USD")
      Log("AVISO: la cuenta no está en USD; InpRiskMoney e InpTakeProfitMoney se interpretan en " +
          AccountInfoString(ACCOUNT_CURRENCY));

   g_emaHandle = iMA(_Symbol, PERIOD_M15, InpEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(g_emaHandle == INVALID_HANDLE)
     {
      Log(StringFormat("No se pudo crear la EMA M15 (error %d)", GetLastError()));
      return INIT_FAILED;
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetMarginMode();
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   ZeroMemory(g_signal);
   g_dirty         = true;
   g_dayKey        = 0;
   g_lastSignalBar = 0;

   LogConfiguration();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   //--- No se tocan órdenes ni posiciones: el SL/TP queda en el servidor y el estado se recupera al reiniciar (T5)
   if(g_emaHandle != INVALID_HANDLE)
     {
      IndicatorRelease(g_emaHandle);
      g_emaHandle = INVALID_HANDLE;
     }
   Log(StringFormat("EA detenido (motivo %d)", reason));
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   g_dirty = true;
  }

//+------------------------------------------------------------------+
//| Flujo principal                                                    |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!MQLInfoInteger(MQL_TESTER) && !TerminalInfoInteger(TERMINAL_CONNECTED))
      return;

   datetime now = TimeCurrent();
   SessionInfo s;
   ComputeSession(now, s);

   if(s.dayKey != g_dayKey)
     {
      g_dayKey        = s.dayKey;
      g_dirty         = true;
      g_lastSignalBar = 0;
      ZeroMemory(g_signal);
      ArrayResize(g_zones, 0);
     }
   if(g_dirty)
     {
      g_dirty = false;
      RefreshDayState(s);
     }

   int nOrders    = CountOurOrders();
   int nPositions = CountOurPositions();
   bool inWindow  = s.tradingDay && now >= s.startSrv && now < s.cutoffSrv;

   //--- 1. Fuera de la ventana (llegada de NY, noche, fin de semana): nada abierto (D07, D10)
   if(!inWindow)
     {
      if(nOrders + nPositions > 0)
         RequestFlatten("fin de sesión: llegada de NY o fuera de la ventana de Londres");
      else
         MaybeLogDailySummary(s);
      return;
     }

   //--- 2. Restos de un día anterior (EA apagado durante el corte)
   if(HasStaleItems(s.startSrv))
     {
      RequestFlatten("órdenes o posiciones de un día anterior");
      return;
     }

   //--- 3. Ya se tocó SL o TP de hoy: cerrar el resto y cancelar pendientes (R23, R24)
   if(g_exitToday)
     {
      if(nOrders + nPositions > 0)
         RequestFlatten("salida del setup de hoy: cerrar todo y cancelar pendientes");
      return;
     }

   //--- 4. Posición abierta: mantener SL/TP del servidor coherentes con L1/L2
   if(nPositions > 0)
     {
      ManageOpenPositions(nOrders);
      return;
     }

   //--- 5. Esperando llenado, o setup del día ya usado (R26)
   if(nOrders > 0 || g_placedToday || IsDayBlocked(s.dayKey) || now >= s.setupEndSrv)
      return;

   //--- 6. Buscar setup con velas M15 cerradas (D04, D05, D06)
   datetime bar = iTime(_Symbol, PERIOD_M15, 0);
   if(bar != g_lastSignalBar || !g_signal.ready)
     {
      g_lastSignalBar = bar;
      ComputeSignal();
     }
   TryPlaceSetup(s);
  }
//+------------------------------------------------------------------+
