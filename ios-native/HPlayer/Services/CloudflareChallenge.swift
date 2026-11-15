import Foundation

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
