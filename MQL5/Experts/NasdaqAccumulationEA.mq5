//+------------------------------------------------------------------+
//|                                         NasdaqAccumulationEA.mq5 |
//|    NASDAQ 100 - Ruptura de la acumulación 09:00-09:30 New York   |
//+------------------------------------------------------------------+
#property copyright   "8bits Agency"
#property version     "1.30"
#property description "NASDAQ 100 / M5: ruptura de la acumulación de apertura de Nueva York."
#property description "Una sola operación por día. Sin martingala, grid, promediado ni reentradas."

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Tipos                                                            |
//+------------------------------------------------------------------+
enum ENUM_PRICE_UNIT
  {
   UNIT_INDEX_POINTS = 0, // Puntos de índice (1.0 de precio)
   UNIT_MT5_POINTS   = 1  // Puntos MT5 (_Point del símbolo)
  };

enum ENUM_SERVER_DST
  {
   SERVER_DST_NONE = 0,   // Sin horario de verano
   SERVER_DST_US   = 1,   // Horario de verano de EE.UU.
   SERVER_DST_EU   = 2    // Horario de verano de Europa
  };

enum ENUM_EA_PHASE
  {
   PHASE_WAIT_SESSION,    // antes del inicio de la acumulación
   PHASE_BUILDING,        // dentro de la ventana de acumulación
   PHASE_WAIT_BREAKOUT,   // acumulación válida, esperando que el precio salga de la zona
   PHASE_SIGNAL_PENDING,  // ruptura detectada, ejecutando la entrada
   PHASE_DONE             // día terminado (operación realizada o bloqueado)
  };

struct TradePlan
  {
   int               direction;   // +1 LONG, -1 SHORT
   double            entry;       // Ask (LONG) o Bid (SHORT)
   double            sl;
   double            tp;
   double            lots;
   double            riskMoney;   // riesgo monetario real con el lotaje final
   double            riskBudget;  // riesgo máximo permitido (RiskPercent)
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== Sesión (hora de Nueva York) ==="
input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_M5;    // Timeframe de la estrategia
input int    StartHour      = 9;                      // StartHour: inicio acumulación/sesión (NY)
input int    StartMinute    = 0;                      // StartMinute
input int    AccumEndHour   = 9;                      // AccumEndHour: fin acumulación = inicio búsqueda de ruptura (NY)
input int    AccumEndMinute = 30;                     // AccumEndMinute
input int    EndHour        = 12;                     // EndHour: última hora para abrir operación (NY)
input int    EndMinute      = 0;                      // EndMinute

input group "=== Zona horaria del servidor del broker ==="
input int             ServerGMTOffset = 2;            // Offset GMT del servidor en horario de invierno (horas)
input ENUM_SERVER_DST ServerDSTMode   = SERVER_DST_US;// Horario de verano que aplica el servidor

input group "=== Estrategia ==="
input ENUM_PRICE_UNIT PointUnit             = UNIT_INDEX_POINTS; // Unidad de todos los inputs en "puntos"
input double          MaxAccumulationPoints = 120.0;  // MaxAccumulationPoints: rango máximo de la acumulación
input bool            UseCandleBodies       = true;   // Acumulación con el CUERPO de las velas (sin mechas)
input int             MinAccumCandles       = 4;      // Mínimo de velas consecutivas que forman la acumulación
input int             MinTouches            = 2;      // Mínimo de toques en el techo y en el suelo
input int             MinRebounds           = 2;      // Mínimo de rebotes (cambios techo<->suelo)
input double          TouchZonePercent      = 20.0;   // Franja de toque: % del rango junto a cada borde
input double          SL_Buffer_Points      = 1.0;    // SL_Buffer_Points: distancia extra del SL tras el extremo
input double          RiskReward            = 2.0;    // RiskReward: TP = riesgo x RiskReward

input group "=== Gestión del riesgo ==="
input double RiskPercent     = 10.0;                  // RiskPercent: % de equity arriesgado (máx. por día)
input double MaxSpreadPoints = 3.0;                   // MaxSpreadPoints: spread máximo para entrar
input bool   AdjustLotToLimits = false;               // Reducir el lote si supera el máximo o el margen libre (riesgo < RiskPercent)

input group "=== Ejecución ==="
input ulong  MagicNumber = 930900;                    // MagicNumber
input double Slippage    = 3.0;                       // Slippage/Deviation máximo (en la unidad de PointUnit)

input group "=== Visual y registro ==="
input bool   DrawObjects          = true;             // Dibujar acumulación y niveles
input bool   ShowPanel            = true;             // Mostrar panel informativo
input bool   KeepPreviousDrawings = false;            // Conservar dibujos de días anteriores
input color  AccumBoxColor        = C'222,196,160';   // Color del cuadro de acumulación válida
input color  InvalidBoxColor      = C'215,215,215';   // Color del cuadro de acumulación no válida
input color  AccumBorderColor     = C'60,60,60';      // Color del borde del cuadro
input bool   WriteCSVLog          = true;             // Guardar registro CSV (carpeta Common\Files)
input string CSVFileName          = "NasdaqAccumulationEA_log.csv"; // Nombre del archivo CSV

//+------------------------------------------------------------------+
//| Constantes                                                       |
//+------------------------------------------------------------------+
#define EA_TITLE             "NASDAQ ACCUMULATION EA"
#define MAX_TRADES_PER_DAY   1   // Regla fundamental: NO es un input a propósito
#define MAX_ORDER_ATTEMPTS   3   // Reintentos de envío ante errores transitorios
#define MAX_PROTECT_ATTEMPTS 3   // Intentos de fijar SL/TP antes de cerrar por seguridad
#define PANEL_LINES          14

//+------------------------------------------------------------------+
//| Variables globales                                               |
//+------------------------------------------------------------------+
CTrade   g_trade;

//--- especificaciones / configuración
double   g_unit         = 1.0;   // precio equivalente a 1 "punto" de los inputs
double   g_tickSize     = 0.0;
double   g_volMin       = 0.0;
double   g_volMax       = 0.0;
double   g_volStep      = 0.0;
int      g_volDigits    = 2;
int      g_tfSeconds    = 300;
ulong    g_deviation    = 0;
bool     g_isHedging    = true;
bool     g_drawEnabled  = false;
bool     g_panelEnabled = false;
bool     g_csvEnabled   = false;
string   g_objPrefix    = "";
ENUM_ORDER_TYPE_FILLING g_filling = ORDER_FILLING_FOK;

//--- estado del día (hora NY)
datetime g_nyDay        = 0;     // medianoche NY (reloj NY) del día en curso
datetime g_srvDayStart  = 0;     // medianoche NY expresada en hora del servidor
datetime g_srvAccStart  = 0;     // inicio acumulación (servidor)
datetime g_srvAccEnd    = 0;     // fin acumulación / inicio búsqueda (servidor)
datetime g_srvTradeEnd  = 0;     // fin de la ventana de entradas (servidor)
bool     g_isWeekend    = false;
ENUM_EA_PHASE g_phase   = PHASE_WAIT_SESSION;

bool     g_accBuilt     = false; // acumulación cerrada y evaluada
bool     g_accValid     = false; // rango dentro del máximo
double   g_accHigh      = 0.0;
double   g_accLow       = 0.0;
double   g_accRangePts  = 0.0;
double   g_estLots      = 0.0;   // lotaje estimado (informativo para el panel)
int      g_touchHigh    = 0;     // velas que tocaron el techo de la zona
int      g_accCandles   = 0;     // velas consecutivas que forman la acumulación
datetime g_srvBoxStart  = 0;     // apertura de la primera vela de la acumulación (servidor)
int      g_touchLow     = 0;     // velas que tocaron el suelo de la zona
int      g_rebounds     = 0;     // veces que el precio fue de un borde al otro

int      g_tradesToday   = 0;
bool     g_dayLocked     = false; // sin más entradas hasta el siguiente día NY
bool     g_noTradeLogged = false;
string   g_lastReason    = "";
double   g_dayStartEquity= 0.0;
double   g_dailyPnL      = 0.0;   // resultado realizado del día

bool     g_watchStarted    = false; // ya se comprobó si la ruptura ocurrió sin el EA
int      g_signalDir       = 0;   // ruptura pendiente de ejecutar
datetime g_signalTime      = 0;   // momento (servidor) en que el precio rompió la zona
double   g_signalPrice     = 0.0;
int      g_orderAttempts   = 0;
string   g_lastTransient   = "";

//--- operación del día
TradePlan g_plan;
bool     g_planActive    = false; // la posición fue abierta por esta instancia
bool     g_tpAdjusted    = false;
int      g_protectFails  = 0;
long     g_positionId    = 0;
datetime g_entryTime     = 0;
string   g_tradeStatus   = "NONE";
datetime g_lastPanelUpdate = 0;
string   g_rejectDetail  = "";    // detalle numérico del último rechazo

//--- estadísticas para el resumen final (backtest)
string   g_statReasons[];
int      g_statCounts[];
int      g_statDays      = 0;
int      g_statTrades    = 0;

//+------------------------------------------------------------------+
//| CONVERSIÓN HORARIA SERVIDOR <-> UTC <-> NUEVA YORK               |
//+------------------------------------------------------------------+
datetime MakeDate(const int year,const int mon,const int day)
  {
   MqlDateTime t;
   ZeroMemory(t);
   t.year = year;
   t.mon  = mon;
   t.day  = day;
   return StructToTime(t);
  }

int WeekDay(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t,s);
   return s.day_of_week;
  }

int YearOf(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t,s);
   return s.year;
  }

datetime DayStart(const datetime t)
  {
   return (datetime)(((long)t/86400)*86400);
  }

//--- n-ésimo domingo de un mes (00:00)
datetime NthSunday(const int year,const int mon,const int n)
  {
   datetime first = MakeDate(year,mon,1);
   int shift = (7 - WeekDay(first)) % 7;
   return first + (shift + 7*(n-1))*86400;
  }

//--- último domingo de un mes (00:00)
datetime LastSunday(const int year,const int mon)
  {
   datetime firstNext = (mon==12) ? MakeDate(year+1,1,1) : MakeDate(year,mon+1,1);
   datetime lastDay   = firstNext - 86400;
   return lastDay - WeekDay(lastDay)*86400;
  }

//--- EE.UU.: 2º domingo de marzo 02:00 local -> 1er domingo de noviembre 02:00 local
bool IsUsDstUtc(const datetime utc)
  {
   int y = YearOf(utc);
   datetime start = NthSunday(y,3,2)  + 7*3600; // 02:00 EST = 07:00 UTC
   datetime end   = NthSunday(y,11,1) + 6*3600; // 02:00 EDT = 06:00 UTC
   return (utc >= start && utc < end);
  }

//--- Europa: último domingo de marzo 01:00 UTC -> último domingo de octubre 01:00 UTC
bool IsEuDstUtc(const datetime utc)
  {
   int y = YearOf(utc);
   datetime start = LastSunday(y,3)  + 3600;
   datetime end   = LastSunday(y,10) + 3600;
   return (utc >= start && utc < end);
  }

int ServerOffsetSeconds(const datetime utc)
  {
   int offset = ServerGMTOffset*3600;
   if(ServerDSTMode==SERVER_DST_US && IsUsDstUtc(utc))
      offset += 3600;
   if(ServerDSTMode==SERVER_DST_EU && IsEuDstUtc(utc))
      offset += 3600;
   return offset;
  }

int NewYorkOffsetSeconds(const datetime utc)
  {
   return IsUsDstUtc(utc) ? -4*3600 : -5*3600;
  }

datetime ServerToUtc(const datetime srv)
  {
   datetime approx = srv - ServerGMTOffset*3600; // sólo para decidir si hay DST
   return srv - ServerOffsetSeconds(approx);
  }

datetime UtcToServer(const datetime utc)  { return utc + ServerOffsetSeconds(utc); }
datetime UtcToNewYork(const datetime utc) { return utc + NewYorkOffsetSeconds(utc); }

datetime NewYorkToUtc(const datetime ny)
  {
   datetime approx = ny + 5*3600; // sólo para decidir si hay DST
   return ny - NewYorkOffsetSeconds(approx);
  }

datetime ServerToNewYork(const datetime srv) { return UtcToNewYork(ServerToUtc(srv)); }
datetime NewYorkToServer(const datetime ny)  { return UtcToServer(NewYorkToUtc(ny)); }

//+------------------------------------------------------------------+
//| UTILIDADES                                                       |
//+------------------------------------------------------------------+
double PointsToPrice(const double pts)   { return pts*g_unit; }
double PriceToPoints(const double price) { return (g_unit > 0.0) ? price/g_unit : 0.0; }

double FloorToTick(const double price) { return NormalizeDouble(MathFloor(price/g_tickSize + 1e-9)*g_tickSize,_Digits); }
double CeilToTick(const double price)  { return NormalizeDouble(MathCeil(price/g_tickSize - 1e-9)*g_tickSize,_Digits); }

string Px(const double price)   { return DoubleToString(price,_Digits); }
string Pts(const double pts)    { return DoubleToString(pts,2); }
string Lots(const double lots)  { return DoubleToString(lots,g_volDigits); }
string Money(const double v)    { return DoubleToString(v,2) + " " + AccountInfoString(ACCOUNT_CURRENCY); }
string Side(const int dir)      { return (dir > 0) ? "LONG" : (dir < 0) ? "SHORT" : "-"; }

int VolumeDigits(const double step)
  {
   int    digits = 0;
   double s      = step;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-8)
     {
      s *= 10.0;
      digits++;
     }
   return digits;
  }

ENUM_ORDER_TYPE_FILLING ResolveFilling()
  {
   long modes = SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((modes & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//--- posición abierta por este EA en este símbolo (queda seleccionada)
ulong FindOurPosition()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0)
         continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC)!=MagicNumber)
         continue;
      return ticket;
     }
   return 0;
  }

//--- en cuentas netting cualquier posición del símbolo se fusionaría con la nuestra
bool AnyPositionOnSymbol()
  {
   for(int i=PositionsTotal()-1; i>=0; i--)
     {
      if(PositionGetTicket(i)>0 && PositionGetString(POSITION_SYMBOL)==_Symbol)
         return true;
     }
   return false;
  }

double FloatingPnL()
  {
   if(FindOurPosition()==0)
      return 0.0;
   return PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
  }

bool IsOurDeal(const ulong deal)
  {
   if(HistoryDealGetString(deal,DEAL_SYMBOL)!=_Symbol)
      return false;
   if((ulong)HistoryDealGetInteger(deal,DEAL_MAGIC)==MagicNumber)
      return true;
   // Cierre manual de nuestra posición: el deal no lleva magic pero sí el ID de posición
   return (g_positionId!=0 && HistoryDealGetInteger(deal,DEAL_POSITION_ID)==g_positionId);
  }

double DealNet(const ulong deal)
  {
   return HistoryDealGetDouble(deal,DEAL_PROFIT) + HistoryDealGetDouble(deal,DEAL_SWAP)
        + HistoryDealGetDouble(deal,DEAL_COMMISSION) + HistoryDealGetDouble(deal,DEAL_FEE);
  }

//--- reconstruye operaciones y resultado del día desde el historial (seguro ante reinicios)
void SyncTradesFromHistory()
  {
   int    entries = 0;
   double pnl     = 0.0;
   if(HistorySelect(g_srvDayStart,TimeCurrent()+86400))
     {
      int total = HistoryDealsTotal();
      for(int i=0; i<total; i++)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal==0 || !IsOurDeal(deal))
            continue;
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY)==DEAL_ENTRY_IN)
            entries++;
         pnl += DealNet(deal);
        }
     }
   if(entries > g_tradesToday)
      g_tradesToday = entries;
   g_dailyPnL    = pnl;
  }

//+------------------------------------------------------------------+
//| REGISTRO (Journal + CSV)                                         |
//+------------------------------------------------------------------+
void LogEvent(const string evt,const int dir,const double entry,const double sl,const double tp,
              const double lots,const double riskMoney,const string outcome,const double pnl,const string reason)
  {
   datetime srv   = TimeCurrent();
   datetime ny    = ServerToNewYork(srv);
   string   date  = TimeToString(ny,TIME_DATE);
   string   clock = TimeToString(ny,TIME_MINUTES);
   string   range = (g_accBuilt || g_accHigh > 0.0) ? Pts(g_accRangePts) : "-";
   string   sEntry= (entry > 0.0) ? Px(entry) : "-";
   string   sSL   = (sl > 0.0) ? Px(sl) : "-";
   string   sTP   = (tp > 0.0) ? Px(tp) : "-";
   string   sLots = (lots > 0.0) ? Lots(lots) : "-";
   string   sRisk = (riskMoney > 0.0) ? DoubleToString(riskMoney,2) : "-";
   string   sPnL  = (evt=="TRADE_CLOSE") ? DoubleToString(pnl,2) : "-";

   PrintFormat("[NAE] %s %s NY | %s | %s | entry=%s sl=%s tp=%s | range=%s pts | lots=%s | risk=%s | result=%s | P/L=%s | reason=%s",
               date,clock,evt,Side(dir),sEntry,sSL,sTP,range,sLots,sRisk,outcome,sPnL,reason);

   if(!g_csvEnabled)
      return;
   int h = FileOpen(CSVFileName,FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_COMMON);
   if(h==INVALID_HANDLE)
     {
      PrintFormat("[NAE] ERROR: no se pudo abrir el CSV '%s' (error %d)",CSVFileName,GetLastError());
      return;
     }
   if(FileSize(h)==0)
      FileWriteString(h,"Date;TimeNY;ServerTime;Symbol;Event;Direction;Entry;StopLoss;TakeProfit;RangePts;Lots;RiskMoney;Result;PnL;Reason\r\n");
   FileSeek(h,0,SEEK_END);
   string line = StringFormat("%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s;%s\r\n",
                              date,clock,TimeToString(srv,TIME_DATE|TIME_SECONDS),_Symbol,evt,Side(dir),
                              sEntry,sSL,sTP,range,sLots,sRisk,outcome,sPnL,reason);
   FileWriteString(h,line);
   FileClose(h);
  }

//--- estadísticas de días sin operar, por motivo
void StatAdd(const string reason)
  {
   int n = ArraySize(g_statReasons);
   for(int i=0; i<n; i++)
     {
      if(g_statReasons[i]==reason)
        {
         g_statCounts[i]++;
         return;
        }
     }
   ArrayResize(g_statReasons,n+1);
   ArrayResize(g_statCounts,n+1);
   g_statReasons[n] = reason;
   g_statCounts[n]  = 1;
  }

void PrintSummary()
  {
   PrintFormat("[NAE] ===== RESUMEN: %d días hábiles evaluados | %d operaciones abiertas =====",g_statDays,g_statTrades);
   for(int i=0; i<ArraySize(g_statReasons); i++)
      PrintFormat("[NAE]   Días sin operar por %s: %d",g_statReasons[i],g_statCounts[i]);
  }

//--- bloquea nuevas entradas hasta el siguiente día NY
void LockDay(const string reason,const bool record=true)
  {
   if(g_dayLocked)
      return;
   g_dayLocked  = true;
   g_signalDir  = 0;
   g_lastReason = reason;
   g_phase      = PHASE_DONE;
   if(record && !g_noTradeLogged && g_tradesToday==0)
     {
      g_noTradeLogged = true;
      StatAdd(reason);
      LogEvent("NO_TRADE",0,0.0,0.0,0.0,0.0,0.0,"NOT_EXECUTED",0.0,reason);
     }
   else
      PrintFormat("[NAE] Entradas bloqueadas hasta el próximo día NY: %s",reason);
  }

//+------------------------------------------------------------------+
//| DIBUJO                                                           |
//+------------------------------------------------------------------+
string DayPrefix(const datetime nyDay) { return g_objPrefix + TimeToString(nyDay,TIME_DATE) + "_"; }
string ObjName(const string suffix)    { return DayPrefix(g_nyDay) + suffix; }

void ApplyCommonProps(const string name,const color clr)
  {
   ObjectSetInteger(0,name,OBJPROP_COLOR,clr);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_SELECTED,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  }

void DrawRectangle(const string name,const datetime t1,const double p1,const datetime t2,const double p2,const color clr)
  {
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_RECTANGLE,0,t1,p1,t2,p2))
         return;
      ObjectSetInteger(0,name,OBJPROP_FILL,true);
      ObjectSetInteger(0,name,OBJPROP_BACK,true);
     }
   else
     {
      ObjectMove(0,name,0,t1,p1);
      ObjectMove(0,name,1,t2,p2);
     }
   ApplyCommonProps(name,clr);
  }

void DrawSegment(const string name,const datetime t1,const datetime t2,const double price,
                 const color clr,const ENUM_LINE_STYLE style,const int width)
  {
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_TREND,0,t1,price,t2,price))
         return;
      ObjectSetInteger(0,name,OBJPROP_RAY_RIGHT,false);
     }
   else
     {
      ObjectMove(0,name,0,t1,price);
      ObjectMove(0,name,1,t2,price);
     }
   ObjectSetInteger(0,name,OBJPROP_STYLE,style);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,width);
   ApplyCommonProps(name,clr);
  }

void DrawLabelText(const string name,const datetime t,const double price,const string text,
                   const color clr,const ENUM_ANCHOR_POINT anchor)
  {
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,OBJ_TEXT,0,t,price))
         return;
     }
   else
      ObjectMove(0,name,0,t,price);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetString(0,name,OBJPROP_FONT,"Arial");
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,8);
   ObjectSetInteger(0,name,OBJPROP_ANCHOR,anchor);
   ApplyCommonProps(name,clr);
  }

void DrawArrow(const string name,const ENUM_OBJECT type,const datetime t,const double price,const color clr)
  {
   if(ObjectFind(0,name)<0)
     {
      if(!ObjectCreate(0,name,type,0,t,price))
         return;
     }
   else
      ObjectMove(0,name,0,t,price);
   ObjectSetInteger(0,name,OBJPROP_WIDTH,2);
   ApplyCommonProps(name,clr);
  }

//--- rectángulo 09:00-09:30 NY + máximo y mínimo extendidos hasta el fin de la sesión
void DrawAccumulation(const double hi,const double lo,const bool valid)
  {
   if(!g_drawEnabled || hi<=0.0 || lo<=0.0)
      return;
   datetime t1 = (g_srvBoxStart > 0) ? g_srvBoxStart : g_srvAccStart;
   // Cuadro relleno detrás de las velas + borde por delante para que siempre se vea
   DrawRectangle(ObjName("ACC_BOX"),t1,hi,g_srvAccEnd,lo,valid ? AccumBoxColor : InvalidBoxColor);
   string border = ObjName("ACC_BORDER");
   DrawRectangle(border,t1,hi,g_srvAccEnd,lo,AccumBorderColor);
   ObjectSetInteger(0,border,OBJPROP_FILL,false);
   ObjectSetInteger(0,border,OBJPROP_BACK,false);
   ObjectSetInteger(0,border,OBJPROP_WIDTH,2);
   DrawSegment(ObjName("ACC_HIGH"),g_srvAccEnd,g_srvTradeEnd,hi,clrDodgerBlue,STYLE_DASH,1);
   DrawSegment(ObjName("ACC_LOW"),g_srvAccEnd,g_srvTradeEnd,lo,clrOrangeRed,STYLE_DASH,1);
   DrawLabelText(ObjName("ACC_HIGH_TXT"),t1,hi,"ACUMULACIÓN  "+IntegerToString(g_accCandles)+" velas  |  "+
                 Pts(PriceToPoints(hi-lo))+" pts  |  rebotes "+IntegerToString(g_rebounds)+
                 (valid ? "" : "  |  NO VÁLIDA"),valid ? AccumBorderColor : clrRed,ANCHOR_LEFT_LOWER);
   ChartRedraw(0);
  }

void DrawTradeLevels(const int dir,const double entry,const double sl,const double tp,const datetime t)
  {
   if(!g_drawEnabled)
      return;
   datetime tEnd = t + 12*g_tfSeconds;
   if(g_srvTradeEnd > tEnd)
      tEnd = g_srvTradeEnd;
   DrawSegment(ObjName("ENTRY"),t,tEnd,entry,clrWhite,STYLE_DOT,1);
   DrawSegment(ObjName("SL"),t,tEnd,sl,clrRed,STYLE_SOLID,2);
   DrawSegment(ObjName("TP"),t,tEnd,tp,clrLime,STYLE_SOLID,2);
   DrawLabelText(ObjName("ENTRY_TXT"),tEnd,entry,"ENTRY "+Px(entry),clrWhite,ANCHOR_LEFT);
   DrawLabelText(ObjName("SL_TXT"),tEnd,sl,"SL "+Px(sl),clrRed,ANCHOR_LEFT);
   DrawLabelText(ObjName("TP_TXT"),tEnd,tp,"TP "+Px(tp),clrLime,ANCHOR_LEFT);
   DrawArrow(ObjName("SIGNAL_ARROW"),dir > 0 ? OBJ_ARROW_BUY : OBJ_ARROW_SELL,t,entry,dir > 0 ? clrLime : clrRed);
   DrawLabelText(ObjName("SIGNAL_TXT"),t,entry,Side(dir),dir > 0 ? clrLime : clrRed,dir > 0 ? ANCHOR_RIGHT_UPPER : ANCHOR_RIGHT_LOWER);
   ChartRedraw(0);
  }

void DrawResult(const datetime t,const double price,const string text,const bool win)
  {
   if(!g_drawEnabled)
      return;
   DrawLabelText(ObjName("RESULT"),t,price,text,win ? clrLime : clrTomato,ANCHOR_LEFT_LOWER);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| PANEL                                                            |
//+------------------------------------------------------------------+
void CreatePanel()
  {
   string bg = g_objPrefix+"PANEL_BG";
   if(ObjectFind(0,bg)<0)
      ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,bg,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,bg,OBJPROP_XDISTANCE,8);
   ObjectSetInteger(0,bg,OBJPROP_YDISTANCE,22);
   ObjectSetInteger(0,bg,OBJPROP_XSIZE,330);
   ObjectSetInteger(0,bg,OBJPROP_YSIZE,PANEL_LINES*16+12);
   ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,C'16,20,30');
   ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,bg,OBJPROP_BACK,false);
   ApplyCommonProps(bg,clrDimGray);

   for(int i=0; i<PANEL_LINES; i++)
     {
      string name = g_objPrefix+"PANEL_L"+IntegerToString(i);
      if(ObjectFind(0,name)<0)
         ObjectCreate(0,name,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,name,OBJPROP_XDISTANCE,16);
      ObjectSetInteger(0,name,OBJPROP_YDISTANCE,28+i*16);
      ObjectSetString(0,name,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,name,OBJPROP_FONTSIZE,9);
      ObjectSetString(0,name,OBJPROP_TEXT," ");
      ApplyCommonProps(name,i==0 ? clrGold : clrWhiteSmoke);
     }
  }

string StatusText()
  {
   if(g_isWeekend)
      return "MARKET CLOSED (WEEKEND)";
   if(FindOurPosition()>0)
      return "IN TRADE";
   if(g_tradesToday>0)
      return "DONE FOR TODAY";
   if(g_dayLocked)
      return "NO TRADE TODAY";
   switch(g_phase)
     {
      case PHASE_WAIT_SESSION:   return "WAITING ACCUMULATION";
      case PHASE_BUILDING:       return "BUILDING ACCUMULATION";
      case PHASE_WAIT_BREAKOUT:  return "WAITING BREAKOUT";
      case PHASE_SIGNAL_PENDING: return "SIGNAL "+Side(g_signalDir)+" PENDING";
      default:                   return "DONE";
     }
  }

string TradeStatusText()
  {
   if(FindOurPosition()>0)
     {
      int dir = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ? 1 : -1;
      return StringFormat("%s OPEN @ %s (%s)",Side(dir),Px(PositionGetDouble(POSITION_PRICE_OPEN)),
                          DoubleToString(PositionGetDouble(POSITION_PROFIT),2));
     }
   return g_tradeStatus;
  }

void UpdatePanel()
  {
   if(!g_panelEnabled)
      return;
   datetime srvNow = (MQLInfoInteger(MQL_TESTER)!=0) ? TimeCurrent() : TimeTradeServer();
   datetime nyNow  = ServerToNewYork(srvNow);
   bool     haveAcc= (g_accHigh > 0.0 && g_accLow > 0.0);

   double spreadPts = 0.0;
   MqlTick tick;
   if(SymbolInfoTick(_Symbol,tick))
      spreadPts = PriceToPoints(tick.ask - tick.bid);

   string lotsTxt = "-";
   if(g_plan.lots > 0.0)
      lotsTxt = Lots(g_plan.lots)+" (risk "+DoubleToString(g_plan.riskMoney,2)+")";
   else if(g_estLots > 0.0)
      lotsTxt = "~"+Lots(g_estLots)+" (estimated)";

   string lines[PANEL_LINES];
   lines[0]  = EA_TITLE;
   lines[1]  = "Status: "+StatusText();
   lines[2]  = "NY Time: "+TimeToString(nyNow,TIME_MINUTES)+"  ("+TimeToString(nyNow,TIME_DATE)+")";
   lines[3]  = "Acc High: "+(haveAcc ? Px(g_accHigh) : "-");
   lines[4]  = "Acc Low:  "+(haveAcc ? Px(g_accLow) : "-");
   lines[5]  = "Range: "+(haveAcc ? Pts(g_accRangePts) : "-")+" pts (max "+Pts(MaxAccumulationPoints)+")";
   lines[6]  = StringFormat("Risk: %.1f%% (%s)",RiskPercent,Money(DailyRiskBudget()));
   lines[7]  = "Lots: "+lotsTxt;
   lines[8]  = "Trade: "+TradeStatusText();
   lines[9]  = StringFormat("Trades today: %d/%d",g_tradesToday,MAX_TRADES_PER_DAY);
   lines[10] = "Daily P/L: "+Money(g_dailyPnL + FloatingPnL());
   lines[11] = "Spread: "+Pts(spreadPts)+" pts (max "+Pts(MaxSpreadPoints)+")";
   lines[12] = "Reason: "+(g_lastReason=="" ? "-" : g_lastReason);
   lines[13] = StringFormat("Candles %d/%d | Touches %d/%d | Rebounds %d/%d",g_accCandles,MinAccumCandles,
                            g_touchHigh,g_touchLow,g_rebounds,MinRebounds);

   for(int i=0; i<PANEL_LINES; i++)
      ObjectSetString(0,g_objPrefix+"PANEL_L"+IntegerToString(i),OBJPROP_TEXT,lines[i]);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| GESTIÓN DEL DÍA                                                  |
//+------------------------------------------------------------------+
void ResetDay(const datetime nyDay)
  {
   if(g_drawEnabled && !KeepPreviousDrawings && g_nyDay>0)
      ObjectsDeleteAll(0,DayPrefix(g_nyDay));

   g_nyDay       = nyDay;
   g_srvDayStart = NewYorkToServer(nyDay);
   g_srvAccStart = NewYorkToServer(nyDay + StartHour*3600    + StartMinute*60);
   g_srvAccEnd   = NewYorkToServer(nyDay + AccumEndHour*3600 + AccumEndMinute*60);
   g_srvTradeEnd = NewYorkToServer(nyDay + EndHour*3600      + EndMinute*60);

   int dow = WeekDay(nyDay);
   g_isWeekend      = (dow==0 || dow==6);
   g_phase          = PHASE_WAIT_SESSION;
   g_accBuilt       = false;
   g_accValid       = false;
   g_accHigh        = 0.0;
   g_accLow         = 0.0;
   g_accRangePts    = 0.0;
   g_estLots        = 0.0;
   g_touchHigh      = 0;
   g_touchLow       = 0;
   g_accCandles     = 0;
   g_rebounds       = 0;
   g_srvBoxStart    = 0;
   g_tradesToday    = 0;
   g_dayLocked      = false;
   g_noTradeLogged  = false;
   g_lastReason     = "";
   g_watchStarted   = false;
   g_signalDir      = 0;
   g_signalTime     = 0;
   g_signalPrice    = 0.0;
   g_orderAttempts  = 0;
   g_lastTransient  = "";
   g_planActive     = false;
   g_tpAdjusted     = false;
   g_protectFails   = 0;
   g_tradeStatus    = "NONE";
   ZeroMemory(g_plan);
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   //--- posición que sigue abierta (día anterior o reinicio del EA)
   g_positionId = 0;
   if(FindOurPosition()>0)
      g_positionId = PositionGetInteger(POSITION_IDENTIFIER);

   SyncTradesFromHistory();

   PrintFormat("[NAE] Nuevo día NY %s | Acumulación (servidor) %s - %s | Fin de entradas %s | Equity inicial %s",
               TimeToString(nyDay,TIME_DATE),TimeToString(g_srvAccStart,TIME_DATE|TIME_MINUTES),
               TimeToString(g_srvAccEnd,TIME_MINUTES),TimeToString(g_srvTradeEnd,TIME_MINUTES),Money(g_dayStartEquity));

   if(!g_isWeekend)
      g_statDays++;
   if(g_isWeekend)
      LockDay("WEEKEND",false);
   else if(g_tradesToday >= MAX_TRADES_PER_DAY)
     {
      g_tradeStatus = "ALREADY TRADED (restored)";
      LockDay("ALREADY_TRADED",false);
     }
  }

//--- cambio de día según la fecha de Nueva York
bool DetectNewDay(const datetime srvNow)
  {
   datetime nyDay = DayStart(ServerToNewYork(srvNow));
   if(nyDay==g_nyDay)
      return false;
   ResetDay(nyDay);
   return true;
  }

//+------------------------------------------------------------------+
//| ACUMULACIÓN                                                      |
//+------------------------------------------------------------------+
//--- velas de la ventana 09:00-09:30 NY en orden cronológico
int WindowBars(const MqlRates &rates[],const int copied,MqlRates &win[])
  {
   ArrayResize(win,0);
   for(int i=0; i<copied; i++)
     {
      if(rates[i].time < g_srvAccStart || rates[i].time >= g_srvAccEnd)
         continue;
      int n = ArraySize(win);
      ArrayResize(win,n+1);
      win[n] = rates[i];
     }
   return ArraySize(win);
  }

double BarTop(const MqlRates &bars[],const int k)    { return UseCandleBodies ? MathMax(bars[k].open,bars[k].close) : bars[k].high; }
double BarBottom(const MqlRates &bars[],const int k) { return UseCandleBodies ? MathMin(bars[k].open,bars[k].close) : bars[k].low; }

//--- ACUMULACIÓN = bloque de velas CONSECUTIVAS que termina en la última vela de la
//    ventana (justo antes de las 09:30), donde cada vela solapa su cuerpo con la zona
//    formada por las siguientes y el rango total no supera MaxAccumulationPoints.
//    Devuelve el número de velas del bloque; 'first' es el índice de la primera.
int FindAccumulation(const MqlRates &win[],const int n,double &hi,double &lo,int &first)
  {
   hi    = 0.0;
   lo    = 0.0;
   first = n;
   for(int k=n-1; k>=0; k--)
     {
      double top    = BarTop(win,k);
      double bottom = BarBottom(win,k);
      if(k==n-1)
        {
         if(PriceToPoints(top-bottom) > MaxAccumulationPoints + 1e-9)
            break;
         hi = top;
         lo = bottom;
         first = k;
         continue;
        }
      if(bottom > hi || top < lo)
         break;   // no solapa: el precio venía de otro nivel (tendencia, no acumulación)
      double newHi = MathMax(hi,top);
      double newLo = MathMin(lo,bottom);
      if(PriceToPoints(newHi-newLo) > MaxAccumulationPoints + 1e-9)
         break;
      hi    = newHi;
      lo    = newLo;
      first = k;
     }
   return n-first;
  }

//--- rebotes: velas del bloque que llegan (mecha incluida) a la franja superior o
//    inferior de la zona. La franja es TouchZonePercent % del rango junto a cada borde.
void CountTouches(const MqlRates &win[],const int first,const int n,const double hi,const double lo,
                  int &touchHi,int &touchLo)
  {
   double tol = (hi - lo)*TouchZonePercent/100.0;
   touchHi = 0;
   touchLo = 0;
   for(int i=first; i<n; i++)
     {
      if(win[i].high >= hi - tol)
         touchHi++;
      if(win[i].low <= lo + tol)
         touchLo++;
     }
  }

//--- rebotes: cuántas veces el precio pasa de tocar un borde a tocar el otro. Una vela que toca
//    ambos bordes cuenta en el orden de su dirección (alcista: suelo->techo, bajista: techo->suelo).
//    Una tendencia sólo cambia de lado una vez; una acumulación va y vuelve varias veces.
int CountRebounds(const MqlRates &win[],const int first,const int n,const double hi,const double lo)
  {
   double tol     = (hi - lo)*TouchZonePercent/100.0;
   int    last    = 0;   // +1 techo, -1 suelo
   int    changes = 0;
   for(int i=first; i<n; i++)
     {
      bool touchTop = (win[i].high >= hi - tol);
      bool touchBot = (win[i].low  <= lo + tol);
      int  sides[2] = {0,0};
      int  count = 0;
      if(touchTop && touchBot)
        {
         bool bullish = (win[i].close >= win[i].open);
         sides[0] = bullish ? -1 : 1;
         sides[1] = bullish ? 1 : -1;
         count    = 2;
        }
      else if(touchTop)
        { sides[0] = 1;  count = 1; }
      else if(touchBot)
        { sides[0] = -1; count = 1; }
      for(int j=0; j<count; j++)
        {
         if(last!=0 && sides[j]!=last)
            changes++;
         last = sides[j];
        }
     }
   return changes;
  }

//--- actualización en vivo mientras se forma (sólo visual/panel)
void UpdateLiveAccumulation(const datetime now)
  {
   MqlRates rates[], win[];
   int copied = CopyRates(_Symbol,SignalTimeframe,g_srvAccStart,now,rates);
   if(copied<=0)
      return;
   int n = WindowBars(rates,copied,win);
   if(n==0)
      return;
   double hi = 0.0, lo = 0.0;
   int first = 0;
   g_accCandles = FindAccumulation(win,n,hi,lo,first);
   if(g_accCandles==0)
      return;
   g_srvBoxStart = win[first].time;
   g_accHigh     = hi;
   g_accLow      = lo;
   g_accRangePts = PriceToPoints(hi-lo);
   CountTouches(win,first,n,hi,lo,g_touchHigh,g_touchLow);
   g_rebounds    = CountRebounds(win,first,n,hi,lo);
   DrawAccumulation(hi,lo,g_accCandles >= MinAccumCandles && g_touchHigh >= MinTouches &&
                    g_touchLow >= MinTouches && g_rebounds >= MinRebounds);
  }

//--- construye la acumulación definitiva con las velas cerradas de la ventana
//    devuelve false si debe reintentarse en el próximo tick (historial sincronizando)
bool BuildAccumulation(const datetime now)
  {
   MqlRates rates[], win[];
   int copied   = CopyRates(_Symbol,SignalTimeframe,g_srvAccStart,g_srvAccEnd-1,rates);
   int expected = (int)(((long)g_srvAccEnd - (long)g_srvAccStart)/g_tfSeconds);
   int n        = (copied > 0) ? WindowBars(rates,copied,win) : 0;

   if(n < expected)
     {
      // El historial puede tardar en sincronizar: se reintenta durante la primera vela posterior
      if(now < g_srvAccEnd + g_tfSeconds)
         return false;
      g_accBuilt = true;
      g_accValid = false;
      PrintFormat("[NAE] Acumulación incompleta: %d de %d velas encontradas",n,expected);
      LockDay("ACCUMULATION_INCOMPLETE");
      return true;
     }

   double hi = 0.0, lo = 0.0;
   int    first   = 0;
   int    candles = FindAccumulation(win,n,hi,lo,first);
   string failReason = "";
   if(candles==0)
     {
      // Ni la última vela cabe en el máximo: se muestra la última vela como referencia
      failReason = "INVALID_RANGE";
      first = n-1;
      hi    = BarTop(win,first);
      lo    = BarBottom(win,first);
     }
   CountTouches(win,first,n,hi,lo,g_touchHigh,g_touchLow);
   g_rebounds = CountRebounds(win,first,n,hi,lo);
   if(failReason=="" && candles < MinAccumCandles)
      failReason = "ACCUMULATION_TOO_SHORT";
   else if(failReason=="" && (g_touchHigh < MinTouches || g_touchLow < MinTouches || g_rebounds < MinRebounds))
      failReason = "NOT_ENOUGH_REBOUNDS";

   g_accBuilt    = true;
   g_accValid    = (failReason=="");
   g_accCandles  = candles;
   g_srvBoxStart = win[first].time;
   g_accHigh     = hi;
   g_accLow      = lo;
   g_accRangePts = PriceToPoints(hi-lo);

   PrintFormat("[NAE] Acumulación %s NY (%s): %d velas desde %s (mín %d) | high=%s low=%s rango=%s pts (máx %s) | toques techo=%d suelo=%d (mín %d) | rebotes %d (mín %d) => %s",
               TimeToString(g_nyDay,TIME_DATE),UseCandleBodies ? "cuerpos" : "mechas",candles,
               TimeToString(ServerToNewYork(g_srvBoxStart),TIME_MINUTES),MinAccumCandles,Px(hi),Px(lo),
               Pts(g_accRangePts),Pts(MaxAccumulationPoints),g_touchHigh,g_touchLow,MinTouches,g_rebounds,MinRebounds,
               g_accValid ? "VÁLIDA" : "INVÁLIDA ("+failReason+")");
   DrawAccumulation(hi,lo,g_accValid);

   if(!g_accValid)
     {
      LockDay(failReason);
      return true;
     }

   // Lotaje estimado para el panel (supone entrada LONG en el máximo)
   double budget = 0.0, risk = 0.0;
   string why    = "";
   g_estLots = CalculatePositionSize(1,hi,CalculateStopLoss(1),budget,risk,why);
   return true;
  }

//+------------------------------------------------------------------+
//| RIESGO: SL, TP Y LOTAJE                                          |
//+------------------------------------------------------------------+
//--- SL al otro lado de la acumulación + buffer, redondeado alejándose del precio
double CalculateStopLoss(const int dir)
  {
   double buffer = PointsToPrice(SL_Buffer_Points);
   if(dir > 0)
      return FloorToTick(g_accLow - buffer);
   return CeilToTick(g_accHigh + buffer);
  }

//--- TP = entrada +/- RiskReward x distancia real entrada-SL (redondeo que garantiza >= R:R)
double CalculateTakeProfit(const int dir,const double entry,const double sl)
  {
   double risk = MathAbs(entry - sl);
   if(dir > 0)
      return CeilToTick(entry + RiskReward*risk);
   return FloorToTick(entry - RiskReward*risk);
  }

//--- presupuesto de riesgo del día: RiskPercent del equity (nunca mayor que el equity del inicio del día)
double DailyRiskBudget()
  {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double base   = (g_dayStartEquity > 0.0) ? MathMin(equity,g_dayStartEquity) : equity;
   return MathMax(0.0,base*RiskPercent/100.0);
  }

//--- pérdida monetaria de 1 lote si se toca el SL (el mayor de dos métodos, conservador)
double LossPerLot(const int dir,const double entry,const double sl)
  {
   double distance  = MathAbs(entry - sl);
   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE_LOSS);
   if(tickValue <= 0.0)
      tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double byTick = (tickValue > 0.0 && g_tickSize > 0.0) ? distance/g_tickSize*tickValue : 0.0;

   double profit = 0.0, byCalc = 0.0;
   if(OrderCalcProfit(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,1.0,entry,sl,profit))
      byCalc = MathAbs(profit);
   return MathMax(byTick,byCalc);
  }

//--- lotaje = riesgo / pérdida por lote, redondeado HACIA ABAJO al step del broker
double CalculatePositionSize(const int dir,const double entry,const double sl,
                             double &budget,double &riskMoney,string &why)
  {
   budget    = DailyRiskBudget();
   riskMoney = 0.0;
   if(MathAbs(entry - sl) <= 0.0 || budget <= 0.0)
     {
      why = "distancia al SL o presupuesto de riesgo inválidos";
      return 0.0;
     }
   double lossPerLot = LossPerLot(dir,entry,sl);
   if(lossPerLot <= 0.0)
     {
      why = "no se pudo calcular el valor del tick del símbolo";
      return 0.0;
     }
   double rawLots = budget/lossPerLot;
   double lots    = NormalizeDouble(MathFloor(rawLots/g_volStep + 1e-9)*g_volStep,g_volDigits);
   if(lots < g_volMin - 1e-12)
     {
      why = StringFormat("lote calculado %.4f < mínimo %s (redondear arriba superaría el riesgo)",rawLots,Lots(g_volMin));
      return 0.0;
     }
   double maxLots  = g_volMax;
   double volLimit = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_LIMIT);
   if(volLimit > 0.0 && volLimit < maxLots)
      maxLots = volLimit;
   if(lots > maxLots + 1e-12)
     {
      if(!AdjustLotToLimits)
        {
         why = StringFormat("lote calculado %s > máximo del broker %s (active AdjustLotToLimits para operar con el máximo)",
                            Lots(lots),Lots(maxLots));
         return 0.0;
        }
      PrintFormat("[NAE] Lote %s reducido al máximo del broker %s: el riesgo queda por debajo de RiskPercent.",Lots(lots),Lots(maxLots));
      lots = NormalizeDouble(MathFloor(maxLots/g_volStep + 1e-9)*g_volStep,g_volDigits);
     }
   riskMoney = lots*lossPerLot;
   return lots;
  }

bool TradingAllowed(const int dir)
  {
   if(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)==0)
     { g_rejectDetail = "botón 'Trading algorítmico' desactivado en el terminal"; return false; }
   if(MQLInfoInteger(MQL_TRADE_ALLOWED)==0)
     { g_rejectDetail = "'Permitir trading algorítmico' desactivado en las propiedades del EA"; return false; }
   if(AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)==0 || AccountInfoInteger(ACCOUNT_TRADE_EXPERT)==0)
     { g_rejectDetail = "la cuenta no permite operar o no permite EAs (¿cuenta investor?)"; return false; }
   ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE);
   if(mode==SYMBOL_TRADE_MODE_FULL)
      return true;
   if(mode==SYMBOL_TRADE_MODE_LONGONLY && dir > 0)
      return true;
   if(mode==SYMBOL_TRADE_MODE_SHORTONLY && dir < 0)
      return true;
   g_rejectDetail = "el símbolo no permite operar en esta dirección (SYMBOL_TRADE_MODE)";
   return false;
  }

bool ValidateStops(const TradePlan &plan,const MqlTick &tick,string &reason)
  {
   double stopsLevel = (double)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   g_rejectDetail = StringFormat("entrada %s SL %s TP %s bid %s ask %s stopsLevel %s",
                                 Px(plan.entry),Px(plan.sl),Px(plan.tp),Px(tick.bid),Px(tick.ask),Px(stopsLevel));
   if(plan.direction > 0)
     {
      if(plan.sl <= 0.0 || plan.entry - plan.sl <= 0.0 || tick.bid - plan.sl <= stopsLevel)
        { reason = "INVALID_SL"; return false; }
      if(plan.tp - tick.bid <= stopsLevel)
        { reason = "INVALID_TP"; return false; }
     }
   else
     {
      if(plan.sl - plan.entry <= 0.0 || plan.sl - tick.ask <= stopsLevel)
        { reason = "INVALID_SL"; return false; }
      if(plan.tp <= 0.0 || tick.ask - plan.tp <= stopsLevel)
        { reason = "INVALID_TP"; return false; }
     }
   return true;
  }

bool CheckOrderRequest(const TradePlan &plan,string &reason)
  {
   MqlTradeRequest     req;
   MqlTradeCheckResult chk;
   ZeroMemory(req);
   ZeroMemory(chk);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.magic        = MagicNumber;
   req.volume       = plan.lots;
   req.type         = (plan.direction > 0) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price        = plan.entry;
   req.sl           = plan.sl;
   req.tp           = plan.tp;
   req.deviation    = g_deviation;
   req.type_filling = g_filling;
   req.type_time    = ORDER_TIME_GTC;
   if(OrderCheck(req,chk))
      return true;
   reason = (chk.retcode==TRADE_RETCODE_NO_MONEY) ? "INSUFFICIENT_MARGIN" : "ORDER_CHECK_FAILED";
   g_rejectDetail = StringFormat("OrderCheck: retcode=%u (%s) lotes %s",chk.retcode,chk.comment,Lots(plan.lots));
   return false;
  }

//--- +1 si el precio supera el máximo, -1 si perfora el mínimo (al menos 1 tick)
int BreakoutDirection(const double price)
  {
   if(price - g_accHigh > g_tickSize*0.5)
      return 1;
   if(g_accLow - price > g_tickSize*0.5)
      return -1;
   return 0;
  }

//--- los 10 filtros de seguridad; rellena el plan de la operación si todo es correcto
bool CheckRiskConditions(const int dir,const datetime now,TradePlan &plan,string &reason)
  {
   ZeroMemory(plan);
   plan.direction = dir;
   g_rejectDetail = "";

   // 1. Horario permitido
   if(now < g_srvAccEnd || now >= g_srvTradeEnd)
     { reason = "OUTSIDE_SESSION"; return false; }
   // 2. Acumulación formada
   if(!g_accBuilt)
     { reason = "ACCUMULATION_NOT_READY"; return false; }
   // 3. Rango dentro del máximo
   if(!g_accValid)
     { reason = "INVALID_RANGE"; return false; }
   // 4. Operaciones de hoy / límite diario
   if(g_tradesToday >= MAX_TRADES_PER_DAY)
     { reason = "ALREADY_TRADED"; return false; }
   double budget = DailyRiskBudget();
   if(budget > 0.0 && g_dailyPnL <= -budget)
     { reason = "DAILY_LIMIT_REACHED"; return false; }
   // 5. Posición abierta del EA (o cualquiera en cuentas netting)
   if(FindOurPosition()>0 || (!g_isHedging && AnyPositionOnSymbol()))
     { reason = "POSITION_EXISTS"; return false; }
   if(!TradingAllowed(dir))
     { reason = "TRADING_DISABLED"; return false; }
   // 6. Spread
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
     { reason = "NO_PRICE"; return false; }
   double spreadPts = PriceToPoints(tick.ask - tick.bid);
   if(spreadPts > MaxSpreadPoints + 1e-9)
     {
      g_rejectDetail = StringFormat("spread %s pts > MaxSpreadPoints %s",Pts(spreadPts),Pts(MaxSpreadPoints));
      reason = "SPREAD_TOO_HIGH";
      return false;
     }
   // 7. Stop Loss (y TP derivado)
   plan.entry = (dir > 0) ? tick.ask : tick.bid;
   plan.sl    = CalculateStopLoss(dir);
   plan.tp    = CalculateTakeProfit(dir,plan.entry,plan.sl);
   if(!ValidateStops(plan,tick,reason))
      return false;
   // 8. Lotaje
   string why = "";
   double riskBudget = 0.0, riskMoney = 0.0;
   plan.lots       = CalculatePositionSize(dir,plan.entry,plan.sl,riskBudget,riskMoney,why);
   plan.riskBudget = riskBudget;
   plan.riskMoney  = riskMoney;
   if(plan.lots <= 0.0)
     {
      g_rejectDetail = why;
      reason = "INVALID_LOT_SIZE";
      return false;
     }
   // 9. Margen
   double margin     = 0.0;
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(!OrderCalcMargin(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,_Symbol,plan.lots,plan.entry,margin))
     {
      g_rejectDetail = StringFormat("OrderCalcMargin falló (error %d)",GetLastError());
      reason = "INSUFFICIENT_MARGIN";
      return false;
     }
   if(margin > freeMargin)
     {
      double nominal = plan.lots*SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE)*plan.entry;
      double fitted  = 0.0;
      if(AdjustLotToLimits && margin > 0.0)
         fitted = NormalizeDouble(MathFloor(plan.lots*(freeMargin*0.95/margin)/g_volStep + 1e-9)*g_volStep,g_volDigits);
      if(fitted < g_volMin - 1e-12)
        {
         g_rejectDetail = StringFormat("%s lotes (riesgo %s, SL %s pts) requieren %s de margen y el margen libre es %s. "+
                                       "Nominal = %.1f veces el equity: el apalancamiento del símbolo no lo permite. "+
                                       "Baje RiskPercent o active AdjustLotToLimits.",
                                       Lots(plan.lots),Money(plan.riskMoney),Pts(PriceToPoints(MathAbs(plan.entry-plan.sl))),
                                       Money(margin),Money(freeMargin),nominal/MathMax(AccountInfoDouble(ACCOUNT_EQUITY),1e-9));
         reason = "INSUFFICIENT_MARGIN";
         return false;
        }
      PrintFormat("[NAE] Lote %s reducido a %s por margen (requería %s, libre %s): el riesgo queda por debajo de RiskPercent.",
                  Lots(plan.lots),Lots(fitted),Money(margin),Money(freeMargin));
      plan.riskMoney = plan.riskMoney*fitted/plan.lots;
      plan.lots      = fitted;
     }
   if(!CheckOrderRequest(plan,reason))
      return false;
   // 10. Ruptura: el precio sigue fuera de la zona en la dirección de la orden
   if(BreakoutDirection(TriggerPrice(tick))!=dir)
     { reason = "PRICE_BACK_INSIDE"; return false; }

   reason = (dir > 0) ? "BREAK_ABOVE_ACC_HIGH" : "BREAK_BELOW_ACC_LOW";
   return true;
  }

bool IsTransientReason(const string reason)
  {
   return (reason=="SPREAD_TOO_HIGH" || reason=="NO_PRICE" || reason=="TRADING_DISABLED" ||
           reason=="PRICE_BACK_INSIDE");
  }

bool IsTransientRetcode(const uint rc)
  {
   return (rc==TRADE_RETCODE_REQUOTE       || rc==TRADE_RETCODE_REJECT      ||
           rc==TRADE_RETCODE_PRICE_CHANGED || rc==TRADE_RETCODE_PRICE_OFF   ||
           rc==TRADE_RETCODE_TIMEOUT       || rc==TRADE_RETCODE_CONNECTION  ||
           rc==TRADE_RETCODE_TOO_MANY_REQUESTS);
  }

//+------------------------------------------------------------------+
//| EJECUCIÓN                                                        |
//+------------------------------------------------------------------+
void OnPositionOpened(const TradePlan &plan,const double fillPrice)
  {
   if(g_tradesToday < 1)
      g_tradesToday = 1;
   g_dayLocked   = true;          // regla fundamental: sin más entradas hoy
   g_signalDir   = 0;
   g_phase       = PHASE_DONE;
   g_plan        = plan;
   g_planActive  = true;
   g_tpAdjusted  = false;
   g_protectFails= 0;
   g_entryTime   = TimeCurrent();
   g_lastReason  = (plan.direction > 0) ? "BREAK_ABOVE_ACC_HIGH" : "BREAK_BELOW_ACC_LOW";
   g_tradeStatus = Side(plan.direction)+" OPEN";
   g_statTrades++;

   if(fillPrice > 0.0)
     {
      g_plan.entry     = fillPrice;
      g_plan.riskMoney = plan.lots*LossPerLot(plan.direction,fillPrice,plan.sl); // riesgo real tras el fill
     }
   if(FindOurPosition()>0)
      g_positionId = PositionGetInteger(POSITION_IDENTIFIER);

   LogEvent("TRADE_OPEN",plan.direction,g_plan.entry,g_plan.sl,g_plan.tp,g_plan.lots,g_plan.riskMoney,
            "OPEN",0.0,g_lastReason);
   PrintFormat("[NAE] Riesgo permitido %s | riesgo real %s (%.2f%% del equity)",
               Money(plan.riskBudget),Money(g_plan.riskMoney),
               100.0*g_plan.riskMoney/MathMax(AccountInfoDouble(ACCOUNT_EQUITY),1e-9));
   DrawTradeLevels(plan.direction,g_plan.entry,g_plan.sl,g_plan.tp,g_entryTime);
   EnsureProtection();
  }

//--- envía la orden de mercado con SL/TP y verifica la ejecución
bool SendMarketOrder(const TradePlan &plan,bool &fatal)
  {
   fatal = false;
   string comment = "NAE "+Side(plan.direction);
   ResetLastError();
   bool sent = (plan.direction > 0)
               ? g_trade.Buy(plan.lots,_Symbol,plan.entry,plan.sl,plan.tp,comment)
               : g_trade.Sell(plan.lots,_Symbol,plan.entry,plan.sl,plan.tp,comment);
   uint rc   = g_trade.ResultRetcode();
   bool ok   = sent && (rc==TRADE_RETCODE_DONE || rc==TRADE_RETCODE_DONE_PARTIAL || rc==TRADE_RETCODE_PLACED);
   if(ok)
     {
      OnPositionOpened(plan,g_trade.ResultPrice());
      return true;
     }

   PrintFormat("[NAE] ERROR al abrir %s %s lotes: retcode=%u (%s) | error=%d",
               Side(plan.direction),Lots(plan.lots),rc,g_trade.ResultRetcodeDescription(),GetLastError());
   // Una respuesta perdida pudo abrir la posición igualmente: se verifica antes de reintentar
   SyncTradesFromHistory();
   if(FindOurPosition()>0 || g_tradesToday>0)
     {
      Print("[NAE] La posición existe a pesar del error: se registra y no se reintenta.");
      OnPositionOpened(plan,0.0);
      return true;
     }
   fatal = !IsTransientRetcode(rc);
   return false;
  }

bool OpenBuy(const TradePlan &plan,bool &fatal)
  {
   fatal = true;
   if(plan.direction <= 0)
      return false;
   return SendMarketOrder(plan,fatal);
  }

bool OpenSell(const TradePlan &plan,bool &fatal)
  {
   fatal = true;
   if(plan.direction >= 0)
      return false;
   return SendMarketOrder(plan,fatal);
  }

//--- ejecuta la ruptura pendiente (reintenta sólo ante causas transitorias)
void TryExecuteSignal(const datetime now)
  {
   TradePlan plan;
   string    reason = "";
   if(!CheckRiskConditions(g_signalDir,now,plan,reason))
     {
      if(IsTransientReason(reason))
        {
         if(reason!=g_lastTransient)
            PrintFormat("[NAE] Entrada %s en espera: %s %s (se reintenta durante 1 vela desde la ruptura)",
                        Side(g_signalDir),reason,g_rejectDetail);
         g_lastTransient = reason;
         return;
        }
      PrintFormat("[NAE] Entrada %s RECHAZADA: %s | %s",Side(g_signalDir),reason,g_rejectDetail);
      LockDay(reason);
      return;
     }

   g_orderAttempts++;
   bool fatal = false;
   bool done  = (plan.direction > 0) ? OpenBuy(plan,fatal) : OpenSell(plan,fatal);
   if(done)
      return;
   if(fatal || g_orderAttempts >= MAX_ORDER_ATTEMPTS)
      LockDay("ORDER_FAILED");
   else
      g_lastTransient = "ORDER_FAILED";
  }

//--- garantiza SL/TP en la posición y ajusta el TP al precio real de entrada
void EnsureProtection()
  {
   ulong ticket = FindOurPosition();
   if(ticket==0)
      return;
   int    dir  = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) ? 1 : -1;
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl   = PositionGetDouble(POSITION_SL);
   double tp   = PositionGetDouble(POSITION_TP);

   double wantSl = sl;
   if(wantSl <= 0.0)
     {
      if(g_planActive)
         wantSl = g_plan.sl;
      else if(g_accBuilt && g_accHigh > 0.0)
         wantSl = CalculateStopLoss(dir);
     }
   if(wantSl <= 0.0)
      return; // posición restaurada sin datos para reconstruir el SL (se avisa en OnInit)

   bool   adjustTp = (tp <= 0.0) || (g_planActive && !g_tpAdjusted);
   double wantTp   = adjustTp ? CalculateTakeProfit(dir,openPrice,wantSl) : tp;
   bool   needSl   = (sl <= 0.0);
   bool   needTp   = adjustTp && MathAbs(wantTp - tp) >= g_tickSize*0.5;
   if(!needSl && !needTp)
     {
      g_tpAdjusted = true;
      return;
     }

   if(g_trade.PositionModify(ticket,wantSl,wantTp) && g_trade.ResultRetcode()==TRADE_RETCODE_DONE)
     {
      g_tpAdjusted   = true;
      g_protectFails = 0;
      if(g_planActive)
        {
         g_plan.entry = openPrice;
         g_plan.sl    = wantSl;
         g_plan.tp    = wantTp;
         DrawTradeLevels(dir,openPrice,wantSl,wantTp,g_entryTime > 0 ? g_entryTime : TimeCurrent());
        }
      PrintFormat("[NAE] Protección fijada: entrada real %s SL=%s TP=%s (R:R 1:%.2f)",Px(openPrice),Px(wantSl),Px(wantTp),RiskReward);
      return;
     }

   g_protectFails++;
   PrintFormat("[NAE] ERROR al fijar SL/TP (intento %d/%d): retcode=%u (%s)",g_protectFails,MAX_PROTECT_ATTEMPTS,
               g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription());
   if(g_protectFails < MAX_PROTECT_ATTEMPTS)
      return;
   if(needSl)
     {
      // Una posición sin Stop Loss viola la gestión de riesgo: se cierra
      Print("[NAE] CRÍTICO: no se pudo colocar el Stop Loss. Cerrando la posición por seguridad.");
      if(!g_trade.PositionClose(ticket))
         PrintFormat("[NAE] ERROR al cerrar la posición sin SL: retcode=%u (%s)",g_trade.ResultRetcode(),g_trade.ResultRetcodeDescription());
      g_lastReason = "PROTECTION_FAILED";
     }
   else
      g_tpAdjusted = true; // se conserva el TP enviado con la orden
  }

//+------------------------------------------------------------------+
//| RUPTURA                                                          |
//+------------------------------------------------------------------+
//--- precio que dibuja las velas del símbolo (Bid en CFDs, Last en símbolos de bolsa)
double TriggerPrice(const MqlTick &tick)
  {
   if(SymbolInfoInteger(_Symbol,SYMBOL_CHART_MODE)==SYMBOL_CHART_MODE_LAST && tick.last > 0.0)
      return tick.last;
   return tick.bid;
  }

//--- ¿alguna vela YA CERRADA desde el fin de la acumulación superó la zona?
//    1 = sí, 0 = no, -1 = historial no disponible (reintentar)
int MissedBreakoutCheck()
  {
   datetime curOpen = iTime(_Symbol,SignalTimeframe,0);
   if(curOpen==0)
      return -1;
   if(curOpen <= g_srvAccEnd)
      return 0;   // seguimos en la primera vela de búsqueda (09:30)
   MqlRates rates[];
   int copied = CopyRates(_Symbol,SignalTimeframe,g_srvAccEnd,curOpen-1,rates);
   if(copied < 0)
      return -1;
   for(int i=0; i<copied; i++)
     {
      if(rates[i].time < g_srvAccEnd || rates[i].time >= curOpen)
         continue;
      if(BreakoutDirection(rates[i].high) > 0 || BreakoutDirection(rates[i].low) < 0)
         return 1;
     }
   return 0;
  }

//--- ruptura INTRAVELA: desde las 09:30 NY, en cuanto el precio supera el máximo o
//    el mínimo de la acumulación se entra, sin esperar el cierre de la vela M5.
void CheckBreakout(const datetime now)
  {
   if(g_signalDir!=0)
     {
      // Reintentos (sólo causas transitorias) durante una vela M5 desde la ruptura
      if(now >= g_signalTime + g_tfSeconds)
        {
         LockDay(g_lastTransient!="" ? g_lastTransient : "BREAKOUT_EXPIRED");
         return;
        }
      TryExecuteSignal(now);
      return;
     }

   if(now >= g_srvTradeEnd)
     {
      LockDay("NO_VALID_BREAKOUT");
      return;
     }

   // Al empezar a vigilar (09:30 o tras reiniciar el EA): si una vela ya cerrada rompió la
   // zona, la ruptura del día ocurrió sin el EA y no se persigue tarde.
   if(!g_watchStarted)
     {
      int missed = MissedBreakoutCheck();
      if(missed < 0)
         return;
      if(missed > 0)
        {
         LockDay("BREAKOUT_MISSED");
         return;
        }
      g_watchStarted = true;
     }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick))
      return;
   double price = TriggerPrice(tick);
   if(price <= 0.0)
      return;
   int dir = BreakoutDirection(price);
   if(dir==0)
      return;

   g_signalDir     = dir;
   g_signalTime    = now;
   g_signalPrice   = price;
   g_orderAttempts = 0;
   g_lastTransient = "";
   g_phase         = PHASE_SIGNAL_PENDING;
   PrintFormat("[NAE] Ruptura %s a las %s NY: precio %s %s %s (acc high %s / low %s)",
               Side(dir),TimeToString(ServerToNewYork(now),TIME_SECONDS),Px(price),dir > 0 ? ">" : "<",
               Px(dir > 0 ? g_accHigh : g_accLow),Px(g_accHigh),Px(g_accLow));
   TryExecuteSignal(now);
  }

//+------------------------------------------------------------------+
//| MÁQUINA DE ESTADOS DIARIA                                        |
//+------------------------------------------------------------------+
void ProcessStrategy(const datetime now)
  {
   if(g_isWeekend)
      return;
   if(now < g_srvAccStart)
     {
      g_phase = PHASE_WAIT_SESSION;
      return;
     }
   if(!g_accBuilt)
     {
      if(now < g_srvAccEnd)
        {
         g_phase = PHASE_BUILDING;
         if(g_drawEnabled || g_panelEnabled)
            UpdateLiveAccumulation(now);
         return;
        }
      if(!BuildAccumulation(now))
         return;
     }
   if(g_dayLocked)
     {
      g_phase = PHASE_DONE;
      return;
     }
   g_phase = (g_signalDir!=0) ? PHASE_SIGNAL_PENDING : PHASE_WAIT_BREAKOUT;
   CheckBreakout(now);
  }

//+------------------------------------------------------------------+
//| VALIDACIONES DE INICIO                                           |
//+------------------------------------------------------------------+
bool ValidClock(const int h,const int m) { return (h>=0 && h<=23 && m>=0 && m<=59); }

bool ValidateInputs()
  {
   bool ok = true;
   if(!ValidClock(StartHour,StartMinute) || !ValidClock(AccumEndHour,AccumEndMinute) || !ValidClock(EndHour,EndMinute))
     { Print("[NAE] Horario inválido: horas 0-23 y minutos 0-59."); ok = false; }
   int startMin  = StartHour*60 + StartMinute;
   int accEndMin = AccumEndHour*60 + AccumEndMinute;
   int endMin    = EndHour*60 + EndMinute;
   if(!(startMin < accEndMin && accEndMin < endMin))
     { Print("[NAE] Debe cumplirse Start < AccumEnd < End (hora NY)."); ok = false; }
   int tfMin = PeriodSeconds(SignalTimeframe)/60;
   if(tfMin<=0 || startMin%tfMin!=0 || accEndMin%tfMin!=0 || endMin%tfMin!=0)
     { PrintFormat("[NAE] Los horarios deben coincidir con aperturas de vela de %d minutos.",tfMin); ok = false; }
   if(RiskPercent <= 0.0 || RiskPercent > 100.0)
     { Print("[NAE] RiskPercent debe estar entre 0 y 100."); ok = false; }
   if(RiskReward <= 0.0)
     { Print("[NAE] RiskReward debe ser mayor que 0."); ok = false; }
   if(MaxAccumulationPoints <= 0.0)
     { Print("[NAE] MaxAccumulationPoints debe ser mayor que 0."); ok = false; }
   if(tfMin > 0 && (MinAccumCandles < 1 || MinAccumCandles > (accEndMin-startMin)/tfMin))
     { PrintFormat("[NAE] MinAccumCandles debe estar entre 1 y %d (velas de la ventana).",(accEndMin-startMin)/tfMin); ok = false; }
   if(MinRebounds < 0 || MinRebounds > 50)
     { Print("[NAE] MinRebounds debe estar entre 0 y 50."); ok = false; }
   if(MinTouches < 0 || MinTouches > 50)
     { Print("[NAE] MinTouches debe estar entre 0 y 50."); ok = false; }
   if(TouchZonePercent < 0.0 || TouchZonePercent > 50.0)
     { Print("[NAE] TouchZonePercent debe estar entre 0 y 50."); ok = false; }
   if(SL_Buffer_Points < 0.0)
     { Print("[NAE] SL_Buffer_Points no puede ser negativo."); ok = false; }
   if(MaxSpreadPoints <= 0.0)
     { Print("[NAE] MaxSpreadPoints debe ser mayor que 0."); ok = false; }
   if(Slippage < 0.0)
     { Print("[NAE] Slippage no puede ser negativo."); ok = false; }
   if(ServerGMTOffset < -12 || ServerGMTOffset > 14)
     { Print("[NAE] ServerGMTOffset fuera de rango (-12..14)."); ok = false; }
   if(MagicNumber==0)
     { Print("[NAE] MagicNumber no puede ser 0 (se confundiría con operaciones manuales)."); ok = false; }
   if(ok && RiskPercent > 5.0)
      PrintFormat("[NAE] ADVERTENCIA: RiskPercent=%.1f%% es un riesgo MUY alto por operación.",RiskPercent);
   return ok;
  }

void CheckTimezoneSetup(const bool tester)
  {
   datetime srv = TimeCurrent();
   PrintFormat("[NAE] Zona horaria: servidor GMT%+d en invierno, DST=%s | servidor %s => Nueva York %s",
               ServerGMTOffset,EnumToString(ServerDSTMode),TimeToString(srv,TIME_DATE|TIME_MINUTES),
               TimeToString(ServerToNewYork(srv),TIME_DATE|TIME_MINUTES));
   if(tester)
     {
      Print("[NAE] Strategy Tester: TimeGMT() no es fiable en el tester; se usa ServerGMTOffset/ServerDSTMode.");
      return;
     }
   long actual = (long)TimeTradeServer() - (long)TimeGMT();
   actual      = (long)MathRound(actual/1800.0)*1800;
   long model  = ServerOffsetSeconds(TimeGMT());
   if(actual!=model)
     {
      string msg = StringFormat("NAE: el servidor está en GMT%+.1f pero la configuración indica GMT%+.1f. Revise ServerGMTOffset/ServerDSTMode.",
                                actual/3600.0,model/3600.0);
      Print("[NAE] ADVERTENCIA: ",msg);
      Alert(msg);
     }
  }

void CheckSymbol()
  {
   string name = _Symbol;
   StringToUpper(name);
   if(StringFind(name,"NAS")<0 && StringFind(name,"US100")<0 && StringFind(name,"USTEC")<0
      && StringFind(name,"NDX")<0 && StringFind(name,"NQ")<0 && StringFind(name,"TECH100")<0)
      PrintFormat("[NAE] ADVERTENCIA: '%s' no parece ser el NASDAQ 100.",_Symbol);
   if(_Period!=SignalTimeframe)
      PrintFormat("[NAE] Aviso: el gráfico es %s; la estrategia calcula sobre %s.",EnumToString(_Period),EnumToString(SignalTimeframe));
   PrintFormat("[NAE] Símbolo %s: digits=%d point=%s tickSize=%s tickValue=%s contrato=%s volMin=%s volMax=%s step=%s stopsLevel=%d %s",
               _Symbol,_Digits,DoubleToString(_Point,_Digits),DoubleToString(g_tickSize,_Digits),
               DoubleToString(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE),5),
               DoubleToString(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_CONTRACT_SIZE),2),
               Lots(g_volMin),Lots(g_volMax),Lots(g_volStep),
               (int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL),g_isHedging ? "HEDGING" : "NETTING");
   PrintFormat("[NAE] 1 punto de input = %s de precio | MaxAccumulation=%s SL_Buffer=%s MaxSpread=%s Deviation=%d puntos MT5",
               DoubleToString(g_unit,_Digits),Pts(MaxAccumulationPoints),Pts(SL_Buffer_Points),Pts(MaxSpreadPoints),(int)g_deviation);
  }

//+------------------------------------------------------------------+
//| EVENTOS                                                          |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   g_tickSize = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(g_tickSize <= 0.0)
      g_tickSize = _Point;
   g_volMin  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   g_volMax  = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   g_volStep = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   if(g_volMin <= 0.0 || g_volMax <= 0.0 || g_volStep <= 0.0)
     {
      Print("[NAE] Especificaciones de volumen del símbolo no disponibles.");
      return INIT_FAILED;
     }
   g_volDigits = VolumeDigits(g_volStep);
   g_unit      = (PointUnit==UNIT_INDEX_POINTS) ? 1.0 : _Point;
   g_tfSeconds = PeriodSeconds(SignalTimeframe);
   g_isHedging = ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE)==ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   g_filling   = ResolveFilling();
   g_deviation = (ulong)MathRound(PointsToPrice(Slippage)/_Point);

   g_trade.SetExpertMagicNumber(MagicNumber);
   g_trade.SetDeviationInPoints(g_deviation);
   g_trade.SetTypeFilling(g_filling);
   g_trade.SetMarginMode();
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   bool tester  = (MQLInfoInteger(MQL_TESTER)!=0);
   bool visual  = (MQLInfoInteger(MQL_VISUAL_MODE)!=0);
   g_drawEnabled  = DrawObjects && (!tester || visual);
   g_panelEnabled = ShowPanel && (!tester || visual);
   g_csvEnabled   = WriteCSVLog && MQLInfoInteger(MQL_OPTIMIZATION)==0;
   g_objPrefix    = "NAE_"+IntegerToString((long)MagicNumber)+"_";

   //--- el estado se reconstruye en el primer tick (las globales sobreviven a un cambio de parámetros)
   g_nyDay        = 0;
   g_positionId   = 0;
   g_planActive   = false;
   ZeroMemory(g_plan);
   ArrayResize(g_statReasons,0);
   ArrayResize(g_statCounts,0);
   g_statDays     = 0;
   g_statTrades   = 0;

   CheckTimezoneSetup(tester);
   CheckSymbol();
   iTime(_Symbol,SignalTimeframe,0); // fuerza la sincronización del historial del timeframe

   if(FindOurPosition()>0 && PositionGetDouble(POSITION_SL) <= 0.0)
      Print("[NAE] ADVERTENCIA: existe una posición del EA SIN Stop Loss. Se intentará colocarlo cuando haya acumulación.");

   if(g_panelEnabled)
     {
      CreatePanel();
      if(!tester)
         EventSetTimer(1);
     }
   PrintFormat("[NAE] Iniciado: Risk=%.2f%% RR=1:%.2f MaxAcc=%s SL_Buffer=%s MaxSpread=%s Magic=%s | Sesión NY %02d:%02d, acumulación hasta %02d:%02d, entradas hasta %02d:%02d",
               RiskPercent,RiskReward,Pts(MaxAccumulationPoints),Pts(SL_Buffer_Points),Pts(MaxSpreadPoints),
               IntegerToString((long)MagicNumber),StartHour,StartMinute,AccumEndHour,AccumEndMinute,EndHour,EndMinute);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
   if(g_statDays > 0)
      PrintSummary();
   if(g_objPrefix=="")
      return;
   ObjectsDeleteAll(0,g_objPrefix+"PANEL_");
   if(reason==REASON_REMOVE)
      ObjectsDeleteAll(0,g_objPrefix);
   ChartRedraw(0);
  }

void OnTick()
  {
   datetime now = TimeCurrent();
   if(now<=0)
      return;
   DetectNewDay(now);
   EnsureProtection();
   ProcessStrategy(now);
   if(g_panelEnabled && now!=g_lastPanelUpdate)
     {
      g_lastPanelUpdate = now;
      UpdatePanel();
     }
  }

void OnTimer()
  {
   UpdatePanel();
  }

//--- registro de apertura/cierre y resultado de la operación
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
  {
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || trans.deal==0)
      return;
   if(!HistoryDealSelect(trans.deal) || !IsOurDeal(trans.deal))
      return;

   ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(entry==DEAL_ENTRY_IN)
     {
      // Bloqueo inmediato aunque la respuesta de OrderSend se haya perdido
      if(g_tradesToday < 1)
         g_tradesToday = 1;
      g_dayLocked   = true;
      g_signalDir   = 0;
      g_positionId  = HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
      return;
     }
   if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY && entry!=DEAL_ENTRY_INOUT)
      return;

   long            posId      = HistoryDealGetInteger(trans.deal,DEAL_POSITION_ID);
   double          closePrice = HistoryDealGetDouble(trans.deal,DEAL_PRICE);
   datetime        closeTime  = (datetime)HistoryDealGetInteger(trans.deal,DEAL_TIME);
   ENUM_DEAL_REASON why       = (ENUM_DEAL_REASON)HistoryDealGetInteger(trans.deal,DEAL_REASON);

   //--- resultado neto de toda la posición (entrada + salida, comisiones y swap)
   double net = 0.0, entryPrice = 0.0, volume = 0.0;
   int    dir = 0;
   if(HistorySelectByPosition(posId))
     {
      int total = HistoryDealsTotal();
      for(int i=0; i<total; i++)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal==0)
            continue;
         net += DealNet(deal);
         if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal,DEAL_ENTRY)==DEAL_ENTRY_IN)
           {
            dir        = (HistoryDealGetInteger(deal,DEAL_TYPE)==DEAL_TYPE_BUY) ? 1 : -1;
            entryPrice = HistoryDealGetDouble(deal,DEAL_PRICE);
            volume     = HistoryDealGetDouble(deal,DEAL_VOLUME);
           }
        }
     }
   SyncTradesFromHistory(); // actualiza el resultado diario

   string exitTag = (why==DEAL_REASON_TP) ? "TP" : (why==DEAL_REASON_SL) ? "SL" : (why==DEAL_REASON_SO) ? "STOP_OUT" : "CLOSED";
   string res     = (net > 0.0) ? "WIN" : (net < 0.0) ? "LOSS" : "BREAKEVEN";
   bool   ours    = (g_planActive && posId==g_positionId);
   double sl      = ours ? g_plan.sl : 0.0;
   double tp      = ours ? g_plan.tp : 0.0;
   double risk    = ours ? g_plan.riskMoney : 0.0;

   LogEvent("TRADE_CLOSE",dir,entryPrice,sl,tp,volume,risk,res+"_"+exitTag,net,
            dir > 0 ? "BREAK_ABOVE_ACC_HIGH" : "BREAK_BELOW_ACC_LOW");
   g_tradeStatus = StringFormat("CLOSED %s %s %s",exitTag,res,DoubleToString(net,2));
   DrawResult(closeTime,closePrice,StringFormat("%s %s %s",res,exitTag,DoubleToString(net,2)),net >= 0.0);
   g_planActive = false;
   g_positionId = 0;
  }
//+------------------------------------------------------------------+
