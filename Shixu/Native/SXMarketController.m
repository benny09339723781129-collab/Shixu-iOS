#import "SXMarketController.h"
#import "SXStore.h"
#import "SXAPI.h"
#import "SXUI.h"
#import "SXMarketData.h"
#import "SXTradingChart.h"
#import "SXResearchController.h"
#import <SafariServices/SafariServices.h>

static double MarketChange(NSDictionary *quote){return SXFiniteNumber(quote[@"changePercent"])?[quote[@"changePercent"] doubleValue]:0;}
static UILabel *MarketLabel(NSString *text,UIFontTextStyle style,UIColor *color) {
    UILabel *label=[UILabel new];label.text=text;label.font=[UIFont preferredFontForTextStyle:style];label.textColor=color;label.adjustsFontForContentSizeCategory=YES;label.numberOfLines=0;return label;
}
static UIStackView *MarketStack(NSArray *views,UILayoutConstraintAxis axis,CGFloat spacing) {
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:views];stack.axis=axis;stack.spacing=spacing;return stack;
}
static void MarketPin(UIView *child,UIView *parent,CGFloat inset) {
    child.translatesAutoresizingMaskIntoConstraints=NO;[parent addSubview:child];[NSLayoutConstraint activateConstraints:@[[child.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor constant:inset],[child.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor constant:-inset],[child.topAnchor constraintEqualToAnchor:parent.topAnchor constant:inset],[child.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor constant:-inset]]];
}

@interface SXMarketController () <UISearchResultsUpdating>
@property(nonatomic,strong) UISegmentedControl *marketControl;
@property(nonatomic,strong) UISearchController *search;
@property(nonatomic,strong) NSArray *visibleStocks;
@property(nonatomic,strong) NSArray *benchmarks;
@property(nonatomic,strong) UIView *dashboard;
@end
@implementation SXMarketController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"行情";self.navigationItem.title=@"拾序";self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=68;
    self.search=[[UISearchController alloc] initWithSearchResultsController:nil];self.search.searchResultsUpdater=self;self.search.obscuresBackgroundDuringPresentation=NO;self.search.searchBar.placeholder=@"搜尋股票代號或公司";self.search.searchBar.accessibilityIdentifier=@"market.search";self.search.searchBar.searchTextField.accessibilityIdentifier=@"market.search";self.search.searchBar.autocorrectionType=UITextAutocorrectionTypeNo;self.navigationItem.searchController=self.search;self.navigationItem.hidesSearchBarWhenScrolling=NO;self.definesPresentationContext=YES;
    self.marketControl=[[UISegmentedControl alloc] initWithItems:@[@"美股",@"台股"]];self.marketControl.accessibilityIdentifier=@"market.scope";self.marketControl.selectedSegmentIndex=[[SXStore.sharedStore setting:@"market" fallback:@"US"] isEqual:@"TW"]?1:0;[self.marketControl addTarget:self action:@selector(marketChanged) forControlEvents:UIControlEventValueChanged];
    __weak typeof(self) weak=self;UIButton *add=SXIconButton(@"建立研究",@"sparkles",[UIAction actionWithHandler:^(__kindof UIAction *a){weak.tabBarController.selectedIndex=2;[(SXResearchController *)((UINavigationController *)weak.tabBarController.selectedViewController).viewControllers.firstObject openSetupForCode:@""];}]);
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:add];
    self.refreshControl=[UIRefreshControl new];[self.refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(rebuild) name:SXStoreDidChangeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(quotesChanged) name:SXQuotesDidChangeNotification object:nil];[self rebuild];[self refresh];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self rebuild];}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {[super traitCollectionDidChange:previous];if(self.isViewLoaded&&self.marketControl&&![previous.preferredContentSizeCategory isEqual:self.traitCollection.preferredContentSizeCategory]){[self buildDashboard];[self.tableView reloadData];}}
- (void)marketChanged {[SXStore.sharedStore setSetting:self.marketControl.selectedSegmentIndex?@"TW":@"US" forKey:@"market"];SXTransition(self.tableView,^{[self rebuild];});[self refresh];}
- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {[self rebuild];if(searchController.searchBar.text.length)[self refresh];}
- (void)rebuild {
    BOOL tw=self.marketControl.selectedSegmentIndex==1;NSString *query=[self.search.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].uppercaseString;
    self.benchmarks=tw?@[@"0050",@"006208",@"00878",@"0056"]:@[@"SPY",@"QQQ",@"DIA",@"SOXX"];
    NSMutableArray *stocks=[NSMutableArray new];
    if(query.length) {for(NSDictionary *stock in SXStore.sharedStore.directory)if([stock[@"market"] isEqual:tw?@"TW":@"US"]&&([[stock[@"code"] uppercaseString] containsString:query]||[[stock[@"name"] uppercaseString] containsString:query]||[[stock[@"alias"] uppercaseString] containsString:query])){[stocks addObject:stock];if(stocks.count>=40)break;}}
    else for(NSString *code in SXStore.sharedStore.watchCodes){NSDictionary *stock=[SXStore.sharedStore stockForCode:code];if([stock[@"market"] isEqual:tw?@"TW":@"US"])[stocks addObject:stock];}
    self.visibleStocks=stocks;[self buildDashboard];[UIView performWithoutAnimation:^{[self.tableView reloadData];}];
}
- (void)quotesChanged {[self buildDashboard];[UIView performWithoutAnimation:^{[self.tableView reloadData];}];}
- (void)refresh {
    NSMutableOrderedSet *codes=[NSMutableOrderedSet orderedSetWithArray:self.benchmarks?:@[]];for(NSDictionary *stock in self.visibleStocks)if(codes.count<20)[codes addObject:stock[@"code"]];
    [SXStore.sharedStore refreshQuotesForCodes:codes.array completion:^{[self.refreshControl endRefreshing];}];
}
- (void)openAssets:(UIButton *)sender {NSString *currency=sender.tag?@"TWD":@"USD";if([SXStore.sharedStore setProfileValue:currency forKey:@"account.currency"])self.tabBarController.selectedIndex=3;}
- (UIButton *)assetButton:(NSString *)currency {
    SXStore *store=SXStore.sharedStore;double cash=0,value=0;BOOL complete=YES;
    for(NSDictionary *row in store.account[@"cash"])if([row[@"currency"] isEqual:currency])cash+=[row[@"amount"] doubleValue];
    for(NSDictionary *row in store.account[@"positions"])if([row[@"currency"] isEqual:currency]){NSDictionary *quote=store.quotes[row[@"code"]];if(SXFiniteNumber(quote[@"price"])&&[quote[@"currency"] isEqual:currency])value+=[quote[@"price"] doubleValue]*[row[@"quantity"] doubleValue];else complete=NO;}
    NSString *text=[NSString stringWithFormat:@"%@ 資產  %@",currency,complete?SXMoney(@(cash+value),currency):@"等待報價"];__weak typeof(self) weak=self;UIButton *button=SXGlassButton(text,nil,[UIAction actionWithHandler:^(__kindof UIAction *action){[weak openAssets:(UIButton *)action.sender];}]);button.tag=[currency isEqual:@"TWD"]?1:0;button.accessibilityIdentifier=[@"assets." stringByAppendingString:currency];return button;
}
- (void)buildDashboard {
    if(!self.isViewLoaded)return;
    BOOL searching=self.search.searchBar.text.length>0;BOOL large=UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);CGFloat width=MAX(280,self.tableView.bounds.size.width);CGFloat cardHeight=large?164:88,gridHeight=cardHeight*2+8,assetHeight=large?96:48,assetY=80+gridHeight+13;
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,width,searching?52:assetY+assetHeight+17)];self.marketControl.translatesAutoresizingMaskIntoConstraints=NO;[self.marketControl removeFromSuperview];[header addSubview:self.marketControl];
    [NSLayoutConstraint activateConstraints:@[[self.marketControl.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],[self.marketControl.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],[self.marketControl.topAnchor constraintEqualToAnchor:header.topAnchor constant:6],[self.marketControl.heightAnchor constraintEqualToConstant:32]]];
    if(!searching){
        UILabel *caption=MarketLabel(@"市場概況",UIFontTextStyleFootnote,UIColor.secondaryLabelColor);caption.frame=CGRectMake(24,52,width-48,20);[header addSubview:caption];
        UIView *grid=[[UIView alloc] initWithFrame:CGRectMake(20,80,width-40,gridHeight)];grid.accessibilityIdentifier=@"market.benchmarks";grid.shouldGroupAccessibilityChildren=YES;[header addSubview:grid];
        for(NSUInteger index=0;index<self.benchmarks.count;index++){
            NSString *code=self.benchmarks[index];NSDictionary *stock=[SXStore.sharedStore stockForCode:code],*quote=SXStore.sharedStore.quotes[code];__weak typeof(self) weak=self;
            UIButton *card=SXGlassButton(@"",nil,[UIAction actionWithHandler:^(__kindof UIAction *action){[weak openCode:code];}]);card.frame=CGRectMake((index%2)*((width-50)/2+10),(index/2)*(cardHeight+8),(width-50)/2,cardHeight);card.autoresizingMask=UIViewAutoresizingFlexibleWidth;UIButtonConfiguration *config=card.configuration;config.contentInsets=NSDirectionalEdgeInsetsZero;config.cornerStyle=UIButtonConfigurationCornerStyleFixed;UIBackgroundConfiguration *background=config.background;background.cornerRadius=16;config.background=background;card.configuration=config;
            UILabel *name=MarketLabel([NSString stringWithFormat:@"%@ · %@",code,stock[@"alias"]?:stock[@"name"]?:@""],UIFontTextStyleCaption1,UIColor.secondaryLabelColor);name.numberOfLines=large?2:1;
            UILabel *price=MarketLabel(SXFormatNumber(quote[@"price"],2),UIFontTextStyleHeadline,UIColor.labelColor);price.numberOfLines=1;price.adjustsFontSizeToFitWidth=YES;
            UILabel *delta=MarketLabel(SXQuoteDelta(quote),UIFontTextStyleCaption1,SXChangeColor(MarketChange(quote)));delta.numberOfLines=1;
            UILabel *stamp=MarketLabel(SXQuoteLabel(quote,[SXStore.sharedStore.quoteErrors containsObject:code]),UIFontTextStyleCaption2,UIColor.secondaryLabelColor);stamp.numberOfLines=large?2:1;
            UIStackView *stack=MarketStack(@[name,price,delta,stamp],UILayoutConstraintAxisVertical,1);stack.userInteractionEnabled=NO;MarketPin(stack,card,10);
            card.accessibilityLabel=[NSString stringWithFormat:@"%@ %@ %@ %@",code,stock[@"alias"]?:stock[@"name"]?:@"",price.text,delta.text];[grid addSubview:card];
        }
        UIStackView *assets=MarketStack(@[[self assetButton:@"USD"],[self assetButton:@"TWD"]],UILayoutConstraintAxisHorizontal,8);assets.distribution=UIStackViewDistributionFillEqually;assets.frame=CGRectMake(20,assetY,width-40,assetHeight);assets.autoresizingMask=UIViewAutoresizingFlexibleWidth;[header addSubview:assets];
    }
    self.dashboard=header;self.tableView.tableHeaderView=header;
}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];if(fabs(self.dashboard.bounds.size.width-self.tableView.bounds.size.width)>1)[self buildDashboard];}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return 1;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return MAX(1,self.visibleStocks.count);}
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    UILabel *label=MarketLabel(self.search.searchBar.text.length?@"搜尋結果":@"自選看盤",UIFontTextStyleSubheadline,UIColor.secondaryLabelColor);label.accessibilityIdentifier=@"market.watchlist";UIView *view=[[UIView alloc] initWithFrame:CGRectMake(0,0,tableView.bounds.size.width,32)];MarketPin(label,view,5);return view;
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {return 32;}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {return self.search.searchBar.text.length?@"點股票看盤；點星號加入自選。":@"Nasdaq／TWSE／TPEx 公開行情 · 下拉更新。自選可向左滑動移除。";}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    if(!self.visibleStocks.count){cell.textLabel.text=self.search.searchBar.text.length?@"找不到相符股票":@"搜尋股票，開始加入自選";cell.textLabel.textColor=UIColor.secondaryLabelColor;return cell;}
    NSDictionary *stock=self.visibleStocks[indexPath.row];NSString *code=stock[@"code"];NSDictionary *quote=SXStore.sharedStore.quotes[code];
    UILabel *symbol=MarketLabel(code,UIFontTextStyleHeadline,UIColor.labelColor),*name=MarketLabel(stock[@"alias"]?:stock[@"name"],UIFontTextStyleCaption1,UIColor.secondaryLabelColor);name.numberOfLines=1;name.lineBreakMode=NSLineBreakByTruncatingTail;
    UILabel *price=MarketLabel(SXMoney(quote[@"price"],self.marketControl.selectedSegmentIndex?@"TWD":@"USD"),UIFontTextStyleHeadline,UIColor.labelColor),*delta=MarketLabel(SXQuoteDelta(quote),UIFontTextStyleSubheadline,SXChangeColor(MarketChange(quote)));price.textAlignment=delta.textAlignment=NSTextAlignmentRight;
    UILabel *stamp=MarketLabel(SXQuoteLabel(quote,[SXStore.sharedStore.quoteErrors containsObject:code]),UIFontTextStyleCaption2,UIColor.secondaryLabelColor);stamp.textAlignment=NSTextAlignmentRight;stamp.numberOfLines=1;UIStackView *left=MarketStack(@[symbol,name],UILayoutConstraintAxisVertical,4),*right=MarketStack(@[price,delta,stamp],UILayoutConstraintAxisVertical,2);[right setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];UIStackView *row=MarketStack(@[left,right],UILayoutConstraintAxisHorizontal,12);row.alignment=UIStackViewAlignmentCenter;MarketPin(row,cell.contentView,12);
    cell.accessibilityIdentifier=[@"stock." stringByAppendingString:code];cell.accessibilityLabel=[NSString stringWithFormat:@"%@ %@ %@ %@ %@",code,name.text,price.text,delta.text,stamp.text];cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    if(self.search.searchBar.text.length){BOOL watched=[SXStore.sharedStore.watchCodes containsObject:code];UIButton *star=[UIButton buttonWithType:UIButtonTypeSystem];[star setImage:[UIImage systemImageNamed:watched?@"star.fill":@"star"] forState:UIControlStateNormal];star.frame=CGRectMake(0,0,44,44);star.accessibilityLabel=[NSString stringWithFormat:@"%@自選 %@",watched?@"移除":@"加入",code];[star addAction:[UIAction actionWithHandler:^(__kindof UIAction *action){NSMutableArray *codes=[SXStore.sharedStore.watchCodes mutableCopy];if([codes containsObject:code])[codes removeObject:code];else[codes addObject:code];[SXStore.sharedStore setWatchCodes:codes];}] forControlEvents:UIControlEventTouchUpInside];cell.accessoryView=star;}
    return cell;
}
- (void)openCode:(NSString *)code {[self.navigationController pushViewController:[[SXStockController alloc] initWithCode:code] animated:YES];}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {[tableView deselectRowAtIndexPath:indexPath animated:YES];if(self.visibleStocks.count)[self openCode:self.visibleStocks[indexPath.row][@"code"]];}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if(self.search.searchBar.text.length||!self.visibleStocks.count)return nil;NSString *code=self.visibleStocks[indexPath.row][@"code"];
    UIContextualAction *remove=[UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"移除自選" handler:^(__kindof UIContextualAction *action,UIView *view,void (^done)(BOOL)){NSMutableArray *codes=[SXStore.sharedStore.watchCodes mutableCopy];[codes removeObject:code];[SXStore.sharedStore setWatchCodes:codes];done(YES);}];return [UISwipeActionsConfiguration configurationWithActions:@[remove]];
}
@end

@interface SXNoteController : UIViewController
@property(nonatomic,copy) NSString *code;
@property(nonatomic,strong) UITextView *text;
@property(nonatomic,copy) NSString *workspace;
@end
@implementation SXNoteController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"研究筆記";self.workspace=SXStore.sharedStore.activeProfileUserID;self.view.backgroundColor=UIColor.systemBackgroundColor;
    self.text=[UITextView new];self.text.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.text.adjustsFontForContentSizeCategory=YES;self.text.textContainerInset=UIEdgeInsetsMake(18,16,18,16);self.text.text=[SXStore.sharedStore valueForProfileKey:[@"note." stringByAppendingString:self.code] fallback:@""];self.text.accessibilityIdentifier=@"stock.note";
    self.text.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:self.text];[NSLayoutConstraint activateConstraints:@[[self.text.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[self.text.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[self.text.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[self.text.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor]]];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"儲存" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
}
- (void)done {
    if(![(self.workspace?:@"") isEqual:(SXStore.sharedStore.activeProfileUserID?:@"")]){SXShowError(self,@"工作區已變更",@"請重新開啟筆記。");return;}
    if(![SXStore.sharedStore setProfileValue:self.text.text?:@"" forKey:[@"note." stringByAppendingString:self.code]]){SXShowError(self,@"無法儲存",SXStore.sharedStore.persistenceError?:@"請重試。");return;}[self.text resignFirstResponder];[self.navigationController popViewControllerAnimated:YES];
}
@end

@interface SXChartFullscreenController : UIViewController
@property(nonatomic,strong) SXTradingChart *chart;
@property(nonatomic,copy) void (^closed)(void);
@end
@implementation SXChartFullscreenController
- (void)viewDidLoad {[super viewDidLoad];self.title=@"TradingView 圖表";self.view.backgroundColor=UIColor.systemBackgroundColor;self.chart.translatesAutoresizingMaskIntoConstraints=NO;[self.chart removeFromSuperview];[self.view addSubview:self.chart];[NSLayoutConstraint activateConstraints:@[[self.chart.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],[self.chart.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],[self.chart.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[self.chart.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor]]];self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStylePlain target:self action:@selector(done)];self.navigationItem.rightBarButtonItem.accessibilityIdentifier=@"chart.close";}
- (void)done {[self dismissViewControllerAnimated:!SXReducedMotion() completion:self.closed];}
@end

@interface SXStockController ()
@property(nonatomic,copy) NSString *code;
@property(nonatomic,strong) NSArray *rows;
@property(nonatomic,strong) NSArray *fields;
@property(nonatomic,strong) NSString *source;
@property(nonatomic,strong) NSString *message;
@property(nonatomic,strong) SXTradingChart *chart;
@property(nonatomic,strong) UILabel *readout;
@property(nonatomic,strong) UISegmentedControl *periodControl;
@property(nonatomic,strong) UISegmentedControl *rangeControl;
@property(nonatomic,strong) UISegmentedControl *contentControl;
@property(nonatomic,strong) UIView *quoteHeader;
@property(nonatomic,strong) UIView *chartPlaceholder;
@property(nonatomic) BOOL chartInFullscreen;
@end
@implementation SXStockController
- (instancetype)initWithCode:(NSString *)code {if((self=[super initWithStyle:UITableViewStyleInsetGrouped])){self.code=code;self.rows=@[];self.fields=@[];self.message=@"正在讀取交易所行情…";}return self;}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=self.code;self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=70;
    self.chart=[[SXTradingChart alloc] initWithFrame:CGRectZero];self.readout=MarketLabel(@"長按十字線看開高低收；雙指縮放、左右拖曳",UIFontTextStyleCaption1,UIColor.secondaryLabelColor);self.readout.accessibilityIdentifier=@"chart.readout";__weak typeof(self) weak=self;self.chart.readoutChanged=^(NSString *text){weak.readout.text=text;};
    id averages=[SXStore.sharedStore valueForProfileKey:@"chart.averages" fallback:@[@5,@20]];self.chart.averages=[averages isKindOfClass:NSArray.class]?averages:@[@5,@20];
    self.periodControl=[[UISegmentedControl alloc] initWithItems:@[@"日K",@"週K",@"15分"]];self.periodControl.selectedSegmentIndex=0;self.periodControl.accessibilityIdentifier=@"chart.period";[self.periodControl addTarget:self action:@selector(periodChanged) forControlEvents:UIControlEventValueChanged];
    self.rangeControl=[[UISegmentedControl alloc] initWithItems:@[@"1月",@"3月",@"1年",@"全部"]];self.rangeControl.selectedSegmentIndex=1;self.rangeControl.accessibilityIdentifier=@"chart.range";[self.rangeControl addTarget:self action:@selector(rangeChanged) forControlEvents:UIControlEventValueChanged];
    self.contentControl=[[UISegmentedControl alloc] initWithItems:@[@"價格圖表",@"基本面",@"技術指標",@"研究筆記"]];self.contentControl.selectedSegmentIndex=0;[self.contentControl addTarget:self action:@selector(contentChanged) forControlEvents:UIControlEventValueChanged];
    UIButton *research=SXIconButton(@"建立研究",@"sparkles",[UIAction actionWithHandler:^(__kindof UIAction *action){[weak research];}]);research.accessibilityIdentifier=@"stock.research";
    UIButton *star=SXIconButton(@"加入或移除自選",@"star",[UIAction actionWithHandler:^(__kindof UIAction *action){NSMutableArray *codes=[SXStore.sharedStore.watchCodes mutableCopy];if([codes containsObject:weak.code])[codes removeObject:weak.code];else[codes addObject:weak.code];[SXStore.sharedStore setWatchCodes:codes];}]);
    self.navigationItem.rightBarButtonItems=@[[[UIBarButtonItem alloc] initWithCustomView:research],[[UIBarButtonItem alloc] initWithCustomView:star]];
    self.refreshControl=[UIRefreshControl new];[self.refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(quoteChanged) name:SXQuotesDidChangeNotification object:nil];[NSNotificationCenter.defaultCenter addObserver:self selector:@selector(preferencesChanged) name:SXStoreDidChangeNotification object:nil];[self buildQuoteHeader];[self refresh];
}
- (void)dealloc {[NSNotificationCenter.defaultCenter removeObserver:self];}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];if(fabs(self.quoteHeader.bounds.size.width-self.tableView.bounds.size.width)>1)[self buildQuoteHeader];}
- (void)traitCollectionDidChange:(UITraitCollection *)previous {[super traitCollectionDidChange:previous];BOOL changed=previous.userInterfaceStyle!=self.traitCollection.userInterfaceStyle||![previous.preferredContentSizeCategory isEqual:self.traitCollection.preferredContentSizeCategory];if(changed&&self.isViewLoaded&&self.contentControl&&!self.presentedViewController){[self buildQuoteHeader];[self.tableView reloadData];}}
- (void)quoteChanged {[self buildQuoteHeader];}
- (void)preferencesChanged {if(!self.presentedViewController){[self buildQuoteHeader];[self.chart render];[self.tableView reloadData];}}
- (void)buildQuoteHeader {
    NSDictionary *stock=[SXStore.sharedStore stockForCode:self.code],*quote=SXStore.sharedStore.quotes[self.code];UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,self.tableView.bounds.size.width,UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)?260:170)];
    UILabel *company=MarketLabel(stock[@"alias"]?:stock[@"name"]?:self.code,UIFontTextStyleSubheadline,UIColor.secondaryLabelColor);
    UILabel *price=MarketLabel(SXMoney(quote[@"price"],[stock[@"market"] isEqual:@"TW"]?@"TWD":@"USD"),UIFontTextStyleLargeTitle,UIColor.labelColor);price.numberOfLines=1;price.adjustsFontSizeToFitWidth=YES;
    UILabel *delta=MarketLabel(SXQuoteDelta(quote),UIFontTextStyleHeadline,SXChangeColor(MarketChange(quote)));UIStackView *values=MarketStack(@[price,delta],UILayoutConstraintAxisHorizontal,12);values.alignment=UIStackViewAlignmentFirstBaseline;
    UILabel *time=MarketLabel([NSString stringWithFormat:@"%@ · %@",quote[@"source"]?:@"交易所來源",SXQuoteLabel(quote,[SXStore.sharedStore.quoteErrors containsObject:self.code])],UIFontTextStyleCaption1,UIColor.secondaryLabelColor);
    [self.contentControl removeFromSuperview];UIStackView *stack=MarketStack(@[company,values,time,self.contentControl],UILayoutConstraintAxisVertical,9);MarketPin(stack,header,16);self.quoteHeader=header;self.tableView.tableHeaderView=header;
}
- (void)refresh {
    [SXStore.sharedStore refreshQuotesForCodes:@[self.code] completion:^{[self.refreshControl endRefreshing];}];
    [[SXMarketData shared] historyForCode:self.code completion:^(NSDictionary *value,NSError *error){if(value){self.rows=value[@"rows"]?:@[];self.source=value[@"source"];self.chart.rows=self.rows;[self.chart render];self.message=[NSString stringWithFormat:@"TradingView Lightweight Charts · %@ 日成交資料",self.source];}else self.message=error.localizedDescription?:@"圖表資料暫缺";[self.tableView reloadData];}];
    NSString *symbol=[[SXStore.sharedStore sourceSymbolForCode:self.code] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    [[SXAPI sharedAPI] requestPath:[NSString stringWithFormat:@"/api/fundamentals?symbol=%@",symbol] method:@"GET" body:nil completion:^(id json,NSInteger status,NSError *error){self.fields=!error&&[json[@"fields"] isKindOfClass:NSArray.class]?json[@"fields"]:@[];if(self.contentControl.selectedSegmentIndex==1)[self.tableView reloadData];}];
}
- (void)periodChanged {
    if(self.periodControl.selectedSegmentIndex==2){NSDictionary *stock=[SXStore.sharedStore stockForCode:self.code];NSString *symbol=self.code;if([stock[@"market"] isEqual:@"TW"])symbol=[NSString stringWithFormat:@"%@:%@",[stock[@"exchange"] isEqual:@"上櫃"]?@"TPEX":@"TWSE",self.code];[self.chart showIntradayForSymbol:symbol];self.rangeControl.enabled=NO;}
    else {self.rangeControl.enabled=YES;self.chart.period=self.periodControl.selectedSegmentIndex?@"week":@"day";[self.chart useLocalChart];}
}
- (void)rangeChanged {self.chart.visibleBars=[@[@22,@66,@252,@0][self.rangeControl.selectedSegmentIndex] integerValue];[self.chart render];[self.chart reset];}
- (void)contentChanged {
    if(self.contentControl.selectedSegmentIndex==3){self.contentControl.selectedSegmentIndex=0;SXNoteController *note=[SXNoteController new];note.code=self.code;[self.navigationController pushViewController:note animated:YES];return;}
    SXTransition(self.tableView,^{[self.tableView reloadData];});
}
- (void)research {SXResearchController *controller=(SXResearchController *)((UINavigationController *)self.tabBarController.viewControllers[2]).viewControllers.firstObject;[controller openSetupForCode:self.code fromNavigation:self.navigationController];}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return self.contentControl.selectedSegmentIndex==0?4:self.contentControl.selectedSegmentIndex==1?MAX(1,self.fields.count):3;}
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)path {if(self.contentControl.selectedSegmentIndex==0){if(path.row==0||path.row==2)return 52;if(path.row==3)return UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory)?150:72;if(path.row==1)return MAX(250,MIN(340,self.view.bounds.size.height*.42));return UITableViewAutomaticDimension;}return UITableViewAutomaticDimension;}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {return self.contentControl.selectedSegmentIndex==0?self.message:self.contentControl.selectedSegmentIndex==1?@"公開基本面資料；來源缺漏時保留空值。":@"以已載入的日 K 計算，不是模型預測。";}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.selectionStyle=UITableViewCellSelectionStyleNone;cell.textLabel.numberOfLines=cell.detailTextLabel.numberOfLines=0;
    if(self.contentControl.selectedSegmentIndex==0){
        if(path.row==0){[self.periodControl removeFromSuperview];MarketPin(self.periodControl,cell.contentView,8);}
        if(path.row==1){UIView *plot=self.chartInFullscreen?self.chartPlaceholder:self.chart;if(plot){[plot removeFromSuperview];MarketPin(plot,cell.contentView,0);}}
        if(path.row==2){
            __weak typeof(self) weak=self;UIButton *ma=SXIconButton(@"設定均線",@"slider.horizontal.3",[UIAction actionWithHandler:^(__kindof UIAction *a){[weak editAverages];}]);ma.accessibilityIdentifier=@"chart.indicators";
            UIButton *reset=SXIconButton(@"重設圖表",@"arrow.counterclockwise",[UIAction actionWithHandler:^(__kindof UIAction *a){[weak.chart reset];}]);reset.accessibilityIdentifier=@"chart.reset";
            UIButton *full=SXIconButton(@"全螢幕圖表",@"arrow.up.left.and.arrow.down.right",[UIAction actionWithHandler:^(__kindof UIAction *a){[weak fullscreen];}]);full.accessibilityIdentifier=@"chart.fullscreen";
            [self.rangeControl removeFromSuperview];UIStackView *tools=MarketStack(@[self.rangeControl,ma,reset,full],UILayoutConstraintAxisHorizontal,5);tools.alignment=UIStackViewAlignmentCenter;MarketPin(tools,cell.contentView,4);
        }
        if(path.row==3){[self.readout removeFromSuperview];MarketPin(self.readout,cell.contentView,10);}
    }else if(self.contentControl.selectedSegmentIndex==1){if(self.fields.count){NSDictionary *field=self.fields[path.row];cell.textLabel.text=[field[@"label"] description];cell.detailTextLabel.text=[field[@"value"] isKindOfClass:NSString.class]?field[@"value"]:@"資料暫缺";}else cell.textLabel.text=@"尚無可驗證基本面資料";}
    else {NSArray *periods=@[@5,@20,@60];NSInteger n=[periods[path.row] integerValue];cell.textLabel.text=[NSString stringWithFormat:@"MA%ld 日均線",(long)n];if(self.rows.count>=(NSUInteger)n){double sum=0;for(NSDictionary *row in [self.rows subarrayWithRange:NSMakeRange(self.rows.count-n,n)])sum+=[row[@"close"] doubleValue];cell.detailTextLabel.text=SXFormatNumber(@(sum/n),2);}else cell.detailTextLabel.text=@"交易日資料不足";}
    return cell;
}
- (void)editAverages {
    if(self.periodControl.selectedSegmentIndex==2){SXShowError(self,@"TradingView 指標",@"15 分圖請使用圖表內的指標選單；日 K 與週 K 使用這裡保存的均線設定。");return;}
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"均線週期" message:@"最多四條，1–500 期；留白隱藏。資料不足的均線不會補造。" preferredStyle:UIAlertControllerStyleAlert];
    for(NSUInteger i=0;i<4;i++)[alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=[NSString stringWithFormat:@"均線 %lu",(unsigned long)i+1];field.keyboardType=UIKeyboardTypeNumberPad;field.text=i<self.chart.averages.count?[self.chart.averages[i] stringValue]:@"";field.accessibilityIdentifier=[NSString stringWithFormat:@"chart.ma.%lu",(unsigned long)i];}];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert=alert;UIAlertAction *save=[UIAlertAction actionWithTitle:@"套用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){NSMutableOrderedSet *periods=[NSMutableOrderedSet new];for(UITextField *field in weakAlert.textFields){NSString *text=[field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];if(!text.length)continue;NSScanner *scanner=[NSScanner scannerWithString:text];NSInteger value;if(![scanner scanInteger:&value]||!scanner.isAtEnd||value<1||value>500){SXShowError(self,@"週期無效",@"請輸入 1 到 500 的整數。");return;}[periods addObject:@(value)];}if(![SXStore.sharedStore setProfileValue:periods.array forKey:@"chart.averages"]){SXShowError(self,@"未儲存",@"請重試。");return;}self.chart.averages=periods.array;[self.chart render];}];save.accessibilityIdentifier=@"chart.ma.save";[alert addAction:save];[self presentViewController:alert animated:YES completion:nil];
}
- (void)fullscreen {
    if(self.chartInFullscreen)return;self.chartPlaceholder=[self.chart snapshotViewAfterScreenUpdates:NO];UIView *parent=self.chart.superview;if(parent&&self.chartPlaceholder)MarketPin(self.chartPlaceholder,parent,0);self.chartInFullscreen=YES;
    SXChartFullscreenController *controller=[SXChartFullscreenController new];controller.chart=self.chart;__weak typeof(self) weak=self;controller.closed=^{SXStockController *stock=weak;if(!stock)return;stock.chartInFullscreen=NO;[stock.chart removeFromSuperview];[stock.tableView reloadData];[stock.tableView layoutIfNeeded];[stock.chartPlaceholder removeFromSuperview];stock.chartPlaceholder=nil;};
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:controller];nav.modalPresentationStyle=UIModalPresentationFullScreen;[self presentViewController:nav animated:!SXReducedMotion() completion:nil];
}
@end

@interface SXNewsController () <UICalendarViewDelegate,UICalendarSelectionSingleDateDelegate>
@property(nonatomic,strong) UISegmentedControl *scope;
@property(nonatomic,strong) NSArray *items;
@property(nonatomic,strong) NSArray *events;
@property(nonatomic,copy) NSString *message;
@property(nonatomic,copy) NSString *kind;
@property(nonatomic) NSInteger days;
@property(nonatomic,strong) UICalendarView *calendar;
@property(nonatomic,copy) NSString *selectedDay;
@end
@implementation SXNewsController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];if(self.scope&&fabs(self.tableView.tableHeaderView.bounds.size.width-self.tableView.bounds.size.width)>1)[self buildHeader];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"情報";self.items=@[];self.events=@[];self.kind=@"all";self.days=7;self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=100;self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;
    self.scope=[[UISegmentedControl alloc] initWithItems:@[@"自選",@"市場",@"日曆"]];self.scope.accessibilityIdentifier=@"news.scope";self.scope.selectedSegmentIndex=0;[self.scope addTarget:self action:@selector(scopeChanged) forControlEvents:UIControlEventValueChanged];
    UIButton *filter=SXIconButton(@"篩選情報",@"line.3.horizontal.decrease",[UIAction actionWithHandler:^(__kindof UIAction *a){}]);filter.showsMenuAsPrimaryAction=YES;__weak typeof(self) weak=self;NSMutableArray *actions=[NSMutableArray new];for(NSArray *item in @[@[@"all",@"全部"],@[@"company",@"公司"],@[@"macro",@"政策與總經"],@[@"saved",@"已收藏"]])[actions addObject:[UIAction actionWithTitle:item[1] image:nil identifier:nil handler:^(__kindof UIAction *a){weak.kind=item[0];[weak.tableView reloadData];}]];filter.menu=[UIMenu menuWithChildren:actions];self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:filter];
    self.refreshControl=[UIRefreshControl new];[self.refreshControl addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];[self buildHeader];[self refresh];
}
- (void)buildHeader {
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,MAX(280,self.tableView.bounds.size.width),self.scope.selectedSegmentIndex==2?390:58)];[self.scope removeFromSuperview];self.scope.translatesAutoresizingMaskIntoConstraints=NO;[header addSubview:self.scope];[NSLayoutConstraint activateConstraints:@[[self.scope.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:20],[self.scope.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-20],[self.scope.topAnchor constraintEqualToAnchor:header.topAnchor constant:8],[self.scope.heightAnchor constraintEqualToConstant:34]]];
    if(self.scope.selectedSegmentIndex==2){if(!self.calendar){self.calendar=[UICalendarView new];self.calendar.delegate=self;self.calendar.selectionBehavior=[[UICalendarSelectionSingleDate alloc] initWithDelegate:self];self.calendar.accessibilityIdentifier=@"news.calendar";self.calendar.locale=[NSLocale localeWithLocaleIdentifier:@"zh_TW"];self.calendar.timeZone=[NSTimeZone timeZoneWithName:@"Asia/Taipei"];}[self.calendar removeFromSuperview];self.calendar.translatesAutoresizingMaskIntoConstraints=NO;[header addSubview:self.calendar];[NSLayoutConstraint activateConstraints:@[[self.calendar.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],[self.calendar.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-16],[self.calendar.topAnchor constraintEqualToAnchor:header.topAnchor constant:54],[self.calendar.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-12]]];}self.tableView.tableHeaderView=header;
}
- (void)scopeChanged {[self buildHeader];[self.tableView reloadData];[self refresh];}
- (NSArray *)visibleItems {
    if(self.scope.selectedSegmentIndex==2){if(!self.selectedDay.length)return self.events;return [self.events filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings){return [SXCalendarDay(item[@"date"]) isEqual:self.selectedDay];}]];}
    NSArray *saved=[SXStore.sharedStore valueForProfileKey:@"intel.bookmarks" fallback:@[]];return [self.items filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings){return [self.kind isEqual:@"all"]||([self.kind isEqual:@"saved"]?[saved containsObject:item[@"id"]?:item[@"url"]]:[item[@"kind"] isEqual:self.kind]);}]];
}
- (void)refresh {
    self.message=@"正在整理公開情報…";NSArray *codes=self.scope.selectedSegmentIndex==0?SXStore.sharedStore.watchCodes:@[@"MARKET"];
    if(!codes.count){self.items=@[];self.message=@"先加入自選股票，即可在這裡追蹤公司消息。";[self.refreshControl endRefreshing];[self.tableView reloadData];return;}
    codes=[codes subarrayWithRange:NSMakeRange(0,MIN(4,codes.count))];NSInteger scope=self.scope.selectedSegmentIndex;__block NSUInteger pending=codes.count;NSMutableDictionary *items=[NSMutableDictionary new],*events=[NSMutableDictionary new];
    for(NSString *code in codes){NSString *path=[NSString stringWithFormat:@"/api/news?symbol=%@&days=%ld",[[SXStore.sharedStore sourceSymbolForCode:code] stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet],(long)self.days];
        [[SXAPI sharedAPI] requestPath:path method:@"GET" body:nil completion:^(id json,NSInteger status,NSError *error){
            if(scope!=self.scope.selectedSegmentIndex)return;
            if(!error&&[json isKindOfClass:NSDictionary.class]){for(NSDictionary *item in [json[@"items"] isKindOfClass:NSArray.class]?json[@"items"]:@[]){NSString *url=[item[@"url"] isKindOfClass:NSString.class]?item[@"url"]:@"",*source=[item[@"source"] description];if([url.lowercaseString containsString:@"yahoo."]||[source.lowercaseString containsString:@"yahoo"]||![item[@"titleZh"] isKindOfClass:NSString.class])continue;items[item[@"id"]?:url]=item;}for(NSDictionary *event in [json[@"upcoming"] isKindOfClass:NSArray.class]?json[@"upcoming"]:@[])if([event isKindOfClass:NSDictionary.class])events[[event[@"date"] description]?:@""]=event;}
            if(--pending==0){self.items=[items.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [[b[@"date"] description] compare:[a[@"date"] description]];}];self.events=[events.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [[a[@"date"] description] compare:[b[@"date"] description]];}];self.message=self.items.count?@"公開來源 · 長按收藏；點擊閱讀原文":@"目前沒有符合條件的中文情報。";[self.refreshControl endRefreshing];[self.tableView reloadData];}
        }];
    }
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {return MAX(1,[self visibleItems].count)+1;}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {return self.scope.selectedSegmentIndex==2?@"BLS 等公開日程 · 台北時間":self.message;}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    NSArray *items=[self visibleItems];UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.textLabel.numberOfLines=3;cell.textLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];cell.detailTextLabel.numberOfLines=2;
    if(path.row==MAX(1,items.count)){cell.textLabel.text=self.scope.selectedSegmentIndex==2?@"更新公開日程":@"載入較早情報";cell.textLabel.textColor=self.view.tintColor;return cell;}
    if(!items.count){cell.textLabel.text=self.scope.selectedSegmentIndex==2?@"這天沒有已取得的經濟事件":self.message;return cell;}
    NSDictionary *item=items[path.row];cell.textLabel.text=item[@"titleZh"]?:item[@"nameZh"]?:item[@"title"]?:item[@"name"]?:@"經濟公告";cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@",item[@"source"]?:@"公開日程",SXDateLabel(item[@"date"])];cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];NSArray *items=[self visibleItems];if(path.row==MAX(1,items.count)){if(self.scope.selectedSegmentIndex!=2)self.days=MIN(90,self.days+14);[self refresh];return;}if(!items.count)return;
    NSURL *url=[NSURL URLWithString:items[path.row][@"url"]?:@""];if([url.scheme isEqual:@"https"]&&!([url.host.lowercaseString containsString:@"yahoo."]))[self presentViewController:[[SFSafariViewController alloc] initWithURL:url] animated:YES completion:nil];
}
- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)path point:(CGPoint)point {
    NSArray *items=[self visibleItems];if(path.row>=items.count)return nil;NSDictionary *item=items[path.row];NSString *identifier=item[@"id"]?:item[@"url"];if(!identifier)return nil;
    return [UIContextMenuConfiguration configurationWithIdentifier:identifier previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested){BOOL saved=[[SXStore.sharedStore valueForProfileKey:@"intel.bookmarks" fallback:@[]] containsObject:identifier];return [UIMenu menuWithChildren:@[[UIAction actionWithTitle:saved?@"取消收藏":@"收藏情報" image:[UIImage systemImageNamed:saved?@"bookmark.slash":@"bookmark"] identifier:nil handler:^(__kindof UIAction *action){NSMutableArray *bookmarks=[[SXStore.sharedStore valueForProfileKey:@"intel.bookmarks" fallback:@[]] mutableCopy];if([bookmarks containsObject:identifier])[bookmarks removeObject:identifier];else[bookmarks addObject:identifier];[SXStore.sharedStore setProfileValue:bookmarks forKey:@"intel.bookmarks"];[self.tableView reloadData];}]]];}];
}
- (void)dateSelection:(UICalendarSelectionSingleDate *)selection didSelectDate:(NSDateComponents *)dateComponents {self.selectedDay=dateComponents?[NSString stringWithFormat:@"%04ld-%02ld-%02ld",(long)dateComponents.year,(long)dateComponents.month,(long)dateComponents.day]:nil;[self.tableView reloadData];}
@end
