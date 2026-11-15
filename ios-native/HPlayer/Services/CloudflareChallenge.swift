import Foundation
import WebKit

/// Jable、MissAV 后台网页共用的 Cloudflare 验证页识别。
///
/// 只看和语言无关的特征：Cloudflare 按设备语言出验证页，中文系统下标题是「请稍候…」、正文是「正在进行安全验证」，
/// 以前只认英文的「Just a moment」，中文系统下认不出验证页，验证弹窗出不来，
/// 还会把验证页当正文解析（片名变成「请稍候…」、找不到播放地址、最后超时）。
enum CloudflareChallenge {
    /// 在页面里执行，返回 true 表示当前是验证页。
    /// 脚本特征只认验证页专用的 `challenge-platform/h/…/chl_page/…`：Cloudflare 在正常页面里也可能插
    /// `challenge-platform/scripts/jsd/…` 的检测脚本，不能把它当成验证页
    static let detectionScript = """
    (() => {
        if (typeof window._cf_chl_opt !== 'undefined') return true;
        const marker = document.querySelector(
            'script[src*="/cdn-cgi/challenge-platform/"][src*="chl_page"], [id^="cf-chl-widget"], #challenge-form, #challenge-running, ' +
            '#challenge-stage, .cf-turnstile, iframe[src*="challenges.cloudflare.com"]'
        );
        if (marker) return true;
        const title = document.title || '';
        return /Just a moment|Attention Required|请稍候|請稍候|しばらくお待ちください/.test(title);
    })()
    """

    /// 检测到验证页后先在后台等这么久：很多验证是非交互式的，浏览器内核里跑几秒会自己放行，
    /// 这期间不打扰用户；过了这段时间还在验证页，才弹出来让用户自己点
    /// Jable、MissAV 的视频页每次都要手动点，等太久只是让用户干等，所以只留 3 秒
    static let silentWait: TimeInterval = 3
}

// MARK: - 后台网页加速（Jable、MissAV 共用）

/// 后台用来抓列表、详情的那张网页的公共设置。
/// - 页面骨架就绪（DOMContentLoaded）就通知提取：列表、播放地址都写在 HTML 里，
///   不用等图片、预览视频、广告和统计脚本全部加载完（以前等 didFinish，常常要多等好几秒）
/// - 不下载图片、视频、字体和统计脚本：App 用不到它们（封面另外单独加载），Cloudflare 验证用的资源照常放行
/// - 每次检查页面同时取回这张页面的导航开始时间：比当前请求开始得还早的是上一个请求的页面，不拿它的数据
enum BackgroundWebPage {
    static let domReadyHandler = "hpDomReady"

    static var domReadyScript: WKUserScript {
        WKUserScript(source: """
        document.addEventListener('DOMContentLoaded', () => {
            try { window.webkit.messageHandlers.\(domReadyHandler).postMessage(location.href); } catch (e) {}
        });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// 返回 { challenge: 是否验证页, origin: 这张页面导航开始的时间（毫秒时间戳）}
    static let stateScript = "(() => ({ challenge: \(CloudflareChallenge.detectionScript), origin: performance.timeOrigin }))()"

    /// 页面是不是这次请求开始之后才打开的（留 0.5 秒余量）
    static func isCurrentPage(_ result: Any?, startedAt: Date) -> Bool {
        guard let state = result as? [String: Any], let origin = state["origin"] as? Double else { return true }
        return origin >= startedAt.timeIntervalSince1970 * 1000 - 500
    }

    static func isChallenge(_ result: Any?) -> Bool {
        ((result as? [String: Any])?["challenge"] as? Bool) ?? false
    }

    /// 给后台网页装上资源拦截规则（编译一次，之后复用）
    @MainActor
    static func installResourceBlocking(on controller: WKUserContentController) {
        if let compiled = blockingRules {
            controller.add(compiled)
            return
        }
        pendingControllers.append(controller)
        guard pendingControllers.count == 1 else { return }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "hplayer.background-page", encodedContentRuleList: rulesJSON
        ) { list, _ in
            Task { @MainActor in
                blockingRules = list
                if let list { pendingControllers.forEach { $0.add(list) } }
                pendingControllers.removeAll()
            }
        }
    }

    @MainActor private static var blockingRules: WKContentRuleList?
    @MainActor private static var pendingControllers: [WKUserContentController] = []

    private static let rulesJSON = """
    [
      {"trigger": {"url-filter": ".*", "resource-type": ["image", "media", "font"]}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "googletagmanager\\\\.com"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "google-analytics\\\\.com"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "doubleclick\\\\.net"}, "action": {"type": "block"}},
      {"trigger": {"url-filter": "challenges\\\\.cloudflare\\\\.com"}, "action": {"type": "ignore-previous-rules"}},
      {"trigger": {"url-filter": "/cdn-cgi/"}, "action": {"type": "ignore-previous-rules"}}
    ]
    """
}
