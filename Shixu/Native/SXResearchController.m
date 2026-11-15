#import "SXResearchController.h"
#import "SXReportController.h"
#import "SXStore.h"
#import "SXAPI.h"
#import "SXUI.h"
#import <math.h>

static NSString *SXResearchText(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static BOOL SXResearchWorkspaceMatches(NSString *identity){return [(SXStore.sharedStore.activeProfileUserID?:@"") isEqualToString:identity?:@""];}
static NSInteger SXResearchDays(NSDictionary *run) { return [run[@"horizon"] respondsToSelector:@selector(integerValue)] ? [run[@"horizon"] integerValue] : 7; }
static NSString *SXResearchHorizon(NSInteger days) { return days == 126 ? @"半年" : [NSString stringWithFormat:@"%ld 日", (long)days]; }
static double SXResearchTime(id value) {
    if (SXFiniteNumber(value)) return [value doubleValue];
    if (![value isKindOfClass:NSString.class]) return 0;
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    NSDate *date = [formatter dateFromString:value];
    if (!date) { formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds; date = [formatter dateFromString:value]; }
    return date.timeIntervalSince1970 * 1000;
}

@interface SXResearchSetupController : UITableViewController <UITextFieldDelegate>
@property(nonatomic,strong) UITextField *codeField;
@property(nonatomic,strong) UISegmentedControl *period;
@property(nonatomic,strong) UIButton *beginButton;
@property(nonatomic,strong) NSArray<NSDictionary *> *matches;
@property(nonatomic,copy) NSString *initialCode;
@property(nonatomic) BOOL submitting;
@property(nonatomic) BOOL planMode;
- (instancetype)initWithCode:(NSString *)code;
@end

@interface SXResearchController () <UISearchResultsUpdating, UISearchBarDelegate>
@property(nonatomic,strong) UISearchController *search;
@property(nonatomic,strong) NSArray<NSDictionary *> *visibleRuns;
@property(nonatomic,copy) NSString *marketFilter;
@property(nonatomic,copy) NSString *exactCode;
@property(nonatomic) NSInteger horizonFilter;
@property(nonatomic) BOOL pinnedOnly;
@property(nonatomic,strong) UIBarButtonItem *filterItem;
@end

@interface SXNexaArchiveController : UITableViewController
@property(nonatomic,strong) NSArray<NSDictionary *> *plans;
@property(nonatomic,strong) NSArray<NSString *> *heldCodes;
@end

@implementation SXNexaArchiveController
- (instancetype)init { self = [super initWithStyle:UITableViewStyleInsetGrouped]; if (self) _plans = @[]; return self; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"NEXA 持股計畫"; self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 88;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reloadPlans) name:SXStoreDidChangeNotification object:nil]; [self reloadPlans];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)reloadPlans {
    id saved = [SXStore.sharedStore valueForProfileKey:@"nexa.plans" fallback:@{}]; NSDictionary *plans = [saved isKindOfClass:NSDictionary.class] ? saved : @{}; NSMutableArray *rows = [NSMutableArray new];
    NSMutableArray<NSString *> *codes = [NSMutableArray new]; for (id key in plans) if ([key isKindOfClass:NSString.class]) [codes addObject:key];
    for (NSString *code in [codes sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *entry = [plans[code] isKindOfClass:NSDictionary.class] ? plans[code] : @{}; NSMutableArray *versions = [NSMutableArray new];
        if ([entry[@"current"] isKindOfClass:NSDictionary.class]) [versions addObject:@{@"run": entry[@"current"], @"label": @"目前封存版本", @"code": code}];
        for (id run in [entry[@"history"] isKindOfClass:NSArray.class] ? entry[@"history"] : @[]) if ([run isKindOfClass:NSDictionary.class]) [versions addObject:@{@"run": run, @"label": @"較早封存版本", @"code": code}];
        [rows addObjectsFromArray:versions];
    }
    self.plans = rows; NSMutableOrderedSet *held=[NSMutableOrderedSet new]; for(NSDictionary *position in SXStore.sharedStore.account[@"positions"])if([SXStore.sharedStore stockForCode:SXResearchText(position[@"code"])])[held addObject:position[@"code"]];self.heldCodes=held.array;[self.tableView reloadData];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return MAX(1,section==0?self.heldCodes.count:self.plans.count); }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section==0?@"建立或重新評估":@"既有計畫 · 原文保留"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section { (void)tableView; (void)section; return @"價格條件失效只代表重新研究。封存模型的賣出、退出或減碼文字不等於你的操作授權；這裡不會自動下單或重跑付費計畫。"; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]; cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0; cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]; cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    if(indexPath.section==0){if(!self.heldCodes.count){cell.textLabel.text=@"先登錄目前持股";cell.detailTextLabel.text=@"到持股頁新增紀錄後，即可建立計畫。";}else{NSString *code=self.heldCodes[indexPath.row];NSDictionary *stock=[SXStore.sharedStore stockForCode:code];id requests=[SXStore.sharedStore valueForProfileKey:@"nexa.requests" fallback:@{}];BOOL pending=[requests isKindOfClass:NSDictionary.class]&&SXResearchText(requests[code]).length;cell.textLabel.text=[NSString stringWithFormat:@"%@ · %@",code,stock[@"alias"]?:stock[@"name"]?:code];cell.detailTextLabel.text=pending?@"分析進行中 · 查看原請求":@"7 日持股研究 · 先檢查條件，再明確開始";}cell.imageView.image=[UIImage systemImageNamed:@"sparkles"];cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;}
    if (!self.plans.count) { cell.textLabel.text = @"尚無本機 NEXA 封存"; cell.detailTextLabel.text = @"從設定匯入既有拾序備份後，原計畫與歷史版本會出現在這裡。"; cell.selectionStyle = UITableViewCellSelectionStyleNone; return cell; }
    NSDictionary *entry = self.plans[indexPath.row], *run = entry[@"run"]; cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", SXResearchText(entry[@"code"]), entry[@"label"]];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@\n查看原始判斷、價位、失效條件與當時來源", SXDateLabel(run[@"completedAt"] ?: run[@"createdAt"])]; cell.imageView.image = [UIImage systemImageNamed:@"sparkles.rectangle.stack"]; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];if(indexPath.section==0){if(!self.heldCodes.count){self.tabBarController.selectedIndex=3;return;}NSString *code=self.heldCodes[indexPath.row];id requests=[SXStore.sharedStore valueForProfileKey:@"nexa.requests" fallback:@{}];NSString *requestID=[requests isKindOfClass:NSDictionary.class]?SXResearchText(requests[code]):@"";if(requestID.length){NSDictionary *pending=nil;for(NSDictionary *row in SXStore.sharedStore.runs)if([row[@"id"] isEqual:requestID])pending=row;if(!pending)pending=@{@"id":requestID,@"code":code,@"kind":@"plan",@"horizon":@7,@"mode":@"event",@"status":@"running"};[self.navigationController pushViewController:[[SXReportController alloc] initWithRun:pending] animated:YES];return;}SXResearchSetupController *setup=[[SXResearchSetupController alloc] initWithCode:code];setup.planMode=YES;[self.navigationController pushViewController:setup animated:YES];return;}if (!self.plans.count) return; NSDictionary *entry = self.plans[indexPath.row]; NSMutableDictionary *run = [entry[@"run"] mutableCopy]; if (!SXResearchText(run[@"code"]).length) run[@"code"] = entry[@"code"];run[@"kind"]=@"plan";
    [self.navigationController pushViewController:[[SXReportController alloc] initWithRun:run] animated:YES];
}
@end

@implementation SXResearchController
- (instancetype)init { self = [super initWithStyle:UITableViewStyleInsetGrouped]; if (self) { _marketFilter = @"all"; _exactCode = @""; _visibleRuns = @[]; } return self; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = @"研究";
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 96;
    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self; self.search.obscuresBackgroundDuringPresentation = NO;
    self.search.searchBar.placeholder = @"搜尋代號或公司名稱"; self.search.searchBar.delegate = self;
    self.search.searchBar.searchTextField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = self.search; self.navigationItem.hidesSearchBarWhenScrolling = NO; self.definesPresentationContext = YES;
    __weak typeof(self) weakSelf = self;
    UIButton *add = SXGlassButton(@"新增", @"plus", [UIAction actionWithHandler:^(__kindof UIAction *action) { (void)action; [weakSelf openSetupForCode:@""]; }]);
    self.filterItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"line.3.horizontal.decrease.circle"] style:UIBarButtonItemStylePlain target:nil action:nil];
    self.filterItem.accessibilityLabel = @"篩選研究";
    self.navigationItem.rightBarButtonItems = @[[[UIBarButtonItem alloc] initWithCustomView:add], self.filterItem];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeChanged:) name:SXStoreDidChangeNotification object:nil];
    [self reloadRuns];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self reloadRuns]; }
- (void)storeChanged:(NSNotification *)notification { (void)notification; if (self.isViewLoaded) [self reloadRuns]; }
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *query = [searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (self.exactCode.length && ![query.uppercaseString isEqualToString:self.exactCode]) self.exactCode = @"";
    [self reloadRuns];
}
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText { (void)searchBar; (void)searchText; self.exactCode = @""; }
- (void)reloadRuns {
    SXStore *store = SXStore.sharedStore;
    NSString *query = [self.search.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSMutableArray *rows = [NSMutableArray new];
    for (id item in store.runs) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *run = item; NSString *code = SXResearchText(run[@"code"]), *runID = SXResearchText(run[@"id"]);
        if (!code.length || !runID.length) continue;
        NSDictionary *stock = [store stockForCode:code] ?: @{};
        if (self.exactCode.length && ![code isEqualToString:self.exactCode]) continue;
        if (![self.marketFilter isEqualToString:@"all"] && ![stock[@"market"] isEqual:self.marketFilter]) continue;
        if (self.horizonFilter && SXResearchDays(run) != self.horizonFilter) continue;
        if (self.pinnedOnly && ![store isPinned:runID]) continue;
        NSString *searchable = [NSString stringWithFormat:@"%@ %@ %@", code, SXResearchText(stock[@"name"]), SXResearchText(stock[@"alias"])];
        if (query.length && [searchable rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location == NSNotFound) continue;
        [rows addObject:run];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double left = SXResearchTime(a[@"createdAt"]), right = SXResearchTime(b[@"createdAt"]);
        return left > right ? NSOrderedAscending : left < right ? NSOrderedDescending : NSOrderedSame;
    }];
    self.visibleRuns = rows; [self updateFilterMenu]; [self.tableView reloadData];
    if (!rows.count) {
        UILabel *empty = [UILabel new]; empty.numberOfLines = 0; empty.textAlignment = NSTextAlignmentCenter;
        empty.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; empty.adjustsFontForContentSizeCategory = YES; empty.textColor = UIColor.secondaryLabelColor;
        empty.text = store.runs.count ? @"沒有符合的研究\n調整搜尋或篩選條件，再試一次。" : @"從第一份研究開始\n點右上角「新增」，建立原生 AI 研究。\n既有紀錄可從設定匯入。";
        self.tableView.backgroundView = empty;
    } else self.tableView.backgroundView = nil;
}
- (UIAction *)filterAction:(NSString *)title selected:(BOOL)selected handler:(void (^)(void))handler {
    UIAction *action = [UIAction actionWithTitle:title image:nil identifier:nil handler:^(__kindof UIAction *a) { (void)a; handler(); }];
    action.state = selected ? UIMenuElementStateOn : UIMenuElementStateOff; return action;
}
- (void)updateFilterMenu {
    __weak typeof(self) weakSelf = self; NSMutableArray *markets = [NSMutableArray new], *periods = [NSMutableArray new];
    NSArray *marketValues = @[@"all", @"US", @"TW"], *marketNames = @[@"全部市場", @"美股", @"台股"];
    for (NSUInteger index = 0; index < marketValues.count; index++) { NSString *value = marketValues[index]; [markets addObject:[self filterAction:marketNames[index] selected:[self.marketFilter isEqual:value] handler:^{ weakSelf.marketFilter = value; [weakSelf reloadRuns]; }]]; }
    for (NSNumber *value in @[@0, @7, @30, @126]) { NSInteger days = value.integerValue; [periods addObject:[self filterAction:days ? SXResearchHorizon(days) : @"全部期間" selected:self.horizonFilter == days handler:^{ weakSelf.horizonFilter = days; [weakSelf reloadRuns]; }]]; }
    UIAction *pins = [self filterAction:@"只看釘選" selected:self.pinnedOnly handler:^{ weakSelf.pinnedOnly = !weakSelf.pinnedOnly; [weakSelf reloadRuns]; }];
    UIAction *clear = [UIAction actionWithTitle:@"清除篩選" image:[UIImage systemImageNamed:@"arrow.counterclockwise"] identifier:nil handler:^(__kindof UIAction *action) { (void)action; weakSelf.marketFilter = @"all"; weakSelf.horizonFilter = 0; weakSelf.pinnedOnly = NO; weakSelf.exactCode = @""; weakSelf.search.searchBar.text = @""; [weakSelf reloadRuns]; }];
    self.filterItem.menu = [UIMenu menuWithTitle:@"研究篩選" children:@[[UIMenu menuWithTitle:@"市場" children:markets], [UIMenu menuWithTitle:@"期間" children:periods], pins, clear]];
    BOOL active = ![self.marketFilter isEqualToString:@"all"] || self.horizonFilter || self.pinnedOnly || self.exactCode.length;
    self.filterItem.image = [UIImage systemImageNamed:active ? @"line.3.horizontal.decrease.circle.fill" : @"line.3.horizontal.decrease.circle"];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 0 ? 1 : self.visibleRuns.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section == 0 ? @"持股研究" : [NSString stringWithFormat:@"%lu 份研究 · 原始結果保持封存", (unsigned long)self.visibleRuns.count]; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ResearchRun"];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ResearchRun"];
    if (indexPath.section == 0) { cell.textLabel.text = @"NEXA 持股計畫"; cell.detailTextLabel.text = @"建立、追蹤與回看持股研究"; cell.imageView.image = [UIImage systemImageNamed:@"sparkles.rectangle.stack"]; cell.imageView.tintColor = self.view.tintColor; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator; cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]; cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES; cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0; return cell; }
    NSDictionary *run = self.visibleRuns[indexPath.row], *stock = [SXStore.sharedStore stockForCode:SXResearchText(run[@"code"])];
    NSString *name = SXResearchText(stock[@"alias"]); if (!name.length) name = SXResearchText(stock[@"name"]);
    NSString *status = SXResearchText(run[@"status"]), *state = @"查看紀錄";
    if ([status isEqualToString:@"running"]) state = @"分析中";
    else if ([status isEqualToString:@"failed"]) state = @"未完成";
    else if ([status isEqualToString:@"completed"] || ([run[@"result"] isKindOfClass:NSDictionary.class] && [run[@"result"] count])) state = @"已封存";
    cell.textLabel.text = [NSString stringWithFormat:@"%@%@%@", SXResearchText(run[@"code"]), name.length ? @" · " : @"", name];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@ · %@", SXResearchHorizon(SXResearchDays(run)), state, SXDateLabel(run[@"createdAt"])];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]; cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0; cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = [UIImage systemImageNamed:[SXStore.sharedStore isPinned:SXResearchText(run[@"id"])] ? @"star.fill" : @"doc.text.magnifyingglass"];
    cell.imageView.tintColor = [SXStore.sharedStore isPinned:SXResearchText(run[@"id"])] ? UIColor.systemYellowColor : self.view.tintColor; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath { [tableView deselectRowAtIndexPath:indexPath animated:YES]; if (indexPath.section == 0) [self.navigationController pushViewController:[SXNexaArchiveController new] animated:YES]; else [self openRun:self.visibleRuns[indexPath.row]]; }
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; if (indexPath.section == 0) return nil; NSDictionary *run = self.visibleRuns[indexPath.row]; NSString *runID = SXResearchText(run[@"id"]);
    UIContextualAction *pin = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:[SXStore.sharedStore isPinned:runID] ? @"取消釘選" : @"釘選" handler:^(__kindof UIContextualAction *action, __kindof UIView *view, void (^completion)(BOOL)) { (void)action; (void)view; [SXStore.sharedStore togglePin:runID]; completion(YES); }];
    pin.backgroundColor = UIColor.systemOrangeColor; pin.image = [UIImage systemImageNamed:@"star"];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[pin]]; configuration.performsFirstActionWithFullSwipe = NO; return configuration;
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    (void)tableView; (void)point; if (indexPath.section == 0) return nil; NSDictionary *run = self.visibleRuns[indexPath.row]; __weak typeof(self) weakSelf = self;
    return [UIContextMenuConfiguration configurationWithIdentifier:SXResearchText(run[@"id"]) previewProvider:nil actionProvider:^UIMenu *(NSArray<UIMenuElement *> *suggestedActions) {
        (void)suggestedActions;
        UIAction *pin = [UIAction actionWithTitle:[SXStore.sharedStore isPinned:SXResearchText(run[@"id"])] ? @"取消釘選" : @"釘選研究" image:[UIImage systemImageNamed:@"star"] identifier:nil handler:^(__kindof UIAction *a) { (void)a; [SXStore.sharedStore togglePin:SXResearchText(run[@"id"])]; }];
        UIAction *same = [UIAction actionWithTitle:@"查看同股研究" image:[UIImage systemImageNamed:@"line.3.horizontal.decrease"] identifier:nil handler:^(__kindof UIAction *a) { (void)a; weakSelf.search.searchBar.text = SXResearchText(run[@"code"]); weakSelf.exactCode = SXResearchText(run[@"code"]); weakSelf.marketFilter = @"all"; weakSelf.horizonFilter = 0; weakSelf.pinnedOnly = NO; [weakSelf reloadRuns]; }];
        return [UIMenu menuWithTitle:@"" children:@[pin, same]];
    }];
}
- (void)openSetupForCode:(NSString *)code { [self.navigationController pushViewController:[[SXResearchSetupController alloc] initWithCode:code ?: @""] animated:YES]; }
- (void)openSetupForCode:(NSString *)code fromNavigation:(UINavigationController *)navigation { [navigation pushViewController:[[SXResearchSetupController alloc] initWithCode:code?:@""] animated:YES]; }
- (void)openRun:(NSDictionary *)run { if ([run isKindOfClass:NSDictionary.class]) [self.navigationController pushViewController:[[SXReportController alloc] initWithRun:run] animated:YES]; }
@end

@implementation SXResearchSetupController
- (instancetype)initWithCode:(NSString *)code { self = [super initWithStyle:UITableViewStyleInsetGrouped]; if (self) { _initialCode = [code copy]; _matches = @[]; } return self; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.title = self.planMode?@"建立持股計畫":@"新的研究";
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 60; self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.codeField = [UITextField new]; self.codeField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; self.codeField.adjustsFontForContentSizeCategory = YES;
    self.codeField.placeholder = @"股票代號或公司名稱"; self.codeField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters; self.codeField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.codeField.clearButtonMode = UITextFieldViewModeWhileEditing; self.codeField.returnKeyType = UIReturnKeyDone; self.codeField.delegate = self; self.codeField.text = self.initialCode;
    [self.codeField addTarget:self action:@selector(codeChanged) forControlEvents:UIControlEventEditingChanged]; self.codeField.accessibilityLabel = @"研究股票代號或公司名稱";
    self.codeField.accessibilityIdentifier=@"research.code";
    if(self.planMode){self.codeField.enabled=NO;self.codeField.clearButtonMode=UITextFieldViewModeNever;}
    self.period = [[UISegmentedControl alloc] initWithItems:@[@"7 日", @"30 日", @"半年"]]; self.period.selectedSegmentIndex = 0; self.period.accessibilityLabel = @"研究期間";
    [self.period addTarget:self action:@selector(periodChanged) forControlEvents:UIControlEventValueChanged];
    self.period.enabled=!self.planMode;
    __weak typeof(self) weakSelf = self;
    self.beginButton = SXGlassButton(self.planMode?@"開始持股計畫研究":@"開始 AI 研究", @"sparkles", [UIAction actionWithHandler:^(__kindof UIAction *action) { (void)action; [weakSelf beginResearch]; }]);
    self.beginButton.accessibilityIdentifier=@"research.start";
    UIView *footer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 96)]; self.beginButton.translatesAutoresizingMaskIntoConstraints = NO; [footer addSubview:self.beginButton];
    [NSLayoutConstraint activateConstraints:@[[self.beginButton.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:20], [self.beginButton.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-20], [self.beginButton.topAnchor constraintEqualToAnchor:footer.topAnchor constant:16], [self.beginButton.heightAnchor constraintGreaterThanOrEqualToConstant:50]]];
    self.tableView.tableFooterView = footer; [self codeChanged];
}
- (NSInteger)days { return self.planMode?7:self.period.selectedSegmentIndex == 2 ? 126 : self.period.selectedSegmentIndex == 1 ? 30 : 7; }
- (NSString *)selectedCode { return self.planMode?self.initialCode:([self.codeField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString ?: @""); }
- (NSDictionary *)heldPosition {double quantity=0,cost=0;for(NSDictionary *row in SXStore.sharedStore.account[@"positions"]){if(![row[@"code"] isEqual:self.selectedCode])continue;if(!SXFiniteNumber(row[@"quantity"])||!SXFiniteNumber(row[@"cost"])||[row[@"quantity"] doubleValue]<=0||[row[@"cost"] doubleValue]<=0)return nil;quantity+=[row[@"quantity"] doubleValue];cost+=[row[@"quantity"] doubleValue]*[row[@"cost"] doubleValue];}if(!isfinite(quantity)||!isfinite(cost)||quantity<=0)return nil;return @{@"quantity":@(quantity),@"cost":@(cost/quantity)};}
- (void)codeChanged {
    NSString *query = [self.codeField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSMutableArray *matches = [NSMutableArray new];
    if (query.length && ![SXStore.sharedStore stockForCode:self.selectedCode]) {
        for (NSDictionary *stock in SXStore.sharedStore.directory) {
            NSString *text = [NSString stringWithFormat:@"%@ %@ %@", SXResearchText(stock[@"code"]), SXResearchText(stock[@"name"]), SXResearchText(stock[@"alias"])];
            if ([text rangeOfString:query options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) { [matches addObject:stock]; if (matches.count == 8) break; }
        }
    }
    self.matches = matches; self.beginButton.enabled = !self.submitting && [SXStore.sharedStore stockForCode:self.selectedCode] != nil;
    if (self.codeField.isFirstResponder) { NSMutableIndexSet *changed = [NSMutableIndexSet indexSetWithIndex:1]; [changed addIndex:3]; [self.tableView reloadSections:changed withRowAnimation:UITableViewRowAnimationNone]; }
    else [self.tableView reloadData];
}
- (void)periodChanged { [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:3] withRowAnimation:UITableViewRowAnimationNone]; }
- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return YES; }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return section == 1 ? self.matches.count : section == 3 ? 3 : 1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return section == 0 ? @"研究股票" : section == 1 ? (self.matches.count ? @"點選股票" : nil) : section == 2 ? @"推演期間" : @"這次研究"; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView; UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil]; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.numberOfLines = 0; cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    cell.textLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    if (indexPath.section == 0 || indexPath.section == 2) {
        UIView *control = indexPath.section == 0 ? self.codeField : self.period; control.translatesAutoresizingMaskIntoConstraints = NO; [cell.contentView addSubview:control];
        [NSLayoutConstraint activateConstraints:@[[control.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor], [control.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor], [control.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12], [control.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12], [control.heightAnchor constraintGreaterThanOrEqualToConstant:38]]];
    } else if (indexPath.section == 1) {
        NSDictionary *stock = self.matches[indexPath.row]; cell.textLabel.text = [NSString stringWithFormat:@"%@ · %@", SXResearchText(stock[@"code"]), SXResearchText(stock[@"alias"]).length ? stock[@"alias"] : SXResearchText(stock[@"name"])];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", SXResearchText(stock[@"market"]), SXResearchText(stock[@"exchange"])]; cell.selectionStyle = UITableViewCellSelectionStyleDefault; cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        if (indexPath.row == 0) { NSDictionary *stock = [SXStore.sharedStore stockForCode:self.selectedCode]; cell.textLabel.text = stock ? [NSString stringWithFormat:@"%@ · %@", self.selectedCode, SXResearchText(stock[@"alias"]).length ? stock[@"alias"] : SXResearchText(stock[@"name"])] : @"請輸入或選取有效股票"; cell.detailTextLabel.text = @"原生研究 · Gemini 4 Argon"; }
        else if (indexPath.row == 1) { cell.textLabel.text = self.planMode?@"7 日持股研究與條件追蹤":[self days] == 126 ? @"24 個約週價位，包含期末" : [self days] == 30 ? @"每 3 個交易日一筆，共 10 個價位" : @"7 個交易日，每日一個價位"; cell.detailTextLabel.text = self.planMode?@"市場獨立判斷；觸及條件只重新研究，不會自動下單、減碼或賣出。":@"保留原始預測與來源，不補造中間價位。"; }
        else { cell.textLabel.text = [NSString stringWithFormat:@"單次用量上限 US$%@", [self days] == 126 ? @"1.00" : [self days] == 30 ? @"0.35" : @"0.25"]; cell.detailTextLabel.text = @"點下方按鈕才呼叫付費模型；費用依實際用量計算。連線中斷後只查詢同一請求，不自動重跑。"; }
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath { [tableView deselectRowAtIndexPath:indexPath animated:YES]; if (indexPath.section == 1) { self.codeField.text = SXResearchText(self.matches[indexPath.row][@"code"]); [self.codeField resignFirstResponder]; [self codeChanged]; } }
- (void)setBusy:(BOOL)busy { self.submitting = busy; self.beginButton.enabled = !busy && [SXStore.sharedStore stockForCode:self.selectedCode] != nil; self.codeField.enabled = !busy&&!self.planMode; self.period.enabled = !busy&&!self.planMode; }
- (void)beginResearch {
    if(self.submitting)return;
    [self setBusy:YES];NSString *expected=SXStore.sharedStore.activeProfileUserID;NSUInteger revision=SXAPI.sharedAPI.identityRevision;__weak typeof(self) weakSelf=self;
    [SXAPI.sharedAPI requestPath:@"/api/account/status" method:@"GET" body:nil completion:^(id json,NSInteger status,NSError *error){
        typeof(self) self=weakSelf;if(!self||!SXResearchWorkspaceMatches(expected))return;[self setBusy:NO];
        BOOL valid=[json isKindOfClass:NSDictionary.class]&&[json[@"signedIn"] isKindOfClass:NSNumber.class];id user=valid?json[@"user"]:nil;NSString *identity=[user isKindOfClass:NSDictionary.class]?SXResearchText(user[@"id"]):@"";BOOL signedIn=valid&&[json[@"signedIn"] isEqual:@YES];NSError *workspaceError=nil;
        if(error||status!=200||!valid||revision!=SXAPI.sharedAPI.identityRevision||(signedIn&&!identity.length)||![SXStore.sharedStore activateProfileForUserID:signedIn?identity:nil error:&workspaceError]){SXShowError(self,@"帳號尚未確認",error.localizedDescription?:workspaceError.localizedDescription?:@"請稍後重試，這次沒有啟動分析。");return;}
        SXStore.sharedStore.accountIdentityResolved=YES;if(SXResearchWorkspaceMatches(expected)&&self.viewIfLoaded.window)[self beginVerifiedResearch];
    }];
}
- (void)beginVerifiedResearch {
    if (self.submitting) return;
    NSUInteger identityRevision=SXAPI.sharedAPI.identityRevision;
    NSString *code = self.selectedCode; if (![SXStore.sharedStore stockForCode:code]) { SXShowError(self, @"請選取股票", @"輸入有效代號，或點選搜尋結果。 "); return; }
    [self.view endEditing:YES]; [self setBusy:YES]; NSInteger days = [self days];
    __weak typeof(self) weakSelf = self;NSString *workspace=[SXStore.sharedStore.activeProfileUserID copy];
    [SXAPI.sharedAPI requestPath:@"/api/research/status" method:@"GET" body:nil completion:^(id json, NSInteger status, NSError *error) {
        typeof(self) self = weakSelf; if (!self||(identityRevision!=SXAPI.sharedAPI.identityRevision||!SXResearchWorkspaceMatches(workspace))) return;
        NSDictionary *health = [json isKindOfClass:NSDictionary.class] ? json : @{};
        if (error || status != 200 || ![health[@"ready"] isEqual:@YES]) { [self setBusy:NO]; SXShowError(self, @"分析暫時無法啟動", error.localizedDescription ?: (SXResearchText(health[@"error"]).length ? health[@"error"] : @"分析後台尚未就緒，沒有呼叫付費模型。")); return; }
        NSDictionary *position=self.planMode?[self heldPosition]:nil;id savedRequests=[SXStore.sharedStore valueForProfileKey:@"nexa.requests" fallback:@{}];if(self.planMode&&(!position||([savedRequests isKindOfClass:NSDictionary.class]&&SXResearchText(savedRequests[code]).length))){[self setBusy:NO];SXShowError(self,@"暫時無法建立",@"目前持股已變更，或已有同股計畫正在進行。請返回持股計畫查看。");return;}
        NSString *runID = NSUUID.UUID.UUIDString.lowercaseString;
        NSString *kind=self.planMode?@"plan":@"forecast";
        if(self.planMode){NSMutableDictionary *requests=[savedRequests mutableCopy];requests[code]=runID;if(![SXStore.sharedStore setProfileValue:requests forKey:@"nexa.requests"]){[self setBusy:NO];SXShowError(self,@"無法保存計畫識別碼",@"這次沒有呼叫付費模型，請先匯出資料。");return;}}
        NSDictionary *pending = @{@"id": runID, @"code": code, @"horizon": @(days), @"mode": @"event", @"kind":kind, @"status": @"running", @"createdAt": @((long long)(NSDate.date.timeIntervalSince1970 * 1000)), @"progress": @{@"phase": @"collecting"}};
        BOOL saved=[SXStore.sharedStore upsertRun:pending];
        if (!saved||SXStore.sharedStore.persistenceError.length) {if(self.planMode)[SXReportController finishNexaRequestForCode:code requestID:runID];[self setBusy:NO]; SXShowError(self, @"無法保存分析識別碼", @"先處理本機儲存問題後再開始，這次沒有呼叫付費模型。"); return; }
        SXReportController *report = [[SXReportController alloc] initWithRun:pending]; [self.navigationController pushViewController:report animated:YES];
        NSDictionary *body = @{@"id": runID, @"code": code, @"symbol": [SXStore.sharedStore sourceSymbolForCode:code], @"days": @(days), @"kind":kind, @"position":position?:NSNull.null};
        [SXAPI.sharedAPI requestPath:@"/api/research" method:@"POST" body:body completion:^(id response, NSInteger responseStatus, NSError *submitError) {
            if((identityRevision!=SXAPI.sharedAPI.identityRevision||!SXResearchWorkspaceMatches(workspace)))return;
            NSDictionary *value = [response isKindOfClass:NSDictionary.class] ? response : @{};
            BOOL completed=!submitError&&responseStatus>=200&&responseStatus<300&&[SXReportController validateCompletedRun:value forRequest:pending allowReusedPlan:[kind isEqual:@"plan"]];
            if([kind isEqual:@"plan"]&&completed){BOOL archived=[SXReportController archiveNexaRun:value forCode:code requestID:runID];if(archived){[SXStore.sharedStore upsertRun:value];[report displayArchivedRun:value];}else SXShowError(report,@"封存尚未保存完成",@"請先匯出原始研究保留副本，再重新查詢同一請求。");[weakSelf setBusy:NO];return;}
            NSDictionary *current = pending;
            for (NSDictionary *saved in SXStore.sharedStore.runs) if ([saved[@"id"] isEqual:runID]) { current = saved; break; }
            BOOL terminal = [current[@"status"] isEqual:@"completed"] || [current[@"status"] isEqual:@"failed"];
            NSMutableDictionary *update = [current mutableCopy];
            if (completed) [update addEntriesFromDictionary:value];
            else if (!terminal && !submitError && responseStatus >= 200 && responseStatus < 300 && [SXResearchText(value[@"status"]) isEqualToString:@"running"]) [update addEntriesFromDictionary:value];
            else if (!terminal && responseStatus >= 400 && responseStatus != 502 && responseStatus != 504 && SXResearchText(value[@"error"]).length) { update[@"status"] = @"failed"; update[@"error"] = value[@"error"]; }
            else if (!terminal) update[@"connectionNotice"] = @"要求回覆尚未確認；只查詢同一分析識別碼，不自動重跑付費模型。";
            // Preserve the local identity even when a server progress envelope omits metadata.
            update[@"id"] = runID; update[@"code"] = code; update[@"horizon"] = @(days); update[@"mode"] = @"event";
            if(![SXStore.sharedStore upsertRun:update])SXShowError(report,@"研究尚未保存",@"請先匯出資料保留副本；不會自動重跑付費模型。");[weakSelf setBusy:NO];
            if([kind isEqual:@"plan"]&&[update[@"status"] isEqual:@"failed"])[SXReportController finishNexaRequestForCode:code requestID:runID];
        }];
    }];
}
@end
