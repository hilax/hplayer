import SwiftUI
import UIKit
import XCTest
@testable import HPlayer

@MainActor
final class SocialComposerKeyboardTests: XCTestCase {
    private func waitUntil(timeout: TimeInterval = 1.0, _ predicate: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return predicate()
    }

    /// 模拟器里输入框一聚焦就会弹出真实键盘。第一次加载键盘时可能把主线程卡住两三秒（日志里的
    /// 「Keyboard queue task timeout」），晚到的真实键盘通知会冲掉测试发的模拟通知、或把计时吃掉。
    /// 先等真实键盘弹出并安静 0.3 秒再开始模拟；连着硬件键盘时不会弹，最多等 `timeout` 秒。
    private func waitForRealKeyboardToSettle(timeout: TimeInterval = 3) async {
        final class Events { var last = Date(); var shown = false }
        let events = Events()
        let names: [Notification.Name] = [
            UIResponder.keyboardWillShowNotification, UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification
        ]
        let tokens = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                events.last = Date()
                if note.name == UIResponder.keyboardDidShowNotification { events.shown = true }
            }
        }
        defer { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if events.shown && Date().timeIntervalSince(events.last) > 0.3 { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testWillHideClosesEvenWhenFocusStateHasNotUpdatedYet() async {
        let tracker = SocialComposerKeyboardTracker(
            hideConfirmDelayNs: 20_000_000,
            frameHideConfirmDelayNs: 40_000_000,
            holdOpenDurationNs: 120_000_000,
            dismissFinishTimeoutNs: 80_000_000
        )
        var closeCount = 0
        tracker.onAutoClose = { closeCount += 1 }

        tracker.handleKeyboardWillShow(
            endFrame: CGRect(x: 0, y: 550, width: 393, height: 302),
            containerBottom: 852,
            duration: 0
        )
        tracker.handleKeyboardDidShow()
        XCTAssertEqual(tracker.overlap, 302)
        XCTAssertTrue(tracker.keyboardSeen)
        XCTAssertTrue(tracker.keyboardVisible)

        // 模拟用户收起键盘时只收到 keyboardWillHideNotification（@FocusState 尚未同步成 false）
        tracker.handleKeyboardWillHide(duration: 0)
        XCTAssertEqual(tracker.overlap, 0)

        let closed = await waitUntil { closeCount == 1 }
        XCTAssertTrue(closed, "键盘收起后输入栏应自动关闭")
        XCTAssertTrue(tracker.isClosing)

        // 后续紧跟着到达的 didHide 不得重复触发关闭
        tracker.handleKeyboardDidHide()
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(closeCount, 1)
    }

    func testWillHideBeforeDidShowStillCloses() async {
        let tracker = SocialComposerKeyboardTracker(
            hideConfirmDelayNs: 20_000_000,
            frameHideConfirmDelayNs: 40_000_000,
            holdOpenDurationNs: 120_000_000,
            dismissFinishTimeoutNs: 80_000_000
        )
        var closeCount = 0
        tracker.onAutoClose = { closeCount += 1 }

        // 键盘刚准备弹出（只发了 willShow 还没到 didShow）就被用户收起
        tracker.handleKeyboardWillShow(
            endFrame: CGRect(x: 0, y: 550, width: 393, height: 302),
            containerBottom: 852,
            duration: 0
        )
        tracker.handleKeyboardWillHide(duration: 0)

        let closed = await waitUntil { closeCount == 1 }
        XCTAssertTrue(closed, "尚未等到 didShow 时收到隐藏通知也应正常关闭")
    }

    func testTransientHideFollowedByWillShowDoesNotClose() async {
        let tracker = SocialComposerKeyboardTracker(
            hideConfirmDelayNs: 40_000_000,
            frameHideConfirmDelayNs: 80_000_000,
            holdOpenDurationNs: 120_000_000,
            dismissFinishTimeoutNs: 80_000_000
        )
        var closeCount = 0
        tracker.onAutoClose = { closeCount += 1 }

        tracker.handleKeyboardWillShow(
            endFrame: CGRect(x: 0, y: 550, width: 393, height: 302),
            containerBottom: 852,
            duration: 0
        )
        tracker.handleKeyboardDidShow()

        // 模拟第三方输入法切换时短暂隐藏再马上弹出
        tracker.handleKeyboardWillHide(duration: 0)
        try? await Task.sleep(nanoseconds: 10_000_000)
        tracker.handleKeyboardWillShow(
            endFrame: CGRect(x: 0, y: 520, width: 393, height: 332),
            containerBottom: 852,
            duration: 0
        )

        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(closeCount, 0, "短时间内恢复显示时不能误关输入栏")
        XCTAssertFalse(tracker.isClosing)
    }

    func testSendingKeepsComposerOpenUntilKeyboardActuallyDismisses() async {
        let tracker = SocialComposerKeyboardTracker(
            hideConfirmDelayNs: 20_000_000,
            frameHideConfirmDelayNs: 40_000_000,
            holdOpenDurationNs: 120_000_000,
            dismissFinishTimeoutNs: 80_000_000
        )
        var closeCount = 0
        tracker.onAutoClose = { closeCount += 1 }

        tracker.handleKeyboardWillShow(
            endFrame: CGRect(x: 0, y: 550, width: 393, height: 302),
            containerBottom: 852,
            duration: 0
        )
        tracker.handleKeyboardDidShow()

        // 按键盘「发送」期间系统会收起键盘，请求未完成前必须保持输入栏显示
        tracker.beginSending()
        tracker.handleKeyboardWillHide(duration: 0)
        tracker.handleKeyboardDidHide()
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(closeCount, 0)

        // 请求失败后叫回键盘（beginHoldOpen + 重新弹出）
        tracker.beginHoldOpen()
        tracker.endSending(succeeded: false)
        try? await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(closeCount, 0)

        tracker.handleKeyboardWillShow(
            endFrame: CGRect(x: 0, y: 550, width: 393, height: 302),
            containerBottom: 852,
            duration: 0
        )
        tracker.handleKeyboardDidShow()

        // 用户看清失败原因后手动收起键盘，输入栏应立即关闭
        tracker.handleKeyboardWillHide(duration: 0)
        let closed = await waitUntil { closeCount == 1 }
        XCTAssertTrue(closed, "发送失败弹回后用户再次收起键盘应自动关闭")
    }

    func testHideDuringHoldOpenClosesWhenHoldExpires() async {
        let tracker = SocialComposerKeyboardTracker(
            hideConfirmDelayNs: 20_000_000,
            frameHideConfirmDelayNs: 40_000_000,
            holdOpenDurationNs: 80_000_000,
            dismissFinishTimeoutNs: 80_000_000
        )
        var closeCount = 0
        tracker.onAutoClose = { closeCount += 1 }

        tracker.handleKeyboardWillShow(
            endFrame: CGRect(x: 0, y: 550, width: 393, height: 302),
            containerBottom: 852,
            duration: 0
        )
        tracker.handleKeyboardDidShow()

        // 在叫回保护期内用户直接收起键盘且未再弹回，保护期结束时必须收起，不能残留
        tracker.beginHoldOpen()
        tracker.handleKeyboardWillHide(duration: 0)
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(closeCount, 0)

        let closed = await waitUntil { closeCount == 1 }
        XCTAssertTrue(closed, "保护期内用户收起键盘后保护期一结束应自动关闭")
    }

    func testDidHideActsAsFallbackWhenWillHideWasDeferred() {
        let tracker = SocialComposerKeyboardTracker(
            hideConfirmDelayNs: 20_000_000,
            frameHideConfirmDelayNs: 40_000_000,
            holdOpenDurationNs: 120_000_000,
            dismissFinishTimeoutNs: 80_000_000
        )
        var closeCount = 0
        tracker.onAutoClose = { closeCount += 1 }

        tracker.handleKeyboardWillShow(
            endFrame: CGRect(x: 0, y: 550, width: 393, height: 302),
            containerBottom: 852,
            duration: 0
        )
        tracker.handleKeyboardDidShow()

        tracker.handleKeyboardDidHide()
        XCTAssertEqual(closeCount, 1)
    }

    func testSoftKeyboardDismissSlidesDownUntilDidHideThenFinishes() async {
        let tracker = SocialComposerKeyboardTracker(
            hideConfirmDelayNs: 20_000_000,
            frameHideConfirmDelayNs: 40_000_000,
            holdOpenDurationNs: 120_000_000,
            dismissFinishTimeoutNs: 200_000_000
        )
        var finished = 0
        tracker.onFinishDismiss = { finished += 1 }

        tracker.handleKeyboardWillShow(
            endFrame: CGRect(x: 0, y: 550, width: 393, height: 302),
            containerBottom: 852,
            duration: 0
        )
        tracker.handleKeyboardDidShow()

        // 软键盘开着时点击遮罩关闭：先进入退场动画态（overlap 降为 0），收到 didHide 时立刻完成卸载
        XCTAssertTrue(tracker.beginClosing())
        XCTAssertTrue(tracker.isDismissing)
        XCTAssertEqual(finished, 0)

        tracker.handleKeyboardWillHide(duration: 0)
        XCTAssertEqual(tracker.overlap, 0)
        XCTAssertEqual(finished, 0)

        tracker.handleKeyboardDidHide()
        XCTAssertEqual(finished, 1)
        XCTAssertFalse(tracker.isDismissing)
    }

    func testWillHideTriggersDismissTimeoutFallbackWhenDidHideNeverArrives() async {
        let tracker = SocialComposerKeyboardTracker(
            hideConfirmDelayNs: 20_000_000,
            frameHideConfirmDelayNs: 40_000_000,
            holdOpenDurationNs: 120_000_000,
            dismissFinishTimeoutNs: 80_000_000
        )
        var autoClosed = 0
        var finished = 0
        tracker.onAutoClose = { autoClosed += 1 }
        tracker.onFinishDismiss = { finished += 1 }

        tracker.handleKeyboardWillShow(
            endFrame: CGRect(x: 0, y: 550, width: 393, height: 302),
            containerBottom: 852,
            duration: 0
        )
        tracker.handleKeyboardDidShow()

        // 仅发出 willHide（不发 didHide），应先触发退场，再由兜底定时器完成卸载
        tracker.handleKeyboardWillHide(duration: 0)
        let closed = await waitUntil { autoClosed == 1 }
        XCTAssertTrue(closed)
        XCTAssertTrue(tracker.isDismissing)

        let dismissed = await waitUntil { finished == 1 }
        XCTAssertTrue(dismissed)
        XCTAssertFalse(tracker.isDismissing)
    }

    func testSoftKeyboardFrameCollapseToZeroClosesEvenWithoutWillHide() async {
        let tracker = SocialComposerKeyboardTracker(
            hideConfirmDelayNs: 20_000_000,
            frameHideConfirmDelayNs: 40_000_000,
            holdOpenDurationNs: 120_000_000,
            dismissFinishTimeoutNs: 80_000_000
        )
        var closeCount = 0
        tracker.onAutoClose = { closeCount += 1 }

        tracker.handleKeyboardWillChangeFrame(
            endFrame: CGRect(x: 0, y: 550, width: 393, height: 302),
            containerBottom: 852,
            duration: 0
        )
        tracker.handleKeyboardWillChangeFrame(
            endFrame: CGRect(x: 0, y: 852, width: 393, height: 302),
            containerBottom: 852,
            duration: 0
        )

        let closed = await waitUntil { closeCount == 1 }
        XCTAssertTrue(closed, "软键盘高度归零且未再恢复时应兜底关闭")
    }

    func testHardwareKeyboardShortcutsBarDoesNotAutoCloseOnFrameZero() async {
        let tracker = SocialComposerKeyboardTracker(
            hideConfirmDelayNs: 20_000_000,
            frameHideConfirmDelayNs: 40_000_000,
            holdOpenDurationNs: 120_000_000,
            dismissFinishTimeoutNs: 80_000_000
        )
        var closeCount = 0
        tracker.onAutoClose = { closeCount += 1 }

        // 外接硬件键盘底部 44pt 快捷条变化不应被当成软键盘收起而误关
        tracker.handleKeyboardWillChangeFrame(
            endFrame: CGRect(x: 0, y: 808, width: 393, height: 44),
            containerBottom: 852,
            duration: 0
        )
        tracker.handleKeyboardWillChangeFrame(
            endFrame: CGRect(x: 0, y: 852, width: 393, height: 44),
            containerBottom: 852,
            duration: 0
        )

        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(closeCount, 0)
    }

    func testDockedCommentBarLiftsOnShowAndReturnsToBottomRepeatedly() async {
        let tracker = SocialComposerKeyboardTracker(
            autoCloseOnHide: false,
            hideConfirmDelayNs: 20_000_000,
            frameHideConfirmDelayNs: 40_000_000,
            holdOpenDurationNs: 120_000_000,
            dismissFinishTimeoutNs: 80_000_000
        )
        var hiddenCallbacks = 0
        var autoCloseCallbacks = 0
        tracker.onKeyboardHidden = { hiddenCallbacks += 1 }
        tracker.onAutoClose = { autoCloseCallbacks += 1 }

        // 第一轮弹出 -> 收起退回底部
        tracker.handleKeyboardWillShow(
            endFrame: CGRect(x: 0, y: 516, width: 393, height: 336),
            containerBottom: 818,
            duration: 0
        )
        XCTAssertEqual(tracker.overlap, 302)
        tracker.handleKeyboardDidShow()

        tracker.handleKeyboardWillHide(duration: 0)
        XCTAssertEqual(tracker.overlap, 0)
        let firstHidden = await waitUntil { hiddenCallbacks == 1 && tracker.hideCount == 1 }
        XCTAssertTrue(firstHidden)
        XCTAssertFalse(tracker.isClosing, "常驻评论输入栏退回底部后必须仍保持可用")
        XCTAssertEqual(autoCloseCallbacks, 0)

        // 第二轮再次弹出 -> 再次收起退回底部
        tracker.handleKeyboardWillShow(
            endFrame: CGRect(x: 0, y: 516, width: 393, height: 336),
            containerBottom: 818,
            duration: 0
        )
        XCTAssertEqual(tracker.overlap, 302)
        tracker.handleKeyboardDidShow()

        tracker.handleKeyboardWillHide(duration: 0)
        let secondHidden = await waitUntil { hiddenCallbacks == 2 && tracker.hideCount == 2 }
        XCTAssertTrue(secondHidden)
        XCTAssertEqual(tracker.overlap, 0)
        XCTAssertFalse(tracker.isClosing)
    }

    func testKeyboardMotionExtractsCurveAndUsesSpringForSystemKeyboard() {
        let userInfo: [AnyHashable: Any] = [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: CGRect(x: 0, y: 550, width: 393, height: 302)),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.25,
            UIResponder.keyboardAnimationCurveUserInfoKey: 7
        ]
        let note = Notification(name: UIResponder.keyboardWillShowNotification, object: nil, userInfo: userInfo)
        let geometry = SocialComposerKeyboardTracker.geometry(from: note)
        XCTAssertEqual(geometry.frame, CGRect(x: 0, y: 550, width: 393, height: 302))
        XCTAssertEqual(geometry.motion, KeyboardMotion(duration: 0.25, curve: 7))
        XCTAssertNotNil(geometry.motion.animation)
        XCTAssertNil(KeyboardMotion(duration: 0, curve: 7).animation)
    }

    func testSocialComposerViewClosesWhenKeyboardHideNotificationsFire() async {
        for target in [SocialComposerTarget.danmaku, .comment(vid: 42, replyTo: nil)] {
            var closeCount = 0
            let composer = SocialComposer(target: target) {
                closeCount += 1
            }

            let window: UIWindow
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
            } else {
                window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            }
            let host = UIHostingController(rootView: composer)
            window.rootViewController = host
            window.makeKeyAndVisible()
            host.view.layoutIfNeeded()
            defer {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                window.isHidden = true
                window.rootViewController = nil
            }

            await waitForRealKeyboardToSettle()

            let shownInfo: [AnyHashable: Any] = [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: CGRect(x: 0, y: 550, width: 393, height: 302)),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.05
            ]
            NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil, userInfo: shownInfo)
            NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil, userInfo: shownInfo)

            try? await Task.sleep(nanoseconds: 40_000_000)
            XCTAssertEqual(closeCount, 0)

            let hideInfo: [AnyHashable: Any] = [
                UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: CGRect(x: 0, y: 852, width: 393, height: 302)),
                UIResponder.keyboardAnimationDurationUserInfoKey: 0.05
            ]
            NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil, userInfo: hideInfo)
            NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil, userInfo: hideInfo)

            // 正常 0.1 秒内就关；给模拟器偶发的主线程卡顿留足余量
            let closed = await waitUntil(timeout: 5) { closeCount == 1 }
            XCTAssertTrue(closed, "SocialComposer(\(target.id)) 应在收到键盘隐藏通知后自动关闭")
        }
    }

    func testSocialComposerViewClosesEvenWithOnlyWillHideNotification() async {
        var closeCount = 0
        let composer = SocialComposer(target: .danmaku) {
            closeCount += 1
        }

        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        }
        let host = UIHostingController(rootView: composer)
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        defer {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            window.isHidden = true
            window.rootViewController = nil
        }

        // 等模拟器自身首次聚焦的真实键盘彻底落稳，再发模拟通知，避免真实 didShow 延迟到达冲掉人工 willHide
        await waitForRealKeyboardToSettle()

        let shownInfo: [AnyHashable: Any] = [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: CGRect(x: 0, y: 550, width: 393, height: 302)),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.05
        ]
        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil, userInfo: shownInfo)
        NotificationCenter.default.post(name: UIResponder.keyboardDidShowNotification, object: nil, userInfo: shownInfo)

        try? await Task.sleep(nanoseconds: 50_000_000)

        let hideInfo: [AnyHashable: Any] = [
            UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: CGRect(x: 0, y: 852, width: 393, height: 302)),
            UIResponder.keyboardAnimationDurationUserInfoKey: 0.05
        ]
        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil, userInfo: hideInfo)

        // 正常约 0.4 秒关掉（80 毫秒确认 + 280 毫秒退场兜底）；给模拟器偶发的主线程卡顿留足余量
        let closed = await waitUntil(timeout: 5) { closeCount == 1 }
        XCTAssertTrue(closed, "即使仅发出 keyboardWillHideNotification，退场结束后也应兜底卸载")
    }
}
