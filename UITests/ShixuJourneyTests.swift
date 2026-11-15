import XCTest

/// Real UI journeys. Every launch is isolated by --ui-fixtures; no test taps
/// research.start, signs in, restores data, removes a record, or contacts live APIs.
final class ShixuJourneyTests: XCTestCase {
    private var app: XCUIApplication!
    private let tabs = ["行情", "情報", "研究", "持股", "設定"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        if let app = app, (testRun?.failureCount ?? 0) > 0 {
            saveScreenshot("failure-\(name)")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "failure-accessibility-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        app?.terminate()
        app = nil
    }

    private func launch(_ flags: [String] = []) {
        app?.terminate()
        app = XCUIApplication(bundleIdentifier: "app.shixu.studio")
        app.launchArguments = ["--ui-fixtures", "-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"] + flags
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15), "Native tab bar did not appear")
        for title in tabs {
            XCTAssertTrue(app.tabBars.buttons[title].exists, "Missing primary tab: \(title)")
        }
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @discardableResult
    private func require(_ id: String, hittable: Bool = true, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let result = element(id)
        XCTAssertTrue(result.waitForExistence(timeout: 10), "Missing AX id: \(id)", file: file, line: line)
        if hittable {
            waitUntil("Not tappable: \(id)", file: file, line: line) { result.isHittable }
        }
        return result
    }

    private func waitUntil(_ message: String, timeout: TimeInterval = 8, file: StaticString = #filePath, line: UInt = #line, _ condition: @escaping () -> Bool) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: timeout), .completed, message, file: file, line: line)
    }

    private func tapTab(_ title: String) {
        let tab = app.tabBars.buttons[title]
        XCTAssertTrue(tab.isHittable, "Tab is covered: \(title)")
        tab.tap()
        XCTAssertTrue(tab.isSelected, "Tab did not select: \(title)")
    }

    private func text(_ view: XCUIElement) -> String {
        ([view.label, view.value as? String ?? ""] + view.staticTexts.allElementsBoundByIndex.map(\.label)).joined(separator: " ")
    }

    private func saveScreenshot(_ title: String, element: XCUIElement? = nil) {
        let shot = element?.screenshot() ?? app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ id: String, swipes: Int = 4) -> XCUIElement {
        let result = element(id)
        for _ in 0..<swipes {
            if result.exists && result.isHittable { return result }
            if app.tables.firstMatch.exists { app.tables.firstMatch.swipeUp() }
            else { app.swipeUp() }
        }
        return require(id)
    }

    private func back() {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(button.isHittable, "Native back button is unavailable")
        button.tap()
    }

    private func choose(_ controlID: String, _ labels: [String]) {
        let control = require(controlID)
        let option = labels.map { control.buttons[$0] }.first { $0.exists }
        XCTAssertNotNil(option, "Missing option \(labels) in \(controlID)")
        option?.tap()
        XCTAssertTrue(option?.isSelected == true, "Segment selection was not retained")
    }

    private func replaceText(_ field: XCUIElement, with replacement: String) {
        field.tap()
        let old = field.value as? String ?? ""
        if !old.isEmpty && old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(replacement)
    }

    /// chart.plot.value is JSON supplied by the native chart bridge, containing
    /// bars, period, visibleFrom, visibleTo and ma. This is observable UI state,
    /// not a test call into the app's controller or JavaScript implementation.
    private func chartState() -> [String: Any] {
        guard let value = element("chart.plot").value as? String,
              let data = value.data(using: .utf8),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return state
    }

    private func chartNumber(_ key: String) -> Double? {
        (chartState()[key] as? NSNumber)?.doubleValue
    }

    private func chartWidth() -> Double? {
        guard let first = chartNumber("visibleFrom"), let last = chartNumber("visibleTo") else { return nil }
        return last - first
    }

    private func openAMD() {
        tapTab("行情")
        require("stock.AMD").tap()
        _ = require("chart.plot")
        waitUntil("Chart never exposed a nonempty data/viewport state") {
            (self.chartNumber("bars") ?? 0) > 0 && (self.chartWidth() ?? 0) > 0
        }
    }

    func test01MarketFirstScreenShowsBenchmarksWatchPricesAndCurrencies() {
        launch()
        XCTAssertTrue(app.tabBars.buttons["行情"].isSelected)
        _ = require("market.benchmarks")
        _ = require("market.watchlist")
        let amd = require("stock.AMD")
        let content = text(amd)
        XCTAssertTrue(content.contains("120.00"), "AMD fixture price is missing from the first screen: \(content)")
        XCTAssertTrue(content.contains("%") && content.contains("+"), "First-screen quote has no signed percentage change")
        saveScreenshot("01-market-first-screen")
        require("assets.TWD").tap()
        XCTAssertTrue(app.tabBars.buttons["持股"].isSelected)
        XCTAssertTrue(require("holding.2330").exists, "TWD chip did not open the TWD ledger")
        tapTab("行情")
        require("assets.USD").tap()
        XCTAssertTrue(require("holding.AMD").exists, "USD chip did not open the USD ledger")
    }

    func test02HoldingMainTapOpensStockAndBackPreservesPortfolio() {
        launch()
        tapTab("持股")
        let amd = require("holding.AMD")
        let before = amd.frame.minY
        saveScreenshot("02-portfolio-first-screen")
        amd.tap()
        _ = require("chart.plot")
        XCTAssertTrue(app.tabBars.buttons["持股"].isSelected, "Pushing a holding detail unexpectedly changed the primary tab")
        saveScreenshot("03-stock-from-holding")
        back()
        XCTAssertTrue(app.tabBars.buttons["持股"].isSelected)
        let restored = require("holding.AMD")
        XCTAssertLessThan(abs(restored.frame.minY - before), 45, "Returning lost the portfolio scroll position")
        let nvda = reveal("holding.NVDA")
        nvda.swipeLeft()
        XCTAssertTrue(app.buttons["編輯"].waitForExistence(timeout: 3), "Holding swipe has no edit action")
        XCTAssertTrue(app.buttons["移除"].exists, "Holding swipe has no remove action")
        nvda.swipeRight() // Do not edit or delete fixture positions.
    }

    func test03ChartPeriodsMAAndRealPanPinchReset() {
        launch()
        openAMD()
        let dailyCount = chartNumber("bars") ?? 0
        choose("chart.period", ["週K", "週 K"])
        waitUntil("Weekly candles did not replace the daily series") {
            guard let count = self.chartNumber("bars") else { return false }
            return count > 0 && count < dailyCount
        }
        choose("chart.period", ["日K", "日 K"])
        waitUntil("Daily candles did not return") { self.chartNumber("bars") == dailyCount }
        choose("chart.range", ["全部"])

        require("chart.indicators").tap()
        replaceText(require("chart.ma.0"), with: "10")
        let identifiedSave = element("chart.ma.save")
        if identifiedSave.exists { identifiedSave.tap() }
        else {
            let apply = app.alerts.buttons["套用"].firstMatch
            XCTAssertTrue(apply.waitForExistence(timeout: 3), "The MA dialog has no Apply action")
            apply.tap()
        }
        waitUntil("MA period was not applied to the chart") {
            (self.chartState()["ma"] as? [NSNumber])?.contains(where: { $0.intValue == 10 }) == true
        }

        let plot = require("chart.plot")
        let initialWidth = chartWidth() ?? 0
        XCTAssertGreaterThan(initialWidth, 0)
        plot.pinch(withScale: 1.45, velocity: 0.8)
        waitUntil("Actual two-finger pinch did not zoom the TradingView viewport") {
            guard let width = self.chartWidth() else { return false }
            return width > 0 && width < initialWidth - 0.5
        }
        let first = chartNumber("visibleFrom") ?? 0
        plot.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
            .press(forDuration: 0.08, thenDragTo: plot.coordinate(withNormalizedOffset: CGVector(dx: 0.67, dy: 0.5)))
        waitUntil("Actual horizontal drag did not pan the chart") {
            abs((self.chartNumber("visibleFrom") ?? first) - first) > 0.5
        }
        let readout = require("chart.readout", hittable: false)
        let oldReadout = text(readout)
        plot.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.42)).press(forDuration: 0.8)
        waitUntil("Long press did not expose a dated OHLC readout") {
            let value = self.text(readout)
            return value != oldReadout && (value.contains("開") || value.contains("收"))
        }
        saveScreenshot("04-chart-after-real-gestures")
        let movedFrom = chartNumber("visibleFrom") ?? 0
        let movedTo = chartNumber("visibleTo") ?? 0
        require("chart.reset").tap()
        waitUntil("Reset did not change the manipulated viewport") {
            guard let first = self.chartNumber("visibleFrom"), let last = self.chartNumber("visibleTo") else { return false }
            return abs(first - movedFrom) > 0.5 || abs(last - movedTo) > 0.5
        }
        require("chart.fullscreen").tap()
        _ = require("chart.close")
        saveScreenshot("chart-fullscreen")
        require("chart.close").tap()
        _ = require("chart.plot")
    }

    func test04SearchNVDAAndOpenStock() {
        launch()
        tapTab("行情")
        // The UISearchBar container and its UITextField may share an identifier.
        // Type into the actual search field, never the outer bar container.
        let search = app.searchFields.matching(identifier: "market.search").firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5) && search.isHittable, "Market search field is not visible")
        search.tap()
        search.typeText("NVDA")
        require("stock.NVDA").tap()
        _ = require("chart.plot")
        XCTAssertTrue(app.navigationBars.staticTexts["NVDA"].exists || app.navigationBars["NVDA"].exists,
                      "Search opened a different company")
        saveScreenshot("search-nvda-stock")
    }

    func test05NewsScopesAndCalendarUseVisibleControls() {
        launch()
        tapTab("情報")
        choose("news.scope", ["自選"])
        saveScreenshot("05-news-watch-scope")
        choose("news.scope", ["市場"])
        choose("news.scope", ["日曆"])
        _ = require("news.calendar")
        saveScreenshot("06-news-calendar")
        choose("news.scope", ["自選"])
    }

    func test06StockResearchSetupRetainsAMDWithoutStartingPaidAnalysis() {
        launch()
        openAMD()
        reveal("stock.research").tap()
        let code = require("research.code")
        XCTAssertTrue((code.value as? String)?.contains("AMD") == true || text(code).contains("AMD"),
                      "Research setup lost the stock selected on the chart")
        _ = require("research.start", hittable: false) // Observe only. Never tap.
        saveScreenshot("07-research-setup-amd")
    }

    func test07LocalBackupOpensNativeShareAndCanCancelWhileSignedOut() {
        launch()
        tapTab("設定")
        let export = app.buttons["匯出本機備份"].firstMatch
        for _ in 0..<4 {
            if export.exists && export.isHittable { break }
            app.tables.firstMatch.swipeUp()
        }
        XCTAssertTrue(export.isHittable, "Local export is unavailable while signed out")
        export.tap()
        let shareLabels = ["拷貝", "複製", "Copy", "儲存到檔案", "存儲到檔案", "Save to Files", "AirDrop"]
        waitUntil("Local export did not present the native share sheet") {
            shareLabels.contains { self.app.buttons[$0].exists || self.app.staticTexts[$0].exists }
        }
        saveScreenshot("08-settings-local-export-share")
        let close = ["關閉", "Close", "取消", "Cancel"].map { app.buttons[$0].firstMatch }.first { $0.exists && $0.isHittable }
        if let close = close { close.tap() }
        else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)))
        }
        waitUntil("The share sheet could not be dismissed") {
            export.isHittable && !shareLabels.contains { self.app.buttons[$0].exists }
        }
    }

    func test08DarkLargeTextAndReducedMotionRemainUsable() {
        for (flag, title) in [("--ui-dark", "dark"), ("--ui-large", "large-text"), ("--ui-reduce-motion", "reduced-motion")] {
            launch([flag])
            _ = reveal("stock.AMD")
            tapTab("持股")
            _ = reveal("holding.AMD")
            saveScreenshot("presentation-\(title)")
        }
    }
}
