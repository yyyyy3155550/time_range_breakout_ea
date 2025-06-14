//+------------------------------------------------------------------+
//|                                                          TRB.mq5 |
//|                                                                  |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright ""
#property link      ""
#property version   "1.00"
#property strict // おまじない

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/OrderInfo.mqh>
#include <Trade/AccountInfo.mqh> // 口座情報取得用
#include <Trade/SymbolInfo.mqh>  // 銘柄情報取得用
#include <ChartObjects\ChartObjectsTxtControls.mqh> // テキストオブジェクト用
#include <ChartObjects\ChartObjectsLines.mqh> // 垂直線オブジェクト用

CTrade trade;
CPositionInfo posinfo;
CChartObjectVLine vline; // 垂直線オブジェクトのインスタンス


//--- グローバル変数 ---
input int MagicNumber = 12345000;
//-- 時間保存 --
datetime lastH2BarTime = 0; //OnTimerで２時間ごとに起動するロジックでつかう
//-- Time set --
input int RangeStartJHour = 15; //Range_Start_JST_Hour
input int RangeStartJMin = 0;   //Range_Start_JST_Min
input int RangeEndJHour = 17;   //Range_End_JST_Hour
input int RangeEndJMin = 0;     //Range_End_JST_Min
input int ClosePositionJHour = 21; //Position_Close_JST_Hour
input int ClosePositionJMin = 0; //Position_Close_JST_Min
//- ServerTime
datetime RangeStartServerTime;
datetime RangeEndServerTime;
datetime PositionCloseServerTime;
datetime CloseTimeVar;
datetime RangeStartServerTimeC;
datetime RangeEndServerTimeC;
datetime PositionCloseServerTimeC;
//-- レンジ情報 --
double   rangeHigh = 0.0;       // 計算されたレンジの最高値
double   rangeLow = 0.0;        // 計算されたレンジの最安値
bool     isRangeCalculated = false; // 当日のレンジ計算が完了したかどうかのフラグ
datetime rangeCalculationDate = 0; // どの日のレンジを計算したかを記録 (日替わり判定用)
//-- MAX Position --
input int MaxPosition = 3; // 最大ポジション数
//--
bool isTradingSessionClosed = false; // その日の取引が終了したか
//--
input int DrawDays = 3; //オブジェクトを描写する日数
//--
input bool ChartObject = true; //チャートオブジェクトを描写するかどうか
//--
double highs[], lows[]; // 高値と安値の配列
//-- DayOpen Position count --
bool hasPositionBeenOpenedToday = false; // 今日すでにポジションを持ったかどうかのフラグ
//-- RangeStartServerTime --
datetime lastRangeStartReset = 0;  // 最後にリセットを実行した RangeStartServerTime
//-- Risk Percent --
input double RiskPercent = 0.5; // リスク許容度（口座残高に対する割合）
//-- PIP --
double PIP = 0; // PIPサイズを取得
//-- Lot setting --
// lot設定オプション：固定Lotかリスク％計算かを選択
enum SelectLotMode
   {
    LOT_MODE_FIXED = 0,      // 固定Lot
    LOT_MODE_RISK_PERCENT    // リスク％計算
   };
input SelectLotMode  LotMode = LOT_MODE_RISK_PERCENT;  // Lot計算モード
input double    FixedLotSize = 0.01;                   // 固定Lotサイズ





//+------------------------------------------------------------------+
//| シグナルフラグの定義                                           |
//+------------------------------------------------------------------+
enum SignalFlag
   {
    SIGNAL_NONE       = 0,  // 何もしない
    SIGNAL_BUY,             // 買いシグナル
    SIGNAL_SELL,            // 売りシグナル
    SIGNAL_OK_TRADE,        // 閾値超え 売買可能
    SIGNAL_NOTTIME          // 時間外
   };

// 各セクションのシグナルフラグ       /////--- グローバル ---/////
//SignalFlag timeSignal = SIGNAL_NONE;
SignalFlag MaxPositionSignal = SIGNAL_OK_TRADE; //上限に達したらNONEになる

//+------------------------------------------------------------------+
//| エキスパート初期化関数                                               |
//+------------------------------------------------------------------+
int OnInit()
   {

//EventSetMillisecondTimer(10000); // 1sec = 1000ms
    EventSetTimer(60);

// CTrade オブジェクトにマジックナンバーを設定
    trade.SetExpertMagicNumber(MagicNumber);

// チャートの最大バー数を設定
//ChartSetInteger(0, CHART_VISIBLE_BARS, 20000);  // 十分な数のバーを許可

//--- TIME Setting~ ---
//- Time set Convert - 日本時間のインプットからサーバーdatetimeへ変換
    RangeStartServerTimeC = JSTtoServerTime(RangeStartJHour, RangeStartJMin);
    RangeEndServerTimeC = JSTtoServerTime(RangeEndJHour, RangeEndJMin);
    PositionCloseServerTimeC = JSTtoServerTime(ClosePositionJHour, ClosePositionJMin);

//現在時間struct
    MqlDateTime dt_now;
    TimeToStruct(TimeCurrent(), dt_now);

//Range Start Struct
    MqlDateTime dt_RangeStart;
    TimeToStruct(RangeStartServerTimeC, dt_RangeStart);
    dt_RangeStart.day = dt_now.day; //今日の日付で上書き //JSTtoServerTimeの設計上時間を過ぎると次の日になるため
    RangeStartServerTime = StructToTime(dt_RangeStart); //時間へ再変換

//Range End Struct
    MqlDateTime dt_RangeEnd;
    TimeToStruct(RangeEndServerTimeC, dt_RangeEnd);
    dt_RangeEnd.day = dt_now.day;
    RangeEndServerTime = StructToTime(dt_RangeEnd);

//Position Cloes Time Struct
    MqlDateTime dt_PositionClose;
    TimeToStruct(PositionCloseServerTimeC, dt_PositionClose);
    dt_PositionClose.day = dt_now.day;
    PositionCloseServerTime = StructToTime(dt_PositionClose);

//日マタギを考慮して、Startのほうが多きければEndに２４時間分追加
    if(RangeStartServerTime >= RangeEndServerTime)
       {
        RangeEndServerTime += PeriodSeconds(PERIOD_D1); //1日後にする
       }
//日マタギを考慮して
    if(RangeEndServerTime >= PositionCloseServerTime)
       {
        PositionCloseServerTime += PeriodSeconds(PERIOD_D1); //1日後にする
       }
//--- ~TIME Setting ---

//最初だけこの時間をつかう
    CloseTimeVar = PositionCloseServerTime;

//--- レンジ変数の初期化 ---
    rangeHigh = 0.0;
    rangeLow = 0.0;
    isRangeCalculated = false;
    rangeCalculationDate = 0; // 起動時に日付をリセット

    if(ChartObject)
       {
        //--- チャートオブジェクトの描写 ---
        ChartOBJ(); //チャートオブジェクト描写関数
       }

      

    Print("EAが初期化されました。");

    return(INIT_SUCCEEDED); // 初期化成功
   }
//+------------------------------------------------------------------+
//| エキスパート終了関数                                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
   {
// Timer の削除
    EventKillTimer();

// チャートオブジェクトの削除
    ObjectsDeleteAll(0, "RangeStartTime_");
    ObjectsDeleteAll(0, "RangeEndTime_");
    ObjectsDeleteAll(0, "PositionCloseTime_");
    ObjectsDeleteAll(0, "RangeBox_");
    ObjectsDeleteAll(0, "RangeHighLine_");
    ObjectsDeleteAll(0, "RangeLowLine_");
    ObjectsDeleteAll(0, "DailyOpen_");


// 終了理由をログに出力
    string reason_description = "";

    switch(reason)
       {
        case REASON_PROGRAM:
            reason_description = "プログラムから要求された終了";
            break;
        case REASON_REMOVE:
            reason_description = "チャートから削除";
            break;
        case REASON_RECOMPILE:
            reason_description = "再コンパイル";
            break;
        case REASON_CHARTCHANGE:
            reason_description = "シンボル変更";
            break;
        case REASON_CHARTCLOSE:
            reason_description = "チャート閉じる";
            break;
        case REASON_PARAMETERS:
            reason_description = "入力パラメータ変更";
            break;
        case REASON_ACCOUNT:
            reason_description = "アカウント変更";
            break;
        default:
            reason_description = "不明な理由";
            break;
       }

    Print("EA が終了しました。理由: ", reason_description);
   }
//+------------------------------------------------------------------+
//| エキスパートティック関数                                                |
//+------------------------------------------------------------------+
void OnTick()
   {

    RangeChecker(); //レンジ計算

    if((bool)MQLInfoInteger(MQL_TESTER)) // バックテスト中かどうかを確認
       {
        ChartOBJ(); //チャートオブジェクト描写関数
       }

//Print("israngeCalculated: ", isRangeCalculated); // デバッグ用


//--- 4時間ごとに動作
    static datetime last4HourTime = 0;
    datetime current4HourBarTime = iTime(_Symbol, PERIOD_H4, 0);
    if(current4HourBarTime > last4HourTime)  // 新しい4時間バーが始まった場合
       {
        last4HourTime = current4HourBarTime; // 記録を更新

        PIP = GetPipSize(); // PIPサイズを取得
       }

   }
//+------------------------------------------------------------------+
//| OnTimer                                                 |
//+------------------------------------------------------------------+
void OnTimer()
   {
    if(ChartObject)
       {
        // チャートオブジェクトが有効な場合のみ描画
        ChartOBJ();
        //ChartRedraw(); // チャートを再描画
       }

    DailyChecker();
    PositionCloseTimeChecker();

//- 2Hごとに起動
    datetime currentH2BarTime = iTime(_Symbol, PERIOD_H2, 0);
    if(currentH2BarTime > lastH2BarTime)
       {
        lastH2BarTime = currentH2BarTime;

        //--- TIME Setting~ ---
        //- Time set Convert - 日本時間のインプットからサーバーdatetimeへ変換
        RangeStartServerTimeC = JSTtoServerTime(RangeStartJHour, RangeStartJMin);
        RangeEndServerTimeC = JSTtoServerTime(RangeEndJHour, RangeEndJMin);
        PositionCloseServerTimeC = JSTtoServerTime(ClosePositionJHour, ClosePositionJMin);
        //--- ~TIME Setting ---
       }

//--- TIME Setting~ ---
//現在時間struct
    MqlDateTime dt_now;
    datetime now = TimeCurrent();
    TimeToStruct(now, dt_now);

//Range Start Struct
    MqlDateTime dt_RangeStart;
    TimeToStruct(RangeStartServerTimeC, dt_RangeStart);
    dt_RangeStart.day = dt_now.day; //今日の日付で上書き //JSTtoServerTimeの設計上時間を過ぎると次の日になるため
    dt_RangeStart.sec = 0; //丸める
    RangeStartServerTime = StructToTime(dt_RangeStart); //時間へ再変換

//Range End Struct
    MqlDateTime dt_RangeEnd;
    TimeToStruct(RangeEndServerTimeC, dt_RangeEnd);
    dt_RangeEnd.day = dt_now.day;
    dt_RangeEnd.sec = 0; //丸める
    RangeEndServerTime = StructToTime(dt_RangeEnd);

//Position Cloes Time Struct
    MqlDateTime dt_PositionClose;
    TimeToStruct(PositionCloseServerTimeC, dt_PositionClose);
    dt_PositionClose.day = dt_now.day;
    dt_PositionClose.sec = 0; //丸める
    PositionCloseServerTime = StructToTime(dt_PositionClose);

//日マタギを考慮して、Startのほうが多きければEndに２４時間分追加
    if(RangeStartServerTime >= RangeEndServerTime)
       {
        RangeEndServerTime += PeriodSeconds(PERIOD_D1); //1日後にする
       }
//日マタギを考慮して
    if(RangeEndServerTime >= PositionCloseServerTime)
       {
        PositionCloseServerTime += PeriodSeconds(PERIOD_D1); //1日後にする
       }
//--- ~TIME Setting ---


// --- ここで次のレンジ開始時間を越えたらリセット ---
    if(now >= RangeStartServerTime && lastRangeStartReset < RangeStartServerTime)
       {
        // リセット処理
        rangeHigh               = 0.0;
        rangeLow                = 0.0;
        isRangeCalculated       = false;
        hasPositionBeenOpenedToday = false;
        lastRangeStartReset     = RangeStartServerTime;
        PrintFormat("次のレンジ開始時刻 %s を検出。レンジ情報をリセットしました。",
                    TimeToString(RangeStartServerTime, TIME_DATE|TIME_SECONDS));
       }
   }

//+------------------------------------------------------------------+
//| OnTradeTransaction (取引処理)                                     |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
   {
//--- トランザクションが新しい約定（実行）であるか確認 ---
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
       {
        ulong deal_ticket = trans.deal; // 実行された約定のチケット番号を取得

        // 履歴から該当する約定を選択
        if(HistoryDealSelect(deal_ticket))
           {
            // 約定の詳細情報を取得
            long deal_magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC); // マジックナンバーを取得
            long deal_type = HistoryDealGetInteger(deal_ticket, DEAL_TYPE); // 約定タイプ（買い/売りなど）
            long deal_entry = HistoryDealGetInteger(deal_ticket, DEAL_ENTRY); // エントリータイプ（新規/決済など）

            //--- このEAのマジックナンバーに該当する約定か確認 ---
            if(deal_magic == MagicNumber)
               {
                // 新規ポジションのエントリー（買いまたは売り）であるか確認
                if((deal_type == DEAL_TYPE_BUY || deal_type == DEAL_TYPE_SELL) && deal_entry == DEAL_ENTRY_IN)
                   {
                    hasPositionBeenOpenedToday = true; // フラグをtrueに設定
                   }
               }
           }
        else
           {
            // 約定の選択に失敗した場合、エラーをログに出力
            PrintFormat("OnTransaction エラー: 約定チケット %I64u の選択に失敗しました。エラー: %d", deal_ticket, GetLastError());
           }
       }
   }

//+------------------------------------------------------------------+
//| OnChartEvent Function                                            |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
   {
// チャートの範囲が変更された場合（スクロールやズームなど）
    if(id == CHARTEVENT_CHART_CHANGE)
       {
        if(ChartObject)
           {
            ChartRedraw(); // チャートを再描画
           }
       }
   }

//+------------------------------------------------------------------+
//|RangeChecker                                              |
//+------------------------------------------------------------------+
void RangeChecker() //時間内（レンジ内）の最、高安値を取得。isRangeCalculatedのフラグ管理
   {
    datetime now = TimeCurrent(); // 現在のサーバー時間

//--- まだ当日のレンジ計算が完了していない場合 ---
    if(!isRangeCalculated)
       {
        //--- 現在時刻がレンジ計算時間内の場合 ---
        if(now >= RangeStartServerTime && now < RangeEndServerTime)
           {
            // 初めてこの範囲に入った時の初期化処理
            if(rangeHigh == 0.0 && rangeLow == 0.0)
               {
                // 最初のティック価格で初期化するか、バーデータを使うか選択
                // ここでは例として、現在の1分足のHigh/Lowで初期化
                double m1High[], m1Low[];
                if(CopyHigh(_Symbol, PERIOD_M1, 0, 1, m1High) > 0 && CopyLow(_Symbol, PERIOD_M1, 0, 1, m1Low) > 0)
                   {
                    rangeHigh = m1High[0];
                    rangeLow = m1Low[0];
                    //PrintFormat("レンジ計算開始: 初期 High=%.5f, Low=%.5f", rangeHigh, rangeLow);
                   }
                else
                   {
                    Print("レンジ計算開始エラー: 1分足データの取得に失敗。Bid/Askで初期化します。");
                    // データ取得失敗時の代替: 現在のBid/Askで仮初期化
                    rangeHigh = SymbolInfoDouble(_Symbol, SYMBOL_ASK); // 高値はAsk
                    rangeLow = SymbolInfoDouble(_Symbol, SYMBOL_BID);  // 安値はBid
                   }
                // rangeCalculationDate が未設定なら現在時刻で設定 (OnTimerの日替わり処理と連携)
                if(rangeCalculationDate == 0)
                   {
                    rangeCalculationDate = now;
                   }

               }
            else
               {
                // 既存のレンジHigh/Lowを更新
                // 方法1: 現在のティック価格で更新 (Askで高値、Bidで安値)
                //rangeHigh = MathMax(rangeHigh, SymbolInfoDouble(_Symbol, SYMBOL_ASK));
                //rangeLow = MathMin(rangeLow, SymbolInfoDouble(_Symbol, SYMBOL_BID));

                // 方法2: 直近の完成した1分足のHigh/Lowで更新 (より安定)
                double m1High[], m1Low[];
                if(CopyHigh(_Symbol, PERIOD_M1, 1, 1, m1High) > 0 && CopyLow(_Symbol, PERIOD_M1, 1, 1, m1Low) > 0)
                   {
                    rangeHigh = MathMax(rangeHigh, m1High[0]);
                    rangeLow = MathMin(rangeLow, m1Low[0]);
                   }
               }
            // PrintFormat("レンジ更新中: High=%.5f, Low=%.5f", rangeHigh, rangeLow); // デバッグ用 (頻繁に出力されるので注意)
           }
        //--- 現在時刻がレンジ終了時間を過ぎ、かつHigh/Lowが一度は設定されている場合 ---
        else
            if(now >= RangeEndServerTime && rangeHigh != 0.0)  // rangeHigh != 0.0 は計算が開始されたことを示す
               {
                isRangeCalculated = true; // レンジ計算完了フラグを立てる→trading開始
                //PrintFormat("レンジ計算完了: Final High=%.5f, Low=%.5f (時刻: %s)",
                //            NormalizeDouble(rangeHigh, _Digits), NormalizeDouble(rangeLow, _Digits), TimeToString(now));

                // (オプション) ここで CopyRates を使い、指定期間のバーデータからより正確な High/Low を再計算することも可能
                // CalculateRangeHighLowAccurate();
               }
       }

//--- レンジ計算が完了していれば、ブレイクアウト判定などを行う ---
    if(isRangeCalculated)
       {
        EntryChecker();

        // Print("ブレイクアウト待機中..."); // デバッグ用
       }

   }

//+------------------------------------------------------------------+
//| DailyChecker                           |
//+------------------------------------------------------------------+
void DailyChecker()
   {
    datetime now = TimeCurrent(); // 現在のサーバー時間
    MqlDateTime dt_now;
    TimeToStruct(now, dt_now);

//--- 日替わりチェック ---
// rangeCalculationDate に記録されている日付と現在の日付が違う場合、リセット処理を行う
    MqlDateTime dt_calc;
    TimeToStruct(rangeCalculationDate, dt_calc);
//日が変われば処理
    if(dt_now.year != dt_calc.year || dt_now.mon != dt_calc.mon || dt_now.day != dt_calc.day)
       {
        Print("日付が変わりました。レンジ情報をリセットします。");
        //rangeHigh = 0.0;
        //rangeLow = 0.0;
        //isRangeCalculated = false; // 計算フラグもリセット
        //isTradingSessionClosed = false; // 日付が変わったらフラグをリセット
        rangeCalculationDate = now; // 現在の日付を記録 (時刻部分は0:00:00にするのがより正確だが、ここでは簡単化)
        // ResetRatesData(); // (もしCopyRatesなどでデータ保持していたらここでリセット)
        //hasPositionBeenOpenedToday = false; // 今日のポジションオープンフラグをリセット
       }
   }


//+------------------------------------------------------------------+
//| CloseTimeChecker                                               |
//+------------------------------------------------------------------+
void PositionCloseTimeChecker()
   {

    datetime now = TimeCurrent();
    if(now >= PositionCloseServerTime /*&& !isTradingSessionClosed*/) // ポジションクローズ時刻になったかチェック
       {
        // 保有ポジションをループして確認
        for(int i = PositionsTotal() - 1; i >= 0; i--)
           {
            ulong ticket = PositionGetTicket(i); // チケット番号を取得
            if(PositionSelectByTicket(ticket)) // チケット番号でポジションを選択
               {
                // MagicNumberを比較
                if(PositionGetInteger(POSITION_MAGIC) == MagicNumber)
                   {
                    PrintFormat("PositionCloseTime 決済試行 (Ticket: %d)", ticket);
                    if(!trade.PositionClose(ticket))
                       {
                        PrintFormat("ポジション (Ticket: %d) の決済に失敗しました。Error: %d", ticket, GetLastError());
                       }
                    else
                       {
                        PrintFormat("決済成功 (Ticket: %d)", ticket);
                       }
                   }
               }
            else
               {
                PrintFormat("ポジション選択に失敗しました。Ticket: %d, Error: %d", ticket, GetLastError());
               }
           }

        //isTradingSessionClosed = true;
        isRangeCalculated = false; // 決済後は再エントリーしないようにレンジ計算フラグもリセット
        //Print("時間決済処理完了。isTradingSessionClosed を true に設定。");

       }
   }
//+------------------------------------------------------------------+
//| EntryChecker                                                  |
//+------------------------------------------------------------------+
void EntryChecker()
   {
    if(isRangeCalculated)
       {
        //Print("1");
        //--- Position Count ---
        MaxPositionSignal = (CountPositionsByMagic(MagicNumber) < MaxPosition)
                            ? SIGNAL_OK_TRADE : SIGNAL_NONE; // 最大ポジション数を超えたらトレードしない
        //--- (Position Count) ---
        //Print("PM: ",CountPositionsByMagic(MagicNumber)," MPS: ", MaxPositionSignal); // デバッグ用

        //--- Trade ---
        if(/*MaxPositionSignal == SIGNAL_OK_TRADE && */ !hasPositionBeenOpenedToday)
           {
            //Print("1.5");
            //レンジ上ブレイク Long
            if(SymbolInfoDouble(_Symbol, SYMBOL_BID) > rangeHigh)
               {
                //Print("2");
                //STOP LOSS価格を計算
                double stopLoss = NormalizeDouble(rangeLow, _Digits);// SL価格を正規化
                //PrintFormat("レンジHigh (%.5f) をブレイク。買いエントリー試行。", rangeHigh);

                //stop PIPを計算
                double stopAskDifference = MathAbs(stopLoss - SymbolInfoDouble(_Symbol, SYMBOL_ASK));
                double stopLossPips = stopAskDifference / PIP; // SLをPIPに変換
                double lotSize = 0.0; // 初期
                if(LotMode == LOT_MODE_RISK_PERCENT)
                   {
                    lotSize = CalculateLotSize(_Symbol, stopLossPips, RiskPercent); // ロットサイズ計算関数を呼び出す
                   }
                else
                    if(LotMode == LOT_MODE_FIXED)
                       {
                        lotSize = FixedLotSize; // 固定ロットサイズを使用
                       }

                // 買い注文 (ロット, シンボル, 価格, SL, TP, Magic, コメント)
                if(!trade.Buy(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), stopLoss, 0, "TRB Buy"))
                   {
                    PrintFormat("買いエントリー失敗。Error: %d", GetLastError());
                   }
                else
                   {
                    isRangeCalculated = false; // レンジ計算フラグをリセット
                    PrintFormat("買いエントリー成功。Ticket: %d", trade.ResultDeal()); // 直近の約定チケット番号
                   }
               }

            //レンジ下ブレイク　Short
            else
                if(SymbolInfoDouble(_Symbol, SYMBOL_BID) < rangeLow)
                   {
                    //Print("2");
                    double stopLoss = NormalizeDouble(rangeHigh, _Digits); // SL価格を正規化
                    //PrintFormat("レンジLow (%.5f) をブレイク。売りエントリー試行。", rangeLow);

                    //stop PIPを計算
                    double stopAskDifference = MathAbs(stopLoss - SymbolInfoDouble(_Symbol, SYMBOL_BID));
                    double stopLossPips = stopAskDifference / PIP; // SLをPIPに変換
                    double lotSize = 0.0; // 初期
                    if(LotMode == LOT_MODE_RISK_PERCENT)
                       {
                        lotSize = CalculateLotSize(_Symbol, stopLossPips, RiskPercent); // ロットサイズ計算関数を呼び出す
                       }
                    else
                        if(LotMode == LOT_MODE_FIXED)
                           {
                            lotSize = FixedLotSize; // 固定ロットサイズを使用
                           }

                    // 売り注文 (ロット, シンボル, 価格, SL, TP, Magic, コメント)
                    if(!trade.Sell(lotSize, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), stopLoss, 0, "TRB Sell"))
                       {
                        PrintFormat("売りエントリー失敗。Error: %d", GetLastError());
                       }
                    else
                       {
                        isRangeCalculated = false; // レンジ計算フラグをリセット
                        PrintFormat("売りエントリー成功。Ticket: %d", trade.ResultDeal()); // 直近の約定チケット番号
                       }
                   }
           }
        //--- (Trade) ---

       }
   }

//+------------------------------------------------------------------+
//| 指定したMagicNumberのポジション数をカウントする関数                |
//+------------------------------------------------------------------+
int CountPositionsByMagic(int magic)
   {
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
       {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
           {
            if(PositionGetInteger(POSITION_MAGIC) == magic)
               {
                count++;
               }
           }
       }
    return count;
   }

//+------------------------------------------------------------------+
//| チャートオブジェクト描写関数                                       |
//+------------------------------------------------------------------+
void ChartOBJ()
   {

//--- [オブジェクト削除]~ ---
    ObjectsDeleteAll(0, "RangeStartTime_");
    ObjectsDeleteAll(0, "RangeEndTime_");
    ObjectsDeleteAll(0, "PositionCloseTime_");
    ObjectsDeleteAll(0, "RangeBox_");
    ObjectsDeleteAll(0, "RangeHighLine_");
    ObjectsDeleteAll(0, "RangeLowLine_");
    ObjectsDeleteAll(0, "DailyOpen_");
//--- ~[オブジェクト削除] ---

//オブジェクト描写ループ
    for(int i = 0; i < DrawDays; i++)
       {
        //-シンプルに１日秒をループごとに引く戦法-
        //レンジスタート時間　i日
        datetime RStart = RangeStartServerTime - (i * PeriodSeconds(PERIOD_D1));
        //レンジ終了時間　i日
        datetime REnd = RangeEndServerTime - (i * PeriodSeconds(PERIOD_D1));
        //ポジションクローズ時間 i日
        datetime PC = PositionCloseServerTime - (i * PeriodSeconds(PERIOD_D1));

        //--- オブジェクト名の生成 ---
        string RSname = "RangeStartTime_" + TimeToString(RStart, TIME_DATE); // レンジスタート時間のオブジェクト名
        string REname = "RangeEndTime_" + TimeToString(REnd, TIME_DATE);      // レンジ終了時間のオブジェクト名
        string PCname = "PositionCloseTime_" + TimeToString(PC, TIME_DATE);   // ポジションクローズ時間のオブジェクト名
        string BoxName = "RangeBox_" + TimeToString(RStart, TIME_DATE);      // レンジボックスのオブジェクト名
        string RangeHighLineName = "RangeHighLine_" + TimeToString(RStart, TIME_DATE); // レンジ高値ラインのオブジェクト名
        string RangeLowLineName = "RangeLowLine_" + TimeToString(RStart, TIME_DATE); // レンジ安値ラインのオブジェクト名
        string DailyOpenVLineName = "DailyOpen_" + TimeToString(RStart, TIME_DATE);// 日足スタートの垂直線オブジェクト名


        //---- [Box描写]~ ----
        //---  レンジ期間の最高値・最安値を取得してボックスを描画 ---
        int startShift = iBarShift(_Symbol, PERIOD_M1, RStart);
        int endShift = iBarShift(_Symbol, PERIOD_M1, REnd);
        double dayRangeHigh = 0.0;
        double dayRangeLow = 0.0;

        // バーインデックスが有効かチェック (未来や古すぎるデータは-1になる)
        if(startShift >= 0 && endShift >= 0 && startShift >= endShift)
           {
            int barsInRange = startShift - endShift + 1; // +1 で endShift のバーも含む
            if(barsInRange > 0)
               {
                //double highs[], lows[];
                int copiedHigh = CopyHigh(_Symbol, PERIOD_M1, endShift, barsInRange, highs);
                int copiedLow = CopyLow(_Symbol, PERIOD_M1, endShift, barsInRange, lows);

                if(copiedHigh > 0 && copiedLow > 0)//取得できたバーの数を返す
                   {
                    dayRangeHigh = highs[ArrayMaximum(highs)];
                    dayRangeLow = lows[ArrayMinimum(lows)];

                    datetime now = TimeCurrent(); // 現在のサーバー時間を取得
                    if(now >= RStart) // 現在時間がレンジスタート時間以上の場合
                       {
                        // ボックスオブジェクトを作成・設定
                        if(ObjectCreate(0, BoxName, OBJ_RECTANGLE, 0, RStart, dayRangeLow, REnd, dayRangeHigh))
                            //if(ObjectCreate(0, BoxName, OBJ_RECTANGLE, 0, RStart, rangeLow, REnd, rangeHigh))
                           {
                            ObjectSetInteger(0, BoxName, OBJPROP_COLOR, C'0xFF,0x33,0x38'); // ボックスの色
                            ObjectSetInteger(0, BoxName, OBJPROP_STYLE, STYLE_SOLID);      // 線のスタイル
                            ObjectSetInteger(0, BoxName, OBJPROP_WIDTH, 1);                // 線の太さ
                            ObjectSetInteger(0, BoxName, OBJPROP_BACK, true);             // 背景に描画
                            ObjectSetInteger(0, BoxName, OBJPROP_FILL, true);             // 塗りつぶし有効
                            ObjectSetInteger(0, BoxName, OBJPROP_SELECTABLE, false);      // 選択不可
                            ObjectSetInteger(0, BoxName, OBJPROP_SELECTED, false);        // 非選択状態
                           }
                        else
                           {
                            PrintFormat("Failed to create Rectangle object %s. Error: %d", BoxName, GetLastError());
                           }
                       }
                   }
                else
                   {
                    PrintFormat("Failed to copy High/Low data for %s range.", TimeToString(RStart, TIME_DATE));
                   }
               }
           }
        else
           {
            // PrintFormat("Invalid bar shifts for %s range. Start: %d, End: %d", TimeToString(RStart, TIME_DATE), startShift, endShift);
           }
        //---- ~[Box描写] ----

        //---- [レンジHLライン描写]~ ----
        // レンジ高値ラインの描画
        if(ObjectCreate(0, RangeHighLineName, OBJ_TREND, 0, RStart, dayRangeHigh, PC, dayRangeHigh))
           {
            ObjectSetInteger(0, RangeHighLineName, OBJPROP_COLOR, clrRed);
            ObjectSetInteger(0, RangeHighLineName, OBJPROP_WIDTH, 1);
            ObjectSetInteger(0, RangeHighLineName, OBJPROP_STYLE, STYLE_SOLID);
            ObjectSetInteger(0, RangeHighLineName, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, RangeHighLineName, OBJPROP_SELECTED, false);
            ObjectSetInteger(0, RangeHighLineName, OBJPROP_BACK, true);
           }
        else
           {
            PrintFormat("Failed to create trend line %s. Error: %d", RangeHighLineName, GetLastError());
           }
        // レンジ安値ラインの描画
        if(ObjectCreate(0, RangeLowLineName, OBJ_TREND, 0, RStart, dayRangeLow, PC, dayRangeLow))
           {
            ObjectSetInteger(0, RangeLowLineName, OBJPROP_COLOR, clrRed);
            ObjectSetInteger(0, RangeLowLineName, OBJPROP_WIDTH, 1);
            ObjectSetInteger(0, RangeLowLineName, OBJPROP_STYLE, STYLE_SOLID);
            ObjectSetInteger(0, RangeLowLineName, OBJPROP_SELECTABLE, false);
            ObjectSetInteger(0, RangeLowLineName, OBJPROP_SELECTED, false);
            ObjectSetInteger(0, RangeLowLineName, OBJPROP_BACK, true);
           }
        else
           {
            PrintFormat("Failed to create trend line %s. Error: %d", RangeLowLineName, GetLastError());
           }
        //---- ~[レンジHLライン描写] ----

        //--- [レンジスタート・終了時間を描画]~ ---
        if(ObjectFind(0, RSname) == -1) // オブジェクトが存在しない場合のみ描画
           {
            // レンジスタート時間の垂直線を描画
            DrawVLine(RSname, RStart, clrRed, 1);
           }
        else
           {
            // 既存のオブジェクトがある場合は、時間を更新して移動させる
            ObjectSetInteger(0, RSname, OBJPROP_TIME, 0, RStart);
           }

        if(ObjectFind(0, REname) == -1) // オブジェクトが存在しない場合のみ描画
           {
            // レンジ終了時間の垂直線を描画
            DrawVLine(REname, REnd, clrRed, 1);
           }
        else
           {
            // 既存のオブジェクトがある場合は、時間を更新して移動させる
            ObjectSetInteger(0, REname, OBJPROP_TIME, 0, REnd);
           }

        if(ObjectFind(0, PCname) == -1) // オブジェクトが存在しない場合のみ描画
           {
            // ポジションクローズ時間の垂直線を描画
            DrawVLine(PCname, PC, clrBlue, 1);
           }
        else
           {
            // 既存のオブジェクトがある場合は、時間を更新して移動させる
            ObjectSetInteger(0, PCname, OBJPROP_TIME, 0, PC);
           }
        //--- ~[レンジスタート・終了時間を描画] ---
       }
//ChartRedraw(); // チャートを再描画
   }
//+------------------------------------------------------------------+
//| DrawVLine 垂直線描写                          |
//+------------------------------------------------------------------+
void DrawVLine(string name, datetime time, color col, int width = 1)
   {
    ObjectCreate(0, name, OBJ_VLINE, 0, time, 0);
    ObjectSetInteger(0, name, OBJPROP_COLOR, col);
    ObjectSetInteger(0, name, OBJPROP_WIDTH, width);
    ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
    ObjectSetInteger(0, name, OBJPROP_BACK, true); // 背景に描画
    ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false); // 選択不可
    ObjectSetInteger(0, name, OBJPROP_SELECTED, false);   // 非選択状態
   }


//+------------------------------------------------------------------+
//|- プレフィックスに一致するオブジェクトをすべて削除する関数
//+------------------------------------------------------------------+
void DeleteObjectsByPrefix(const string prefix, const long chart_id = 0)
   {
    int totalObjects = ObjectsTotal(chart_id);
    for(int i = totalObjects - 1; i >= 0; i--)
       {
        string objName = ObjectName(chart_id, i, 0);
        if(StringFind(objName, prefix, 0) == 0) // プレフィックスが先頭にあるかチェック
           {
            if(!ObjectDelete(chart_id, objName))
               {
                PrintFormat("オブジェクト '%s' の削除に失敗しました。エラー: %d", objName, GetLastError());
               }
           }
       }
   }


//+========================================================================+
//|| ---------------- TIME SECTION ------------------                    ||
//+========================================================================+
//+------------------------------------------------------------------+
//| DSTルール定義 TIME SECTION  (ヘッダーに置く?)            |
//+------------------------------------------------------------------+
enum ENUM_DST_RULE
   {
    DST_NONE,     // DSTなし
    DST_EUROPE,   // 欧州ルール (デフォルト)
    DST_USA       // 米国ルール
   };
//+----------------------------------------------------------------------------------------------------------+
//| JST to ServerTIME 関数                                                                                   |
//| 指定されたJST時刻(時・分)に相当をサーバー時刻に変換し返す                                                    |
//| テスターモードでは standardServerOffsetHours と dstRule に基づいて手動DST判定を行う                         |
//| ライブ環境では TimeCurrent() と TimeGMT() の差からDST込みのオフセットを自動計算するため、dstRule は無視される  |
//+----------------------------------------------------------------------------------------------------------+
datetime JSTtoServerTime(
    int jHour,                            // 目標のJST時 (0-23)
    int jMinute,                         // 目標のJST分 (0-59)
    int standardServerOffsetHours = 2,  // サーバーの*標準時*のGMTオフセット(時間単位, 例: GMT+2なら2)
    ENUM_DST_RULE dstRule = DST_USA    // テスターモードで使用するDSTルール (ライブでは無視)
)
   {
// --- 入力値検証 ---
    if(jHour < 0 || jHour > 23 || jMinute < 0 || jMinute > 59)
       {
        PrintFormat("time_con エラー: 無効な時刻が指定されました (時=%d, 分=%d)", jHour, jMinute);
        return 0;
       }
// OffSetの検証 (例: GMT-12からGMT+14の範囲)
    if(standardServerOffsetHours < -12 || standardServerOffsetHours > 14)
       {
        PrintFormat("time_con エラー: 無効な標準オフセットが指定されました (OffSet=%d)", standardServerOffsetHours);
        return 0;
       }

// --- JSTのGMTからのオフセット(秒) (JST = GMT+9) ---
    const long jst_offset_seconds = 9 * 3600; //1h=3600sec

// --- 現在のサーバー時刻を取得 ---
// (テスター/ライブ共通: TimeCurrent()はどちらでも動作する)
    datetime now_server = TimeCurrent();
    if(now_server == 0) // TimeCurrent()がまだ有効でない場合(起動直後など)
       {
        PrintFormat("time_con エラー: 現在のサーバー時刻を取得できません。");
        return 0;
       }

    long server_offset_seconds = 0; // サーバーの現在のGMTオフセット(秒)

// --- モードに応じてサーバーのGMTオフセット(秒)を計算 ---
    bool isTester = (bool)MQLInfoInteger(MQL_TESTER);
    if(isTester)
       {
        // --- テスターモード ---
        // PrintFormat("time_con: テスターモード (標準オフセット = %+d, DSTルール = %s)",
        //             standardServerOffsetHours, EnumToString(dstRule));

        // 1. 標準時のオフセットを秒に変換
        long base_offset_seconds = (long)standardServerOffsetHours * 3600;

        // 2. 指定されたルールに基づいて現在のシミュレーション時刻のDSTを判定
        bool is_dst = false;
        switch(dstRule)
           {
            case DST_EUROPE:
                is_dst = IsSummerTime_Europe(now_server, (int)base_offset_seconds);
                //if(is_dst) Print("time_con: DST期間中と判定 (欧州ルール)");
                break;
            case DST_USA:
                is_dst = IsSummerTime_USA(now_server, (int)base_offset_seconds);
                //if(is_dst) Print("time_con: DST期間中と判定 (米国ルール)");
                break;
            case DST_NONE:
            default:
                is_dst = false; // DSTなし、または不明なルール
                //if(dstRule != DST_NONE) PrintFormat("time_con 警告: 不明なDSTルール %d が指定されました。DSTなしとして扱います。", (int)dstRule);
                break;
           }

        // 3. 夏時間ならオフセットを+1時間調整
        long dst_offset_seconds_adjustment = (is_dst ? 3600 : 0);
        server_offset_seconds = base_offset_seconds + dst_offset_seconds_adjustment;

        // PrintFormat("time_con: 計算されたサーバーオフセット = %d 秒 (GMT %+f)", server_offset_seconds, (double)server_offset_seconds / 3600.0);
       }
    else
       {
        // --- ライブ環境 ---
        // Print("time_con: ライブモード");
        // 1. 現在のサーバー時刻とGMTを取得
        datetime now_gmt = TimeGMT();
        if(now_gmt == 0) // TimeGMT()がまだ有効でない場合
           {
            PrintFormat("time_con エラー: GMT時刻を取得できません。ライブ環境では処理を中断します。");
            // ライブでGMTが取れないのは致命的。テスターのように標準オフセットを使うのは不正確すぎる可能性がある。
            return 0;
           }

        // 2. サーバーの現在のGMTからのオフセット(秒)を計算 (DST自動反映)
        server_offset_seconds = (long)now_server - (long)now_gmt;
        // PrintFormat("time_con: ライブ オフセット = %d 秒 (GMT %+f)", server_offset_seconds, (double)server_offset_seconds / 3600.0);
       }

// --- 共通計算部分 ---

// 4. JSTとサーバー時間のオフセットの差を計算 (JSTがサーバー時間より何秒進んでいるか)
    long diff_jst_vs_server = jst_offset_seconds - server_offset_seconds;

// 5. 今日のサーバー日付で、指定された JST 時・分を持つ仮の時刻を作成
//    (これはまだ正しいサーバー時間ではない。あくまで計算の基準点)
    MqlDateTime dt;
    TimeToStruct(now_server, dt); // 現在のサーバー日付を取得
    dt.hour = jHour;              // 指定されたJSTの「時」を設定 (まだ仮)
    dt.min = jMinute;             // 指定されたJSTの「分」を設定 (まだ仮)
    dt.sec = 0;
    datetime target_time_on_server_date = StructToTime(dt);
    if(target_time_on_server_date == 0) // StructToTime失敗チェック
       {
        PrintFormat("time_con エラー: 仮の目標時刻を作成できませんでした (日付:%s, 時:%d, 分:%d)",
                    TimeToString(now_server, TIME_DATE), jHour, jMinute);
        return 0;
       }

// 6. 仮の時刻からオフセット差を引いて、目標のJST時刻に対するサーバー時刻を計算
//    例: JST=GMT+9, Server=GMT+3(DST) の場合、差は +6時間。
//        JST 10:00 は Server 04:00。
//        ステップ5で仮に作った Server日付の10:00 から 6時間引くと Server日付の04:00 になる。
    datetime target_server_time = (datetime)target_time_on_server_date - (datetime)diff_jst_vs_server;

// 7. 日付ロールオーバー処理: 計算結果が現在時刻より過去なら翌日の時刻とする
//    これにより、常に「次の」指定JST時刻に対応するサーバー時刻を返す
    if(target_server_time <= now_server)
       {
        target_server_time += 24 * 3600; // 1日(秒)を加算

        // --- DST境界チェック (テスターモードのみ、翌日にDST状態が変わる可能性がある場合) ---
        // 翌日にした結果、DST状態が変わる場合、オフセットが1時間ずれる可能性がある。
        // このずれを補正するために、翌日のオフセットを再計算し、target_server_time を微調整する。
        if(isTester && dstRule != DST_NONE) // ライブでは不要、DSTなしルールでも不要
           {
            long next_day_base_offset_seconds = (long)standardServerOffsetHours * 3600;
            bool next_day_is_dst = false;
            switch(dstRule)
               {
                case DST_EUROPE:
                    next_day_is_dst = IsSummerTime_Europe(target_server_time, (int)next_day_base_offset_seconds);
                    break;
                case DST_USA:
                    next_day_is_dst = IsSummerTime_USA(target_server_time, (int)next_day_base_offset_seconds);
                    break;
               }
            long next_day_dst_offset_adjustment = (next_day_is_dst ? 3600 : 0);
            long next_day_server_offset_seconds = next_day_base_offset_seconds + next_day_dst_offset_adjustment;

            // オフセットが変化した場合、その差分だけ時刻を調整
            long offset_difference = next_day_server_offset_seconds - server_offset_seconds;
            if(offset_difference != 0)
               {
                // PrintFormat("time_con: DST境界を跨ぎました。オフセット変化: %d秒。時刻を調整します。", offset_difference);
                // JSTとサーバーの差が変化するので、その分 target_server_time を調整する。
                // diff_jst_vs_server = jst_offset_seconds - server_offset_seconds;
                // next_diff_jst_vs_server = jst_offset_seconds - next_day_server_offset_seconds;
                // 調整量 = target_server_time(旧オフセット基準) - target_server_time(新オフセット基準)
                //       = (target_jst_utc + server_offset_seconds) - (target_jst_utc + next_day_server_offset_seconds)
                //       = server_offset_seconds - next_day_server_offset_seconds = -offset_difference
                target_server_time -= (datetime)offset_difference;

                // 再度、調整後の時刻が過去になっていないかチェック（通常は不要だが念のため）
                if(target_server_time <= now_server)
                   {
                    target_server_time += 24 * 3600;
                   }
               }
           }
       }

// PrintFormat("time_con: 指定JST %02d:%02d -> 次のサーバー時間 %s (オフセット: %+f)",
//             jHour, jMinute, TimeToString(target_server_time, TIME_DATE|TIME_SECONDS), (double)server_offset_seconds / 3600.0); // デバッグ用

    return target_server_time;
   }
//+------------------------------------------------------------------+
//| 欧州夏時間ルールに基づき、指定時刻が夏時間中か判定                   |
//| (テスター用ヘルパー関数)                                        |
//| serverTime: 判定対象のサーバー時間                             |
//| standardOffsetSeconds: サーバーの*標準時*のGMTオフセット(秒)       |
//+------------------------------------------------------------------+
bool IsSummerTime_Europe(datetime serverTime, int standardOffsetSeconds)
   {
// サーバー時間からUTC時間を計算 (DST考慮前の標準時オフセットを使用)
    datetime utcTime = (datetime)serverTime - (datetime)standardOffsetSeconds;
    MqlDateTime dtUTC;
    if(!TimeToStruct(utcTime, dtUTC)) // 失敗チェック追加
       {
        PrintFormat("IsSummerTime_Europe Error: TimeToStruct failed for UTC time calculation (serverTime=%s, offset=%d)",
                    TimeToString(serverTime), standardOffsetSeconds);
        return false; // 失敗時は判定不可として標準時扱い
       }

// 4月～9月は確定で夏時間
    if(dtUTC.mon > 3 && dtUTC.mon < 10)
       {
        return true;
       }
// 1月, 2月, 11月, 12月は確定で標準時間
    if(dtUTC.mon < 3 || dtUTC.mon > 10)
       {
        return false;
       }

// 3月の場合: 最終日曜日の AM 1:00 UTC 以降か判定
    if(dtUTC.mon == 3)
       {
        datetime dstStartTime = GetLastSunday1amUTC(dtUTC.year, 3);
        if(dstStartTime == 0)
           {
            PrintFormat("IsSummerTime_Europe Warning: Failed to get DST start time for %d-03. Assuming standard time.", dtUTC.year);
            return false; // 最終日曜日の取得失敗時は標準時扱い
           }
        return (utcTime >= dstStartTime);
       }

// 10月の場合: 最終日曜日の AM 1:00 UTC より前か判定
    if(dtUTC.mon == 10)
       {
        datetime dstEndTime = GetLastSunday1amUTC(dtUTC.year, 10);
        if(dstEndTime == 0)
           {
            PrintFormat("IsSummerTime_Europe Warning: Failed to get DST end time for %d-10. Assuming standard time.", dtUTC.year);
            return false; // 最終日曜日の取得失敗時は標準時扱い
           }
        return (utcTime < dstEndTime);
       }

// ここには到達しないはず
    PrintFormat("IsSummerTime_Europe Error: Unexpected month %d", dtUTC.mon);
    return false;
   }
//+------------------------------------------------------------------+
//| 米国夏時間ルールに基づき、指定時刻が夏時間中か判定              |
//| (テスター用ヘルパー関数)                                        |
//| serverTime: 判定対象のサーバー時間                             |
//| standardOffsetSeconds: サーバーの*標準時*のGMTオフセット(秒)     |
//+------------------------------------------------------------------+
bool IsSummerTime_USA(datetime serverTime, int standardOffsetSeconds)
   {
// サーバー時間からUTC時間を計算 (DST考慮前の標準時オフセットを使用)
    datetime utcTime = (datetime)serverTime - (datetime)standardOffsetSeconds;
    MqlDateTime dtUTC;
    if(!TimeToStruct(utcTime, dtUTC))
       {
        PrintFormat("IsSummerTime_USA Error: TimeToStruct failed for UTC time calculation (serverTime=%s, offset=%d)",
                    TimeToString(serverTime), standardOffsetSeconds);
        return false; // 失敗時は判定不可として標準時扱い
       }


// 月による絞り込み
    if(dtUTC.mon < 3 || dtUTC.mon > 11)
        return false; // 1, 2, 12月は標準時
    if(dtUTC.mon > 3 && dtUTC.mon < 11)
        return true;  // 4月～10月は夏時間

// --- DST開始判定 (3月) ---
    if(dtUTC.mon == 3)
       {
        // DSTは3月第2日曜日の現地標準時AM 2:00に開始
        // その瞬間のUTC時刻を計算する
        datetime secondSundayStartUTC = GetNthWeekdayOfMonthUTC(dtUTC.year, 3, 2, SUNDAY, 0, 0); // 第2日曜日のUTC 00:00
        if(secondSundayStartUTC == 0)
           {
            PrintFormat("IsSummerTime_USA Warning: Failed to get 2nd Sunday of March %d. Assuming standard time.", dtUTC.year);
            return false;
           }
        // 現地標準時 AM 2:00に対応するUTC時刻 = 日曜UTC 00:00 + (2時間 - 標準オフセット秒)
        datetime dstStartTimeUTC = secondSundayStartUTC + (2 * 3600 - standardOffsetSeconds);

        // PrintFormat("Debug USA Start: Year=%d, 2ndSunUTC0=%s, StartUTC=%s, CurrentUTC=%s",
        //             dtUTC.year, TimeToString(secondSundayStartUTC, TIME_DATE|TIME_SECONDS),
        //             TimeToString(dstStartTimeUTC, TIME_DATE|TIME_SECONDS),
        //             TimeToString(utcTime, TIME_DATE|TIME_SECONDS));

        return (utcTime >= dstStartTimeUTC);
       }

// --- DST終了判定 (11月) ---
    if(dtUTC.mon == 11)
       {
        // DSTは11月第1日曜日の現地夏時間AM 2:00に終了 (現地標準時AM 1:00に戻る)
        // その瞬間のUTC時刻を計算する (標準時に戻る瞬間 = 現地標準時AM 1:00)
        datetime firstSundayStartUTC = GetNthWeekdayOfMonthUTC(dtUTC.year, 11, 1, SUNDAY, 0, 0); // 第1日曜日のUTC 00:00
        if(firstSundayStartUTC == 0)
           {
            PrintFormat("IsSummerTime_USA Warning: Failed to get 1st Sunday of November %d. Assuming standard time.", dtUTC.year);
            return false;
           }
        // 現地標準時 AM 1:00に対応するUTC時刻 = 日曜UTC 00:00 + (1時間 - 標準オフセット秒)
        datetime dstEndTimeUTC = firstSundayStartUTC + (1 * 3600 - standardOffsetSeconds);

        // PrintFormat("Debug USA End: Year=%d, 1stSunUTC0=%s, EndUTC=%s, CurrentUTC=%s",
        //             dtUTC.year, TimeToString(firstSundayStartUTC, TIME_DATE|TIME_SECONDS),
        //             TimeToString(dstEndTimeUTC, TIME_DATE|TIME_SECONDS),
        //             TimeToString(utcTime, TIME_DATE|TIME_SECONDS));

        // DST終了時刻(UTC)より前であれば、まだDST期間中
        return (utcTime < dstEndTimeUTC);
       }

// ここには到達しないはず
    PrintFormat("IsSummerTime_USA Error: Unexpected month %d", dtUTC.mon);
    return false;
   }
//+------------------------------------------------------------------+
//| 指定した年月の最終日曜日 AM 1:00 UTC の datetime を返す        |
//| (欧州 DST 計算用ヘルパー関数)                                   |
//+------------------------------------------------------------------+
datetime GetLastSunday1amUTC(int year, int month)
   {
    MqlDateTime dt;
    dt.year = year;
    dt.mon = month;
    dt.hour = 1; // UTC 1時
    dt.min = 0;
    dt.sec = 0;

// その月の最終日を取得 (簡便法)
    int daysInMonth = 31;
    if(month == 4 || month == 6 || month == 9 || month == 11)
        daysInMonth = 30;
    else
        if(month == 2)
           {
            // うるう年判定
            bool isLeap = (year % 4 == 0 && year % 100 != 0) || (year % 400 == 0);
            daysInMonth = isLeap ? 29 : 28;
           }
// dt.day は設定せず、月末から探す

// 月末日から遡って日曜日を探す
    for(int d = daysInMonth; d >= 1; d--)
       {
        dt.day = d; // 日付を設定
        // MqlDateTimeからdatetimeを生成し、曜日を確認
        datetime tempTime = StructToTime(dt);
        if(tempTime > 0) // 有効な日時か確認
           {
            MqlDateTime checkDt;
            if(TimeToStruct(tempTime, checkDt)) // 再度構造体を取得して曜日を確認
               {
                // StructToTime/TimeToStructで日付が変わらないか念のため確認
                if(checkDt.year == year && checkDt.mon == month && checkDt.day == d)
                   {
                    if(checkDt.day_of_week == SUNDAY) // 0 = Sunday
                       {
                        // 見つかった日曜日の 1:00 UTC を正確に作る
                        // 既に dt.hour = 1 になっているので tempTime をそのまま返せば良い
                        return tempTime;
                       }
                   }
                else
                   {
                    // 日付が変わってしまった場合（通常ありえない）
                    PrintFormat("GetLastSunday1amUTC Warning: Date mismatch after StructToTime/TimeToStruct for %d-%02d-%02d", year, month, d);
                   }
               }
            else
               {
                PrintFormat("GetLastSunday1amUTC Warning: TimeToStruct failed for tempTime %s", TimeToString(tempTime));
               }
           }
        else
           {
            // StructToTimeが失敗した場合 (月の最終週などで稀に発生しうる)
            // PrintFormat("GetLastSunday1amUTC Debug: StructToTime failed for %d-%02d-%02d 01:00", year, month, d);
           }

       }
// 見つからなかった場合 (通常ありえない)
    PrintFormat("GetLastSunday1amUTC Error: Could not find last Sunday for %d-%02d", year, month);
    return 0;
   }
//+------------------------------------------------------------------+
//| 指定した年月の第N週・指定曜日の指定UTC時刻のdatetimeを返す      　　 |
//| (米国 DST 計算用ヘルパー関数)                                 　  |
//| nth: 週番号 (1=第1, 2=第2, ...) 第何週か                     　   |
//| day_of_week: 曜日 (0=日, 1=月, ..., 6=土)                        |
//| hourUTC, minuteUTC: 目標のUTC時刻                            　  |
//+------------------------------------------------------------------+
datetime GetNthWeekdayOfMonthUTC(int year, int month, int nth, int day_of_week, int hourUTC = 0, int minuteUTC = 0)
   {
    if(nth <= 0 || nth > 5)
       {
        PrintFormat("GetNthWeekdayOfMonthUTC Error: Invalid nth value %d", nth);
        return 0; // 無効な週番号
       }
    if(day_of_week < 0 || day_of_week > 6)
       {
        PrintFormat("GetNthWeekdayOfMonthUTC Error: Invalid day_of_week value %d", day_of_week);
        return 0; // 無効な曜日
       }


    MqlDateTime dt;
    dt.year = year;
    dt.mon = month;
    dt.day = 1; // 月の初日から開始
    dt.hour = hourUTC; // 指定されたUTC時
    dt.min = minuteUTC; // 指定されたUTC分
    dt.sec = 0;

    datetime firstDayTime = StructToTime(dt);
    if(firstDayTime == 0)
       {
        PrintFormat("GetNthWeekdayOfMonthUTC Error: Failed to create time for the 1st day of %d-%02d", year, month);
        return 0; // 月初日時作成失敗
       }

    MqlDateTime firstDayStruct;
    if(!TimeToStruct(firstDayTime, firstDayStruct))
       {
        PrintFormat("GetNthWeekdayOfMonthUTC Error: TimeToStruct failed for the 1st day of %d-%02d", year, month);
        return 0; // 構造体取得失敗
       }

// 月の初日の曜日 (0=Sun, 6=Sat)
    int firstDayOfWeek = firstDayStruct.day_of_week;

// 最初の目標曜日が何日になるか計算
// 例: 月初が水曜(3)で、目標が日曜(0)の場合: (0 - 3 + 7) % 7 = 4日後 -> 1 + 4 = 5日
// 例: 月初が日曜(0)で、目標が日曜(0)の場合: (0 - 0 + 7) % 7 = 0日後 -> 1 + 0 = 1日
    int daysToAddForFirstOccurrence = (day_of_week - firstDayOfWeek + 7) % 7;
    int firstOccurrenceDayOfMonth = 1 + daysToAddForFirstOccurrence;

// 第N週の目標曜日の日付を計算
    int targetDayOfMonth = firstOccurrenceDayOfMonth + (nth - 1) * 7;

// 計算結果の日付を dt 構造体に設定
    dt.day = targetDayOfMonth;

// 最終的な datetime を生成
    datetime targetTime = StructToTime(dt);
    if(targetTime == 0)
       {
        // PrintFormat("GetNthWeekdayOfMonthUTC Info: Calculated day %d for %d-%02d might be invalid (e.g., 5th Sunday).", targetDayOfMonth, year, month);
        return 0; // 無効な日付 (例: 存在しない第5日曜日など)
       }

// 生成された datetime が本当に正しい月か確認
    MqlDateTime verifyDt;
    if(!TimeToStruct(targetTime, verifyDt))
       {
        PrintFormat("GetNthWeekdayOfMonthUTC Error: TimeToStruct failed for targetTime %s", TimeToString(targetTime));
        return 0;
       }

    if(verifyDt.mon != month)
       {
        // PrintFormat("GetNthWeekdayOfMonthUTC Info: Target day %d for %d-%02d resulted in month %d. Not found.", targetDayOfMonth, year, month, verifyDt.mon);
        return 0; // 計算した日が翌月になってしまった場合 = その月のN番目の曜日は存在しない
       }

// 時刻が指定通りになっているか最終確認 (StructToTimeの挙動による影響を排除)
    if(verifyDt.hour != hourUTC || verifyDt.min != minuteUTC)
       {
        // PrintFormat("GetNthWeekdayOfMonthUTC Debug: Time components mismatch. Re-adjusting. Expected %02d:%02d, Got %02d:%02d for %s",
        //             hourUTC, minuteUTC, verifyDt.hour, verifyDt.min, TimeToString(targetTime));
        verifyDt.hour = hourUTC;
        verifyDt.min = minuteUTC;
        verifyDt.sec = 0;
        targetTime = StructToTime(verifyDt);
        if(targetTime == 0)
           {
            PrintFormat("GetNthWeekdayOfMonthUTC Error: Failed to re-adjust time components for %d-%02d-%02d %02d:%02d",
                        verifyDt.year, verifyDt.mon, verifyDt.day, hourUTC, minuteUTC);
            return 0;
           }
       }

    return targetTime;
   }
//==TIME SECTION=========================================================================================================================++

//+------------------------------------------------------------------+
//|ロットサイズ計算関数 許容損失％と損切幅から計算                        |
//+------------------------------------------------------------------+
double CalculateLotSize(
    const string symbol,
    const double stopLossPips,
    const double riskPercent,
    const bool useBalance = true,
    const ENUM_ORDER_TYPE orderType = NULL
)

   {
// --- 0. 入力値検証 ---
    if(symbol == "" || !SymbolSelect(symbol, true))
       {
        PrintFormat("%s: Error - Symbol '%s' is invalid, not found, or not selected in Market Watch.", __FUNCTION__, symbol);
        return (0.0);
       }
    if(stopLossPips <= 0)
       {
        PrintFormat("%s: Error - Stop Loss (%.2f pips/points) must be positive.", __FUNCTION__, stopLossPips);
        return (0.0);
       }
    if(riskPercent <= 0)
       {
        PrintFormat("%s: Error - Risk percentage (%.2f%%) must be positive.", __FUNCTION__, riskPercent);
        return (0.0);
       }
// orderType は現在計算に不要だが、将来的に使う可能性を考慮し形式チェックのみ
    /*if(orderType != ORDER_TYPE_BUY && orderType != ORDER_TYPE_SELL)
       {
        PrintFormat("%s: Warning - Invalid order type specified (%d). Calculation proceeds but ensure correct usage.", __FUNCTION__, orderType);
        // return(0.0); // エラーにする場合はコメント解除
       }
    */

// --- 1. 必要な口座情報を取得 ---
    double accountFund = useBalance ? AccountInfoDouble(ACCOUNT_BALANCE) : AccountInfoDouble(ACCOUNT_EQUITY);
    string accountCurrency = AccountInfoString(ACCOUNT_CURRENCY);

    if(accountFund <= 0)
       {
        PrintFormat("%s: Error - Account %s (%.2f %s) is zero or negative.", __FUNCTION__,
                    useBalance ? "Balance" : "Equity", accountFund, accountCurrency);
        return (0.0);
       }

// --- 2. 必要な銘柄情報を取得 ---
    double point = SymbolInfoDouble(symbol, SYMBOL_POINT);             // 最小価格変動単位
    double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE); // 1ティックの価値(口座通貨) - 1 Lot あたり
    double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);   // 1ティックの価格変動幅
    double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);      // ロットステップ
    double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);        // 最小ロット
    double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);        // 最大ロット
    int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);      // 価格の小数点以下桁数
    int    lotDigits = 0; // ロットの小数点以下桁数

// ロットステップから小数点以下桁数を決定
    if(lotStep > 0)
       {
        //-mathlog10が0を下回れば、0.0が採用される。mathlog10は10の何乗で()になるかの計算-にしてるのは+に反転させるため +0.00001は誤計算対策(例:-1.9999999998)
        lotDigits = (int)MathMax(0.0, -MathLog10(lotStep) + 0.00001);
       }
    else
       {
        PrintFormat("%s: Warning - Lot step for '%s' is zero or invalid. Assuming 2 digits for lot normalization.", __FUNCTION__, symbol);
        lotDigits = 2;
       }

    if(point <= 0 || tickValue <= 0 || tickSize <= 0 || lotStep <= 0 || minLot <= 0)
       {
        PrintFormat("%s: Error - Failed to retrieve critical symbol info for '%s'. Point=%.10f, TickValue=%.5f, TickSize=%.10f, LotStep=%.*f, MinLot=%.*f",
                    __FUNCTION__, symbol, point, tickValue, tickSize, lotDigits, lotStep, lotDigits, minLot);
        // TickValueが0または負は計算不能
        return (0.0);
       }

// --- 3. 1ロットあたりの損失額を計算 (口座通貨建て) ---
//    OrderCalcProfit を使わずに計算する

    double valuePerPoint = 0;
// TickValue は 1 Lot あたりの TickSize 変動による価値
// Point あたりの価値を計算 (TickSize が Point の N 倍の場合があるため)
    if(tickSize > 1e-10)  //1e-10=1 × 10⁻¹⁰=0.0000000001 誤差によって、理論上ゼロでも "0.00000000000001" のような超微小な値が残っていた場合に true になってしまう。それの対策
       {
        valuePerPoint = tickValue * (point / tickSize);
       }
    else
       {
        PrintFormat("%s: Error - Tick size for '%s' is zero or too small (%.10f). Cannot calculate value per point.", __FUNCTION__, symbol, tickSize);
        return (0.0);
       }


// 1 Pip は Point の何倍か？ (FXペアでは通常10倍、CFD等では1倍の場合が多い)
// 一般的なルール: 桁数が 3 または 5 -> 1 Pip = 10 Points, 桁数が 2 または 4 -> 1 Pip = 1 Point
    double pointsPerPip = 1.0;
    if(digits == 3 || digits == 5)
       {
        pointsPerPip = 10.0;
       }
// 例外的な銘柄 (例: XAUUSD=2桁だがPointがPipを表さない場合) は別途考慮が必要になる場合がある
// ここでは一般的なルールを適用

// 1 Pip あたりの価値 (1ロットあたり、口座通貨建て)
    double valuePerPip = valuePerPoint * pointsPerPip;

// 1ロットあたりの損失額 (SL幅 Pips * 1 Pip あたりの価値)
    double lossPerLot = stopLossPips * valuePerPip;

    if(lossPerLot <= 1e-10)  // 損失が計算できない、またはゼロの場合
       {
        PrintFormat("%s: Warning/Error - Calculated loss per lot for '%s' is zero or negative (%.10f %s). Check symbol info (TickValue=%.5f, TickSize=%.10f, Point=%.10f) and Stop Loss (%.2f pips).",
                    __FUNCTION__, symbol, lossPerLot, accountCurrency, tickValue, tickSize, point, stopLossPips);
        return(0.0);
       }

// --- 4. リスク許容額から最適ロットを計算 ---
    double riskAmount = accountFund * (riskPercent / 100.0);
    double calculatedLot = riskAmount / lossPerLot;

// --- 5. ロットサイズを正規化し、制約内に収める ---
    double adjustedLot = MathFloor(calculatedLot / lotStep) * lotStep;

    if(adjustedLot < minLot)
       {
        PrintFormat("%s: Info - Calculated lot (%.*f -> adjusted %.*f) for '%s' is below minimum (%.*f). Returning 0.0.",
                    __FUNCTION__,
                    lotDigits + 2, calculatedLot,
                    lotDigits, adjustedLot,
                    symbol,
                    lotDigits, minLot);
        return (0.0);
       }

    if(adjustedLot > maxLot)
       {
        PrintFormat("%s: Info - Calculated lot (%.*f -> adjusted %.*f) for '%s' exceeds maximum (%.*f). Capping at maximum.",
                    __FUNCTION__,
                    lotDigits + 2, calculatedLot,
                    lotDigits, adjustedLot,
                    symbol,
                    lotDigits, maxLot);
        adjustedLot = maxLot;
       }

    double finalLotSize = NormalizeDouble(adjustedLot, lotDigits);

// --- 6. 結果表示 (デバッグ用) ---
    PrintFormat("%s: Symbol=%s, SL Pips=%.1f, Risk=%.2f%%, Fund=%.2f %s => Risk Amount=%.2f %s, Value/Pip=%.5f %s, Loss/Lot=%.2f %s => Calc Lot=%.*f => Final Lot=%.*f",
                __FUNCTION__,
                symbol, stopLossPips, riskPercent,
                accountFund, accountCurrency,
                riskAmount, accountCurrency,
                valuePerPip, accountCurrency, // 1 Pipあたりの価値も表示
                lossPerLot, accountCurrency,
                lotDigits + 2, calculatedLot,
                lotDigits, finalLotSize);


// --- 7. 計算結果を返す ---
    return (finalLotSize);
   }

//+------------------------------------------------------------------+
//| Pip size取得関数                                            |
//+------------------------------------------------------------------+
double GetPipSize()
   {
// シンボル情報を取得
    int calc_mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_CALC_MODE);
    double pointSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

// Pointサイズが無効な場合は基本的なチェック
    if(pointSize <= 0)
       {
        PrintFormat("Warning: Invalid SYMBOL_POINT (%.*f) for %s. Returning 0.", digits, pointSize, _Symbol);
        return 0.0;
       }

    double pipSize = 0.0;

// --- Code B の CALC_MODE による分岐を採用 ---
    if(calc_mode == SYMBOL_CALC_MODE_FOREX || calc_mode == SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE)
       {
        // --- FX系の処理: Code A の正しいロジックを採用 ---
        if(digits == 3 || digits == 5)  // JPY系3桁 (123.456) または 非JPY系5桁 (1.23456)
           {
            pipSize = pointSize * 10.0;
           }
        else
            if(digits == 2 || digits == 4)  // JPY系2桁 (123.45) または 非JPY系4桁 (1.2345)
               {
                pipSize = pointSize;
               }
            else // FXカテゴリだが標準外の桁数の場合 (念のためPointを返す)
               {
                pipSize = pointSize;
                // 必要なら警告メッセージを表示
                // PrintFormat("Warning: Unusual digits (%d) for Forex symbol %s. Using PointSize as PipSize.", digits, _Symbol);
               }
       }
// --- それ以外の計算モード (CFD, Futures, Stock, etc.) ---
    else
       {
        // --- Code B の TickSize を返すロジックを基本とするが、Code A の堅牢性を加える ---
        // TickSizeが有効であればそれを採用
        if(tickSize > 0)
           {
            pipSize = tickSize;
           }
        // TickSizeが無効ならPointをフォールバック (安全策)
        else
           {
            pipSize = pointSize;
            // 必要なら警告メッセージを表示
            // PrintFormat("Warning: Invalid SYMBOL_TRADE_TICK_SIZE (%.*f) for non-Forex symbol %s. Using PointSize as fallback.", digits, tickSize, _Symbol);
           }
       }

// 念のため、計算されたPipSizeがPointSizeより小さくならないようにする
// (TickSize が PointSize より小さい特殊ケースへの対応)
    if(pipSize < pointSize)
       {
        // TickSize が有効で PointSize より小さい場合は、TickSize を優先すべきか検討
        // ここでは安全策として、PointSize を下回らないように調整する
        // PrintFormat("Warning: Calculated PipSize (%.*f) was smaller than PointSize (%.*f) for %s. Adjusted to PointSize.", digits, pipSize, digits, pointSize, _Symbol);
        pipSize = pointSize;
       }


// --- Code A 同様、最後に NormalizeDouble を適用 (重要!) ---
    return NormalizeDouble(pipSize, digits);
   }
//+------------------------------------------------------------------+

