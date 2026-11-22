import Network
import XCTest
@testable import HPlayer

final class CastServiceTests: XCTestCase {
    private var tempDirectory: URL!
    private var suiteName: String!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CastServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        suiteName = "hplayer.cast-tests.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        if let suiteName {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    // MARK: - DLNA XML & SSDP 解析

    func testParsesUPnPDescriptionWithNestedDeviceListAndRelativeControlURL() throws {
        let xml = """
        <?xml version="1.0"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          <URLBase>http://192.168.1.55:49152</URLBase>
          <device>
            <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
            <friendlyName>客厅电视</friendlyName>
            <manufacturer>Xiaomi</manufacturer>
            <modelName>MiTV-AX</modelName>
            <UDN>uuid:living-room-tv</UDN>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                <controlURL>/upnp/control/AVTransport1</controlURL>
              </service>
              <service>
                <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
                <controlURL>upnp/control/RenderingControl1</controlURL>
              </service>
            </serviceList>
            <deviceList>
              <device>
                <friendlyName>Nested Child Device</friendlyName>
                <UDN>uuid:child-device</UDN>
              </device>
            </deviceList>
          </device>
        </root>
        """
        let location = try XCTUnwrap(URL(string: "http://192.168.1.55:49152/description.xml"))
        let device = try XCTUnwrap(DLNADeviceParser.parseDeviceDescription(Data(xml.utf8), locationURL: location))
        XCTAssertEqual(device.id, "uuid:living-room-tv")
        XCTAssertEqual(device.name, "客厅电视")
        XCTAssertEqual(device.manufacturer, "Xiaomi")
        XCTAssertEqual(device.modelName, "MiTV-AX")
        XCTAssertEqual(device.host, "192.168.1.55")
        XCTAssertEqual(device.avTransportControlURL.absoluteString, "http://192.168.1.55:49152/upnp/control/AVTransport1")
        XCTAssertEqual(device.renderingControlURL?.absoluteString, "http://192.168.1.55:49152/upnp/control/RenderingControl1")
    }

    func testParsesDescriptionWithoutRenderingControlAndExtractsSSDPLocation() throws {
        let xml = """
        <root>
          <device>
            <friendlyName>投影仪</friendlyName>
            <serviceList>
              <service>
                <serviceType>urn:schemas-upnp-org:service:AVTransport:2</serviceType>
                <controlURL>http://192.168.1.88:9999/avt/control</controlURL>
              </service>
            </serviceList>
          </device>
        </root>
        """
        let location = try XCTUnwrap(URL(string: "http://192.168.1.88:9999/dmr.xml"))
        let device = try XCTUnwrap(DLNADeviceParser.parseDeviceDescription(Data(xml.utf8), locationURL: location))
        XCTAssertEqual(device.name, "投影仪")
        XCTAssertEqual(device.avTransportServiceType, "urn:schemas-upnp-org:service:AVTransport:2")
        XCTAssertEqual(device.avTransportControlURL.absoluteString, "http://192.168.1.88:9999/avt/control")
        XCTAssertNil(device.renderingControlURL)

        let ssdp = "HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=1800\r\nlocation: http://192.168.1.88:9999/dmr.xml\r\nST: upnp:rootdevice\r\n\r\n"
        XCTAssertEqual(DLNADeviceParser.parseSSDPHeaders(ssdp), location)
    }

    // MARK: - SOAP 编码与时间转换

    func testDLNATimeFormattingAndParsing() {
        XCTAssertEqual(DLNASoapClient.formatDLNATime(0), "00:00:00")
        XCTAssertEqual(DLNASoapClient.formatDLNATime(65.9), "00:01:05")
        XCTAssertEqual(DLNASoapClient.formatDLNATime(3661), "01:01:01")
        XCTAssertEqual(DLNASoapClient.parseDLNATime("1:02:03.5") ?? -1, 3723.5, accuracy: 0.01)
        XCTAssertEqual(DLNASoapClient.parseDLNATime("04:05") ?? -1, 245, accuracy: 0.01)
        XCTAssertNil(DLNASoapClient.parseDLNATime("NOT_IMPLEMENTED"))
        XCTAssertNil(DLNASoapClient.parseDLNATime("--:--:--"))
        XCTAssertNil(DLNASoapClient.parseDLNATime(""))
    }

    func testDIDLLiteEscapesSpecialCharactersAndIncludesSubtitleTags() throws {
        let videoURL = try XCTUnwrap(URL(string: "http://192.168.1.10:8080/media/tok/A&B.mkv"))
        let subURL = try XCTUnwrap(URL(string: "http://192.168.1.10:8080/sub/tok/sub.srt"))
        let didl = DLNASoapClient.buildDIDLLite(uri: videoURL, title: "S01E01 <测试 & \"剧\">", mimeType: "video/x-matroska", subtitleURL: subURL)
        XCTAssertTrue(didl.contains("S01E01 &lt;测试 &amp; &quot;剧&quot;&gt;"))
        XCTAssertTrue(didl.contains("http-get:*:video/x-matroska:DLNA.ORG_OP=01"))
        XCTAssertTrue(didl.contains("http://192.168.1.10:8080/media/tok/A&amp;B.mkv"))
        XCTAssertTrue(didl.contains("<sec:CaptionInfoEx sec:type=\"srt\">http://192.168.1.10:8080/sub/tok/sub.srt</sec:CaptionInfoEx>"))
    }

    func testSoapClientParsesFaultsAndTransportResponses() async throws {
        let device = CastDevice(
            id: "uuid:mock",
            name: "Mock TV",
            manufacturer: "",
            modelName: "",
            host: "tv.local",
            locationURL: URL(string: "http://tv.local/desc.xml")!,
            avTransportControlURL: URL(string: "http://tv.local/avt")!,
            renderingControlURL: URL(string: "http://tv.local/rc")!,
            avTransportServiceType: "urn:schemas-upnp-org:service:AVTransport:1",
            renderingControlServiceType: "urn:schemas-upnp-org:service:RenderingControl:1",
            isManual: false,
            lastUsedAt: nil
        )
        RoutedURLProtocol.install { request in
            let action = request.value(forHTTPHeaderField: "SOAPACTION") ?? ""
            if action.contains("GetPositionInfo") {
                let xml = """
                <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>
                  <u:GetPositionInfoResponse xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">
                    <TrackDuration>00:45:10</TrackDuration>
                    <RelTime>00:12:34</RelTime>
                    <TrackURI>http://192.168.1.10/video.mp4</TrackURI>
                  </u:GetPositionInfoResponse>
                </s:Body></s:Envelope>
                """
                return .init(status: 200, headers: ["Content-Type": "text/xml"], body: Data(xml.utf8))
            }
            if action.contains("GetVolume") {
                let xml = "<s:Envelope><s:Body><u:GetVolumeResponse><CurrentVolume>42</CurrentVolume></u:GetVolumeResponse></s:Body></s:Envelope>"
                return .init(status: 200, headers: ["Content-Type": "text/xml"], body: Data(xml.utf8))
            }
            let fault = "<s:Envelope><s:Body><s:Fault><faultstring>UPnPError</faultstring><detail><UPnPError><errorCode>714</errorCode><errorDescription>Illegal MIME-type</errorDescription></UPnPError></detail></s:Fault></s:Body></s:Envelope>"
            return .init(status: 500, headers: ["Content-Type": "text/xml"], body: Data(fault.utf8))
        }

        let client = DLNASoapClient(session: RoutedURLProtocol.session())
        let pos = try await client.getPositionInfo(device: device)
        XCTAssertEqual(pos.duration, 45 * 60 + 10, accuracy: 0.1)
        XCTAssertEqual(pos.relTime, 12 * 60 + 34, accuracy: 0.1)
        let volume = await client.getVolume(device: device)
        XCTAssertEqual(volume, 42)

        do {
            try await client.play(device: device)
            XCTFail("Expected SOAP fault to throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("714"))
        }
    }

    // MARK: - CastMediaServer 本地文件、Range、代理与 m3u8 改写

    func testCastMediaServerServesLocalFileWithHeadRangeAndInvalidatesOnStop() async throws {
        let fileURL = tempDirectory.appendingPathComponent("sample.mkv")
        let payload = Data("0123456789ABCDEF".utf8)
        try payload.write(to: fileURL)

        let server = CastMediaServer(bindHostOverride: "127.0.0.1")
        defer { server.stop() }

        let descriptor = CastMediaDescriptor(
            url: fileURL,
            localProxyURL: nil,
            title: "Sample",
            headers: [:],
            position: 0,
            duration: 100,
            subtitleFileURL: nil,
            isTorrentStream: false
        )
        let maybeRegistered = await server.registerMedia(descriptor)
        let registered = try XCTUnwrap(maybeRegistered)
        XCTAssertEqual(registered.mimeType, "video/x-matroska")

        var headReq = URLRequest(url: registered.url)
        headReq.httpMethod = "HEAD"
        let (headData, headResp) = try await URLSession.shared.data(for: headReq)
        let headHTTP = try XCTUnwrap(headResp as? HTTPURLResponse)
        XCTAssertEqual(headHTTP.statusCode, 200)
        XCTAssertTrue(headData.isEmpty)
        XCTAssertEqual(headHTTP.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")
        XCTAssertEqual(headHTTP.value(forHTTPHeaderField: "Content-Length"), "\(payload.count)")

        var rangeReq = URLRequest(url: registered.url)
        rangeReq.setValue("bytes=4-9", forHTTPHeaderField: "Range")
        let (rangeData, rangeResp) = try await URLSession.shared.data(for: rangeReq)
        let rangeHTTP = try XCTUnwrap(rangeResp as? HTTPURLResponse)
        XCTAssertEqual(rangeHTTP.statusCode, 206)
        XCTAssertEqual(rangeHTTP.value(forHTTPHeaderField: "Content-Range"), "bytes 4-9/16")
        XCTAssertEqual(String(decoding: rangeData, as: UTF8.self), "456789")

        // 非法令牌返回 404
        let badURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(registered.url.port!)/media/unknown/sample.mkv"))
        let (_, badResp) = try await URLSession.shared.data(from: badURL)
        XCTAssertEqual((badResp as? HTTPURLResponse)?.statusCode, 404)

        // 停止服务后原链接失效
        server.stop()
        try await Task.sleep(nanoseconds: 100_000_000)
        do {
            _ = try await URLSession.shared.data(from: registered.url)
            XCTFail("Expected request after stop() to fail")
        } catch {
            // Expected connection refused / error
        }
    }

    func testCastMediaServerProxiesAndRewritesM3U8EndToEnd() async throws {
        let upstream = try LoopbackHTTPServer { path, method, headers in
            if path == "/live/index.m3u8" {
                let m3u8 = """
                #EXTM3U
                #EXT-X-VERSION:3
                #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
                #EXTINF:5.0,
                seg0.ts
                #EXTINF:5.0,
                http://127.0.0.1:\(headers["__port"] ?? "0")/chunks/seg1.ts
                #EXT-X-ENDLIST
                """
                return .init(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(m3u8.utf8))
            }
            if path == "/live/key.bin" {
                return .init(status: 200, headers: ["Content-Type": "application/octet-stream"], body: Data("KEYDATA".utf8))
            }
            if path == "/live/seg0.ts" {
                return .init(status: 200, headers: ["Content-Type": "video/mp2t"], body: Data("SEGMENT0".utf8))
            }
            if path == "/chunks/seg1.ts" {
                if method == "HEAD" {
                    return .init(status: 405, headers: [:], body: Data())
                }
                if headers["range"] == "bytes=0-0" {
                    return .init(status: 206, headers: ["Content-Range": "bytes 0-0/8", "Content-Type": "video/mp2t"], body: Data("S".utf8))
                }
                return .init(status: 200, headers: ["Content-Type": "video/mp2t"], body: Data("SEGMENT1".utf8))
            }
            return .init(status: 404, headers: [:], body: Data())
        }
        defer { upstream.stop() }

        let server = CastMediaServer(bindHostOverride: "127.0.0.1")
        defer { server.stop() }

        let masterURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(upstream.port)/live/index.m3u8"))
        let descriptor = CastMediaDescriptor(
            url: masterURL,
            localProxyURL: nil,
            title: "Anime Ep 1",
            headers: ["Referer": "https://anime.example/"],
            position: 0,
            duration: 10,
            subtitleFileURL: nil,
            isTorrentStream: false
        )
        let maybeRegistered = await server.registerMedia(descriptor)
        let registered = try XCTUnwrap(maybeRegistered)

        let (m3u8Data, m3u8Resp) = try await URLSession.shared.data(from: registered.url)
        XCTAssertEqual((m3u8Resp as? HTTPURLResponse)?.statusCode, 200)
        let rewritten = String(decoding: m3u8Data, as: UTF8.self)
        XCTAssertTrue(rewritten.contains("/hls/"))
        XCTAssertFalse(rewritten.contains("URI=\"key.bin\""))

        // 解析改写后的分片和密钥链接并逐个通过 CastMediaServer 拉取成功
        let hlsLinks = rewritten.components(separatedBy: CharacterSet.newlines).compactMap { line -> URL? in
            if let uriStart = line.range(of: "URI=\"") {
                let rest = line[uriStart.upperBound...]
                if let uriEnd = rest.firstIndex(of: "\"") {
                    return URL(string: String(rest[..<uriEnd]))
                }
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            return URL(string: trimmed)
        }
        XCTAssertEqual(hlsLinks.count, 3)

        let (keyData, _) = try await URLSession.shared.data(from: hlsLinks[0])
        let (seg0Data, _) = try await URLSession.shared.data(from: hlsLinks[1])
        let (seg1Data, _) = try await URLSession.shared.data(from: hlsLinks[2])
        XCTAssertEqual(String(decoding: keyData, as: UTF8.self), "KEYDATA")
        XCTAssertEqual(String(decoding: seg0Data, as: UTF8.self), "SEGMENT0")
        XCTAssertEqual(String(decoding: seg1Data, as: UTF8.self), "SEGMENT1")

        // 验证 HEAD 遇到上游 405 时自动降级为 bytes=0-0 返回 200 与总长度
        var headSeg1 = URLRequest(url: hlsLinks[2])
        headSeg1.httpMethod = "HEAD"
        let (_, headResp) = try await URLSession.shared.data(for: headSeg1)
        let headHTTP = try XCTUnwrap(headResp as? HTTPURLResponse)
        XCTAssertEqual(headHTTP.statusCode, 200)
        XCTAssertEqual(headHTTP.value(forHTTPHeaderField: "Content-Length"), "8")
    }

    // MARK: - CastManager 完整投屏生命周期（连接 -> 起播续播跳转 -> 暂停 -> 跳转 -> 音量 -> 退出）

    @MainActor
    func testCastManagerEndToEndDLNALifecycle() async throws {
        let videoFile = tempDirectory.appendingPathComponent("movie.mp4")
        try Data("MP4BYTES".utf8).write(to: videoFile)

        let lock = NSLock()
        var soapActions: [String] = []
        var seekTargets: [String] = []
        var transportState = "STOPPED"
        var currentVolume = 35
        var relTime = "00:00:00"

        let renderer = try LoopbackHTTPServer { path, _, headers in
            let action = headers["soapaction"] ?? ""
            lock.lock()
            if !action.isEmpty { soapActions.append(action) }
            let bodyText = headers["__body"] ?? ""
            if action.contains("#Stop") {
                transportState = "STOPPED"
                lock.unlock()
                return .init(status: 200, headers: ["Content-Type": "text/xml"], body: Data("<s:Envelope><s:Body><u:StopResponse/></s:Body></s:Envelope>".utf8))
            }
            if action.contains("#SetAVTransportURI") {
                lock.unlock()
                return .init(status: 200, headers: ["Content-Type": "text/xml"], body: Data("<s:Envelope><s:Body><u:SetAVTransportURIResponse/></s:Body></s:Envelope>".utf8))
            }
            if action.contains("#Play") {
                transportState = "PLAYING"
                lock.unlock()
                return .init(status: 200, headers: ["Content-Type": "text/xml"], body: Data("<s:Envelope><s:Body><u:PlayResponse/></s:Body></s:Envelope>".utf8))
            }
            if action.contains("#Pause") {
                transportState = "PAUSED_PLAYBACK"
                lock.unlock()
                return .init(status: 200, headers: ["Content-Type": "text/xml"], body: Data("<s:Envelope><s:Body><u:PauseResponse/></s:Body></s:Envelope>".utf8))
            }
            if action.contains("#Seek") {
                if let start = bodyText.range(of: "<Target>"), let end = bodyText.range(of: "</Target>") {
                    let target = String(bodyText[start.upperBound..<end.lowerBound])
                    seekTargets.append(target)
                    relTime = target
                }
                lock.unlock()
                return .init(status: 200, headers: ["Content-Type": "text/xml"], body: Data("<s:Envelope><s:Body><u:SeekResponse/></s:Body></s:Envelope>".utf8))
            }
            if action.contains("#GetTransportInfo") {
                let state = transportState
                lock.unlock()
                let xml = "<s:Envelope><s:Body><u:GetTransportInfoResponse><CurrentTransportState>\(state)</CurrentTransportState></u:GetTransportInfoResponse></s:Body></s:Envelope>"
                return .init(status: 200, headers: ["Content-Type": "text/xml"], body: Data(xml.utf8))
            }
            if action.contains("#GetPositionInfo") {
                let current = relTime
                lock.unlock()
                let xml = "<s:Envelope><s:Body><u:GetPositionInfoResponse><TrackDuration>00:10:00</TrackDuration><RelTime>\(current)</RelTime></u:GetPositionInfoResponse></s:Body></s:Envelope>"
                return .init(status: 200, headers: ["Content-Type": "text/xml"], body: Data(xml.utf8))
            }
            if action.contains("#GetVolume") {
                let vol = currentVolume
                lock.unlock()
                let xml = "<s:Envelope><s:Body><u:GetVolumeResponse><CurrentVolume>\(vol)</CurrentVolume></u:GetVolumeResponse></s:Body></s:Envelope>"
                return .init(status: 200, headers: ["Content-Type": "text/xml"], body: Data(xml.utf8))
            }
            if action.contains("#SetVolume") {
                if let start = bodyText.range(of: "<DesiredVolume>"), let end = bodyText.range(of: "</DesiredVolume>") {
                    currentVolume = Int(bodyText[start.upperBound..<end.lowerBound]) ?? currentVolume
                }
                lock.unlock()
                return .init(status: 200, headers: ["Content-Type": "text/xml"], body: Data("<s:Envelope><s:Body><u:SetVolumeResponse/></s:Body></s:Envelope>".utf8))
            }
            if path == "/description.xml" {
                lock.unlock()
                let desc = """
                <root>
                  <device>
                    <friendlyName>测试客厅电视</friendlyName>
                    <UDN>uuid:mock-tv-e2e</UDN>
                    <serviceList>
                      <service>
                        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
                        <controlURL>/avt</controlURL>
                      </service>
                      <service>
                        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
                        <controlURL>/rc</controlURL>
                      </service>
                    </serviceList>
                  </device>
                </root>
                """
                return .init(status: 200, headers: ["Content-Type": "text/xml"], body: Data(desc.utf8))
            }
            lock.unlock()
            return .init(status: 404, headers: [:], body: Data())
        }
        defer { renderer.stop() }

        let defaults = UserDefaults(suiteName: suiteName)!
        let discovery = DLNADiscovery(defaults: defaults)
        let manualDevice = try await discovery.addManualDevice(input: "127.0.0.1:\(renderer.port)")
        XCTAssertEqual(manualDevice.name, "测试客厅电视")

        // 重新实例化的 discovery 能恢复已保存的设备并支持删除
        let reloaded = DLNADiscovery(defaults: defaults)
        XCTAssertEqual(reloaded.devices.map(\.id), ["uuid:mock-tv-e2e"])
        reloaded.removeSavedDevice(id: "uuid:mock-tv-e2e")
        XCTAssertTrue(reloaded.devices.isEmpty)

        let manager = CastManager(
            discovery: discovery,
            soap: DLNASoapClient(),
            server: CastMediaServer(bindHostOverride: "127.0.0.1"),
            enableKeepAlive: false
        )

        var startedCalled = false
        var stoppedInfo: (Bool, Double)?
        manager.onStartedCasting = { startedCalled = true }
        manager.onStoppedCasting = { resumeLocal, time in stoppedInfo = (resumeLocal, time) }

        let media = CastMediaDescriptor(
            url: videoFile,
            localProxyURL: nil,
            title: "Test Movie",
            headers: [:],
            position: 45,
            duration: 600,
            subtitleFileURL: nil,
            isTorrentStream: false
        )
        await manager.castToDLNA(manualDevice, media: media)
        XCTAssertTrue(startedCalled)
        XCTAssertTrue(manager.isCasting)
        XCTAssertEqual(manager.volume, 35)

        // 等待轮询周期收到 PLAYING 并触发开播续播跳转 Seek(00:00:45)
        for _ in 0..<25 {
            let hasInitialSeek = lock.withLock { seekTargets.contains("00:00:45") }
            if hasInitialSeek { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(lock.withLock { seekTargets.contains("00:00:45") })

        manager.togglePlayPause()
        manager.seek(to: 120)
        manager.adjustVolume(delta: 10)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertEqual(manager.volume, 45)
        XCTAssertTrue(lock.withLock { seekTargets.contains("00:02:00") })

        manager.stopCasting(resumeLocal: true)
        XCTAssertFalse(manager.isCasting)
        XCTAssertEqual(stoppedInfo?.0, true)
        XCTAssertEqual(stoppedInfo?.1 ?? 0, 120, accuracy: 2.0)

        try await Task.sleep(nanoseconds: 150_000_000)
        let recorded = lock.withLock { soapActions }
        XCTAssertTrue(recorded.contains { $0.contains("#SetAVTransportURI") })
        XCTAssertTrue(recorded.contains { $0.contains("#Play") })
        XCTAssertTrue(recorded.contains { $0.contains("#Pause") })
        XCTAssertTrue(recorded.contains { $0.contains("#SetVolume") })
        XCTAssertTrue(recorded.contains { $0.contains("#Stop") })
    }

    // MARK: - 手动地址候选与 AirPlay 格式兼容性

    @MainActor
    func testManualCandidateURLGenerationAndAirPlayFormatCheck() {
        let bareIP = DLNADiscovery.candidateDescriptionURLs(for: "192.168.1.20")
        XCTAssertTrue(bareIP.contains(URL(string: "http://192.168.1.20:49152/description.xml")!))
        XCTAssertTrue(bareIP.contains(URL(string: "http://192.168.1.20:8200/rootDesc.xml")!))

        let withPort = DLNADiscovery.candidateDescriptionURLs(for: "192.168.1.20:9999")
        XCTAssertEqual(withPort.first, URL(string: "http://192.168.1.20:9999/description.xml"))

        let full = DLNADiscovery.candidateDescriptionURLs(for: "http://192.168.1.20:1567/custom.xml")
        XCTAssertEqual(full, [URL(string: "http://192.168.1.20:1567/custom.xml")!])

        XCTAssertFalse(AirPlayCastController.isAirPlayNativelySupported(url: URL(string: "https://cdn.example/movie.mkv")!))
        XCTAssertFalse(AirPlayCastController.isAirPlayNativelySupported(url: URL(fileURLWithPath: "/tmp/clip.avi")))
        XCTAssertFalse(AirPlayCastController.isAirPlayNativelySupported(url: URL(string: "https://cdn.example/clip.flv")!))
        XCTAssertFalse(AirPlayCastController.isAirPlayNativelySupported(url: URL(string: "https://cdn.example/clip.webm")!))
        XCTAssertTrue(AirPlayCastController.isAirPlayNativelySupported(url: URL(string: "https://cdn.example/index.m3u8")!))
        XCTAssertTrue(AirPlayCastController.isAirPlayNativelySupported(url: URL(string: "https://cdn.example/movie.mp4")!))
        XCTAssertTrue(AirPlayCastController.isAirPlayNativelySupported(url: URL(string: "https://cdn.example/clip.mov")!))
        XCTAssertTrue(AirPlayCastController.isAirPlayNativelySupported(url: URL(string: "https://cdn.example/stream")!))
    }
}

// MARK: - 轻量环回测试服务器

private final class LoopbackHTTPServer {
    struct Reply {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private(set) var port: UInt16 = 0
    private let queue = DispatchQueue(label: "hplayer.cast-test-http")
    private let listener: NWListener
    private let handler: (String, String, [String: String]) -> Reply

    init(handler: @escaping (String, String, [String: String]) -> Reply) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        var boundPort: UInt16 = 0
        var startError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                boundPort = listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                startError = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw XCTSkip("Timed out starting loopback HTTP server")
        }
        if let startError {
            listener.cancel()
            throw startError
        }
        self.port = boundPort
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
                guard let self else { connection.cancel(); return }
                if let data { buffer.append(data) }
                if let separator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let headerData = buffer.subdata(in: 0..<separator.lowerBound)
                    let headerText = String(decoding: headerData, as: UTF8.self)
                    let lines = headerText.components(separatedBy: "\r\n")
                    let parts = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: true)
                    let method = parts.count > 0 ? String(parts[0]).uppercased() : "GET"
                    let path = parts.count > 1 ? String(parts[1]) : "/"

                    var headers: [String: String] = ["__port": "\(self.port)"]
                    var contentLength = 0
                    for line in lines.dropFirst() {
                        guard let colon = line.firstIndex(of: ":") else { continue }
                        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                        let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        headers[key] = val
                        if key == "content-length" { contentLength = Int(val) ?? 0 }
                    }

                    let bodyStart = separator.upperBound
                    if buffer.count - bodyStart >= contentLength {
                        let bodyData = buffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                        headers["__body"] = String(decoding: bodyData, as: UTF8.self)
                        let reply = self.handler(path, method, headers)
                        var responseText = "HTTP/1.1 \(reply.status) \(HTTPURLResponse.localizedString(forStatusCode: reply.status))\r\n"
                        responseText += "Content-Length: \(reply.body.count)\r\n"
                        for (k, v) in reply.headers {
                            responseText += "\(k): \(v)\r\n"
                        }
                        responseText += "Connection: close\r\n\r\n"
                        var payload = Data(responseText.utf8)
                        if method != "HEAD" { payload.append(reply.body) }
                        connection.send(content: payload, completion: .contentProcessed { _ in
                            connection.cancel()
                        })
                        return
                    }
                }
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    receiveMore()
                }
            }
        }
        receiveMore()
    }
}
