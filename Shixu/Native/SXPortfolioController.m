#import "SXPortfolioController.h"
#import "SXStore.h"
#import "SXUI.h"
#import "SXMarketController.h"
#import <math.h>

static NSArray<NSDictionary *> *SXPortfolioRows(id value) {
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *rows = [NSMutableArray array];
    for (id row in value) if ([row isKindOfClass:NSDictionary.class]) [rows addObject:row];
    return rows;
}
static NSString *SXPortfolioText(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSString *SXPortfolioToday(void) {
    NSDateFormatter *format = [NSDateFormatter new];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Taipei"];
    format.dateFormat = @"yyyy-MM-dd";
    return [format stringFromDate:NSDate.date];
}
static BOOL SXPortfolioPositive(id value) { return SXFiniteNumber(value) && [value doubleValue] > 0; }
static double SXPortfolioValue(id value) { return SXFiniteNumber(value) ? [value doubleValue] : NAN; }
static NSString *SXPortfolioEditableNumber(id value, BOOL absolute) {
    if (!SXFiniteNumber(value)) return @"";
    NSNumberFormatter *formatter = [NSNumberFormatter new]; formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.numberStyle = NSNumberFormatterDecimalStyle; formatter.usesGroupingSeparator = NO; formatter.maximumFractionDigits = 20;
    return [formatter stringFromNumber:absolute ? @(fabs([value doubleValue])) : value] ?: @"";
}
static NSNumber *SXPortfolioInput(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length || [trimmed rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789."] invertedSet]].location != NSNotFound) return nil;
    if ([[trimmed componentsSeparatedByString:@"."] count] > 2) return nil;
    NSScanner *scanner = [NSScanner scannerWithString:trimmed];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    double value = 0;
    if (![scanner scanDouble:&value] || !scanner.isAtEnd || !isfinite(value) || value <= 0 || value > 1e15) return nil;
    return @(value);
}

@interface SXPortfolioRecordController : UIViewController <UITextFieldDelegate>
@property(nonatomic) BOOL cashRecord;
@property(nonatomic,copy) NSString *currency;
@property(nonatomic,copy,nullable) NSDictionary *record;
@property(nonatomic,copy) void (^saveRecord)(NSDictionary *record);
@property(nonatomic,strong) UITextField *codeField;
@property(nonatomic,strong) UITextField *amountField;
@property(nonatomic,strong) UITextField *costField;
@property(nonatomic,strong) UITextField *noteField;
@property(nonatomic,strong) UISegmentedControl *currencyControl;
@property(nonatomic,strong) UISegmentedControl *directionControl;
@property(nonatomic,strong) UIDatePicker *datePicker;
@property(nonatomic,strong) UILabel *companyLabel;
@property(nonatomic,strong) UILabel *errorLabel;
@end

@implementation SXPortfolioRecordController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.cashRecord ? (self.record ? @"編輯資金" : @"新增資金") : (self.record ? @"編輯持股" : @"新增持股");
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 13; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:22],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-20]
    ]];
    self.currencyControl = [[UISegmentedControl alloc] initWithItems:@[@"美元 USD", @"台幣 TWD"]];
    self.currencyControl.selectedSegmentIndex = [self.currency isEqualToString:@"TWD"] ? 1 : 0;
    self.currencyControl.accessibilityLabel = @"紀錄幣別";
    if (self.cashRecord) {
        [self addLabel:@"幣別" toStack:stack]; [stack addArrangedSubview:self.currencyControl];
        self.directionControl = [[UISegmentedControl alloc] initWithItems:@[@"增加資金", @"減少資金"]];
        self.directionControl.selectedSegmentIndex = SXPortfolioValue(self.record[@"amount"]) < 0 ? 1 : 0;
        self.directionControl.accessibilityLabel = @"資金變動方向";
        [self addLabel:@"變動方向" toStack:stack]; [stack addArrangedSubview:self.directionControl];
        self.amountField = [self field:@"金額" value:SXPortfolioEditableNumber(self.record[@"amount"], YES) keyboard:UIKeyboardTypeDecimalPad stack:stack];
    } else {
        self.codeField = [self field:@"股票代號" value:SXPortfolioText(self.record[@"code"]) keyboard:UIKeyboardTypeASCIICapable stack:stack];
        self.codeField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        self.codeField.autocorrectionType = UITextAutocorrectionTypeNo;
        self.codeField.enabled = self.record == nil;
        [self.codeField addTarget:self action:@selector(codeChanged) forControlEvents:UIControlEventEditingChanged];
        self.companyLabel = [UILabel new]; self.companyLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        self.companyLabel.textColor = UIColor.secondaryLabelColor; self.companyLabel.numberOfLines = 0;
        [stack addArrangedSubview:self.companyLabel]; [self codeChanged];
        self.amountField = [self field:@"持股數量（股）" value:SXPortfolioEditableNumber(self.record[@"quantity"], NO) keyboard:UIKeyboardTypeDecimalPad stack:stack];
        self.costField = [self field:@"平均成本（股票原幣）" value:SXPortfolioEditableNumber(self.record[@"cost"], NO) keyboard:UIKeyboardTypeDecimalPad stack:stack];
    }
    [self addLabel:@"紀錄日期" toStack:stack];
    self.datePicker = [UIDatePicker new]; self.datePicker.datePickerMode = UIDatePickerModeDate;
    self.datePicker.preferredDatePickerStyle = UIDatePickerStyleCompact;
    self.datePicker.locale = [NSLocale localeWithLocaleIdentifier:@"zh_TW"];
    self.datePicker.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Taipei"];
    self.datePicker.accessibilityLabel = @"紀錄日期";
    NSDateFormatter *dateFormat = [NSDateFormatter new]; dateFormat.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    dateFormat.timeZone = self.datePicker.timeZone; dateFormat.dateFormat = @"yyyy-MM-dd";
    NSDate *date = [dateFormat dateFromString:SXPortfolioText(self.record[@"date"])];
    if (date) self.datePicker.date = date;
    [stack addArrangedSubview:self.datePicker];
    self.noteField = [self field:@"備註（選填）" value:SXPortfolioText(self.record[@"note"]) keyboard:UIKeyboardTypeDefault stack:stack];
    self.noteField.returnKeyType = UIReturnKeyDone;
    UILabel *hint = [UILabel new]; hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; hint.numberOfLines = 0; hint.textColor = UIColor.secondaryLabelColor;
    hint.text = self.cashRecord ? @"這是可用資金帳。登錄持股不會自動扣款，請分別記錄實際資金。" : @"只登錄現有持股，不會下單。同一股票新增時會合併數量並加權成本。";
    [stack addArrangedSubview:hint];
    self.errorLabel = [UILabel new]; self.errorLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.errorLabel.textColor = UIColor.systemRedColor; self.errorLabel.numberOfLines = 0; self.errorLabel.hidden = YES;
    [stack addArrangedSubview:self.errorLabel];
    __weak typeof(self) weakSelf = self;
    UIButton *save = SXGlassButton(@"儲存紀錄", @"checkmark", [UIAction actionWithHandler:^(__kindof UIAction *action) { [weakSelf saveTapped]; }]);
    [save.heightAnchor constraintGreaterThanOrEqualToConstant:50].active = YES;
    [stack addArrangedSubview:save];
}
- (void)addLabel:(NSString *)text toStack:(UIStackView *)stack {
    UILabel *label = [UILabel new]; label.text = text; label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline]; label.textColor = UIColor.secondaryLabelColor;
    [stack addArrangedSubview:label];
}
- (UITextField *)field:(NSString *)label value:(NSString *)value keyboard:(UIKeyboardType)keyboard stack:(UIStackView *)stack {
    [self addLabel:label toStack:stack];
    UITextField *field = [UITextField new]; field.text = value; field.placeholder = label; field.accessibilityLabel = label;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; field.adjustsFontForContentSizeCategory = YES;
    field.borderStyle = UITextBorderStyleRoundedRect; field.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    field.keyboardType = keyboard; field.clearButtonMode = UITextFieldViewModeWhileEditing; field.delegate = self;
    [field.heightAnchor constraintGreaterThanOrEqualToConstant:48].active = YES;
    if (keyboard == UIKeyboardTypeDecimalPad) {
        UIToolbar *toolbar = [UIToolbar new]; [toolbar sizeToFit];
        toolbar.items = @[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil], [[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:field action:@selector(resignFirstResponder)]];
        field.inputAccessoryView = toolbar;
    }
    [stack addArrangedSubview:field]; return field;
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField { [textField resignFirstResponder]; return YES; }
- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    NSUInteger count = textField.text.length - range.length + string.length;
    return count <= (textField == self.noteField ? 160 : textField == self.codeField ? 20 : 30);
}
- (void)codeChanged {
    NSString *code = [self.codeField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
    NSDictionary *stock = [[SXStore sharedStore] stockForCode:code];
    self.companyLabel.text = stock ? [NSString stringWithFormat:@"%@ · %@", SXPortfolioText(stock[@"alias"]).length ? stock[@"alias"] : SXPortfolioText(stock[@"name"]), [stock[@"market"] isEqual:@"TW"] ? @"TWD" : @"USD"] : @"輸入官方股票代號，例如 AMD、2330。";
}
- (void)fail:(NSString *)message {
    self.errorLabel.text = message; self.errorLabel.hidden = NO;
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
}
- (void)saveTapped {
    NSNumber *amount = SXPortfolioInput(self.amountField.text);
    if (!amount) { [self fail:self.cashRecord ? @"請填入大於零且有效的資金金額。" : @"請填入大於零且有效的持股數量。"]; return; }
    NSMutableDictionary *record = self.record ? [self.record mutableCopy] : [NSMutableDictionary dictionary];
    if (!SXPortfolioText(record[@"id"]).length) record[@"id"] = NSUUID.UUID.UUIDString;
    NSDateFormatter *format = [NSDateFormatter new]; format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    format.timeZone = [NSTimeZone timeZoneWithName:@"Asia/Taipei"]; format.dateFormat = @"yyyy-MM-dd";
    record[@"date"] = [format stringFromDate:self.datePicker.date] ?: SXPortfolioToday();
    record[@"note"] = [self.noteField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new]; NSString *timestamp = [iso stringFromDate:NSDate.date];
    record[@"updatedAt"] = timestamp;
    if (self.cashRecord) {
        record[@"currency"] = self.currencyControl.selectedSegmentIndex == 1 ? @"TWD" : @"USD";
        record[@"amount"] = @(amount.doubleValue * (self.directionControl.selectedSegmentIndex == 1 ? -1 : 1));
        if (!record[@"createdAt"]) record[@"createdAt"] = timestamp;
    } else {
        NSString *code = [self.codeField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
        NSDictionary *stock = [[SXStore sharedStore] stockForCode:code];
        NSNumber *cost = SXPortfolioInput(self.costField.text);
        if (!stock) { [self fail:@"請輸入官方名錄中的股票代號。"]; return; }
        if (!cost || !isfinite(amount.doubleValue * cost.doubleValue) || amount.doubleValue * cost.doubleValue > 1e15) { [self fail:@"請檢查平均成本與持股總成本。"]; return; }
        record[@"code"] = code; record[@"quantity"] = amount; record[@"cost"] = cost;
        record[@"currency"] = [stock[@"market"] isEqual:@"TW"] ? @"TWD" : @"USD";
    }
    [self.view endEditing:YES]; if (self.saveRecord) self.saveRecord(record);
}
@end

@interface SXPortfolioController ()
@property(nonatomic,strong) SXStore *store;
@property(nonatomic,copy) NSString *currency;
@property(nonatomic,copy) NSString *sortOrder;
@property(nonatomic,strong) UISegmentedControl *currencyControl;
@property(nonatomic,strong) UIButton *sortButton;
@property(nonatomic,strong) NSDictionary *summary;
@property(nonatomic,strong) NSArray<NSDictionary *> *positions;
@property(nonatomic,strong) NSArray<NSDictionary *> *cashEntries;
@property(nonatomic,strong) NSArray<NSDictionary *> *allocation;
@property(nonatomic) BOOL refreshing;
@end

@implementation SXPortfolioController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.store = [SXStore sharedStore]; self.title = @"持股";
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 74;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    [self synchronizeCurrency];
    self.sortOrder = [self.store setting:@"account.sort" fallback:@"original"];
    if (![@[@"original", @"value", @"pnl", @"code"] containsObject:self.sortOrder]) self.sortOrder = @"original";
    self.currencyControl = [[UISegmentedControl alloc] initWithItems:@[@"美股 · USD", @"台股 · TWD"]];
    self.currencyControl.selectedSegmentIndex = [self.currency isEqualToString:@"TWD"] ? 1 : 0;
    self.currencyControl.accessibilityLabel = @"持股幣別";
    [self.currencyControl addTarget:self action:@selector(currencyChanged) forControlEvents:UIControlEventValueChanged];
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 65)]; self.currencyControl.translatesAutoresizingMaskIntoConstraints = NO; [header addSubview:self.currencyControl];
    [NSLayoutConstraint activateConstraints:@[[self.currencyControl.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20], [self.currencyControl.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20], [self.currencyControl.topAnchor constraintEqualToAnchor:header.topAnchor constant:12], [self.currencyControl.heightAnchor constraintGreaterThanOrEqualToConstant:36]]];
    self.tableView.tableHeaderView = header;
    __weak typeof(self) weakSelf = self;
    self.sortButton = SXIconButton(@"排序", @"arrow.up.arrow.down", [UIAction actionWithHandler:^(__kindof UIAction *action) {}]);
    self.sortButton.showsMenuAsPrimaryAction = YES;
    UIButton *add = SXIconButton(@"新增", @"plus", [UIAction actionWithHandler:^(__kindof UIAction *action) { [weakSelf addTapped]; }]);
    self.navigationItem.rightBarButtonItems = @[[[UIBarButtonItem alloc] initWithCustomView:add], [[UIBarButtonItem alloc] initWithCustomView:self.sortButton]];
    self.refreshControl = [UIRefreshControl new];
    [self.refreshControl addTarget:self action:@selector(refreshQuotes) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeChanged:) name:SXStoreDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(quotesChanged:) name:SXQuotesDidChangeNotification object:nil];
    [self rebuild];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self synchronizeCurrency]; [self rebuild]; [self refreshQuotes]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)storeChanged:(NSNotification *)notification { BOOL changed=[self synchronizeCurrency]; [self rebuild]; if(changed)[self refreshQuotes]; }
- (void)quotesChanged:(NSNotification *)notification { [self rebuild]; }
- (void)currencyChanged {
    NSString *currency=self.currencyControl.selectedSegmentIndex == 1 ? @"TWD" : @"USD";
    if(![self.store setProfileValue:currency forKey:@"account.currency"]){[self synchronizeCurrency];SXShowError(self,@"幣別未儲存",self.store.persistenceError?:@"請重試，原有設定保留。");return;}
    [self synchronizeCurrency]; [self rebuild]; [self refreshQuotes];
}
- (BOOL)synchronizeCurrency {
    id value=[self.store valueForProfileKey:@"account.currency" fallback:NSNull.null];
    if(value==NSNull.null)value=[self.store setting:@"account.currency" fallback:@"USD"];
    NSString *currency=[value isEqual:@"TWD"]?@"TWD":@"USD";BOOL changed=![self.currency isEqual:currency];
    self.currency=currency;self.currencyControl.selectedSegmentIndex=[currency isEqual:@"TWD"]?1:0;return changed;
}
- (NSDictionary *)validQuoteForCode:(NSString *)code {
    NSDictionary *quote = self.store.quotes[code];
    if (![quote isKindOfClass:NSDictionary.class] || !SXPortfolioPositive(quote[@"price"]) || ![quote[@"currency"] isEqual:self.currency]) return nil;
    return quote;
}
- (void)refreshQuotes {
    if (self.refreshing) return;
    NSMutableOrderedSet *codes = [NSMutableOrderedSet orderedSet];
    for (NSDictionary *position in self.positions) if (SXPortfolioText(position[@"code"]).length) [codes addObject:position[@"code"]];
    if (!codes.count) { [self.refreshControl endRefreshing]; return; }
    self.refreshing = YES; NSString *requestedCurrency = self.currency;
    __weak typeof(self) weakSelf = self;
    [self.store refreshQuotesForCodes:codes.array completion:^{ weakSelf.refreshing = NO; [weakSelf.refreshControl endRefreshing]; [weakSelf rebuild]; if (weakSelf && ![weakSelf.currency isEqual:requestedCurrency]) [weakSelf refreshQuotes]; }];
}
- (void)rebuild {
    NSMutableArray *positions = [NSMutableArray array], *cash = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *groups = [NSMutableDictionary dictionary];
    double cashTotal = 0, costTotal = 0, marketTotal = 0; BOOL complete = YES, cashValid = YES, costValid = YES;
    for (NSDictionary *entry in SXPortfolioRows(self.store.account[@"cash"])) if ([entry[@"currency"] isEqual:self.currency]) {
        [cash addObject:entry]; if (SXFiniteNumber(entry[@"amount"])) cashTotal += SXPortfolioValue(entry[@"amount"]); else { complete = NO; cashValid = NO; }
    }
    for (NSDictionary *position in SXPortfolioRows(self.store.account[@"positions"])) if ([position[@"currency"] isEqual:self.currency]) {
        [positions addObject:position]; NSString *code = SXPortfolioText(position[@"code"]);
        BOOL valid = code.length && SXPortfolioPositive(position[@"quantity"]) && SXPortfolioPositive(position[@"cost"]);
        double quantity = valid ? SXPortfolioValue(position[@"quantity"]) : 0, cost = valid ? quantity * SXPortfolioValue(position[@"cost"]) : 0;
        NSDictionary *quote = [self validQuoteForCode:code]; double value = quote ? quantity * [quote[@"price"] doubleValue] : 0;
        if (!valid || !isfinite(cost)) costValid = NO;
        if (!valid || !quote || !isfinite(cost) || !isfinite(value)) complete = NO;
        costTotal += cost; if (quote && isfinite(value)) marketTotal += value;
        NSMutableDictionary *group = groups[code];
        if (!group) { group = [@{@"code":code, @"value":@0, @"quoted":@YES} mutableCopy]; groups[code] = group; }
        group[@"value"] = @([group[@"value"] doubleValue] + value);
        group[@"quoted"] = @([group[@"quoted"] boolValue] && valid && quote != nil && isfinite(value));
    }
    if (!isfinite(cashTotal)) cashValid = NO; if (!isfinite(costTotal)) costValid = NO;
    if (!cashValid || !costValid || !isfinite(marketTotal) || !isfinite(cashTotal + marketTotal)) complete = NO;
    NSInteger priced = 0, stale = 0;
    for (NSDictionary *group in groups.allValues) { if ([group[@"quoted"] boolValue]) priced++; if ([group[@"quoted"] boolValue] && [self.store.quoteErrors containsObject:group[@"code"]]) stale++; }
    double assets = cashTotal + marketTotal, pnl = marketTotal - costTotal, rate = costTotal > 0 ? pnl / costTotal * 100 : NAN;
    BOOL allocationAvailable = complete && assets > 0 && cashTotal >= 0;
    self.summary = @{@"cash":cashValid ? @(cashTotal) : NSNull.null, @"cost":costValid ? @(costTotal) : NSNull.null, @"value":complete ? @(marketTotal) : NSNull.null, @"assets":complete ? @(assets) : NSNull.null, @"pnl":complete && isfinite(pnl) ? @(pnl) : NSNull.null, @"return":complete && isfinite(rate) ? @(rate) : NSNull.null, @"complete":@(complete), @"allocationAvailable":@(allocationAvailable), @"priced":@(priced), @"total":@(groups.count), @"stale":@(stale)};
    NSMutableArray *allocation = [NSMutableArray array];
    if (allocationAvailable) {
        if (cashTotal > 0) [allocation addObject:@{@"code":@"", @"name":@"可用資金", @"value":@(cashTotal), @"weight":@(cashTotal / assets * 100)}];
        NSArray *ordered = [groups.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            NSComparisonResult result = [b[@"value"] compare:a[@"value"]]; return result == NSOrderedSame ? [a[@"code"] compare:b[@"code"]] : result;
        }];
        for (NSDictionary *group in ordered) [allocation addObject:@{@"code":group[@"code"], @"name":group[@"code"], @"value":group[@"value"], @"weight":@([group[@"value"] doubleValue] / assets * 100)}];
    }
    self.allocation = allocation;
    NSString *order = self.sortOrder;
    if (![order isEqual:@"original"]) [positions sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        if ([order isEqual:@"code"]) return [SXPortfolioText(a[@"code"]) compare:SXPortfolioText(b[@"code"]) options:NSNumericSearch];
        NSDictionary *aq = [self validQuoteForCode:SXPortfolioText(a[@"code"])], *bq = [self validQuoteForCode:SXPortfolioText(b[@"code"])];
        if (!aq) return bq ? NSOrderedDescending : NSOrderedSame; if (!bq) return NSOrderedAscending;
        double av = ([aq[@"price"] doubleValue] - ([order isEqual:@"pnl"] ? SXPortfolioValue(a[@"cost"]) : 0)) * SXPortfolioValue(a[@"quantity"]);
        double bv = ([bq[@"price"] doubleValue] - ([order isEqual:@"pnl"] ? SXPortfolioValue(b[@"cost"]) : 0)) * SXPortfolioValue(b[@"quantity"]);
        if (!isfinite(av)) return isfinite(bv) ? NSOrderedDescending : NSOrderedSame; if (!isfinite(bv)) return NSOrderedAscending;
        return av > bv ? NSOrderedAscending : av < bv ? NSOrderedDescending : NSOrderedSame;
    }];
    [cash sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [SXPortfolioText(b[@"date"]) compare:SXPortfolioText(a[@"date"])]; }];
    self.positions = positions; self.cashEntries = cash;
    [self updateSortMenu]; CGPoint offset=self.tableView.contentOffset;[UIView performWithoutAnimation:^{[self.tableView reloadData];[self.tableView layoutIfNeeded];}];if(!self.tableView.dragging&&!self.tableView.decelerating){CGFloat maximum=MAX(-self.tableView.adjustedContentInset.top,self.tableView.contentSize.height-self.tableView.bounds.size.height+self.tableView.adjustedContentInset.bottom);offset.y=MAX(-self.tableView.adjustedContentInset.top,MIN(maximum,offset.y));self.tableView.contentOffset=offset;}
}
- (void)updateSortMenu {
    __weak typeof(self) weakSelf = self; NSMutableArray *actions = [NSMutableArray array];
    NSArray *items = @[@[@"original", @"登錄順序"], @[@"value", @"市值由高到低"], @[@"pnl", @"損益由高到低"], @[@"code", @"股票代號"]];
    for (NSArray *item in items) {
        UIAction *action = [UIAction actionWithTitle:item[1] image:nil identifier:nil handler:^(__kindof UIAction *action) { weakSelf.sortOrder = item[0]; [weakSelf.store setSetting:item[0] forKey:@"account.sort"]; [weakSelf rebuild]; }];
        action.state = [self.sortOrder isEqual:item[0]] ? UIMenuElementStateOn : UIMenuElementStateOff; [actions addObject:action];
    }
    self.sortButton.menu = [UIMenu menuWithTitle:@"持股排序" children:actions];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 5; }
- (NSInteger)logicalSection:(NSInteger)section {return [@[@0,@2,@1,@3,@4][section] integerValue];}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    section=[self logicalSection:section];
    if (section == 0) return 1;
    if (section == 1) return MAX((NSInteger)self.allocation.count, 1);
    if (section == 2) return MAX((NSInteger)self.positions.count, 1);
    if (section == 3) return MAX((NSInteger)self.cashEntries.count, 1);
    return 1;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    section=[self logicalSection:section];if(section==0)return nil;
    return @[@"資產總覽", @"資產配置", @"目前持股", @"可用資金帳", @"備份"][(NSUInteger)section];
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {return section==0?8:32;}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    section=[self logicalSection:section];
    if (section == 0) {
        NSString *coverage = [self.summary[@"total"] integerValue] ? [NSString stringWithFormat:@"已取得 %@ / %@ 檔行情。", self.summary[@"priced"], self.summary[@"total"]] : @"尚未登錄持股。";
        return [self.summary[@"stale"] integerValue] ? [coverage stringByAppendingFormat:@"%@ 檔更新暫停，估值採上次報價。", self.summary[@"stale"]] : [coverage stringByAppendingString:@"下拉更新；USD／TWD 分開計算。"];
    }
    if (section == 1) {
        NSString *note = @"配置占比以同幣別現金加持股市值計算；缺少行情時暫不顯示完整比例。";
        for (NSDictionary *item in self.allocation) if (SXPortfolioText(item[@"code"]).length) return [NSString stringWithFormat:@"最大持股 %@，占同幣別資產 %@%%。%@", item[@"code"], SXFormatNumber(item[@"weight"], 2), note];
        return note;
    }
    if (section == 2) return @"點持股看盤；左滑可編輯或移除紀錄。";
    if (section == 3) return @"資金與持股分別記錄，不會自動扣除買進金額。點選可編輯，向左滑動可刪除。";
    return @"原生分享可將紀錄存入「檔案」或傳送至你指定的位置。";
}
- (UITableViewCell *)cellWithTitle:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol disclosure:(BOOL)disclosure {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = title; cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0; cell.detailTextLabel.text = detail; cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.numberOfLines = 0; cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = [UIImage systemImageNamed:symbol]; cell.imageView.tintColor = self.view.tintColor;
    cell.accessoryType = disclosure ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = disclosure ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return cell;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    indexPath=[NSIndexPath indexPathForRow:indexPath.row inSection:[self logicalSection:indexPath.section]];
    NSInteger row = indexPath.row;
    if (indexPath.section == 0) {
        UITableViewCell *card=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];card.selectionStyle=UITableViewCellSelectionStyleNone;card.accessibilityIdentifier=@"portfolio.summary";
        UILabel *label=[UILabel new];label.text=@"總資產";label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];label.textColor=UIColor.secondaryLabelColor;
        UILabel *assets=[UILabel new];assets.text=SXMoney(self.summary[@"assets"],self.currency);assets.font=[UIFont preferredFontForTextStyle:UIFontTextStyleLargeTitle];assets.adjustsFontForContentSizeCategory=YES;assets.numberOfLines=0;
        UILabel *cash=[UILabel new];cash.text=[NSString stringWithFormat:@"可用資金  %@",SXMoney(self.summary[@"cash"],self.currency)];cash.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];cash.numberOfLines=0;
        UILabel *pnl=[UILabel new];pnl.text=[NSString stringWithFormat:@"持股損益  %@%@",SXMoney(self.summary[@"pnl"],self.currency),SXFiniteNumber(self.summary[@"return"])?[NSString stringWithFormat:@"（%@%%）",SXFormatNumber(self.summary[@"return"],2)]:@""];pnl.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];pnl.textColor=SXFiniteNumber(self.summary[@"pnl"])?SXChangeColor([self.summary[@"pnl"] doubleValue]):UIColor.secondaryLabelColor;pnl.numberOfLines=0;
        for(UILabel *item in @[label,assets,cash,pnl])item.adjustsFontForContentSizeCategory=YES;
        UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[label,assets,cash,pnl]];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=8;stack.translatesAutoresizingMaskIntoConstraints=NO;[card.contentView addSubview:stack];[NSLayoutConstraint activateConstraints:@[[stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:16],[stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-16],[stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:18],[stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-18]]];return card;

    }
    if (indexPath.section == 1) {
        if (!self.allocation.count) return [self cellWithTitle:![self.summary[@"complete"] boolValue] ? @"等待完整行情" : [self.summary[@"cash"] doubleValue] < 0 ? @"可用資金為負數" : @"尚無資產配置" detail:![self.summary[@"complete"] boolValue] ? @"可下拉更新，來源失敗時不會補造價格。" : [self.summary[@"cash"] doubleValue] < 0 ? @"保留實際資金餘額，配置比例暫不顯示。" : @"新增資金或持股後，即可查看配置。" symbol:@"chart.pie" disclosure:NO];
        NSDictionary *item = self.allocation[(NSUInteger)row];
        return [self cellWithTitle:[NSString stringWithFormat:@"%@ · %@%%", item[@"name"], SXFormatNumber(item[@"weight"], 2)] detail:SXMoney(item[@"value"], self.currency) symbol:SXPortfolioText(item[@"code"]).length ? @"chart.bar.fill" : @"banknote" disclosure:NO];
    }
    if (indexPath.section == 2) {
        if (!self.positions.count) return [self cellWithTitle:@"尚未登錄持股" detail:@"點右上方「新增」開始記錄。" symbol:@"plus.circle" disclosure:NO];
        NSDictionary *position = self.positions[(NSUInteger)row]; NSString *code = SXPortfolioText(position[@"code"]);
        NSDictionary *stock = [self.store stockForCode:code], *quote = [self validQuoteForCode:code];
        NSString *name = SXPortfolioText(stock[@"alias"]).length ? stock[@"alias"] : SXPortfolioText(stock[@"name"]);
        NSString *detail = [NSString stringWithFormat:@"%@ 股 · 成本 %@\n%@", SXFormatNumber(position[@"quantity"], 4), SXMoney(position[@"cost"], self.currency), quote ? [NSString stringWithFormat:@"現價 %@ · 市值 %@\n%@", SXMoney(quote[@"price"], self.currency), SXMoney(@([quote[@"price"] doubleValue] * SXPortfolioValue(position[@"quantity"])), self.currency), SXQuoteLabel(quote, [self.store.quoteErrors containsObject:code])] : [self.store.quoteErrors containsObject:code] ? @"行情來源暫缺，請下拉重試。" : @"行情尚未取得。"];
        UITableViewCell *cell=[self cellWithTitle:[NSString stringWithFormat:@"%@ %@", code, name] detail:detail symbol:@"chart.xyaxis.line" disclosure:YES];cell.accessibilityIdentifier=[@"holding." stringByAppendingString:code];return cell;
    }
    if (indexPath.section == 3) {
        if (!self.cashEntries.count) return [self cellWithTitle:@"尚無資金紀錄" detail:@"可以新增目前可用資金，或記錄資金增減。" symbol:@"banknote" disclosure:NO];
        NSDictionary *entry = self.cashEntries[(NSUInteger)row];
        return [self cellWithTitle:[NSString stringWithFormat:@"%@ · %@", SXPortfolioValue(entry[@"amount"]) < 0 ? @"減少資金" : @"增加資金", SXMoney(entry[@"amount"], self.currency)] detail:[NSString stringWithFormat:@"%@%@%@", SXPortfolioText(entry[@"date"]), SXPortfolioText(entry[@"note"]).length ? @" · " : @"", SXPortfolioText(entry[@"note"])] symbol:@"banknote" disclosure:YES];
    }
    UITableViewCell *cell = [self cellWithTitle:@"匯出持股與資金" detail:@"JSON 紀錄，包含美元與台幣帳。" symbol:@"square.and.arrow.up" disclosure:YES]; return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    indexPath=[NSIndexPath indexPathForRow:indexPath.row inSection:[self logicalSection:indexPath.section]];
    if (indexPath.section == 2 && self.positions.count) [self.navigationController pushViewController:[[SXStockController alloc] initWithCode:self.positions[(NSUInteger)indexPath.row][@"code"]] animated:YES];
    if (indexPath.section == 3 && self.cashEntries.count) [self showRecord:self.cashEntries[(NSUInteger)indexPath.row] cash:YES];
    if (indexPath.section == 4) [self exportAccount];
}
- (void)addTapped {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"新增紀錄" message:@"登錄可用資金或現有持股。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"新增持股" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf showRecord:nil cash:NO]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"新增資金" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf showRecord:nil cash:YES]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItems.firstObject;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)showRecord:(NSDictionary *)record cash:(BOOL)cash {
    SXPortfolioRecordController *form = [SXPortfolioRecordController new]; form.cashRecord = cash; form.currency = record ? SXPortfolioText(record[@"currency"]) : self.currency; form.record = record;
    __weak typeof(self) weakSelf = self;
    form.saveRecord = ^(NSDictionary *saved) { [weakSelf saveRecord:saved cash:cash original:record]; };
    [self.navigationController pushViewController:form animated:YES];
}
- (void)saveRecord:(NSDictionary *)record cash:(BOOL)cash original:(NSDictionary *)original {
    NSString *key = cash ? @"cash" : @"positions"; NSMutableDictionary *account = [self.store.account mutableCopy];
    NSMutableArray *rows = [([account[key] isKindOfClass:NSArray.class] ? account[key] : @[]) mutableCopy];
    if (original) {
        NSUInteger index = [rows indexOfObjectPassingTest:^BOOL(NSDictionary *row, NSUInteger index, BOOL *stop) { return [row isKindOfClass:NSDictionary.class] && [row[@"id"] isEqual:record[@"id"]]; }];
        if (index == NSNotFound || ![rows[index] isEqualToDictionary:original]) { SXShowError(self.navigationController.topViewController, @"紀錄已更新", @"紀錄已更新，請返回重新開啟。"); return; }
        rows[index] = record;
    } else if (!cash) {
        NSUInteger index = [rows indexOfObjectPassingTest:^BOOL(NSDictionary *row, NSUInteger index, BOOL *stop) { return [row isKindOfClass:NSDictionary.class] && [row[@"code"] isEqual:record[@"code"]] && [row[@"currency"] isEqual:record[@"currency"]]; }];
        if (index != NSNotFound) {
            NSDictionary *previous = rows[index]; if (!SXPortfolioPositive(previous[@"quantity"]) || !SXPortfolioPositive(previous[@"cost"])) { SXShowError(self.navigationController.topViewController, @"原紀錄待修正", @"請先編輯原持股的數量與成本，再新增同一股票。"); return; } double quantity = [previous[@"quantity"] doubleValue] + [record[@"quantity"] doubleValue];
            double totalCost = [previous[@"quantity"] doubleValue] * [previous[@"cost"] doubleValue] + [record[@"quantity"] doubleValue] * [record[@"cost"] doubleValue];
            if (!isfinite(quantity) || quantity <= 0 || !isfinite(totalCost) || totalCost > 1e15) { SXShowError(self.navigationController.topViewController, @"無法合併", @"合併後數量或成本超出可記錄範圍。"); return; }
            NSMutableDictionary *merged = [previous mutableCopy]; merged[@"quantity"] = @(quantity); merged[@"cost"] = @(totalCost / quantity); merged[@"updatedAt"] = record[@"updatedAt"];
            rows[index] = merged;
        } else [rows addObject:record];
    } else [rows addObject:record];
    account[key] = rows;
    if (![self.store saveAccount:account]) { SXShowError(self.navigationController.topViewController, @"無法儲存", self.store.persistenceError ?: @"本機儲存失敗，請保留輸入並重試。"); return; }
    self.currency = record[@"currency"]; self.currencyControl.selectedSegmentIndex = [self.currency isEqual:@"TWD"] ? 1 : 0;
    if(![self.store setProfileValue:self.currency forKey:@"account.currency"])[self synchronizeCurrency];
    [self.navigationController popToViewController:self animated:YES]; [self rebuild]; [self refreshQuotes];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    indexPath=[NSIndexPath indexPathForRow:indexPath.row inSection:[self logicalSection:indexPath.section]];
    BOOL cash = indexPath.section == 3;
    if ((!cash && indexPath.section != 2) || (cash ? !self.cashEntries.count : !self.positions.count)) return nil;
    NSDictionary *record = cash ? self.cashEntries[(NSUInteger)indexPath.row] : self.positions[(NSUInteger)indexPath.row];
    __weak typeof(self) weakSelf = self;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"移除" handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) { completion(NO); [weakSelf confirmDelete:record cash:cash]; }];
    UIContextualAction *edit=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"編輯" handler:^(__kindof UIContextualAction *action,UIView *view,void (^done)(BOOL)){done(YES);[weakSelf showRecord:record cash:cash];}];edit.image=[UIImage systemImageNamed:@"pencil"];
    remove.image = [UIImage systemImageNamed:@"trash"]; UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[remove,edit]];
    configuration.performsFirstActionWithFullSwipe = NO; return configuration;
}
- (void)confirmDelete:(NSDictionary *)record cash:(BOOL)cash {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:cash ? @"刪除此資金紀錄？" : @"移除此持股紀錄？" message:@"只移除本機紀錄，不會執行交易。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"刪除紀錄" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        NSString *key = cash ? @"cash" : @"positions"; NSMutableDictionary *account = [weakSelf.store.account mutableCopy]; NSMutableArray *rows = [([account[key] isKindOfClass:NSArray.class] ? account[key] : @[]) mutableCopy];
        NSIndexSet *indexes = [rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *row, NSUInteger index, BOOL *stop) { return [row isKindOfClass:NSDictionary.class] && [row[@"id"] isEqual:record[@"id"]]; }];
        [rows removeObjectsAtIndexes:indexes]; account[key] = rows;
        if (![weakSelf.store saveAccount:account]) SXShowError(weakSelf, @"無法刪除", weakSelf.store.persistenceError ?: @"本機儲存失敗，紀錄仍保留。");
        [weakSelf rebuild];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)exportAccount {
    NSMutableDictionary *export = [self.store.account mutableCopy]; export[@"version"] = @1;
    NSISO8601DateFormatter *iso = [NSISO8601DateFormatter new]; export[@"exportedAt"] = [iso stringFromDate:NSDate.date];
    NSError *error = nil; NSData *data = [NSJSONSerialization dataWithJSONObject:export options:NSJSONWritingPrettyPrinted error:&error];
    NSURL *url = [[NSFileManager.defaultManager temporaryDirectory] URLByAppendingPathComponent:[NSString stringWithFormat:@"Shixu-Portfolio-%@.json", NSUUID.UUID.UUIDString]];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:&error]) { SXShowError(self, @"無法匯出", error.localizedDescription ?: @"無法建立分享檔案。"); return; }
    SXShare(self, url);
}
@end
