import XCTest
final class LibraryUITests:XCTestCase {
    func testLibraryAndModes() throws {
        let app=XCUIApplication(); app.launchArguments=["--ui-test","--ui-reset"]; app.launch()
        let address=app.textFields["address"]
        XCTAssertTrue(address.waitForExistence(timeout:10)); XCTAssertEqual(app.keyboards.count,0)
        address.tap(); address.typeText("http://127.0.0.1:19791/kit-static/index.html")
        app.buttons["checkAddress"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout:10)); app.alerts.buttons["Ja"].tap()
        XCTAssertTrue(app.buttons["Vollständig"].firstMatch.waitForExistence(timeout:10)); XCTAssertEqual(app.keyboards.count,0)
        app.buttons["Vollständig"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Vollständig gesichert · 1"].waitForExistence(timeout:45))
        let open=app.buttons.matching(NSPredicate(format:"identifier BEGINSWITH %@","open-")).firstMatch
        app.buttons["Offline"].tap(); open.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout:10))
        XCTAssertEqual(app.keyboards.count,0)
        let viewerShot=XCTAttachment(screenshot:app.screenshot()); viewerShot.name="Viewer-ohne-Bedienelemente"; viewerShot.lifetime = .keepAlways; add(viewerShot)
        XCTAssertFalse(app.buttons["Zur Webseitenübersicht"].exists)
        let edge=app.webViews.firstMatch.coordinate(withNormalizedOffset:CGVector(dx:0,dy:0.5)).withOffset(CGVector(dx:35,dy:0))
        let inside=edge.withOffset(CGVector(dx:200,dy:0))
        edge.press(forDuration:0.05,thenDragTo:inside)
        let closed=XCTNSPredicateExpectation(predicate:NSPredicate(format:"exists == false"),object:app.webViews.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for:[closed],timeout:5),.completed)
        guard !app.webViews.firstMatch.exists else { return }
        XCTAssertTrue(address.waitForExistence(timeout:5)); XCTAssertEqual(app.keyboards.count,0)
        app.buttons["Online"].tap()
        app.buttons["Laufend sichern"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Nein"].waitForExistence(timeout:5)); app.buttons["Nein"].tap()
        app.buttons["Laufend sichern"].firstMatch.tap(); app.buttons["Ja"].tap()
        XCTAssertTrue(app.staticTexts["Laufend sichern · aktiv"].waitForExistence(timeout:10))
        XCTAssertTrue(app.buttons["Zurücksetzen"].firstMatch.isEnabled)
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval:2)
        // Windowed iPad apps can retain a narrow window after device rotation.
        // Descendant coordinates are screen-relative, so compare to the viewport.
        let viewport=app.scrollViews.firstMatch.frame
        XCTAssertGreaterThan(viewport.width,0); XCTAssertGreaterThan(viewport.height,0)
        for element in [address,app.segmentedControls["networkMode"],app.buttons["Eintrag löschen"].firstMatch] {
            XCTAssertGreaterThanOrEqual(element.frame.minX,viewport.minX)
            XCTAssertLessThanOrEqual(element.frame.maxX,viewport.maxX+1)
        }
        let screenshot=XCTAttachment(screenshot:app.screenshot()); screenshot.name="Bibliothek-Querformat"; screenshot.lifetime = .keepAlways; add(screenshot)
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval:1)
        app.buttons["Eintrag löschen"].firstMatch.tap(); app.buttons.matching(identifier:"Eintrag löschen").allElementsBoundByIndex.last!.tap()
        XCTAssertTrue(app.staticTexts["Ihre Bibliothek beginnt hier"].waitForExistence(timeout:10))
    }
}
