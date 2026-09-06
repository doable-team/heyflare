import XCTest

/// A tour of the app, screenshot at every stop.
///
/// Not assertions about pixels — those rot — but a way to exercise every screen and every
/// gesture from the command line and look at the result. The simulator has to be signed in
/// already; the tour starts on the Imbox.
final class HeyflareUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        settle(3)
    }

    // MARK: Helpers

    private func settle(_ seconds: TimeInterval = 1) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The first button whose label starts with `text`. SwiftUI folds a button's texts
    /// into one label, so a row reading "Security" and "Password · two-factor off" is
    /// "Security, Password · two-factor off".
    private func button(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", text)).firstMatch
    }

    private func buttonContaining(_ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", text)).firstMatch
    }

    private func tap(_ element: XCUIElement, _ name: String, wait: TimeInterval = 4) {
        XCTAssertTrue(element.waitForExistence(timeout: wait), "\(name) not found")
        element.tap()
        settle(1.2)
    }

    private func back() {
        tap(button("Back"), "Back")
    }

    // MARK: Tour

    func testSettingsTour() {
        tap(app.buttons["More"], "More tab")
        app.swipeUp()
        app.swipeUp()
        settle()
        shot("01-more-bottom")

        tap(button("Settings"), "Settings row")
        shot("02-settings-top")
        app.swipeUp()
        settle()
        shot("03-settings-mailboxes")

        tap(button("Security"), "Security row")
        shot("04-security")
        back()

        tap(button("Domains"), "Domains row")
        settle(1.5)
        shot("05-domains")
        back()

        app.swipeUp()
        settle()
        tap(button("AI assistant"), "AI row")
        settle(1.5)
        shot("06-ai-settings")
        app.swipeUp()
        settle()
        tap(button("What the assistant remembers"), "Memory row")
        settle(1.5)
        shot("07-ai-memory")
        back()
        back()
        back()
    }

    func testWeekAndCalendar() {
        tap(app.buttons["More"], "More tab")
        tap(button("This week"), "This week row")
        settle(1.5)
        shot("10-week")

        let field = app.textFields["Add something for this week…"]
        if field.waitForExistence(timeout: 3) {
            field.tap()
            field.typeText("Book the dentist")
            tap(button("Add"), "Add task")
            shot("11-week-task-added")
        }
        back()

        tap(app.buttons["Calendar"], "Calendar tab")
        settle(1.5)
        shot("12-calendar")
    }

    /// A finger's drag rather than XCTest's flick: `swipeRight()` is a fast throw that the
    /// row's drag gesture never sees enough of, and it lands as a tap.
    private func drag(_ element: XCUIElement, fromX: CGFloat, toX: CGFloat) {
        let from = element.coordinate(withNormalizedOffset: CGVector(dx: fromX, dy: 0.5))
        let to = element.coordinate(withNormalizedOffset: CGVector(dx: toX, dy: 0.5))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.05)
        settle(1.2)
    }

    func testThreadCreateEventAndSwipes() {
        tap(app.buttons["Imbox"], "Imbox tab")
        settle(1.5)
        let row = buttonContaining("Marcus")
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Imbox row not found")

        // Drag right: select.
        drag(row, fromX: 0.15, toX: 0.85)
        shot("20-imbox-drag-right")
        XCTAssertTrue(button("Cancel").exists, "drag right did not open selection")
        if button("Cancel").exists { tap(button("Cancel"), "Cancel selection") }

        // Drag left: read/unread toggle. The row stays, this screen stays, only the
        // row's weight changes — a drag that also opened the thread is the tap leaking.
        let again = buttonContaining("Marcus")
        if again.waitForExistence(timeout: 3) {
            drag(again, fromX: 0.85, toX: 0.15)
            shot("21-imbox-drag-left")
            XCTAssertFalse(button("More actions").exists, "drag left opened the thread")
        }

        // The rows must not eat vertical scrolling. The fixture has enough threads that
        // the last one starts off screen; after a swipe up it has to be reachable.
        // A named row, not `firstMatch`: after a scroll the first match is simply
        // whichever row is now on top, at the same height as before.
        let anchor = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Scroll fixture")).element(boundBy: 0)
        let anchorLabel = anchor.label
        let before = anchor.frame.minY
        app.swipeUp()
        settle()
        shot("21b-imbox-scrolled")
        let after = app.buttons.matching(NSPredicate(format: "label == %@", anchorLabel)).firstMatch
        XCTAssertTrue(!after.exists || after.frame.minY != before, "the list did not scroll")
        app.swipeDown()
        app.swipeDown()
        settle()

        // Open the thread and start an event from it.
        if !button("More actions").exists {
            tap(buttonContaining("Marcus"), "Imbox row")
            settle(1.5)
        }
        tap(button("More actions"), "More actions")
        settle()
        tap(button("Create event"), "Create event")
        settle(2.5)
        shot("22-event-from-thread")
    }

    /// The rows must not eat vertical scrolling. Kept apart from the swipe test so the
    /// two can be diagnosed separately.
    func testImboxScrolls() {
        tap(app.buttons["Imbox"], "Imbox tab")
        settle(1.5)
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Scroll fixture"))
        XCTAssertTrue(rows.element(boundBy: 0).waitForExistence(timeout: 5), "fixture rows not found")
        let anchor = rows.element(boundBy: 0)
        let anchorLabel = anchor.label
        let before = anchor.frame.minY
        app.swipeUp()
        settle()
        shot("30-imbox-after-swipe-up")
        let after = app.buttons.matching(NSPredicate(format: "label == %@", anchorLabel)).firstMatch
        XCTAssertTrue(!after.exists || after.frame.minY != before, "the list did not scroll")
    }
}
