import AVFoundation
import Foundation
import Network
import WebKit

enum APIError: LocalizedError {
    case unauthorized
    case server(String)
    case badURL

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "登录已过期，请重新登录"
        case .server(let message):
            return NetworkErrorFormatter.localizeRawMessage(message)
        case .badURL:
            return "地址无效"
        }
    }
}

/// 统一把系统网络错误、连接异常、底层播放内核与第三方引擎的英文报错转换为用户可直接理解的中文提示。
enum NetworkErrorFormatter {
    static func message(for error: Error) -> String {
        if error is CancellationError {
            return "请求已取消"
        }

        if let engineError = error as? NuvioEngineError {
            return formatNuvioEngineMessage(engineError.message)
        }

        if let decodingError = error as? DecodingError {
            return formatDecodingError(decodingError)
        }

        if let nwError = error as? NWError {
            return formatNWError(nwError)
        }

        if let localized = error as? LocalizedError,
           let description = localized.errorDescription?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            return localizeRawMessage(description)
        }

        let nsError = error as NSError
        if let mapped = mapNSError(nsError) {
            return mapped
        }

        return localizeRawMessage(nsError.localizedDescription)
    }

    static func describe(_ nsError: NSError) -> String {
        if let mapped = mapNSError(nsError) {
            return mapped
        }
        return localizeRawMessage(nsError.localizedDescription)
    }

    /// 翻译 mpv / FFmpeg 播放内核返回的英文错误或日志行。
    static func translateMediaEngineMessage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if containsChinese(trimmed) {
            return trimmed
        }
        let lower = trimmed.lowercased()

        if let status = extractHTTPStatus(from: lower) {
            return describeHTTPStatus(status)
        }

        if lower.contains("connection timed out") || lower.contains("operation timed out") || lower.contains("timed out") || lower.contains("timeout") {
            return "连接超时，请检查网络后重试"
        }
        if lower.contains("connection refused") {
            return "服务器拒绝连接，请稍后重试"
        }
        if lower.contains("connection reset") {
            return "网络连接被服务器重置，请重试"
        }
        if lower.contains("broken pipe") {
            return "网络连接意外断开，请重试"
        }
        if lower.contains("failed to resolve hostname") || lower.contains("nodename nor servname") || lower.contains("name or service not known") || lower.contains("could not resolve host") {
            return "域名解析失败，请检查网络或 DNS 设置"
        }
        if lower.contains("network is unreachable") || lower.contains("network is down") {
            return "当前网络不可用，请检查网络连接"
        }
        if lower.contains("no route to host") || lower.contains("host is unreachable") || lower.contains("host is down") {
            return "无法连接到服务器，请检查网络或代理设置"
        }
        if lower.contains("tls") || lower.contains("ssl") || lower.contains("certificate") || lower.contains("handshake") {
            return "安全连接（TLS/SSL）建立失败，请检查网络或代理"
        }
        if lower.contains("end of file") || lower.contains("unexpected eof") {
            return "视频数据流意外中断，请重试"
        }
        if lower.contains("unrecognized file format") || lower.contains("invalid data found") || lower.contains("moov atom not found") {
            return "无法识别视频格式或文件已损坏"
        }
        if lower.contains("no audio or video data") || lower.contains("nothing was played") {
            return "未获取到可播放的音视频流"
        }
        if lower.contains("loading failed") || lower.contains("failed to open") || lower.contains("error opening") {
            return "视频加载失败，请检查网络或尝试切换画质"
        }
        if lower.contains("input/output error") || lower.contains("i/o error") {
            return "网络数据读取异常，请重试"
        }
        if lower.contains("permission denied") || lower.contains("forbidden") {
            return "无权访问该视频资源，地址可能已失效"
        }
        if lower.contains("no such file") || lower.contains("file not found") {
            return "找不到视频文件或资源已失效"
        }
        if lower.contains("out of memory") {
            return "内存不足，无法继续播放"
        }
        if lower.contains("generic error") {
            return "播放内核发生异常，请重试"
        }

        if let translated = translateCommonEnglishErrorText(trimmed) {
            return translated
        }
        return "视频加载或解码失败，请重试或切换画质"
    }

    /// 翻译 BT 磁力引擎（NuvioEngine / libtorrent）返回的英文错误信息。
    static func formatNuvioEngineMessage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "磁力引擎发生未知错误，请重试" }
        if containsChinese(trimmed) {
            return trimmed
        }
        let lower = trimmed.lowercased()

        if lower.contains("info hash") || lower.contains("info_hash") {
            return "链接里的信息哈希无效，请确认复制完整"
        }
        if lower.contains("closed") {
            return "BT 引擎已关闭，请重试"
        }
        if lower.contains("timed out") || lower.contains("timeout") {
            return "连接磁力节点超时，请重试"
        }
        if lower.contains("preload ended") {
            return "磁力视频预加载意外中断，请重试"
        }
        if lower.contains("loopback") {
            return "本地磁力流连接异常，请重试"
        }
        if lower.contains("empty handle") || lower.contains("empty request") {
            return "BT 引擎初始化异常，请重试"
        }
        if lower.contains("metadata-ready") || lower.contains("stream-prepared") {
            return "种子信息返回不完整，请重试"
        }
        if lower.contains("must not be empty") {
            return "种子数据为空"
        }
        if lower.contains("exceeds") {
            return "种子数据超出大小限制"
        }
        if lower.contains("stream id") {
            return "磁力播放会话标识无效，请重试"
        }
        if let translated = translateCommonEnglishErrorText(trimmed) {
            return translated
        }
        return "磁力引擎连接异常，请稍后重试"
    }

    /// 翻译 UPnP / DLNA 电视设备返回的常见英文错误描述。
    static func translateDLNAFault(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "电视设备响应异常" }
        if containsChinese(trimmed) {
            return trimmed
        }
        let lower = trimmed.lowercased()
        if let status = extractHTTPStatus(from: lower) {
            return "电视返回异常状态（HTTP \(status)）"
        }
        if lower.contains("illegal mime") || lower.contains("mime-type") {
            return "电视不支持当前视频格式"
        }
        if lower.contains("transition not available") {
            return "电视当前状态不支持该操作，请稍后重试"
        }
        if lower.contains("invalid args") || lower.contains("invalid argument") {
            return "电视拒绝了播放参数"
        }
        if lower.contains("invalid action") {
            return "电视不支持该控制指令"
        }
        if lower.contains("action failed") {
            return "电视执行指令失败，请重试"
        }
        if lower.contains("transport is locked") {
            return "电视播放通道正被占用"
        }
        if lower.contains("resource not found") || lower.contains("no contents") {
            return "电视无法读取该视频地址，请确认在同一局域网内"
        }
        if lower.contains("seek mode not supported") || lower.contains("illegal seek") {
            return "电视不支持当前进度跳转方式"
        }
        if lower.contains("upnperror") {
            return "电视端播放服务返回错误"
        }
        if let translated = translateCommonEnglishErrorText(trimmed) {
            return translated
        }
        return trimmed
    }

    /// 如果消息本身已经是中文则原样返回，否则尝试将常见英文网络/系统错误转为中文。
    static func localizeRawMessage(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "网络连接失败，请稍后重试" }
        if containsChinese(trimmed) {
            return trimmed
        }
        if let translated = translateCommonEnglishErrorText(trimmed) {
            return translated
        }
        return trimmed
    }

    // MARK: - 系统错误域映射

    private static func mapNSError(_ error: NSError, depth: Int = 0) -> String? {
        guard depth < 4 else { return nil }

        switch error.domain {
        case NSURLErrorDomain:
            return mapURLError(error, depth: depth)
        case "kCFErrorDomainCFNetwork":
            return mapCFNetworkError(error, depth: depth)
        case NSPOSIXErrorDomain:
            return mapPOSIXCode(Int32(error.code))
        case WKErrorDomain, "WebKitErrorDomain":
            return mapWebKitError(error, depth: depth)
        case AVFoundationErrorDomain, "CoreMediaErrorDomain":
            return mapAVError(error, depth: depth)
        case NSCocoaErrorDomain:
            return mapCocoaError(error, depth: depth)
        default:
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
               let mapped = mapNSError(underlying, depth: depth + 1) {
                return mapped
            }
            if let cfDomain = error.userInfo["_kCFStreamErrorDomainKey"] as? Int,
               let cfCode = error.userInfo["_kCFStreamErrorCodeKey"] as? Int,
               let mapped = mapCFStreamError(domain: cfDomain, code: cfCode) {
                return mapped
            }
            return nil
        }
    }

    private static func mapURLError(_ error: NSError, depth: Int) -> String {
        switch error.code {
        case NSURLErrorCancelled:
            return "请求已取消"
        case NSURLErrorBadURL:
            return "请求地址无效"
        case NSURLErrorTimedOut:
            return "网络连接超时，请检查网络后重试"
        case NSURLErrorUnsupportedURL:
            return "不支持的链接格式"
        case NSURLErrorCannotFindHost:
            return "找不到服务器地址，请检查网络或代理设置"
        case NSURLErrorCannotConnectToHost:
            return "无法连接到服务器，请检查网络或代理后重试"
        case NSURLErrorNetworkConnectionLost:
            return "网络连接意外中断，请重试"
        case NSURLErrorDNSLookupFailed:
            return "域名解析失败，请检查网络或 DNS 设置"
        case NSURLErrorHTTPTooManyRedirects:
            return "页面重定向次数过多"
        case NSURLErrorResourceUnavailable:
            return "请求的资源暂时不可用，请稍后重试"
        case NSURLErrorNotConnectedToInternet:
            return "当前无网络连接，请检查 Wi-Fi 或蜂窝网络"
        case NSURLErrorRedirectToNonExistentLocation:
            return "跳转的目标地址无效"
        case NSURLErrorBadServerResponse:
            return "服务器响应异常，请稍后重试"
        case NSURLErrorUserCancelledAuthentication:
            return "已取消身份验证"
        case NSURLErrorUserAuthenticationRequired:
            return "需要身份验证才能访问"
        case NSURLErrorZeroByteResource:
            return "服务器未返回任何内容"
        case NSURLErrorCannotDecodeRawData, NSURLErrorCannotDecodeContentData:
            return "无法解码服务器返回的数据"
        case NSURLErrorCannotParseResponse:
            return "无法解析服务器返回的数据"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "需要安全连接（HTTPS）才能加载"
        case NSURLErrorFileDoesNotExist:
            return "请求的资源或文件不存在"
        case NSURLErrorFileIsDirectory:
            return "目标地址是文件夹，无法直接读取"
        case NSURLErrorNoPermissionsToReadFile:
            return "没有权限读取该资源"
        case NSURLErrorDataLengthExceedsMaximum:
            return "返回的数据超出最大限制"
        case NSURLErrorSecureConnectionFailed:
            return "安全连接（TLS/SSL）建立失败，请检查网络或代理"
        case NSURLErrorServerCertificateHasBadDate:
            return "服务器安全证书已过期或尚未生效，请检查系统时间"
        case NSURLErrorServerCertificateUntrusted:
            return "服务器安全证书不受信任"
        case NSURLErrorServerCertificateHasUnknownRoot:
            return "服务器安全证书颁发机构不受信任"
        case NSURLErrorServerCertificateNotYetValid:
            return "服务器安全证书尚未生效，请检查系统时间"
        case NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
            return "客户端安全证书验证失败"
        case NSURLErrorCannotLoadFromNetwork:
            return "无法从网络加载资源，请检查网络连接"
        case NSURLErrorInternationalRoamingOff:
            return "当前未开启国际漫游，无法联网"
        case NSURLErrorCallIsActive:
            return "通话中暂无法建立数据连接"
        case NSURLErrorDataNotAllowed:
            return "未允许使用蜂窝网络，请在系统设置中检查联网权限"
        case NSURLErrorRequestBodyStreamExhausted:
            return "请求数据流已结束，请重试"
        case NSURLErrorBackgroundSessionRequiresSharedContainer,
             NSURLErrorBackgroundSessionInUseByAnotherProcess,
             NSURLErrorBackgroundSessionWasDisconnected:
            return "后台网络连接已断开，请重试"
        default:
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
               let mapped = mapNSError(underlying, depth: depth + 1) {
                return mapped
            }
            if let cfDomain = error.userInfo["_kCFStreamErrorDomainKey"] as? Int,
               let cfCode = error.userInfo["_kCFStreamErrorCodeKey"] as? Int,
               let mapped = mapCFStreamError(domain: cfDomain, code: cfCode) {
                return mapped
            }
            return "网络连接失败（错误码 \(error.code)）"
        }
    }

    private static func mapCFNetworkError(_ error: NSError, depth: Int) -> String {
        switch error.code {
        case 1, 2:
            return "域名解析失败，找不到服务器"
        case 120...124, 306...311:
            return "代理服务器连接失败，请检查代理设置"
        case 302...305:
            return "网络连接中断或服务器响应异常"
        case -1001:
            return "网络连接超时，请检查网络后重试"
        case -1003:
            return "找不到服务器地址，请检查网络或代理设置"
        case -1004:
            return "无法连接到服务器，请检查网络或代理后重试"
        case -1005:
            return "网络连接意外中断，请重试"
        case -1009:
            return "当前无网络连接，请检查 Wi-Fi 或蜂窝网络"
        default:
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
               let mapped = mapNSError(underlying, depth: depth + 1) {
                return mapped
            }
            return "网络请求失败（错误码 \(error.code)）"
        }
    }

    private static func mapCFStreamError(domain: Int, code: Int) -> String? {
        // kCFStreamErrorDomainPOSIX == 1, kCFStreamErrorDomainNetDB == 8, kCFStreamErrorDomainSSL == 3
        switch domain {
        case 1:
            return mapPOSIXCode(Int32(code))
        case 3:
            return "安全连接（TLS/SSL）建立失败，请检查网络或代理"
        case 8:
            return "域名解析失败，请检查网络或 DNS 设置"
        default:
            return nil
        }
    }

    private static func mapPOSIXCode(_ code: Int32) -> String {
        switch code {
        case ECONNREFUSED:
            return "服务器拒绝连接，请稍后重试"
        case ETIMEDOUT:
            return "网络连接超时，请检查网络后重试"
        case ECONNRESET:
            return "网络连接被服务器重置，请重试"
        case ECONNABORTED:
            return "网络连接已中止，请重试"
        case ENETDOWN, ENETUNREACH, EHOSTDOWN, EHOSTUNREACH:
            return "网络或目标服务器不可达，请检查网络连接"
        case ENETRESET:
            return "网络连接已重置，请重试"
        case EPIPE:
            return "网络连接已断开，请重试"
        case ENOTCONN:
            return "网络连接未建立，请重试"
        case ENOSPC:
            return "手机存储空间不足"
        case EACCES, EPERM:
            return "没有访问权限"
        case ENOENT:
            return "找不到指定文件或资源"
        default:
            return "网络连接异常（系统错误 \(code)）"
        }
    }

    private static func formatNWError(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            return mapPOSIXCode(code.rawValue)
        case .dns:
            return "域名解析失败，请检查网络或 DNS 设置"
        case .tls:
            return "安全连接（TLS/SSL）握手失败"
        @unknown default:
            return "网络连接异常，请稍后重试"
        }
    }

    private static func mapWebKitError(_ error: NSError, depth: Int) -> String {
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           let mapped = mapNSError(underlying, depth: depth + 1) {
            return mapped
        }
        switch error.code {
        case WKError.webContentProcessTerminated.rawValue:
            return "网页加载进程意外中断，请重试"
        case WKError.webViewInvalidated.rawValue:
            return "网页视图已失效，请重试"
        case WKError.javaScriptExceptionOccurred.rawValue:
            return "页面内容解析失败，站点结构可能已变化"
        case WKError.javaScriptResultTypeIsUnsupported.rawValue:
            return "页面返回了无法识别的数据"
        case 101:
            return "网页加载已取消"
        case 102:
            return "页面加载被中断，请重试"
        default:
            return "网页加载失败，请检查网络后重试"
        }
    }

    private static func mapAVError(_ error: NSError, depth: Int) -> String {
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           let mapped = mapNSError(underlying, depth: depth + 1) {
            return mapped
        }
        if error.domain == AVFoundationErrorDomain {
            switch error.code {
            case AVError.fileFailedToParse.rawValue, AVError.fileFormatNotRecognized.rawValue:
                return "视频格式无法识别或暂不支持"
            case AVError.decodeFailed.rawValue:
                return "视频解码失败"
            case AVError.contentIsNotAuthorized.rawValue, AVError.contentIsProtected.rawValue:
                return "视频受权限保护，无法播放"
            case AVError.serverIncorrectlyConfigured.rawValue:
                return "视频服务器配置异常，无法播放"
            case AVError.noLongerPlayable.rawValue:
                return "视频资源已失效，请重试"
            case AVError.mediaServicesWereReset.rawValue:
                return "系统媒体服务已重置，请重试"
            default:
                return "视频加载失败，请检查网络后重试"
            }
        }
        return "视频加载失败，请检查网络后重试"
    }

    private static func mapCocoaError(_ error: NSError, depth: Int) -> String? {
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
           let mapped = mapNSError(underlying, depth: depth + 1) {
            return mapped
        }
        switch error.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return "找不到指定文件"
        case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
            return "没有文件访问权限"
        case NSFileWriteOutOfSpaceError:
            return "手机存储空间不足"
        case NSFileWriteFileExistsError:
            return "目标位置已存在同名文件"
        case NSPropertyListReadCorruptError, 4864, 4865:
            return "服务器返回的数据格式异常，无法解析"
        default:
            return nil
        }
    }

    private static func formatDecodingError(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted:
            return "服务器返回的数据格式异常，无法解析"
        case .keyNotFound, .valueNotFound, .typeMismatch:
            return "服务器返回的数据结构不兼容，请稍后重试"
        @unknown default:
            return "数据解析失败，请稍后重试"
        }
    }

    // MARK: - 英文报错文本兜底翻译

    private static func translateCommonEnglishErrorText(_ text: String) -> String? {
        let lower = text.lowercased()

        if lower.contains("internet connection appears to be offline") || lower.contains("not connected to the internet") {
            return "当前无网络连接，请检查 Wi-Fi 或蜂窝网络"
        }
        if lower.contains("request timed out") || lower.contains("connection timed out") || lower.contains("timed out") {
            return "网络连接超时，请检查网络后重试"
        }
        if lower.contains("network connection was lost") || lower.contains("connection lost") {
            return "网络连接意外中断，请重试"
        }
        if lower.contains("hostname could not be found") || lower.contains("cannot find host") || lower.contains("dns lookup failed") {
            return "找不到服务器地址，请检查网络或代理设置"
        }
        if lower.contains("could not connect to the server") || lower.contains("cannot connect to host") || lower.contains("connection refused") {
            return "无法连接到服务器，请检查网络或代理后重试"
        }
        if lower.contains("ssl error") || lower.contains("secure connection") || lower.contains("certificate for this server is invalid") || lower.contains("tls") {
            return "安全连接（TLS/SSL）建立失败，请检查网络或代理"
        }
        if lower.contains("app transport security") {
            return "需要安全连接（HTTPS）才能加载"
        }
        if lower.contains("too many http redirects") {
            return "页面重定向次数过多"
        }
        if lower.contains("bad server response") || lower.contains("cannot parse response") {
            return "服务器响应异常，请稍后重试"
        }
        if lower.contains("zero byte resource") {
            return "服务器未返回任何内容"
        }
        if lower.contains("unsupported url") || lower.contains("bad url") {
            return "请求地址无效"
        }
        if lower.contains("data couldn’t be read") || lower.contains("data couldn't be read") {
            return "服务器返回的数据格式异常，无法解析"
        }
        if lower.contains("javascript exception") {
            return "页面内容解析失败，站点结构可能已变化"
        }
        if lower.contains("cancelled") || lower.contains("canceled") {
            return "请求已取消"
        }
        if let status = extractHTTPStatus(from: lower) {
            return describeHTTPStatus(status)
        }
        if lower.contains("operation couldn’t be completed") || lower.contains("operation couldn't be completed") {
            if lower.contains("nsurlerrordomain") || lower.contains("cfnetwork") || lower.contains("nwerror") {
                return "网络连接失败，请检查网络后重试"
            }
            if lower.contains("posix") {
                return "网络连接异常，请稍后重试"
            }
        }
        return nil
    }

    private static func extractHTTPStatus(from lower: String) -> Int? {
        let pattern = #"(?:http(?:\s+error)?|status(?:\s+code)?|server\s+returned)\s*[:(]?\s*([45]\d{2})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..<lower.endIndex, in: lower)),
              let range = Range(match.range(at: 1), in: lower),
              let code = Int(lower[range]) else {
            return nil
        }
        return code
    }

    private static func describeHTTPStatus(_ code: Int) -> String {
        switch code {
        case 401: return "登录或授权已失效（401）"
        case 403: return "服务器拒绝访问（403），资源地址可能已失效或受限"
        case 404: return "请求的资源不存在（404）"
        case 410: return "资源地址已失效（410）"
        case 429: return "请求过于频繁，请稍后再试（429）"
        case 500...599: return "服务器暂时异常（\(code)），请稍后重试"
        default: return "服务器返回异常状态（\(code)）"
        }
    }

    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }
}

extension Error {
    /// 供界面显示的中文错误提示：网络、连接、解码、播放内核等英文报错都会自动转换为中文。
    var userMessage: String {
        NetworkErrorFormatter.message(for: self)
    }
}
