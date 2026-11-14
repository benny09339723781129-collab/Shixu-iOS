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
    [self finishWithMessage:message]; SXShowError(self, status == 409 ? @"備份版本衝突" : @"操作未完成", message); return NO;
}
- (void)refreshStatus {
    if (self.busy) { [self.refreshControl endRefreshing]; return; }
    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    [[SXAPI sharedAPI] requestPath:@"/api/account/status" method:@"GET" body:nil completion:^(id json, NSInteger status, NSError *error) {
        SXSettingsController *controller = weakSelf; if (!controller) return;
        if (![controller checkResponse:json status:status error:error]) return;
        controller.accountStatus = json; controller.statusLoaded = YES;
        [controller finishWithMessage:controller.conflict ? @"版本衝突尚未處理，請先還原雲端備份。" : @""];
    }];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return 1; if (section == 1) return self.signedIn ? 5 : 3; if (section == 2) return 3; return 2;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"外觀", @"Google 帳號與雲端備份", @"本機資料", @"關於拾序"][(NSUInteger)section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"使用 iOS 系統外觀；系統選擇會隨手機的淺色、深色模式切換。";
    if (section == 1) {
        NSString *note = @"雲端備份只會在你按下「備份本機」後執行；這個版本不會自動備份。還原會先在本機保存還原前副本。";
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
    __weak typeof(self) weakSelf = self; NSInteger row = indexPath.row;
    if (indexPath.section == 0) return [self detailCell:@"外觀模式" detail:self.themeName symbol:@"circle.lefthalf.filled" disclosure:YES];
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
        if (row == 2) return [self buttonCell:@"備份本機" symbol:@"icloud.and.arrow.up" enabled:!self.conflict action:^{ [weakSelf confirmBackup]; }];
        if (row == 3) return [self buttonCell:@"還原雲端" symbol:@"icloud.and.arrow.down" enabled:self.conflict || SXSettingsDictionary(self.accountStatus[@"backup"]).count > 0 action:^{ [weakSelf fetchCloudRestore]; }];
        return [self buttonCell:@"登出 Google" symbol:@"rectangle.portrait.and.arrow.right" enabled:YES action:^{ [weakSelf confirmSignOut]; }];
    }
    if (indexPath.section == 2) {
        if (row == 0) return [self buttonCell:@"匯出本機備份" symbol:@"square.and.arrow.up" enabled:YES action:^{ [weakSelf exportLocal]; }];
        if (row == 1) return [self buttonCell:@"從檔案匯入備份" symbol:@"square.and.arrow.down" enabled:YES action:^{ [weakSelf importLocal]; }];
        return [self buttonCell:@"重新讀取舊版 App 資料" symbol:@"arrow.triangle.2.circlepath" enabled:YES action:^{ [weakSelf migrateLegacy]; }];
    }
    if (row == 0) {
        NSDictionary *info = NSBundle.mainBundle.infoDictionary; NSString *version = SXSettingsText(info[@"CFBundleShortVersionString"]), *build = SXSettingsText(info[@"CFBundleVersion"]);
        return [self detailCell:@"拾序 iOS 原生版" detail:[NSString stringWithFormat:@"版本 %@（%@）", version.length ? version : @"—", build.length ? build : @"—"] symbol:@"info.circle" disclosure:NO];
    }
    return [self detailCell:@"本機紀錄" detail:[NSString stringWithFormat:@"自選 %lu 檔 · 研究 %lu 份 · 持股 %lu 筆", (unsigned long)self.store.watchCodes.count, (unsigned long)self.store.runs.count, (unsigned long)([self.store.account[@"positions"] isKindOfClass:NSArray.class] ? [self.store.account[@"positions"] count] : 0)] symbol:@"externaldrive" disclosure:NO];
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES]; if (indexPath.section == 0 && !self.busy) [self pickTheme];
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
    if (self.busy) return; self.busy = YES;
    __weak typeof(self) weakSelf = self;
    [[SXSession sharedSession] signInFromController:self completion:^(BOOL success, NSError *error) {
        SXSettingsController *controller = weakSelf; if (!controller) return;
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
    if (self.busy || !self.signedIn || self.conflict) return;
    NSDictionary *backup = SXSettingsDictionary(self.accountStatus[@"backup"]); id revision = backup[@"revision"];
    if (!SXFiniteNumber(revision) || [revision doubleValue] < 0 || [revision doubleValue] != floor([revision doubleValue])) revision = @0;
    NSDictionary *body = @{@"baseRevision":revision, @"profile":@{@"version":@1, @"values":self.store.profile}};
    self.busy = YES; __weak typeof(self) weakSelf = self;
    [[SXAPI sharedAPI] requestPath:@"/api/account/backup" method:@"POST" body:body completion:^(id json, NSInteger status, NSError *error) {
        SXSettingsController *controller = weakSelf; if (!controller || ![controller checkResponse:json status:status error:error]) return;
        NSMutableDictionary *state = [controller.accountStatus mutableCopy]; state[@"backup"] = json; controller.accountStatus = state;
        [controller finishWithMessage:@"已手動備份目前原生 App 的資料。"];
        SXShowError(controller, @"備份完成", @"資料已存入目前 Google 帳號；自動備份保持關閉。");
    }];
}
- (void)fetchCloudRestore {
    if (self.busy || !self.signedIn) return; self.busy = YES;
    __weak typeof(self) weakSelf = self;
    [[SXAPI sharedAPI] requestPath:@"/api/account/backup" method:@"GET" body:nil completion:^(id json, NSInteger status, NSError *error) {
        SXSettingsController *controller = weakSelf; if (!controller || ![controller checkResponse:json status:status error:error]) return;
        NSDictionary *profile = [json[@"profile"] isKindOfClass:NSDictionary.class] ? json[@"profile"] : nil;
        if (!profile) { [controller finishWithMessage:@"雲端備份格式不正確，本機資料仍保留。"];
            SXShowError(controller, @"無法還原", controller.statusMessage); return; }
        [controller finishWithMessage:@""];
        [controller confirmRestore:profile source:@"雲端備份" completion:^{
            NSMutableDictionary *state = [controller.accountStatus mutableCopy]; state[@"backup"] = @{@"revision":json[@"revision"] ?: @0, @"updatedAt":json[@"updatedAt"] ?: NSNull.null};
            controller.accountStatus = state; controller.conflict = NO; [controller finishWithMessage:@"已還原雲端備份；還原前副本保存在這個裝置。"];
        }];
    }];
}
- (void)confirmSignOut {
    if (self.busy || !self.signedIn) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"登出 Google 帳號？" message:@"會結束這個 App 的 Google 工作階段。本機自選、持股與研究紀錄保留。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"登出" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SXSettingsController *controller = weakSelf; if (!controller || controller.busy) return; controller.busy = YES;
        [[SXAPI sharedAPI] requestPath:@"/api/account/sign-out" method:@"POST" body:@{} completion:^(id json, NSInteger status, NSError *error) {
            SXSettingsController *current = weakSelf; if (!current || ![current checkResponse:json status:status error:error]) return;
            current.accountStatus = @{@"configured":@YES, @"signedIn":@NO}; current.conflict = NO;
            [current finishWithMessage:@"已登出，本機資料保留。"];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)exportLocal {
    if (self.busy) return; NSError *error = nil; NSData *data = [self.store exportProfileData:&error];
    NSURL *url = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:[NSString stringWithFormat:@"Shixu-Backup-%@.json", NSUUID.UUID.UUIDString]];
    if (!data || ![data writeToURL:url options:NSDataWritingAtomic | NSDataWritingFileProtectionComplete error:&error]) { SXShowError(self, @"無法匯出", error.localizedDescription ?: @"無法建立備份檔案。"); return; }
    SXShare(self, url);
}
- (void)importLocal {
    if (self.busy) return;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.delegate = self; picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (self.busy || !urls.count) return; NSURL *url = urls.firstObject; BOOL access = [url startAccessingSecurityScopedResource];
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
- (void)confirmRestore:(NSDictionary *)profile source:(NSString *)source completion:(void (^ _Nullable)(void))completion {
    NSDictionary *values = SXSettingsDictionary(profile[@"values"]), *account = SXSettingsDictionary(values[@"account.v1"]);
    NSUInteger watch = [values[@"watch"] isKindOfClass:NSArray.class] ? [values[@"watch"] count] : 0;
    NSUInteger runs = [values[@"runs"] isKindOfClass:NSArray.class] ? [values[@"runs"] count] : 0;
    NSUInteger positions = [account[@"positions"] isKindOfClass:NSArray.class] ? [account[@"positions"] count] : 0;
    NSString *message = [NSString stringWithFormat:@"%@包含自選 %lu 檔、研究 %lu 份、持股 %lu 筆。將以這份備份替換目前原生 App 的資料。%@替換前會先保存本機副本；舊版資料保留。", source, (unsigned long)watch, (unsigned long)runs, (unsigned long)positions, [self.store hasPersonalData] ? @"目前已有個人紀錄，兩份資料不會合併。" : @""];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"確認還原備份？" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存副本並還原" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        SXSettingsController *controller = weakSelf; if (!controller || controller.busy) return;
        NSError *error = nil;
        if (![controller.store importProfile:profile replace:YES error:&error]) { SXShowError(controller, @"還原未完成", error.localizedDescription ?: @"備份格式不正確，原有資料仍保留。"); return; }
        [controller applyTheme]; [controller finishWithMessage:@"已還原備份，還原前副本已保留。"];
        if (completion) completion(); else SXShowError(controller, @"還原完成", @"原生 App 已使用這份備份。還原前的本機副本仍保留。");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)migrateLegacy {
    if (self.busy) return; self.busy = YES; __weak typeof(self) weakSelf = self;
    [[SXSession sharedSession] readLegacyProfileWithCompletion:^(NSDictionary *profile, NSError *error) {
        SXSettingsController *controller = weakSelf; if (!controller) return; controller.busy = NO;
        if (error || !profile) { [controller finishWithMessage:error.localizedDescription ?: @"未取得舊版資料，原有資料仍保留。"];
            SXShowError(controller, @"讀取未完成", controller.statusMessage); return; }
        void (^done)(void) = ^{ [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"native-migration-v1"]; [controller finishWithMessage:@"已將舊版資料複製至原生 App；舊版資料保留。"];
            SXShowError(controller, @"資料已讀取", @"原生 App 已使用這份舊版備份。舊版資料與本機還原前副本仍保留。"); };
        if ([controller.store hasPersonalData]) [controller confirmRestore:profile source:@"舊版 App 資料" completion:done];
        else {
            NSError *importError = nil;
            if (![controller.store importProfile:profile replace:NO error:&importError]) { [controller finishWithMessage:importError.localizedDescription ?: @"無法匯入舊版資料。"];
                SXShowError(controller, @"讀取未完成", controller.statusMessage); return; }
            [controller applyTheme]; done();
        }
    }];
}
@end
