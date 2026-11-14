#import "SXReportController.h"
#import "SXStore.h"
#import "SXAPI.h"
#import "SXUI.h"
#import <SafariServices/SafariServices.h>
#import <math.h>

static NSDictionary *SXRD(id value) { return [value isKindOfClass:NSDictionary.class] ? value : @{}; }
static BOOL SXRWorkspaceMatches(NSString *identity){return [(SXStore.sharedStore.activeProfileUserID?:@"") isEqualToString:identity?:@""];}
static NSArray *SXRA(id value) { return [value isKindOfClass:NSArray.class] ? value : @[]; }
static NSString *SXRT(id value) { if ([value isKindOfClass:NSString.class]) return value; if ([value isKindOfClass:NSNumber.class]) return [value stringValue]; return @""; }
static NSString *SXRJoin(NSArray *values, NSString *separator) { NSMutableArray *strings = [NSMutableArray new]; for (id value in values) { NSString *text = SXRT(value); if (text.length) [strings addObject:text]; } return [strings componentsJoinedByString:separator]; }
static NSString *SXRPct(id value, BOOL fraction) { return SXFiniteNumber(value) ? [NSString stringWithFormat:@"%@%%", SXFormatNumber(@([value doubleValue] * (fraction ? 100 : 1)), 2)] : @"資料不足"; }
static NSString *SXRURL(id value) { NSString *text = SXRT(value); NSURLComponents *parts = [NSURLComponents componentsWithString:text]; if (!parts.host.length || parts.user.length || parts.password.length || ![@[@"https", @"http"] containsObject:parts.scheme.lowercaseString]) return @""; return text; }
static void SXRRow(NSMutableArray *rows, NSString *title, id detail, id url) {
    NSString *text = SXRT(detail), *link = SXRURL(url); if (!title.length && !text.length) return;
    [rows addObject:@{@"title": title ?: @"", @"detail": text, @"url": link}];
}
static void SXRSection(NSMutableArray *sections, NSString *title, NSArray *rows) { if (rows.count) [sections addObject:@{@"title": title ?: @"", @"rows": [rows copy]}]; }
static void SXRMetrics(NSMutableArray *rows, NSDictionary *values, NSArray<NSArray *> *specifications, NSString *currency) {
    for (NSArray *spec in specifications) { NSString *key = spec[0], *label = spec[1], *format = spec.count > 2 ? spec[2] : @"number"; id value = values[key];
        NSString *formatted = [format isEqualToString:@"money"] ? SXMoney(value, currency) : [format isEqualToString:@"percent"] ? SXRPct(value, NO) : [format isEqualToString:@"fraction"] ? SXRPct(value, YES) : [format isEqualToString:@"text"] ? SXRT(value) : SXFormatNumber(value, 2);
        SXRRow(rows, label, formatted.length ? formatted : @"資料不足", nil);
    }
}

@interface SXReportController ()
@property(nonatomic,strong) NSDictionary *run;
@property(nonatomic,strong) NSArray<NSDictionary *> *sections;
@property(nonatomic,strong) UISegmentedControl *tabs;
@property(nonatomic,strong) NSTimer *pollTimer;
@property(nonatomic,strong) NSDictionary *evaluation;
@property(nonatomic,copy) NSString *statusMessage;
@property(nonatomic) NSInteger selectedTab;
@property(nonatomic) NSInteger pollAttempts;
@property(nonatomic) BOOL visible;
@property(nonatomic) BOOL fetching;
@property(nonatomic) BOOL evaluating;
@property(nonatomic,strong) NSDictionary *monitor;
@property(nonatomic) BOOL monitoring;
@end

@implementation SXReportController
+ (BOOL)validateCompletedRun:(NSDictionary *)run forRequest:(NSDictionary *)request allowReusedPlan:(BOOL)allowReuse {
 if(![run isKindOfClass:NSDictionary.class]||![run[@"status"] isEqual:@"completed"]||![run[@"model"] isEqual:@"gemini-4-argon"]||!SXRT(run[@"id"]).length||![run[@"code"] isEqual:request[@"code"]]||![run[@"horizon"] isEqual:request[@"horizon"]])return NO;
 BOOL same=[run[@"id"] isEqual:request[@"id"]];if(!same&&!(allowReuse&&[request[@"kind"] isEqual:@"plan"]&&[run[@"kind"] isEqual:@"plan"]&&[run[@"unchanged"] isEqual:@YES]))return NO;
 NSDictionary *result=SXRD(run[@"result"]),*stock=[SXStore.sharedStore stockForCode:SXRT(request[@"code"])];NSString *currency=[stock[@"market"] isEqual:@"TW"]?@"TWD":@"USD";
 if(!result.count||![result[@"currency"] isEqual:currency]||![result[@"symbol"] isEqual:[SXStore.sharedStore sourceSymbolForCode:SXRT(request[@"code"])]])return NO;
 NSArray *prices=SXRA(result[@"daily"]);NSInteger days=[request[@"horizon"] integerValue];NSUInteger count=days==126?24:days==30?10:7;if(prices.count!=count)return NO;
 for(id item in prices){NSDictionary *point=SXRD(item);if(!SXFiniteNumber(point[@"price"])||[point[@"price"] doubleValue]<=0||!SXFiniteNumber(point[@"low"])||!SXFiniteNumber(point[@"high"])||[point[@"low"] doubleValue]<=0||[point[@"low"] doubleValue]>[point[@"price"] doubleValue]||[point[@"high"] doubleValue]<[point[@"price"] doubleValue]||SXRT(point[@"date"]).length!=10)return NO;}
 NSDictionary *report=SXRD(result[@"report"]),*archive=SXRD(report[@"archive"]);if(report.count){NSString *fingerprint=SXRT(archive[@"fingerprint"]);NSCharacterSet *hex=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"];if(![report[@"version"] isEqual:@2]||fingerprint.length!=64||[fingerprint rangeOfCharacterFromSet:hex.invertedSet].location!=NSNotFound||!SXRT(archive[@"researchId"]).length)return NO;}
 return YES;
}
+ (BOOL)finishNexaRequestForCode:(NSString *)code requestID:(NSString *)requestID {
    SXStore *store = SXStore.sharedStore; NSMutableDictionary *requests = [SXRD([store valueForProfileKey:@"nexa.requests" fallback:@{}]) mutableCopy];
    if (![SXRT(requests[code]) isEqualToString:requestID]) return YES;
    [requests removeObjectForKey:code]; return [store setProfileValue:requests forKey:@"nexa.requests"];
}
+ (BOOL)archiveNexaRun:(NSDictionary *)run forCode:(NSString *)code requestID:(NSString *)requestID {
    if (![run[@"status"] isEqual:@"completed"] || ![run[@"model"] isEqual:@"gemini-4-argon"] || !SXRD(run[@"result"]).count || !SXRT(run[@"id"]).length || !code.length) return NO;
    for(NSDictionary *stored in SXStore.sharedStore.runs)if([stored[@"id"] isEqual:run[@"id"]]&&[stored[@"status"] isEqual:@"completed"]&&stored[@"result"]&&![stored[@"result"] isEqual:run[@"result"]])return NO;
    SXStore *store = SXStore.sharedStore; NSMutableDictionary *plans = [SXRD([store valueForProfileKey:@"nexa.plans" fallback:@{}]) mutableCopy];
    NSMutableDictionary *entry = [SXRD(plans[code]) mutableCopy]; NSDictionary *current = SXRD(entry[@"current"]);
    if ([SXRT(current[@"id"]) isEqualToString:SXRT(run[@"id"])]) {
        if (current[@"result"] && ![current[@"result"] isEqual:run[@"result"]]) return NO;
        // The original snapshot remains exact when the service reuses a plan.
    } else {
        NSMutableArray *history = [SXRA(entry[@"history"]) mutableCopy];
        if (current.count && ![history containsObject:current]) [history insertObject:current atIndex:0];
        entry[@"current"] = run; entry[@"history"] = history; plans[code] = entry;
        if (![store setProfileValue:plans forKey:@"nexa.plans"]) return NO;
    }
    // A reused server plan can have its original ID, different from the new
    // provisional request ID. Remove only that empty provisional row.
    if (![SXRT(run[@"id"]) isEqualToString:requestID]) {
        NSMutableArray *rows = [NSMutableArray new];
        for (NSDictionary *saved in store.runs) {
            BOOL provisional = [SXRT(saved[@"id"]) isEqualToString:requestID] && [saved[@"status"] isEqual:@"running"] && !SXRD(saved[@"result"]).count;
            if (!provisional) [rows addObject:saved];
        }
        if (![store setProfileValue:rows forKey:@"runs"]) return NO;
    }
    return [self finishNexaRequestForCode:code requestID:requestID];
}
- (instancetype)initWithRun:(NSDictionary *)run { self = [super initWithStyle:UITableViewStyleInsetGrouped]; if (self) { _run = [run copy]; _sections = @[]; _statusMessage = @""; } return self; }
- (void)displayArchivedRun:(NSDictionary *)run { if (![run isKindOfClass:NSDictionary.class]) return; self.run = run; self.statusMessage = @""; self.monitor = nil; [self stopPolling]; if (self.isViewLoaded) [self rebuild]; if (self.visible) [self fetchMonitor]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 86;
    self.tabs = [[UISegmentedControl alloc] initWithItems:@[@"總覽", @"價位", @"事件", @"估值", @"風險"]]; self.tabs.selectedSegmentIndex = 0; self.tabs.accessibilityLabel = @"研究報告內容";
    [self.tabs addTarget:self action:@selector(tabChanged) forControlEvents:UIControlEventValueChanged];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 60)]; self.tabs.translatesAutoresizingMaskIntoConstraints = NO; [header addSubview:self.tabs];
    [NSLayoutConstraint activateConstraints:@[[self.tabs.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16], [self.tabs.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16], [self.tabs.topAnchor constraintEqualToAnchor:header.topAnchor constant:8], [self.tabs.heightAnchor constraintGreaterThanOrEqualToConstant:40]]]; self.tableView.tableHeaderView = header;
    self.refreshControl = [UIRefreshControl new]; [self.refreshControl addTarget:self action:@selector(refreshRequested) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeChanged:) name:SXStoreDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(applicationInactive:) name:UIApplicationWillResignActiveNotification object:nil];
    [self rebuild];
}
- (void)dealloc { [self.pollTimer invalidate]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; self.visible = YES; self.pollAttempts = 0; [self resumePolling]; [self fetchMonitor]; }
- (void)viewWillDisappear:(BOOL)animated { [super viewWillDisappear:animated]; self.visible = NO; [self stopPolling]; }
- (void)applicationActive:(NSNotification *)notification { (void)notification; if (self.visible) { [self resumePolling]; [self fetchMonitor]; } }
- (void)applicationInactive:(NSNotification *)notification { (void)notification; [self stopPolling]; }
- (void)storeChanged:(NSNotification *)notification {
    (void)notification; NSString *runID = SXRT(self.run[@"id"]);
    for (NSDictionary *run in SXStore.sharedStore.runs) if ([SXRT(run[@"id"]) isEqualToString:runID]) { self.run = run; break; }
    if (![SXRT(self.run[@"status"]) isEqualToString:@"running"]) [self stopPolling];
    [self rebuild];
}
- (void)stopPolling { [self.pollTimer invalidate]; self.pollTimer = nil; }
- (void)resumePolling {
    if (!self.visible || ![SXRT(self.run[@"status"]) isEqualToString:@"running"] || self.pollTimer || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    [self fetchRun]; __weak typeof(self) weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:3 repeats:YES block:^(NSTimer *timer) { (void)timer; [weakSelf fetchRun]; }];
}
- (void)refreshRequested { [self fetchRun]; }
- (void)fetchRun {
    if (self.fetching) { [self.refreshControl endRefreshing]; return; }
    NSString *runID = SXRT(self.run[@"id"]); if (!runID.length) { [self.refreshControl endRefreshing]; return; }
    if (++self.pollAttempts > 80) { self.statusMessage = @"分析尚未確認完成。稍後可重新開啟這份紀錄；不會自動重跑付費模型。"; [self stopPolling]; [self.refreshControl endRefreshing]; [self rebuild]; return; }
    self.fetching = YES;
    NSString *encoded = [runID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
    __weak typeof(self) weakSelf = self;NSString *workspace=[SXStore.sharedStore.activeProfileUserID copy];
    [SXAPI.sharedAPI requestPath:[@"/api/research/run?id=" stringByAppendingString:encoded] method:@"GET" body:nil completion:^(id json, NSInteger status, NSError *error) {
        typeof(self) self = weakSelf; if (!self||!SXRWorkspaceMatches(workspace)) return; self.fetching = NO; [self.refreshControl endRefreshing]; NSDictionary *value = SXRD(json);
        if (error || status != 200) {
            self.statusMessage = status == 404 && [SXRT(self.run[@"status"]) isEqualToString:@"running"] ? @"正在建立原始研究請求，稍後只查詢同一識別碼。" : error.localizedDescription ?: (SXRT(value[@"error"]).length ? value[@"error"] : @"研究狀態暫時無法取得。原始本機紀錄仍保留。");
            [self rebuild]; return;
        }
        NSString *state = SXRT(value[@"status"]);
        if ([self.run[@"status"] isEqual:@"completed"] && ![state isEqual:@"completed"]) return;
        if ([state isEqualToString:@"completed"] && ![SXReportController validateCompletedRun:value forRequest:self.run allowReusedPlan:NO]) { self.statusMessage = @"後台結果未通過識別碼、期間、幣別或價位格式檢查，尚未覆蓋本機紀錄。"; [self stopPolling]; [self rebuild]; return; }
        if ([self.run[@"status"] isEqual:@"completed"] && SXRD(self.run[@"result"]).count && ![self.run[@"result"] isEqual:value[@"result"]]) { self.statusMessage = @"後台回傳內容與本機原始研究不同，已保留本機封存；沒有自動改寫預測。"; [self stopPolling]; [self rebuild]; return; }
        if (![@[@"running", @"completed", @"failed"] containsObject:state]) { self.statusMessage = @"後台未回傳可辨識的研究狀態，原始紀錄仍保留。"; [self rebuild]; return; }
        NSMutableDictionary *merged = [self.run mutableCopy]; [merged addEntriesFromDictionary:value]; merged[@"id"] = runID;
        self.statusMessage = @""; [SXStore.sharedStore upsertRun:merged];
        if ([merged[@"kind"] isEqual:@"plan"]) {
            if ([state isEqual:@"completed"] && ![SXReportController archiveNexaRun:merged forCode:SXRT(merged[@"code"]) requestID:runID]) { self.statusMessage = @"原始結果已保留，但 NEXA 歷史封存尚未保存完成；請先匯出備份。"; [self rebuild]; }
            else if ([state isEqual:@"failed"]) [SXReportController finishNexaRequestForCode:SXRT(merged[@"code"]) requestID:runID];
            if ([state isEqual:@"completed"]) [self fetchMonitor];
        }
    }];
}
- (void)fetchMonitor {
    if (!self.visible || self.monitoring || ![self.run[@"kind"] isEqual:@"plan"] || ![self.run[@"status"] isEqual:@"completed"]) return;
    NSString *symbol = [SXStore.sharedStore sourceSymbolForCode:SXRT(self.run[@"code"])]; if (!symbol.length) return;
    self.monitoring = YES; NSString *runID = SXRT(self.run[@"id"]); __weak typeof(self) weakSelf = self;NSString *workspace=[SXStore.sharedStore.activeProfileUserID copy];
    [SXAPI.sharedAPI requestPath:[@"/api/research/monitor?symbol=" stringByAppendingString:[symbol stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet]] method:@"GET" body:nil completion:^(id json, NSInteger status, NSError *error) {
        typeof(self) self = weakSelf; if (!self||!SXRWorkspaceMatches(workspace)) return; self.monitoring = NO; if (![SXRT(self.run[@"id"]) isEqualToString:runID]) return;
        NSDictionary *value = SXRD(json);
        if (!error && status == 200 && [value[@"runId"] isEqual:runID] && SXFiniteNumber(value[@"price"]) && [@[@"within", @"risk", @"target"] containsObject:SXRT(value[@"state"])]) self.monitor = value;
        else self.monitor = @{@"unavailable": @YES, @"notice": !error && status == 200 && ![value[@"runId"] isEqual:runID] ? @"後台最新計畫已換版，這份歷史封存不套用新版條件。" : @"即時條件暫時無法核對；原始計畫與研究價位仍保留。"};
        [self rebuild];
    }];
}
- (void)tabChanged { self.selectedTab = self.tabs.selectedSegmentIndex; [self rebuild]; if ([self.tableView numberOfSections]) [self.tableView setContentOffset:CGPointMake(0, -self.tableView.adjustedContentInset.top) animated:NO]; }
- (void)updateMenu {
    __weak typeof(self) weakSelf = self; NSString *runID = SXRT(self.run[@"id"]);
    UIAction *pin = [UIAction actionWithTitle:[SXStore.sharedStore isPinned:runID] ? @"取消釘選" : @"釘選研究" image:[UIImage systemImageNamed:@"star"] identifier:nil handler:^(__kindof UIAction *action) { (void)action; [SXStore.sharedStore togglePin:runID]; }];
    UIAction *full = [UIAction actionWithTitle:@"完整研究與來源" image:[UIImage systemImageNamed:@"doc.text"] identifier:nil handler:^(__kindof UIAction *action) { (void)action; weakSelf.selectedTab = 5; weakSelf.tabs.selectedSegmentIndex = UISegmentedControlNoSegment; [weakSelf rebuild]; }];
    UIAction *check = [UIAction actionWithTitle:self.evaluating ? @"正在核對行情…" : @"核對已發生的行情" image:[UIImage systemImageNamed:@"checkmark.shield"] identifier:nil handler:^(__kindof UIAction *action) { (void)action; [weakSelf evaluateForecast]; }];
    if (self.evaluating || !SXRD(self.run[@"result"]).count) check.attributes = UIMenuElementAttributesDisabled;
    UIAction *share = [UIAction actionWithTitle:@"匯出原始研究 JSON" image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil handler:^(__kindof UIAction *action) { (void)action; [weakSelf exportRun]; }];
    UIBarButtonItem *more = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"] style:UIBarButtonItemStylePlain target:nil action:nil]; more.accessibilityLabel = @"研究操作"; more.menu = [UIMenu menuWithTitle:@"研究操作" children:@[pin, full, check, share]]; self.navigationItem.rightBarButtonItem = more;
}
- (void)exportRun {
    NSError *error = nil; NSData *data = [NSJSONSerialization dataWithJSONObject:self.run options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data) { SXShowError(self, @"無法匯出", error.localizedDescription ?: @"研究格式無法序列化。"); return; }
    NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[NSString stringWithFormat:@"Shixu-research-%@.json", NSUUID.UUID.UUIDString]];
    if (![data writeToURL:url options:NSDataWritingAtomic error:&error]) { SXShowError(self, @"無法匯出", error.localizedDescription ?: @"暫存空間不足。"); return; }
    SXShare(self, url);
}
- (void)evaluateForecast {
    if (self.evaluating) return; self.evaluating = YES; [self updateMenu];
    NSString *encoded = [SXRT(self.run[@"id"]) stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet]; __weak typeof(self) weakSelf = self;NSString *workspace=[SXStore.sharedStore.activeProfileUserID copy];
    [SXAPI.sharedAPI requestPath:[@"/api/research/evaluate?id=" stringByAppendingString:encoded] method:@"GET" body:nil completion:^(id json, NSInteger status, NSError *error) {
        typeof(self) self = weakSelf; if (!self||!SXRWorkspaceMatches(workspace)) return; self.evaluating = NO;
        if (error || status != 200 || ![json isKindOfClass:NSDictionary.class]) { [self updateMenu]; SXShowError(self, @"行情核對暫時無法完成", error.localizedDescription ?: (SXRT(SXRD(json)[@"error"]).length ? SXRD(json)[@"error"] : @"正式交易日資料尚未齊備。")); return; }
        self.evaluation = json; self.selectedTab = 5; self.tabs.selectedSegmentIndex = UISegmentedControlNoSegment; [self rebuild];
    }];
}
- (void)rebuild {
    NSString *code = SXRT(self.run[@"code"]); NSInteger horizon = [self.run[@"horizon"] respondsToSelector:@selector(integerValue)] ? [self.run[@"horizon"] integerValue] : 7;
    self.title = [NSString stringWithFormat:@"%@ · %@", code, horizon == 126 ? @"半年" : [NSString stringWithFormat:@"%ld 日", (long)horizon]];
    NSDictionary *a = SXRD(self.run[@"result"]), *r = SXRD(a[@"report"]); NSMutableArray *sections = [NSMutableArray new];
    BOOL full = self.selectedTab == 5; NSString *currency = SXRT(a[@"currency"]); if (!currency.length) currency = [[[SXStore.sharedStore stockForCode:code] objectForKey:@"market"] isEqual:@"TW"] ? @"TWD" : @"USD";
    if (!a.count) {
        NSMutableArray *rows = [NSMutableArray new]; NSString *state = SXRT(self.run[@"status"]), *phase = SXRT(SXRD(self.run[@"progress"])[@"phase"]);
        NSDictionary *phases = @{@"collecting": @"蒐集行情與官方來源", @"preflight": @"檢查資料與用量", @"model": @"模型正在推演", @"validating": @"驗算價格與證據", @"archiving": @"保存原始研究"};
        SXRRow(rows, [state isEqualToString:@"running"] ? @"分析進行中" : [state isEqualToString:@"failed"] ? @"這次研究沒有完成" : @"這份紀錄沒有完整結果", [state isEqualToString:@"running"] ? (phases[phase] ?: @"正在查詢原始研究狀態") : SXRT(self.run[@"error"]), nil);
        if (self.statusMessage.length) SXRRow(rows, @"連線狀態", self.statusMessage, nil);
        if (SXRT(self.run[@"connectionNotice"]).length) SXRRow(rows, @"要求狀態", self.run[@"connectionNotice"], nil);
        SXRRow(rows, @"保留原請求", @"離開畫面不會自動建立新分析。重新開啟這份紀錄只查詢同一識別碼，不重跑付費模型。", nil);
        SXRSection(sections, @"研究狀態", rows);
    } else {
        if (self.selectedTab == 0 || full) [self addOverview:sections analysis:a report:r currency:currency];
        if (self.selectedTab == 1 || full) [self addPrices:sections analysis:a currency:currency];
        if (self.selectedTab == 2 || full) [self addEvents:sections analysis:a];
        if (self.selectedTab == 3 || full) [self addValuation:sections analysis:a report:r currency:currency];
        if (self.selectedTab == 4 || full) [self addRisks:sections analysis:a report:r currency:currency];
        if (full) [self addEvaluation:sections];
        if (self.selectedTab == 0 || full) [self addSources:sections analysis:a report:r];
        if (self.statusMessage.length) { NSMutableArray *rows = [NSMutableArray new]; SXRRow(rows, @"狀態更新", self.statusMessage, nil); SXRSection(sections, @"本機原始結果仍保留", rows); }
    }
    self.sections = sections; self.tabs.enabled = a.count > 0; [self updateMenu]; [self.tableView reloadData];
}
- (void)addOverview:(NSMutableArray *)sections analysis:(NSDictionary *)a report:(NSDictionary *)r currency:(NSString *)currency {
    NSMutableArray *rows = [NSMutableArray new]; NSDictionary *last = SXRD(SXRA(a[@"daily"]).lastObject), *calculations = SXRD(r[@"calculations"]), *basis = SXRD(r[@"basis"]);
    if ([self.run[@"kind"] isEqual:@"plan"]) SXRRow(rows, @"NEXA 原文封存", @"以下保留當時模型文字，不代表已採用出場、減碼或停損提案。條件失效先重新研究，沒有自動下單或變更持股。", nil);
    if ([self.run[@"kind"] isEqual:@"plan"] && self.monitor.count) {
        if ([self.monitor[@"unavailable"] isEqual:@YES]) SXRRow(rows, @"目前條件核對", self.monitor[@"notice"], nil);
        else { SXRRow(rows, @"目前條件核對", SXRJoin(@[SXRT(self.monitor[@"label"]), SXRT(self.monitor[@"researchLabel"]), SXQuoteLabel(SXRD(self.monitor[@"quote"]), NO), SXDateLabel(self.monitor[@"checkedAt"])], @"\n"), nil); SXRRow(rows, @"量測報價", SXMoney(self.monitor[@"price"], currency), nil); NSDictionary *decision=SXRD(self.monitor[@"decision"]);SXRRow(rows,@"持股規則",SXRJoin(@[SXRT(decision[@"label"]),SXRT(decision[@"explanation"])],@"\n"),nil);NSDictionary *previous=SXRD(self.monitor[@"previousCondition"]);if([previous[@"breached"] isEqual:@YES])SXRRow(rows,@"前版研究條件已觸發",[NSString stringWithFormat:@"前版價位 %@；正式收盤 %@。原紀錄保留，這不是賣出授權。",SXMoney(previous[@"stop"],currency),SXMoney(previous[@"formalClose"],currency)],nil);SXRRow(rows, @"條件與操作", @"行情觸發只提醒重評，不會自動重跑 AI、減碼、停損或下單。", nil); }
    }
    SXRRow(rows, @"核心判斷", a[@"summary"], nil); SXRRow(rows, @"推演依據", a[@"rationale"], nil);
    if (SXRT(r[@"direction"]).length) SXRRow(rows, @"方向判斷", r[@"direction"], nil);
    SXRRow(rows, @"模型參考價", [NSString stringWithFormat:@"%@ · %@", SXMoney(a[@"latestClose"], currency), SXRT(a[@"marketDate"])], nil);
    if (last.count) SXRRow(rows, [NSString stringWithFormat:@"%@ 期末情境", SXRT(last[@"date"])], [NSString stringWithFormat:@"收盤 %@\n低 %@　高 %@", SXMoney(last[@"price"], currency), SXMoney(last[@"low"], currency), SXMoney(last[@"high"], currency)], nil);
    if (r.count) { SXRRow(rows, @"方向信心", [NSString stringWithFormat:@"%@ / 100\n%@", SXFormatNumber(r[@"confidence"], 0), SXRT(r[@"confidenceMeaning"])], nil); SXRRow(rows, @"期間預測範圍", [NSString stringWithFormat:@"最低 %@　最高 %@", SXMoney(calculations[@"low"], currency), SXMoney(calculations[@"high"], currency)], nil); }
    if (SXRT(a[@"boundsMeaning"]).length) SXRRow(rows, @"區間意義", a[@"boundsMeaning"], nil);
    if (SXRT(a[@"cadence"]).length) SXRRow(rows, @"取樣方式", a[@"cadence"], nil);
    SXRSection(sections, @"研究總覽", rows); rows = [NSMutableArray new];
    for (NSArray *spec in @[@[@"formal", @"正式收盤"], @[@"extended", @"盤後分鐘參考"], @[@"reference", @"本次推演基準"]]) {
        NSDictionary *ref = SXRD(basis[spec[0]]); if (!ref.count) continue;
        NSString *details = SXRJoin(@[SXMoney(ref[@"price"], currency), SXRT(ref[@"date"]), SXRT(ref[@"kind"]), SXRT(ref[@"timezone"]), SXRT(ref[@"source"])], @" · ");
        SXRRow(rows, spec[1], details, ref[@"url"]);
    }
    if (SXRT(basis[@"afterHoursNotice"]).length) SXRRow(rows, @"基準說明", basis[@"afterHoursNotice"], nil);
    SXRSection(sections, @"當時的行情基準", rows);
    NSDictionary *technical = SXRD(a[@"technical"]); rows = [NSMutableArray new];
    if (SXRT(SXRD(r[@"narratives"])[@"technical"]).length) SXRRow(rows, @"量價解讀", SXRD(r[@"narratives"])[@"technical"], nil);
    NSArray *averages = SXRA(technical[@"averages"]); NSUInteger start = averages.count > 4 ? averages.count - 4 : 0;
    for (NSUInteger index = start; index < averages.count; index++) { NSDictionary *point = SXRD(averages[index]); SXRRow(rows, SXRT(point[@"date"]), [NSString stringWithFormat:@"20MA %@ · 乖離 %@\n成交量 %@ 股 · 20日均量倍率 %@", SXMoney(point[@"ma20"], currency), SXRPct(point[@"deviation20Percent"], NO), SXFormatNumber(point[@"volume"], 0), SXFormatNumber(point[@"volumeRatio"], 2)], nil); }
    if (technical.count) { SXRRow(rows, @"20日平均量", [NSString stringWithFormat:@"%@ 股", SXFormatNumber(technical[@"volumeMean20"], 0)], nil); SXRRow(rows, @"基準價相對20MA", SXRPct(technical[@"referenceDeviation20Percent"], NO), nil); }
    SXRSection(sections, @"20MA 與量能", rows);
    NSDictionary *institutional = SXRD(r[@"twInstitutional"]), *summary = SXRD(institutional[@"summary"]), *latest = SXRD(summary[@"latest"]); rows = [NSMutableArray new];
    if (latest.count) {
        NSArray *keys = @[@"foreign", @"trust", @"dealerProprietary", @"dealerHedge", @"dealer"], *names = @[@"外資", @"投信", @"自營自行", @"自營避險", @"自營合計"];
        NSDictionary *windows = SXRD(summary[@"windows"]), *five = SXRD(windows[@"5"]), *ten = SXRD(windows[@"10"]);
        for (NSUInteger i = 0; i < keys.count; i++) { NSString *key = keys[i]; NSString *(^lots)(id) = ^NSString *(id value) { return SXFiniteNumber(value) ? [SXFormatNumber(@([value doubleValue] / 1000), 1) stringByAppendingString:@" 張"] : @"資料不足"; }; SXRRow(rows, names[i], [NSString stringWithFormat:@"最近一日 %@\n近5日 %@ · 近10日 %@", lots(latest[key]), lots(five[key]), lots(ten[key])], nil); }
        SXRRow(rows, @"官方資料日期", latest[@"date"], institutional[@"url"]); SXRRow(rows, @"資料說明", summary[@"disclaimer"], nil); SXRRow(rows, @"籌碼解讀", SXRD(r[@"narratives"])[@"institutional"], nil);
    }
    SXRSection(sections, @"台股官方法人", rows);
}
- (void)addPrices:(NSMutableArray *)sections analysis:(NSDictionary *)a currency:(NSString *)currency {
    NSMutableArray *rows = [NSMutableArray new];
    for (id value in SXRA(a[@"daily"])) { NSDictionary *point = SXRD(value); if (!point.count) continue;
        NSString *title = [NSString stringWithFormat:@"%@ · 第 %@ 個交易日", SXRT(point[@"date"]), SXFormatNumber(point[@"day"], 0)];
        NSMutableArray *detail = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"收盤 %@\n低 %@　高 %@", SXMoney(point[@"price"], currency), SXMoney(point[@"low"], currency), SXMoney(point[@"high"], currency)]];
        if (SXFiniteNumber(point[@"ma20"])) [detail addObject:[@"條件式20MA " stringByAppendingString:SXMoney(point[@"ma20"], currency)]];
        if (SXRT(point[@"judgment"]).length) [detail addObject:point[@"judgment"]];
        SXRRow(rows, title, [detail componentsJoinedByString:@"\n\n"], nil);
    }
    if (!rows.count) SXRRow(rows, @"沒有完整價位", @"原始紀錄未提供可顯示的價格路徑。", nil);
    SXRSection(sections, @"原始情境價位", rows); rows = [NSMutableArray new]; SXRRow(rows, @"解讀方式", a[@"boundsMeaning"], nil); SXRRow(rows, @"取樣與日期", a[@"cadence"], nil); SXRRow(rows, @"保留原始資料", @"只列原模型回傳的價位與交易日，中間日期不補值；未來行情核對另行呈現，不改寫這份預測。", nil); SXRSection(sections, @"價格說明", rows);
}
- (void)addEvents:(NSMutableArray *)sections analysis:(NSDictionary *)a {
    NSArray *events = [SXRA(a[@"events"]) sortedArrayUsingComparator:^NSComparisonResult(id left, id right) { double x = fabs([SXRD(left)[@"impact"] respondsToSelector:@selector(doubleValue)] ? [SXRD(left)[@"impact"] doubleValue] : 0), y = fabs([SXRD(right)[@"impact"] respondsToSelector:@selector(doubleValue)] ? [SXRD(right)[@"impact"] doubleValue] : 0); return x > y ? NSOrderedAscending : x < y ? NSOrderedDescending : NSOrderedSame; }];
    if (!events.count) { NSMutableArray *rows = [NSMutableArray new]; SXRRow(rows, @"沒有可引用事件", @"原始研究未提供事件證據，沒有補造新聞或因果。", nil); SXRSection(sections, @"事件影響", rows); return; }
    for (id value in events) { NSDictionary *event = SXRD(value); NSMutableArray *rows = [NSMutableArray new];
        SXRRow(rows, SXRT(event[@"title"]).length ? event[@"title"] : @"事件標題未提供", SXRJoin(@[SXRT(event[@"date"]), SXRT(event[@"source"]), SXRT(event[@"status"])], @" · "), event[@"url"]);
        SXRRow(rows, @"影響路徑", SXRJoin(SXRA(event[@"causalChain"]), @" → "), nil); SXRRow(rows, @"判斷依據", event[@"assessment"], nil);
        SXRRow(rows, @"主觀情境影響", SXRPct(event[@"impact"], YES), nil);
        if (SXFiniteNumber(event[@"favorability"])) SXRRow(rows, @"主觀利多分數", [NSString stringWithFormat:@"%@ / 100；不是事件機率", SXFormatNumber(event[@"favorability"], 0)], nil);
        if (SXRT(event[@"importance"]).length) SXRRow(rows, @"重要性", event[@"importance"], nil);
        SXRRow(rows, @"已反映估計", SXRPct(event[@"pricedIn"], NO), nil); SXRRow(rows, @"作用期間", event[@"window"], nil);
        SXRSection(sections, @"封存事件 · 依影響絕對值排序", rows);
    }
}
- (void)addValuation:(NSMutableArray *)sections analysis:(NSDictionary *)a report:(NSDictionary *)r currency:(NSString *)currency {
    NSDictionary *narratives = SXRD(r[@"narratives"]), *financials = SXRD(r[@"financials"]), *tw = SXRD(r[@"twQuarterFinancials"]), *monthly = SXRD(r[@"twMonthlyRevenue"]); NSMutableArray *rows = [NSMutableArray new];
    SXRRow(rows, @"基本面解讀", narratives[@"fundamentals"], nil);
    if (tw.count) {
        SXRRow(rows, @"官方季度財報", tw[@"period"], tw[@"incomeUrl"]);
        SXRMetrics(rows, tw, @[@[@"revenueYtdTwd", @"年初累計營收", @"money"], @[@"operatingIncomeYtdTwd", @"年初累計營業利益", @"money"], @[@"netIncomeYtdTwd", @"年初累計稅後淨利", @"money"], @[@"epsYtdTwd", @"年初累計基本EPS（元）"], @[@"operatingCashFlowYtdTwd", @"年初累計營業現金流", @"money"], @[@"ppeAcquisitionCashFlowYtdTwd", @"年初累計設備購置現金流", @"money"], @[@"cashAndEquivalentsTwd", @"期末現金及約當現金", @"money"], @[@"assetsTwd", @"期末資產總計", @"money"], @[@"totalLiabilitiesTwd", @"期末負債總計", @"money"]], @"TWD");
        SXRRow(rows, @"期間與單位", @"損益與現金流為年初累計，不是單季。資產負債為期末存量；負債總計不等於有息債務。", nil);
    } else if (financials.count) {
        SXRRow(rows, @"官方已公布財報", financials[@"period"], financials[@"url"]);
        SXRMetrics(rows, financials, @[@[@"revenueUsd", @"營收", @"money"], @[@"revenueYoyPercent", @"營收年增", @"percent"], @[@"dataCenterRevenueUsd", @"資料中心營收", @"money"], @[@"dataCenterGrowthPercent", @"資料中心年增", @"percent"], @[@"freeCashFlowUsd", @"自由現金流", @"money"], @[@"cashAndInvestmentsUsd", @"現金與短期投資", @"money"], @[@"totalDebtUsd", @"總債務", @"money"], @[@"netCashUsd", @"淨現金", @"money"]], @"USD");
        SXRMetrics(rows, SXRD(financials[@"nonGaap"]), @[@[@"eps", @"非GAAP EPS"]], @"USD");
        SXRMetrics(rows, SXRD(financials[@"gaap"]), @[@[@"eps", @"GAAP EPS"], @[@"netIncomeUsd", @"GAAP淨利", @"money"]], @"USD");
    } else SXRRow(rows, @"財報原始資料", @"完整官方財報資料不足，未補造EPS或財務比率。", nil);
    if (monthly.count) { SXRRow(rows, @"官方單月營收", monthly[@"period"], monthly[@"url"]); SXRMetrics(rows, monthly, @[@[@"revenueTwd", @"單月營收", @"money"], @[@"revenueYoyPercent", @"單月年增", @"percent"]], @"TWD"); }
    SXRSection(sections, @"公司基本面", rows);
    NSDictionary *calcs = SXRD(r[@"calculations"]), *earnings = SXRD(calcs[@"earnings"]); rows = [NSMutableArray new];
    if ([SXRT(earnings[@"status"]) isEqualToString:@"computed"]) {
        SXRRow(rows, @"獨立預測期間", earnings[@"period"], nil);
        SXRMetrics(rows, earnings, @[@[@"revenueUsd", @"預測營收", @"money"], @[@"grossMargin", @"非GAAP毛利率", @"fraction"], @[@"operatingExpensesUsd", @"非GAAP營業費用", @"money"], @[@"operatingIncomeUsd", @"推算營業利益", @"money"], @[@"eps", @"推算非GAAP EPS"], @[@"nextGuidanceUsd", @"再下一季營收展望假設", @"money"]], @"USD");
        SXRRow(rows, @"公式", earnings[@"formula"], nil); SXRRow(rows, @"假設", earnings[@"assumption"], nil); SXRRow(rows, @"推算理由", earnings[@"reason"], nil);
        NSDictionary *guidance = SXRD(financials[@"guidance"]); if (guidance.count) { SXRRow(rows, @"公司官方指引期間", guidance[@"period"], financials[@"url"]); SXRMetrics(rows, guidance, @[@[@"revenueMidUsd", @"官方營收指引中值", @"money"], @[@"revenueToleranceUsd", @"官方指引上下幅度", @"money"], @[@"nonGaapGrossMargin", @"官方非GAAP毛利率", @"fraction"]], @"USD"); }
        if (SXFiniteNumber(earnings[@"companyExpenseGuidanceUsd"])) { SXRMetrics(rows, earnings, @[@[@"companyExpenseGuidanceUsd", @"公司原費用指引", @"money"], @[@"expenseDifferenceUsd", @"模型費用相對指引差額", @"money"]], @"USD"); SXRRow(rows, @"費用差異理由", earnings[@"expenseReason"], nil); SXRMetrics(rows, SXRD(earnings[@"sensitivity"]), @[@[@"epsAtCompanyExpense", @"沿用公司費用時EPS"], @[@"epsPerAdditional100MExpense", @"費用每多1億美元的EPS影響"]], @"USD"); }
    } else SXRRow(rows, @"預測限制", SXRT(earnings[@"reason"]).length ? earnings[@"reason"] : @"尚未建立可驗證的下一季盈餘輸入，未計算。", nil);
    SXRRow(rows, @"財報推算解讀", narratives[@"earnings"], nil); SXRSection(sections, @"獨立財報推算 · 非已公布結果", rows);
    NSDictionary *valuation = SXRD(r[@"valuationMetrics"]); rows = [NSMutableArray new];
    if (valuation.count) {
        SXRMetrics(rows, valuation, @[@[@"referencePrice", @"估值基準股價"], @[@"marketCapUsd", @"推算市值", @"money"], @[@"priceSales", @"P/S（倍）"], @[@"gaapPE", @"GAAP P/E（倍）"]], @"USD");
        SXRRow(rows, @"TTM營收", [NSString stringWithFormat:@"%@ · 截至 %@", SXMoney(SXRD(valuation[@"ttmRevenue"])[@"value"], @"USD"), SXRT(SXRD(valuation[@"ttmRevenue"])[@"end"])], nil);
        SXRRow(rows, @"TTM GAAP淨利", SXMoney(SXRD(valuation[@"ttmNetIncome"])[@"value"], @"USD"), nil);
        SXRRow(rows, @"流通股申報", [NSString stringWithFormat:@"%@ 股 · %@", SXFormatNumber(SXRD(valuation[@"sharesOutstanding"])[@"value"], 0), SXRT(SXRD(valuation[@"sharesOutstanding"])[@"asOf"])], nil);
        SXRRow(rows, @"計算方法", valuation[@"method"], valuation[@"url"]);
    } else SXRRow(rows, @"TTM估值", @"原始數據不足，沒有補造本益比或市銷率。", nil);
    SXRRow(rows, @"估值與宏觀解讀", narratives[@"macro"], nil);
    for (id value in SXRA(a[@"valuation"])) { NSDictionary *factor = SXRD(value); SXRRow(rows, SXRT(factor[@"name"]), SXRJoin(@[SXRPct(factor[@"impact"], YES), SXRT(factor[@"assessment"])], @"\n"), nil); }
    SXRSection(sections, @"估值與宏觀", rows);
    NSDictionary *bridge = SXRD(calcs[@"bridge"]); rows = [NSMutableArray new];
    if (bridge.count) { SXRRow(rows, @"推演基準", SXMoney(bridge[@"baseline"], currency), nil); for (id value in SXRA(bridge[@"parts"])) { NSDictionary *part = SXRD(value); SXRRow(rows, SXRT(part[@"label"]), SXRJoin(@[SXMoney(part[@"delta"], currency), SXRT(part[@"reason"])], @"\n"), nil); } SXRRow(rows, @"拆解加總", SXMoney(bridge[@"sum"], currency), nil); SXRRow(rows, @"原始終點預測", SXMoney(bridge[@"target"], currency), nil); SXRRow(rows, @"拆解說明", bridge[@"reason"], nil); }
    SXRSection(sections, @"終點價格拆解 · 主觀金額", rows);
}
- (void)addRisks:(NSMutableArray *)sections analysis:(NSDictionary *)a report:(NSDictionary *)r currency:(NSString *)currency {
    NSMutableArray *rows = [NSMutableArray new];
    for (id value in SXRA(r[@"invalidations"])) { NSDictionary *condition = SXRD(value); SXRRow(rows, SXRT(condition[@"date"]).length ? condition[@"date"] : @"客觀失效訊號", SXRJoin(@[SXRT(condition[@"signal"]), SXRT(condition[@"response"])], @"\n\n"), nil); }
    NSDictionary *plan = SXRD(a[@"plan"]); if (SXRT(plan[@"invalidation"]).length) SXRRow(rows, @"原始判斷失效條件", plan[@"invalidation"], nil); if (SXRT(plan[@"reviewTrigger"]).length) SXRRow(rows, @"重新研究條件", plan[@"reviewTrigger"], nil);
    if (!rows.count) SXRRow(rows, @"失效條件未提供", @"這份原始紀錄沒有完整的可驗證失效訊號。", nil);
    SXRSection(sections, @"判斷失效與重評條件", rows); rows = [NSMutableArray new];
    if ([self.run[@"kind"] isEqual:@"plan"]) {
        NSDictionary *labels = @{@"hold": @"持有", @"reduce": @"減碼", @"exit": @"退出", @"watch": @"觀察"}; NSString *proposal = SXRT(plan[@"action"]);
        SXRRow(rows, @"模型當時原提案 · 尚未採用", labels[proposal] ?: proposal, nil); SXRRow(rows, @"原提案理由", plan[@"reason"], nil); SXRRow(rows, @"原提案變動理由", plan[@"changeReason"], nil);
        SXRRow(rows, @"原始風險研究價位", SXMoney(plan[@"stop"], currency), nil); SXRRow(rows, @"原始目標研究價位", SXMoney(plan[@"target"], currency), nil);
        SXRRow(rows, @"操作界線", @"這些是原模型提案與研究價位；不採用為賣出、減碼、停損或到期交易授權。", nil); SXRSection(sections, @"NEXA 原提案封存", rows); rows = [NSMutableArray new];
    }
    for (id assumption in SXRA(a[@"assumptions"])) if (SXRT(assumption).length) SXRRow(rows, @"情境假設", assumption, nil);
    NSDictionary *volatility = SXRD(SXRD(r[@"calculations"])[@"volatility"]); if (volatility.count) { SXRMetrics(rows, volatility, @[@[@"dailySigma", @"樣本日波動", @"fraction"], @[@"horizonSigma", @"期間波動尺度", @"fraction"], @[@"priceScale", @"對應價格尺度", @"money"]], currency); SXRRow(rows, @"波動方法", volatility[@"method"], nil); }
    SXRSection(sections, @"假設與波動尺度", rows); rows = [NSMutableArray new];
    SXRRow(rows, @"封存的持股與交易解讀", SXRD(r[@"narratives"])[@"trade"], nil);
    NSDictionary *pnl = SXRD(SXRD(r[@"calculations"])[@"pnl"]); if (pnl.count) { SXRRow(rows, @"當時的假設持股", [NSString stringWithFormat:@"%@ 股 · 成本 %@", SXFormatNumber(pnl[@"quantity"], 4), SXMoney(pnl[@"cost"], currency)], nil); for (id value in SXRA(pnl[@"rows"])) { NSDictionary *point = SXRD(value); SXRRow(rows, SXRT(point[@"label"]), [NSString stringWithFormat:@"股價 %@ · 損益 %@", SXMoney(point[@"price"], currency), SXMoney(point[@"pnl"], currency)], nil); } SXRRow(rows, @"試算說明", pnl[@"note"], nil); }
    SXRRow(rows, @"研究與操作", @"封存文字與價位保留供回看；條件失效代表需要重新研究。這裡不會自動送出交易或變更持股。", nil); SXRSection(sections, @"原始研究的持股視角", rows);
    rows = [NSMutableArray new]; NSDictionary *quality = SXRD(r[@"quality"]);
    for (id issue in SXRA(quality[@"issues"])) if (SXRT(issue).length) SXRRow(rows, @"資料與驗算限制", issue, nil);
    for (id value in SXRA(quality[@"sourceFailures"])) { if ([value isKindOfClass:NSString.class]) SXRRow(rows, @"來源未取得", value, nil); else { NSDictionary *failure = SXRD(value); SXRRow(rows, SXRT(failure[@"source"]).length ? failure[@"source"] : @"來源未取得", SXRJoin(@[SXRT(failure[@"error"]), SXRT(failure[@"message"]), SXRT(failure[@"reason"]), SXRT(failure[@"status"])], @" · "), nil); } }
    if ([a[@"partial"] isEqual:@YES]) SXRRow(rows, @"部分資料缺漏", @"本次原始研究有來源未取得；缺口不直接視為日後誤差的原因。", nil);
    SXRSection(sections, @"資料限制", rows);
}
- (void)addSources:(NSMutableArray *)sections analysis:(NSDictionary *)a report:(NSDictionary *)r {
    NSMutableArray *rows = [NSMutableArray new]; NSDictionary *archive = SXRD(r[@"archive"]);
    SXRRow(rows, @"研究識別碼", SXRT(archive[@"researchId"]).length ? archive[@"researchId"] : self.run[@"id"], nil);
    SXRRow(rows, @"分析建立時間 · 台灣", SXDateLabel(self.run[@"createdAt"]), nil); if (self.run[@"completedAt"]) SXRRow(rows, @"分析完成時間 · 台灣", SXDateLabel(self.run[@"completedAt"]), nil);
    SXRRow(rows, @"資料快照時間", r[@"collectedAt"], nil); SXRRow(rows, @"模型", SXRT(self.run[@"modelVersion"]).length ? self.run[@"modelVersion"] : self.run[@"model"], nil);
    if (SXRT(archive[@"fingerprint"]).length) SXRRow(rows, @"原始研究 SHA-256", archive[@"fingerprint"], nil);
    for (id rule in SXRA(r[@"rules"])) if (SXRT(rule).length) SXRRow(rows, @"研究原則", rule, nil);
    SXRSection(sections, @"原始封存", rows); rows = [NSMutableArray new];
    for (id value in SXRA(a[@"evidence"])) { NSDictionary *source = SXRD(value); SXRRow(rows, SXRJoin(@[SXRT(source[@"ref"]), SXRT(source[@"title"])], @" · "), SXRJoin(@[SXRT(source[@"date"]), SXRT(source[@"source"]), SXRT(source[@"status"]), SXRT(source[@"verification"])], @"\n"), source[@"url"]); }
    if (!rows.count) SXRRow(rows, @"來源快照未提供", @"這份原始紀錄未保存完整引用清單。", nil);
    SXRSection(sections, @"當時來源快照 · 點選開啟原文", rows);
}
- (void)addEvaluation:(NSMutableArray *)sections {
    NSDictionary *data = self.evaluation; if (!data.count) return; NSMutableArray *rows = [NSMutableArray new]; NSDictionary *direction = SXRD(data[@"direction"]);
    SXRRow(rows, @"核對範圍", [NSString stringWithFormat:@"已核對 %@ / %@\n方向符合 %@ / %@", SXFormatNumber(data[@"observations"], 0), SXFormatNumber(data[@"total"], 0), SXFormatNumber(direction[@"correct"], 0), SXFormatNumber(direction[@"total"], 0)], nil);
    SXRRow(rows, @"核對時間 · 台灣", SXDateLabel(data[@"checkedAt"]), nil);
    SXRRow(rows, @"收盤 MAPE", SXRPct(data[@"meanAbsoluteErrorPercent"], NO), nil); SXRRow(rows, @"樣本限制", data[@"sampleWarning"], nil);
    for (id value in SXRA(data[@"rows"])) { NSDictionary *point = SXRD(value); if (![point[@"status"] isEqual:@"observed"]) { SXRRow(rows, SXRT(point[@"date"]), [point[@"status"] isEqual:@"missing"] ? @"正式交易日資料暫缺" : @"尚未發生", nil); continue; }
        NSString *detail = [NSString stringWithFormat:@"預測收盤 %@ · 實際收盤 %@\n絕對百分比誤差 %@\n實際低 %@ · 高 %@", SXFormatNumber(point[@"predicted"], 2), SXFormatNumber(point[@"actual"], 2), SXRPct(point[@"absoluteErrorPercent"], NO), SXFormatNumber(point[@"actualLow"], 2), SXFormatNumber(point[@"actualHigh"], 2)];
        if ([point[@"eligible"] isEqual:@NO]) detail = [detail stringByAppendingString:@"\n產生時間不符合期外條件，未列入準度。"];
        SXRRow(rows, SXRT(point[@"date"]), detail, nil);
        for (id baselineValue in SXRA(point[@"baselines"])) { NSDictionary *baseline = SXRD(baselineValue); SXRRow(rows, SXRJoin(@[SXRT(point[@"date"]), SXRT(baseline[@"label"])], @" · "), [NSString stringWithFormat:@"同一截點基準 %@ · APE %@", SXFormatNumber(baseline[@"price"], 2), SXRPct(baseline[@"absoluteErrorPercent"], NO)], nil); }
    }
    SXRRow(rows, @"核對說明", data[@"note"], nil); SXRRow(rows, @"這次核對", @"使用正式行情查核，不呼叫付費AI；原始預測維持封存，單次觀測不能證明長期優勢。", nil); SXRSection(sections, @"事後行情核對 · 與原始研究分開", rows);
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return SXRA(self.sections[section][@"rows"]).count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return SXRT(self.sections[section][@"title"]); }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ReportText"]; if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ReportText"];
    NSDictionary *row = self.sections[indexPath.section][@"rows"][indexPath.row]; cell.textLabel.text = SXRT(row[@"title"]); cell.detailTextLabel.text = SXRT(row[@"detail"]);
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]; cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0; cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    BOOL link = SXRT(row[@"url"]).length > 0; cell.accessoryType = link ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone; cell.selectionStyle = link ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone; cell.accessibilityHint = link ? @"開啟這份研究當時引用的原始來源" : nil; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES]; NSDictionary *row = self.sections[indexPath.section][@"rows"][indexPath.row]; NSString *link = SXRURL(row[@"url"]); if (!link.length) return;
    SFSafariViewController *reader = [[SFSafariViewController alloc] initWithURL:[NSURL URLWithString:link]]; reader.preferredControlTintColor = self.view.tintColor; [self presentViewController:reader animated:YES completion:nil];
}
@end
