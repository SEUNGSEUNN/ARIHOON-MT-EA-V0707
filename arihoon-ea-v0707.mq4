// === EA 메타 정보 ===
#property copyright   "ARIHOON"
#property link        "https://arihoon.example"
#property version     "1.00"
#property strict

// === 사용자 입력값 ===
input double 진입_랏크기 = 0.1;
input double 익절금액_USD = 5.0;
input double TP_금액_USD = 5.0;
input double SL_거리_비율 = 1.0;
input int    슬리피지허용 = 30;
input double 최대허용스프레드 = 3.0;
input int    허용_계좌번호 = 774010;
input string 사용_만료일자 = "2025.12.31";
input int    사용자_매직넘버 = 0; // 0이면 자동 설정
input double 마틴_배율 = 2.0;
input double 반익절_비율 = 0.5;
input double 트레일링_비율 = 0.3;
input string 로그파일명 = "arihoon_log.csv";
input int 재진입_대기초 = 10;
input int 유지시간_초 = 30;

// === 전역 변수 선언 ===
bool isMartin1Entered = false;
bool isMartin2Entered = false;
int  lastDirection = 0;
int  lastOrderTicket = -1;
int  martinCount = 0;
bool isEntered = false;
datetime lastCloseTime = 0;
datetime sameColorStartTime = 0;
datetime entryTime = 0;
double entryPrice = 0.0;
bool isTrailingActive = false;
double partialTP = 0.0;
int 매직넘버;
bool isPartialExitDone = false;

// === 초기화 함수 (OnInit): 계좌/기간 검사 및 매직넘버 설정 통합 ===
int OnInit() {
    if (AccountNumber() != 허용_계좌번호) {
        Alert("❌ 계좌번호 불일치: EA 실행이 차단됩니다.");
        return(INIT_FAILED);
    }
    if (TimeCurrent() > StringToTime(사용_만료일자)) {
        Alert("❌ EA 사용 기간이 만료되었습니다.");
        return(INIT_FAILED);
    }
    if (사용자_매직넘버 == 0)
        매직넘버 = StringToInteger(StringSubstr(Symbol(), 0, 6) + IntegerToString(Period()));
    else
        매직넘버 = 사용자_매직넘버;
    Print("✅ ARIHOON EA 초기화 완료, 매직넘버: ", 매직넘버);
    return INIT_SUCCEEDED;
}
// === 로그 저장 함수 ===
void SaveLog(string event, double price, double lots) {
    int handle = FileOpen(로그파일명, FILE_CSV|FILE_WRITE|FILE_READ|FILE_SHARE_WRITE, ';');
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), event, Symbol(), DoubleToString(price, Digits), DoubleToString(lots, 2));
        FileClose(handle);
    }
}

// === HUD 출력 함수 ===
void DrawHUD() {
    string info = "진입상태: " + (isEntered ? "ON" : "OFF") +
                  "\n마틴횟수: " + IntegerToString(martinCount) +
                  "\n현재가: " + DoubleToString(Bid, Digits) +
                  "\n스프레드: " + DoubleToString(Spread(), 1);
    if(ObjectFind(0, "HUD_Info") == -1)
        ObjectCreate(0, "HUD_Info", OBJ_LABEL, 0, 0, 0);
    ObjectSetInteger(0, "HUD_Info", OBJPROP_CORNER, CORNER_LEFT_UPPER);
    ObjectSetInteger(0, "HUD_Info", OBJPROP_XDISTANCE, 10);
    ObjectSetInteger(0, "HUD_Info", OBJPROP_YDISTANCE, 20);
    ObjectSetInteger(0, "HUD_Info", OBJPROP_FONTSIZE, 12);
    ObjectSetInteger(0, "HUD_Info", OBJPROP_COLOR, clrWhite);
    ObjectSetString(0, "HUD_Info", OBJPROP_TEXT, info);
}

void UpdateHUD() {
    DrawHUD();
}

void ClearAllObjects() {
    if (ObjectFind(0, "HUD_Info") != -1) ObjectDelete(0, "HUD_Info");
}

// === 진입 전 조건 검사 ===
bool IsValidSignal() {
    if (Volume[0] > 1) return false;
    if (Spread() > 최대허용스프레드) {
        Alert("[EA] 스프레드 초과로 진입 불가 - 현재: ", DoubleToString(Spread(), 1));
        return false;
    }
    return true;
}

bool IsTradeAllowed() {
    if (!IsValidSignal()) return false;
    if (AccountFreeMargin() < 100) {
        Alert("[EA] 마진 부족으로 진입 차단");
        return false;
    }
    return true;
}

bool IsMyOrder(int index) {
    if (!OrderSelect(index, SELECT_BY_POS, MODE_TRADES)) return false;
    return (OrderMagicNumber() == 매직넘버 && OrderSymbol() == Symbol());
}

bool IsHoldTimePassed() {
    return (TimeCurrent() - entryTime >= 유지시간_초);
}

bool IsReentryAllowed() {
    return (TimeCurrent() - lastCloseTime >= 재진입_대기초);
}

// === 반익절 + 트레일링스탑 ===
bool IsMACDOppositeSignal() {
    double macd = iMACD(Symbol(), 0, 12, 26, 9, PRICE_CLOSE, MODE_MAIN, 0);
    double signal = iMACD(Symbol(), 0, 12, 26, 9, PRICE_CLOSE, MODE_SIGNAL, 0);
    if (lastDirection == OP_BUY) return (macd < signal);
    if (lastDirection == OP_SELL) return (macd > signal);
    return false;
}

void CheckPartialExitAndTrailing() {
    if (!isEntered || isPartialExitDone || !isMartin1Entered) return;

    if (IsMACDOppositeSignal()) {
        for (int i = OrdersTotal() - 1; i >= 0; i--) {
            if (!IsMyOrder(i)) continue;
            double halfLots = NormalizeDouble(OrderLots() * 반익절_비율, 2);
            if (halfLots < MarketInfo(Symbol(), MODE_MINLOT)) continue;
            double price = (OrderType() == OP_BUY) ? Bid : Ask;
            OrderClose(OrderTicket(), halfLots, price, 슬리피지허용, clrOrange);
            SaveLog("PartialExit", price, halfLots);
            isPartialExitDone = true;
            isTrailingActive = true;
        }
    }

    if (isTrailingActive) {
        for (int i = OrdersTotal() - 1; i >= 0; i--) {
            if (!IsMyOrder(i)) continue;
            double newSL = 0;
            if (OrderType() == OP_BUY) {
                newSL = Bid - (익절금액_USD * 트레일링_비율 * Point);
                if (newSL > OrderStopLoss())
                    OrderModify(OrderTicket(), OrderOpenPrice(), newSL, OrderTakeProfit(), 0, clrAqua);
            }
            if (OrderType() == OP_SELL) {
                newSL = Ask + (익절금액_USD * 트레일링_비율 * Point);
                if (newSL < OrderStopLoss())
                    OrderModify(OrderTicket(), OrderOpenPrice(), newSL, OrderTakeProfit(), 0, clrAqua);
            }
        }
    }
}

// === 진입 함수 ===
void EnterBuy() {
    if (!IsTradeAllowed() || isEntered || martinCount > 0 || !IsHoldTimePassed() || !IsReentryAllowed()) return;
    double macd = iMACD(Symbol(), 0, 12, 26, 9, PRICE_CLOSE, MODE_MAIN, 0);
    double signal = iMACD(Symbol(), 0, 12, 26, 9, PRICE_CLOSE, MODE_SIGNAL, 0);
    double slGap = MathAbs(macd - signal) * SL_거리_비율 * Point;
    double sl = Ask - slGap;
    double tp = Ask + (TP_금액_USD / MarketInfo(Symbol(), MODE_TICKVALUE));
    int ticket = OrderSend(Symbol(), OP_BUY, 진입_랏크기, Ask, 슬리피지허용, sl, tp, "Buy", 매직넘버, 0, clrBlue);
    if(ticket > 0) {
        isEntered = true;
        lastOrderTicket = ticket;
        lastDirection = OP_BUY;
        entryPrice = Ask;
        entryTime = TimeCurrent();
        isPartialExitDone = false;
        SaveLog("Buy", Ask, 진입_랏크기);
    }
}

void EnterSell() {
    if (!IsTradeAllowed() || isEntered || martinCount > 0 || !IsHoldTimePassed() || !IsReentryAllowed()) return;
    double macd = iMACD(Symbol(), 0, 12, 26, 9, PRICE_CLOSE, MODE_MAIN, 0);
    double signal = iMACD(Symbol(), 0, 12, 26, 9, PRICE_CLOSE, MODE_SIGNAL, 0);
    double slGap = MathAbs(macd - signal) * SL_거리_비율 * Point;
    double sl = Bid + slGap;
    double tp = Bid - (TP_금액_USD / MarketInfo(Symbol(), MODE_TICKVALUE));
    int ticket = OrderSend(Symbol(), OP_SELL, 진입_랏크기, Bid, 슬리피지허용, sl, tp, "Sell", 매직넘버, 0, clrRed);
    if(ticket > 0) {
        isEntered = true;
        lastOrderTicket = ticket;
        lastDirection = OP_SELL;
        entryPrice = Bid;
        entryTime = TimeCurrent();
        isPartialExitDone = false;
        SaveLog("Sell", Bid, 진입_랏크기);
    }
}
void EnterMartin() {
    if (!isEntered || martinCount >= 2) return;

    double lots = 진입_랏크기 * MathPow(마틴_배율, martinCount + 1);
    double price = (lastDirection == OP_BUY) ? Ask : Bid;
    double slGap = 10 * Point; // 간소화된 SL
    double sl = (lastDirection == OP_BUY) ? price - slGap : price + slGap;
    double tp = (lastDirection == OP_BUY) ? price + TP_금액_USD / MarketInfo(Symbol(), MODE_TICKVALUE)
                                          : price - TP_금액_USD / MarketInfo(Symbol(), MODE_TICKVALUE);
    int ticket = OrderSend(Symbol(), lastDirection, lots, price, 슬리피지허용, sl, tp, "Martin", 매직넘버, 0, clrYellow);
    if (ticket > 0) {
        martinCount++;
        SaveLog("Martin" + IntegerToString(martinCount), price, lots);
    }
}

void ExitTrade() {
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (!IsMyOrder(i)) continue;
        double price = (OrderType() == OP_BUY) ? Bid : Ask;
        bool closed = OrderClose(OrderTicket(), OrderLots(), price, 슬리피지허용, clrRed);
        if (closed)
            SaveLog("Exit", price, OrderLots());
    }

    isEntered = false;
    martinCount = 0;
    isMartin1Entered = false;
    isMartin2Entered = false;
    isTrailingActive = false;
    lastCloseTime = TimeCurrent();
    lastOrderTicket = -1;
    entryTime = 0;
    entryPrice = 0.0;
}
void OnTick() {
    UpdateHUD();

    // 진입 처리
    EnterBuy();
    EnterSell();

    // 마틴 진입 처리
    if (isEntered && !isMartin1Entered) {
        double profit = 0;
        for (int i = OrdersTotal() - 1; i >= 0; i--) {
            if (!IsMyOrder(i)) continue;
            profit += OrderProfit() + OrderSwap() + OrderCommission();
        }

        if (profit < 0 && TimeCurrent() - entryTime > 유지시간_초) {
            double lots = 진입_랏크기 * 마틴_배율;
            double price = (lastDirection == OP_BUY) ? Ask : Bid;
            int ticket = OrderSend(Symbol(), lastDirection, lots, price, 슬리피지허용, 0, 0, "Martin1", 매직넘버, 0, clrYellow);
            if (ticket > 0) {
                isMartin1Entered = true;
                martinCount = 1;
                SaveLog("Martin1", price, lots);
            }
        }
    }

    // 반익절 및 트레일링스탑
    CheckPartialExitAndTrailing();

    // 익절 or 손절 도달 시 전체 포지션 청산
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (!IsMyOrder(i)) continue;

        double price = (OrderType() == OP_BUY) ? Bid : Ask;
        double profit = OrderProfit() + OrderSwap() + OrderCommission();
        double tpValue = TP_금액_USD / MarketInfo(Symbol(), MODE_TICKVALUE);

        if (profit >= TP_금액_USD || profit <= -tpValue) {
            bool closed = OrderClose(OrderTicket(), OrderLots(), price, 슬리피지허용, clrRed);
            if (closed) {
                SaveLog("Exit", price, OrderLots());
                isEntered = false;
                isMartin1Entered = false;
                isMartin2Entered = false;
                martinCount = 0;
                lastCloseTime = TimeCurrent();
                isTrailingActive = false;
            }
        }
    }
}
// === SL/TP 조정 함수 ===
void AdjustSLTP(int ticket, double newSL, double newTP) {
    if (!OrderSelect(ticket, SELECT_BY_TICKET)) return;
    OrderModify(ticket, OrderOpenPrice(), newSL, newTP, 0, clrViolet);
}

// === SL 라인 시각화 ===
void DrawSLLine(int ticket) {
    if (!OrderSelect(ticket, SELECT_BY_TICKET)) return;
    string name = "SL_Line_" + IntegerToString(ticket);
    ObjectDelete(name);
    ObjectCreate(name, OBJ_HLINE, 0, 0, OrderStopLoss());
    ObjectSetInteger(0, name, OBJPROP_COLOR, clrRed);
}

// === TP 라인 시각화 ===
void DrawTPLine(int ticket) {
    if (!OrderSelect(ticket, SELECT_BY_TICKET)) return;
    string name = "TP_Line_" + IntegerToString(ticket);
    ObjectDelete(name);
    ObjectCreate(name, OBJ_HLINE, 0, 0, OrderTakeProfit());
    ObjectSetInteger(0, name, OBJPROP_COLOR, clrGreen);
}

// === 모든 오브젝트 제거 ===
void ClearVisualObjects() {
    ObjectsDeleteAll(0, OBJ_HLINE);
    ObjectsDeleteAll(0, OBJ_LABEL);
}

// === 상태 초기화 함수 ===
void ResetAllStatus() {
    isMartin1Entered = false;
    isMartin2Entered = false;
    martinCount = 0;
    isEntered = false;
    isTrailingActive = false;
    isPartialExitDone = false;
    lastOrderTicket = -1;
    entryPrice = 0.0;
    entryTime = 0;
}

// === 종료 시 정리 ===
void OnDeinit(const int reason) {
    ClearVisualObjects();
    Print("🧹 EA 종료 - 오브젝트 정리 완료");
}
void EnterMartin() {
    if (!isEntered || isMartin2Entered || !IsReentryAllowed()) return;
    double lot = 진입_랏크기 * MathPow(마틴_배율, martinCount + 1);
    int type = lastDirection;
    double price = (type == OP_BUY) ? Ask : Bid;
    double slGap = MarketInfo(Symbol(), MODE_SPREAD) * SL_거리_비율 * Point;
    double sl = (type == OP_BUY) ? price - slGap : price + slGap;
    double tp = (type == OP_BUY) ? price + (TP_금액_USD / MarketInfo(Symbol(), MODE_TICKVALUE))
                                 : price - (TP_금액_USD / MarketInfo(Symbol(), MODE_TICKVALUE));

    int ticket = OrderSend(Symbol(), type, lot, price, 슬리피지허용, sl, tp, "Martin", 매직넘버, 0, clrYellow);
    if (ticket > 0) {
        isEntered = true;
        lastOrderTicket = ticket;
        entryTime = TimeCurrent();
        entryPrice = price;
        martinCount++;
        if (martinCount == 1) isMartin1Entered = true;
        if (martinCount == 2) isMartin2Entered = true;
        SaveLog("Martin" + IntegerToString(martinCount), price, lot);
    }
}

void ExitTrade() {
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (!IsMyOrder(i)) continue;
        double price = (OrderType() == OP_BUY) ? Bid : Ask;
        OrderClose(OrderTicket(), OrderLots(), price, 슬리피지허용, clrPurple);
        SaveLog("Exit", price, OrderLots());
    }
    isEntered = false;
    martinCount = 0;
    isMartin1Entered = false;
    isMartin2Entered = false;
    isPartialExitDone = false;
    isTrailingActive = false;
    lastCloseTime = TimeCurrent();
}

void CheckCloseByTPorSL() {
    for (int i = OrdersTotal() - 1; i >= 0; i--) {
        if (!IsMyOrder(i)) continue;
        double profit = OrderProfit() + OrderSwap() + OrderCommission();
        if (profit >= TP_금액_USD || profit <= -TP_금액_USD) {
            ExitTrade();
            break;
        }
    }
}
void OnTick() {
    UpdateHUD();

    if (!isEntered) {
        EnterBuy();
        EnterSell();
    } else {
        EnterMartin();
        CheckPartialExitAndTrailing();
        CheckCloseByTPorSL();
    }
}

void OnDeinit(const int reason) {
    ClearAllObjects();
    Print("🧹 EA 종료 - 모든 객체 정리 완료");
}
