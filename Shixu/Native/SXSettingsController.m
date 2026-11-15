#import "SXSettingsController.h"
#import "SXStore.h"
#import "SXAPI.h"
#import "SXSession.h"
#import "SXUI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <math.h>

static NSString *SXSettingsText(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }
static NSDictionary *SXSettingsDictionary(id value) { return [value isKindOfClass:NSDictionary.class] ? value : @{}; }

@interface SXSettingsController () <UIDocumentPickerDelegate>
@property(nonatomic,strong) SXStore *store;
@property(nonatomic,strong) NSDictionary *accountStatus;
@property(nonatomic,copy) NSString *statusMessage;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL statusLoaded;
@property(nonatomic) BOOL conflict;
@property(nonatomic) BOOL accountVerified;
@property(nonatomic) NSUInteger requestGeneration;
@end

@implementation SXSettingsController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad]; self.store = [SXStore sharedStore]; self.title = @"設定";
    self.tableView.rowHeight = UITableViewAutomaticDimension; self.tableView.estimatedRowHeight = 70;
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor; self.statusMessage = @"";
    self.refreshControl = [UIRefreshControl new]; [self.refreshControl addTarget:self action:@selector(refreshStatus) forControlEvents:UIControlEventValueChanged];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(storeChanged:) name:SXStoreDidChangeNotification object:nil];
    [self applyTheme]; [self refreshStatus];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self applyTheme]; [self.tableView reloadData]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)storeChanged:(NSNotification *)notification { [self applyTheme]; [self.tableView reloadData]; }
- (BOOL)signedIn { return [self.accountStatus[@"signedIn"] isEqual:@YES]; }
- (BOOL)isCurrentController {return self.tabBarController&&[self.tabBarController.viewControllers containsObject:self.navigationController];}
- (BOOL)requestCurrent:(NSUInteger)generation userID:(NSString *)userID {return generation==self.requestGeneration&&[self isCurrentController]&&((!userID&&!self.store.activeProfileUserID)||[userID isEqual:self.store.activeProfileUserID]);}
- (NSString *)statusUserID {return SXSettingsText(SXSettingsDictionary(self.accountStatus[@"user"])[@"id"]);}
- (void)withVerifiedAccount:(void (^)(NSString *,NSUInteger))action {
 if(self.busy||!self.signedIn||!self.accountVerified)return;NSString *expected=self.statusUserID;
 if(!expected.length||![expected isEqual:self.store.activeProfileUserID]){self.accountVerified=NO;SXShowError(self,@"帳號未確認",@"目前工作區與登入帳號不同，請重新檢查帳號。");return;}
 self.busy=YES;NSUInteger generation=++self.requestGeneration;__weak typeof(self) weakSelf=self;
 [[SXAPI sharedAPI] requestPath:@"/api/account/status" method:@"GET" body:nil completion:^(id json,NSInteger status,NSError *error){SXSettingsController *controller=weakSelf;if(!controller||![controller requestCurrent:generation userID:expected])return;
 if(![controller checkResponse:json status:status error:error])return;NSString *actual=SXSettingsText(SXSettingsDictionary(json[@"user"])[@"id"]);
 if(![json[@"signedIn"] isEqual:@YES]||![actual isEqual:expected]){controller.accountVerified=NO;[controller finishWithMessage:@"登入帳號已變更，未傳送或還原任何資料。請重新檢查帳號。"];SXShowError(controller,@"帳號已變更",controller.statusMessage);return;}action(expected,generation);
 }];
}
- (void)applyTheme {
    id theme = [self.store setting:@"theme" fallback:@"system"];
    UIUserInterfaceStyle style = [theme isEqual:@"light"] ? UIUserInterfaceStyleLight : [@[@"dark", @"black", @"navy"] containsObject:theme] ? UIUserInterfaceStyleDark : UIUserInterfaceStyleUnspecified;
    UIViewController *root = self.tabBarController ?: self.navigationController ?: self;
    root.overrideUserInterfaceStyle = style;
}
- (NSString *)themeName {
    id theme = [self.store setting:@"theme" fallback:@"system"];
    return [theme isEqual:@"light"] ? @"淺色" : [@[@"dark", @"black", @"navy"] containsObject:theme] ? @"深色" : @"跟隨系統";
}
- (void)setBusy:(BOOL)busy {
    _busy = busy; if (self.isViewLoaded) [self.tableView reloadData];
}
- (void)finishWithMessage:(NSString *)message {
    self.statusMessage = message ?: @""; self.busy = NO; [self.refreshControl endRefreshing]; [self.tableView reloadData];
}
- (BOOL)checkResponse:(id)json status:(NSInteger)status error:(NSError *)error {
    if (!error && status >= 200 && status < 300 && [json isKindOfClass:NSDictionary.class]) return YES;
    NSString *message = status == 409 ? @"另一個裝置已有較新的雲端備份。這次沒有覆寫，也不會自動重試；請先還原雲端。" : SXSettingsText(SXSettingsDictionary(json)[@"error"]);
    if (!message.length) message = error.localizedDescription ?: @"目前無法連線，請稍後重試。";
    if (status == 409) self.conflict = YES;
    if((error&&status==0)||status==401)self.accountVerified=NO;
    [self finishWithMessage:message]; if(!self.presentedViewController)SXShowError(self, status == 409 ? @"備份版本衝突" : @"操作未完成", message); return NO;
}
- (void)refreshStatus {
    if (self.busy) { [self.refreshControl endRefreshing]; return; }
    self.busy = YES;self.accountVerified=NO;NSUInteger generation=++self.requestGeneration;
    __weak typeof(self) weakSelf = self;
    [[SXAPI sharedAPI] requestPath:@"/api/account/status" method:@"GET" body:nil completion:^(id json, NSInteger status, NSError *error) {
        SXSettingsController *controller = weakSelf; if (!controller||generation!=controller.requestGeneration||![controller isCurrentController]) return;
        if (![controller checkResponse:json status:status error:error]) return;
        NSString *userID=SXSettingsText(SXSettingsDictionary(json[@"user"])[@"id"]);NSError *workspaceError=nil;
        if(([json[@"signedIn"] isEqual:@YES]&&!userID.length)||![controller.store activateProfileForUserID:[json[@"signedIn"] isEqual:@YES]?userID:nil error:&workspaceError]){[controller finishWithMessage:workspaceError.localizedDescription?:@"帳號身分無法驗證，工作區未變更。"];SXShowError(controller,@"工作區未切換",controller.statusMessage);return;}
        if(![controller isCurrentController])return;
        controller.accountStatus = json; controller.statusLoaded = YES;controller.accountVerified=[json[@"signedIn"] isEqual:@YES]&&[userID isEqual:controller.store.activeProfileUserID];
        controller.store.accountIdentityResolved=YES;
        [controller finishWithMessage:controller.conflict ? @"版本衝突尚未處理，請先還原雲端備份。" : @""];
    }];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)logicalSection:(NSInteger)section {return [@[@0,@2,@1,@3][section] integerValue];}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    section=[self logicalSection:section];if (section == 0) return 4; if (section == 1) return self.signedIn ? 6 : 3; if (section == 2) return 4; return 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    section=[self logicalSection:section];
    return @[@"外觀", @"Google 帳號與雲端備份", self.store.activeProfileUserID?@"目前帳號工作區":@"未登入的本機工作區", @"關於拾序"][(NSUInteger)section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    section=[self logicalSection:section];
    if (section == 0) return @"使用 iOS 系統外觀；系統選擇會隨手機的淺色、深色模式切換。";
    if (section == 1) {
        NSString *note = @"每個 Google 帳號與未登入資料分開儲存。只會備份目前帳號工作區；這個版本不會自動備份。還原會先保存本機副本。";
        if(self.store.persistenceError)note=[@"本機工作區目前無法正常讀取或保存，雲端備份已停用；可以從雲端或檔案還原。\n" stringByAppendingString:note];
        return self.statusMessage.length ? [NSString stringWithFormat:@"%@\n%@", self.statusMessage, note] : note;
    }
    if (section == 2) return @"匯入或還原會替換原生資料，不會合併兩份持股。替換前會先保存本機副本；舊版 App 的資料不會被刪除。";
    return @"行情來源失敗時不補造價格。AI 分析只會在你明確啟動推演後呼叫。";
}
- (UITableViewCell *)detailCell:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol disclosure:(BOOL)disclosure {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.text = title; cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody]; cell.textLabel.numberOfLines = 0; cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.text = detail; cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]; cell.detailTextLabel.numberOfLines = 0; cell.detailTextLabel.adjustsFontForContentSizeCategory = YES; cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = [UIImage systemImageNamed:symbol]; cell.imageView.tintColor = self.view.tintColor;
    cell.accessoryType = disclosure ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    cell.selectionStyle = disclosure && !self.busy ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    return cell;
}
- (UITableViewCell *)buttonCell:(NSString *)title symbol:(NSString *)symbol enabled:(BOOL)enabled action:(void (^)(void))action {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil]; cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIButton *button = SXGlassButton(title, symbol, [UIAction actionWithHandler:^(__kindof UIAction *sender) { if (action) action(); }]);
    button.enabled = enabled && !self.busy; button.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:button];
    [NSLayoutConstraint activateConstraints:@[[button.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor], [button.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor], [button.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:9], [button.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-9]]];
    return cell;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    indexPath=[NSIndexPath indexPathForRow:indexPath.row inSection:[self logicalSection:indexPath.section]];
    __weak typeof(self) weakSelf = self; NSInteger row = indexPath.row;
    if (indexPath.section == 0) {if(row==0)return [self detailCell:@"外觀模式" detail:self.themeName symbol:@"circle.lefthalf.filled" disclosure:YES];if(row==1)return [self detailCell:@"漲跌顏色" detail:[[self.store setting:@"up" fallback:@"green"] isEqual:@"red"]?@"紅漲綠跌":@"綠漲紅跌" symbol:@"arrow.up.arrow.down" disclosure:YES];if(row==2)return [self detailCell:@"預設市場" detail:[[self.store setting:@"market" fallback:@"US"] isEqual:@"TW"]?@"台股":@"美股" symbol:@"globe" disclosure:YES];return [self detailCell:@"減少動態" detail:SXReducedMotion()?@"已開啟":@"跟隨系統與標準動畫" symbol:@"figure.walk" disclosure:YES];}
    if (indexPath.section == 1) {
        if (row == 0) {
            NSDictionary *user = SXSettingsDictionary(self.accountStatus[@"user"]), *backup = SXSettingsDictionary(self.accountStatus[@"backup"]);
            NSString *name = SXSettingsText(user[@"name"]), *email = SXSettingsText(user[@"email"]);
            NSString *title = self.signedIn ? (name.length ? name : @"Google 帳號已登入") : self.busy ? @"正在檢查帳號…" : @"尚未登入 Google";
            NSString *detail = self.signedIn ? [NSString stringWithFormat:@"%@\n%@", email, backup.count ? [NSString stringWithFormat:@"雲端備份第 %@ 版 · %@", backup[@"revision"] ?: @"—", SXDateLabel(backup[@"updatedAt"])] : @"尚無雲端備份"] : self.statusLoaded && ![self.accountStatus[@"configured"] isEqual:@YES] ? @"Google 登入設定尚未完成，目前資料保存在這個裝置。" : @"登入後可手動備份與還原原生資料。";
            return [self detailCell:title detail:detail symbol:self.signedIn ? @"person.crop.circle.badge.checkmark" : @"person.crop.circle" disclosure:NO];
        }
        if (row == 1) return [self buttonCell:@"重新檢查帳號" symbol:@"arrow.clockwise" enabled:YES action:^{ [weakSelf refreshStatus]; }];
        if (!self.signedIn) return [self buttonCell:@"使用 Google 登入" symbol:@"person.crop.circle.badge.plus" enabled:self.statusLoaded && [self.accountStatus[@"configured"] isEqual:@YES] action:^{ [weakSelf signIn]; }];
        if (row == 2) return [self buttonCell:@"備份本機" symbol:@"icloud.and.arrow.up" enabled:self.accountVerified&&!self.conflict&&!self.store.persistenceError action:^{ [weakSelf confirmBackup]; }];
        if (row == 3) return [self buttonCell:@"還原雲端" symbol:@"icloud.and.arrow.down" enabled:self.accountVerified&&(self.conflict || SXSettingsDictionary(self.accountStatus[@"backup"]).count > 0) action:^{ [weakSelf fetchCloudRestore]; }];
        if(row==4)return [self buttonCell:@"將本機資料複製到此帳號" symbol:@"doc.on.doc" enabled:self.accountVerified&&self.store.profile.count==0&&!self.store.persistenceError action:^{[weakSelf confirmCopyLocal];}];
        return [self buttonCell:@"登出 Google" symbol:@"rectangle.portrait.and.arrow.right" enabled:YES action:^{ [weakSelf confirmSignOut]; }];
    }
    if (indexPath.section == 2) {
        if (row == 0) return [self localButtonCell:@"匯出本機備份" symbol:@"square.and.arrow.up" action:^{ [weakSelf exportLocal]; }];
        if (row == 1) return [self localButtonCell:@"從檔案匯入備份" symbol:@"square.and.arrow.down" action:^{ [weakSelf importLocal]; }];
        if(row==2)return [self localButtonCell:@"預覽並移轉舊版資料" symbol:@"arrow.triangle.2.circlepath" action:^{[weakSelf migrateLegacy];}];
        return [self localButtonCell:@"還原前副本" symbol:@"clock.arrow.circlepath" action:^{[weakSelf showRestoreCopies];}];
    }
    if (row == 0) {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary; NSString *version = SXSettingsText(info[@"CFBundleShortVersionString"]), *build = SXSettingsText(info[@"CFBundleVersion"]);
        return [self detailCell:@"拾序 iOS 原生版" detail:[NSString stringWithFormat:@"版本 %@（%@）", version.length ? version : @"—", build.length ? build : @"—"] symbol:@"info.circle" disclosure:NO];
    }
    return [self detailCell:@"本機紀錄" detail:[NSString stringWithFormat:@"自選 %lu 檔 · 研究 %lu 份 · 持股 %lu 筆", (unsigned long)self.store.watchCodes.count, (unsigned long)self.store.runs.count, (unsigned long)([self.store.account[@"positions"] isKindOfClass:NSArray.class] ? [self.store.account[@"positions"] count] : 0)] symbol:@"externaldrive" disclosure:NO];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];if(indexPath.section!=0)return;if(indexPath.row==0){[self pickTheme];return;}if(indexPath.row==1){[self pickPreference:@"up" title:@"漲跌顏色" items:@[@[@"green",@"綠漲紅跌"],@[@"red",@"紅漲綠跌"]]];return;}if(indexPath.row==2){[self pickPreference:@"market" title:@"預設市場" items:@[@[@"US",@"美股"],@[@"TW",@"台股"]]];return;}[self pickPreference:@"reduceMotion" title:@"減少動態" items:@[@[@NO,@"跟隨系統"],@[@YES,@"減少動態"]]];
}
- (void)pickTheme {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"外觀模式" message:@"選擇 iOS 系統外觀。" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    for (NSArray *item in @[@[@"system", @"跟隨系統"], @[@"light", @"淺色"], @[@"dark", @"深色"]]) {
        [sheet addAction:[UIAlertAction actionWithTitle:item[1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            if (![weakSelf.store setSetting:item[0] forKey:@"theme"]) { SXShowError(weakSelf, @"外觀未儲存", weakSelf.store.persistenceError ?: @"本機設定無法儲存，請重試。"); return; }
            [weakSelf applyTheme]; [weakSelf.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
    sheet.popoverPresentationController.sourceView = cell ?: self.view; sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)signIn {
    if (self.busy) return; self.busy = YES;self.accountVerified=NO;NSUInteger generation=++self.requestGeneration;
    __weak typeof(self) weakSelf = self;
    [[SXSession sharedSession] signInFromController:self completion:^(BOOL success, NSError *error) {
        SXSettingsController *controller = weakSelf; if (!controller||generation!=controller.requestGeneration||![controller isCurrentController]) return;
        controller.busy = NO;
        if (success) { controller.conflict = NO; [controller refreshStatus]; }
        else if (error) { [controller finishWithMessage:error.localizedDescription]; SXShowError(controller, @"Google 登入未完成", error.localizedDescription); }
        else [controller finishWithMessage:@"登入已取消，本機資料保留。"];
    }];
}
- (void)confirmBackup {
    if (self.busy || !self.signedIn || self.conflict) return;
    NSDictionary *backup = SXSettingsDictionary(self.accountStatus[@"backup"]), *user = SXSettingsDictionary(self.accountStatus[@"user"]);
    NSString *identity = SXSettingsText(user[@"email"]).length ? user[@"email"] : @"目前 Google 帳號";
    NSString *message = [NSString stringWithFormat:@"將目前原生 App 的自選、持股與研究紀錄備份至 %@。%@", identity, backup.count ? @"這會建立新的雲端版本，取代目前可還原的版本。" : @"不會開啟自動備份。"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"備份目前本機資料？" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"備份本機" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) { [weakSelf backupLocal]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)backupLocal {
    if(self.busy||!self.signedIn||self.conflict||!self.accountVerified||self.store.persistenceError)return;
    NSDictionary *backup=SXSettingsDictionary(self.accountStatus[@"backup"]);id revision=backup[@"revision"];
    if(!SXFiniteNumber(revision)||[revision doubleValue]<0||[revision doubleValue]!=floor([revision doubleValue]))revision=@0;
    __weak typeof(self) weakSelf=self;
    [self withVerifiedAccount:^(NSString *userID,NSUInteger generation){
        SXSettingsController *controller=weakSelf;if(!controller||![controller requestCurrent:generation userID:userID])return;
        NSDictionary *body=@{@"baseRevision":revision,@"profile":@{@"version":@1,@"values":controller.store.profile}};
        [[SXAPI sharedAPI] requestPath:@"/api/account/backup" method:@"POST" body:body completion:^(id json,NSInteger status,NSError *error){
            SXSettingsController *current=weakSelf;if(!current||![current requestCurrent:generation userID:userID]||![current checkResponse:json status:status error:error])return;
            NSMutableDictionary *state=[current.accountStatus mutableCopy];state[@"backup"]=json;current.accountStatus=state;
            [current finishWithMessage:@"已手動備份目前帳號工作區。"];
            SXShowError(current,@"備份完成",@"只備份目前 Google 帳號的工作區，自動備份保持關閉。");
        }];
    }];
}
- (void)fetchCloudRestore {
    __weak typeof(self) weakSelf=self;
    [self withVerifiedAccount:^(NSString *userID,NSUInteger generation){
        [[SXAPI sharedAPI] requestPath:@"/api/account/backup" method:@"GET" body:nil completion:^(id json,NSInteger status,NSError *error){
            SXSettingsController *controller=weakSelf;if(!controller||![controller requestCurrent:generation userID:userID]||![controller checkResponse:json status:status error:error])return;
            NSDictionary *profile=[json[@"profile"] isKindOfClass:NSDictionary.class]?json[@"profile"]:nil;
            if(!profile){[controller finishWithMessage:@"雲端備份格式不正確，目前工作區保留。"];SXShowError(controller,@"無法還原",controller.statusMessage);return;}
            [controller finishWithMessage:@""];
            [controller confirmRestore:profile source:@"目前 Google 帳號的雲端備份" completion:^{
                if(![controller requestCurrent:generation userID:userID])return;
                NSMutableDictionary *state=[controller.accountStatus mutableCopy];state[@"backup"]=@{@"revision":json[@"revision"]?:@0,@"updatedAt":json[@"updatedAt"]?:NSNull.null};controller.accountStatus=state;controller.conflict=NO;[controller finishWithMessage:@"已還原此帳號的備份；還原前副本保留。"];
            }];
        }];
    }];
}
- (void)confirmCopyLocal {
    if(self.busy||!self.accountVerified||self.store.profile.count)return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"將未登入的本機資料複製到此帳號？" message:@"只複製到目前空白的 Google 帳號工作區。未登入工作區的原檔保留，不會自動送至雲端。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];__weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"複製本機資料" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[weakSelf withVerifiedAccount:^(NSString *userID,NSUInteger generation){SXSettingsController *controller=weakSelf;if(!controller||![controller requestCurrent:generation userID:userID])return;NSError *error=nil;if(![controller.store copyLocalProfileToActiveAccount:&error]){[controller finishWithMessage:error.localizedDescription];SXShowError(controller,@"未複製資料",error.localizedDescription?:@"目前帳號工作區已非空白。");return;}[controller finishWithMessage:@"已明確複製本機資料；原本本機工作區與雲端備份保留。"];}];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)confirmSignOut {
    if (self.busy || !self.signedIn) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"登出 Google 帳號？" message:@"會結束這個 App 的 Google 工作階段。本機自選、持股與研究紀錄保留。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"登出" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SXSettingsController *controller = weakSelf; if (!controller || controller.busy) return; controller.busy = YES;controller.accountVerified=NO;NSUInteger generation=++controller.requestGeneration;NSString *userID=controller.store.activeProfileUserID;
        [[SXAPI sharedAPI] requestPath:@"/api/account/sign-out" method:@"POST" body:@{} completion:^(id json, NSInteger status, NSError *error) {
            SXSettingsController *current = weakSelf; if (!current || ![current requestCurrent:generation userID:userID] || ![current checkResponse:json status:status error:error]) return;
            NSError *workspaceError=nil;if(![current.store activateProfileForUserID:nil error:&workspaceError]){[current finishWithMessage:workspaceError.localizedDescription];SXShowError(current,@"已登出，工作區未切換",workspaceError.localizedDescription?:@"本機資料無法保存，原檔保留。");return;}
            current.accountStatus = @{@"configured":@YES, @"signedIn":@NO}; current.conflict = NO;
            [current finishWithMessage:@"已登出，本機資料保留。"];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)exportLocal {
    NSError *error = nil; NSData *data = [self.store exportProfileData:&error];
    NSURL *url = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"Shixu-Backup-%@.json", NSUUID.UUID.UUIDString]];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:&error]) { SXShowError(self, @"無法匯出", error.localizedDescription ?: @"無法建立備份檔案。"); return; }
    SXShare(self, url);
}
- (UITableViewCell *)localButtonCell:(NSString *)title symbol:(NSString *)symbol action:(void (^)(void))action {
    UITableViewCell *cell=[self buttonCell:title symbol:symbol enabled:YES action:action];
    for(UIView *view in cell.contentView.subviews)if([view isKindOfClass:UIButton.class]){((UIButton *)view).enabled=YES;view.accessibilityIdentifier=[title isEqual:@"匯出本機備份"]?@"settings.export":nil;}
    return cell;
}
- (void)pickPreference:(NSString *)key title:(NSString *)title items:(NSArray *)items {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSArray *item in items)[sheet addAction:[UIAlertAction actionWithTitle:item[1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){if(![self.store setSetting:item[0] forKey:key])SXShowError(self,@"設定未儲存",self.store.persistenceError?:@"請重試。");[self.tableView reloadData];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];sheet.popoverPresentationController.sourceView=self.view;sheet.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),100,1,1);[self presentViewController:sheet animated:YES completion:nil];
}
- (void)showRestoreCopies {
    NSArray<NSURL *> *copies=[self.store restoreCopiesForActiveProfile];if(!copies.count){SXShowError(self,@"尚無還原前副本",@"每次匯入或還原前，會在目前工作區保留一份原檔。");return;}
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"還原前副本" message:@"只列出目前工作區的副本。選取後可匯出，或預覽後還原。" preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger index=0;for(NSURL *url in copies){if(index++>=8)break;NSDate *date=nil;[url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];NSString *title=[NSString stringWithFormat:@"%@ · 副本 %lu",date?SXDateLabel(@(date.timeIntervalSince1970*1000)):@"日期未記錄",(unsigned long)index];[sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){[self chooseRestoreCopy:url title:title];}]];}
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];sheet.popoverPresentationController.sourceView=self.view;sheet.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),200,1,1);[self presentViewController:sheet animated:YES completion:nil];
}
- (void)chooseRestoreCopy:(NSURL *)url title:(NSString *)title {
    if(![self isCurrentController]||![[self.store restoreCopiesForActiveProfile] containsObject:url])return;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:title message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"匯出這份副本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){if([[self.store restoreCopiesForActiveProfile] containsObject:url])SXShare(self,url);}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"預覽並還原" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){if(![[self.store restoreCopiesForActiveProfile] containsObject:url])return;self.requestGeneration+=1;self.busy=NO;self.accountVerified=NO;NSData *bytes=[NSData dataWithContentsOfURL:url];id profile=bytes.length&&bytes.length<=8*1024*1024?[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]:nil;if(![profile isKindOfClass:NSDictionary.class]){SXShowError(self,@"無法讀取副本",@"原有資料未變更。");return;}[self confirmRestore:profile source:title completion:nil];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];sheet.popoverPresentationController.sourceView=self.view;sheet.popoverPresentationController.sourceRect=CGRectMake(CGRectGetMidX(self.view.bounds),200,1,1);[self presentViewController:sheet animated:YES completion:nil];
}
- (void)importLocal {
    self.requestGeneration+=1;self.busy=NO;self.accountVerified=NO;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.delegate = self; picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.busy || ![self isCurrentController] || !urls.count) return; NSURL *url = urls.firstObject; BOOL access = [url startAccessingSecurityScopedResource];
    NSError *error = nil; NSNumber *size = nil; [url getResourceValue:&size forKey:NSURLFileSizeKey error:&error];
    NSData *data = !error && (!size || size.unsignedLongLongValue <= 8 * 1024 * 1024) ? [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:&error] : nil;
    if (access) [url stopAccessingSecurityScopedResource];
    id profile = data.length && data.length <= 8 * 1024 * 1024 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    __weak typeof(self) weakSelf = self;
    void (^finish)(void) = ^{
        SXSettingsController *settings = weakSelf; if (!settings) return;
        if (![profile isKindOfClass:NSDictionary.class]) { SXShowError(settings, @"無法匯入", @"請選擇小於 8 MB 的拾序 JSON 備份。原有資料仍保留。"); return; }
        [settings confirmRestore:profile source:@"檔案備份" completion:nil];
    };
    if (controller.presentingViewController) [controller dismissViewControllerAnimated:YES completion:finish]; else finish();
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {[self refreshStatus];}
- (void)confirmRestore:(NSDictionary *)profile source:(NSString *)source completion:(void (^ _Nullable)(void))completion {
    NSDictionary *values = SXSettingsDictionary(profile[@"values"]), *account = SXSettingsDictionary(values[@"account.v1"]);
    NSUInteger watch = [values[@"watch"] isKindOfClass:NSArray.class] ? [values[@"watch"] count] : 0;
    NSUInteger runs = [values[@"runs"] isKindOfClass:NSArray.class] ? [values[@"runs"] count] : 0;
    NSUInteger positions = [account[@"positions"] isKindOfClass:NSArray.class] ? [account[@"positions"] count] : 0;
    NSString *restoreWorkspace=self.store.activeProfileUserID;NSUInteger generation=self.requestGeneration;
    NSString *target=self.store.activeProfileUserID?@"目前 Google 帳號的工作區":@"未登入的本機工作區";
    NSString *message = [NSString stringWithFormat:@"%@\n包含自選 %lu 檔、研究 %lu 份、持股 %lu 筆。\n目標：%@。\n%@替換前會先保存本機副本；舊版資料保留。", source, (unsigned long)watch, (unsigned long)runs, (unsigned long)positions, target, [self.store hasPersonalData] ? @"目前已有個人紀錄，兩份資料不會合併。" : @""];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"確認還原備份？" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存副本並還原" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SXSettingsController *controller = weakSelf; if (!controller || controller.busy) return;
        if(![controller requestCurrent:generation userID:restoreWorkspace]){SXShowError(controller,@"工作區已變更",@"資料未還原，請在目前帳號重新選取備份。");return;}
        NSError *error = nil;
        if (![controller.store importProfile:profile replace:YES error:&error]) { SXShowError(controller, @"還原未完成", error.localizedDescription ?: @"備份格式不正確，原有資料仍保留。"); return; }
        [controller applyTheme]; [controller finishWithMessage:@"已還原備份，還原前副本已保留。"];
        if (completion) completion(); else SXShowError(controller, @"還原完成", @"原生 App 已使用這份備份。還原前的本機副本仍保留。");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)migrateLegacy {
    self.busy = YES;self.accountVerified=NO;NSUInteger generation=++self.requestGeneration;NSString *workspace=self.store.activeProfileUserID; __weak typeof(self) weakSelf = self;
    [[SXSession sharedSession] readLegacyProfileWithCompletion:^(NSDictionary *profile, NSError *error) {
        SXSettingsController *controller = weakSelf; if (!controller || ![controller requestCurrent:generation userID:workspace]) return; controller.busy = NO;
        if (error || !profile) { [controller finishWithMessage:error.localizedDescription ?: @"未取得舊版資料，原有資料仍保留。"];
            SXShowError(controller, @"讀取未完成", controller.statusMessage); return; }
        void (^done)(void) = ^{ [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"native-migration-v1"]; [controller finishWithMessage:@"已將舊版資料複製至原生 App；舊版資料保留。"];
            SXShowError(controller, @"資料已讀取", @"原生 App 已使用這份舊版備份。舊版資料與本機還原前副本仍保留。"); };
        [controller confirmRestore:profile source:@"舊版 App 資料。舊版紀錄沒有可驗證的帳號歸屬，請先確認這些是你的資料，再決定是否複製。" completion:done];
    }];
}
@end
