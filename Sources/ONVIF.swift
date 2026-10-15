import Foundation
import CryptoKit
import Darwin

struct ONVIFDevice: Identifiable, Sendable { let id: String; let name: String; let endpoint: URL; let scopes: [String] }
struct ONVIFProfile: Identifiable, Sendable { let id: String; let name: String; let streamURL: URL? }
struct ONVIFCredentials: Sendable { let username: String; let password: String }
struct ONVIFPreset: Identifiable, Sendable { let id: String; let name: String }

enum ONVIFError: Error, LocalizedError, Sendable {
    case missingCredentials, invalidEndpoint, malformedXML, missingMediaService, unsupportedPTZ
    case invalidResponse(String), http(Int), soap(code: String, reason: String), transport(Int), discovery(String)
    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "请输入摄像头用户名和密码。"
        case .invalidEndpoint: return "ONVIF 服务地址必须是有效的 HTTP 或 HTTPS 地址。"
        case .malformedXML: return "摄像头返回了无效的 XML。"
        case .missingMediaService: return "摄像头未提供 ONVIF Media 服务地址。"
        case .unsupportedPTZ: return "摄像头未提供 ONVIF PTZ 服务。"
        case .invalidResponse(let detail): return "ONVIF 响应不完整：\(detail)"
        case .http(let status): return "ONVIF HTTP 状态 \(status)（401/403 表示认证失败）。"
        case .soap(let code, let reason): return "ONVIF SOAP Fault [\(code)]：\(reason)"
        case .transport(let code): return "摄像头网络请求失败（URLSession \(code)）。"
        case .discovery(let detail): return "ONVIF 发现失败：\(detail)"
        }
    }
}

// Deterministic internal helpers support offline fixture tests.
enum ONVIFXML {
    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }
    static func passwordDigest(nonce: Data, created: String, password: String) -> String {
        var bytes = nonce; bytes.append(Data(created.utf8)); bytes.append(Data(password.utf8))
        return Data(Insecure.SHA1.hash(data: bytes)).base64EncodedString()
    }
    static func security(_ credentials: ONVIFCredentials) -> String {
        let nonce = Data((0..<20).map { _ in UInt8.random(in: .min ... .max) })
        let created = ISO8601DateFormatter().string(from: Date())
        let digest = passwordDigest(nonce: nonce, created: created, password: credentials.password)
        return """
        <wsse:Security s:mustUnderstand="1" xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>\(escape(credentials.username))</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digest)</wsse:Password><wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonce.base64EncodedString())</wsse:Nonce><wsu:Created>\(created)</wsu:Created></wsse:UsernameToken></wsse:Security>
        """
    }
    static func sanitize(_ text: String, credentials: ONVIFCredentials) -> String {
        var result = text
        let basic = Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString()
        for secret in [basic, credentials.password, credentials.username].sorted(by: { $0.count > $1.count }) where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: "[redacted]")
        }
        return String(result.prefix(512))
    }
    static func fault(_ root: ONVIFElement, credentials: ONVIFCredentials, status: Int? = nil) -> ONVIFError? {
        guard let fault = root.first("Fault") else { return nil }
        let code = fault.first("Value")?.value ?? fault.first("faultcode")?.value ?? "Unknown"
        let reason = fault.first("Text")?.value ?? fault.first("faultstring")?.value ?? "摄像头返回 SOAP 错误"
        let prefix = status.map { "HTTP \($0); " } ?? ""
        return .soap(code: sanitize(prefix + code, credentials: credentials), reason: sanitize(reason, credentials: credentials))
    }
    static func endpoint(_ text: String) -> URL? {
        guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func velocity(_ value: Double) -> Double { value.isFinite ? min(1, max(-1, value)) : 0 }
    static func profiles(_ root: ONVIFElement) -> [(String, String)] {
        root.all("Profiles").compactMap { node in
            guard let token = node.attributes["token"], !token.isEmpty else { return nil }
            return (token, node.first("Name")?.value ?? token)
        }
    }
    static func devices(_ root: ONVIFElement) -> [ONVIFDevice] {
        root.all("ProbeMatch").compactMap { match in
            let types = match.first("Types")?.value ?? ""
            guard types.isEmpty || types.contains("NetworkVideo") || types.contains("Device") else { return nil }
            let addresses = (match.first("XAddrs")?.value ?? "").split(whereSeparator: { $0.isWhitespace })
            guard let endpoint = addresses.compactMap({ self.endpoint(String($0)) }).first else { return nil }
            let scopes = (match.first("Scopes")?.value ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let name = scopes.first(where: { $0.contains("/name/") }).flatMap { $0.components(separatedBy: "/name/").last?.removingPercentEncoding } ?? endpoint.host ?? "ONVIF Camera"
            return ONVIFDevice(id: match.first("Address")?.value ?? endpoint.absoluteString, name: name, endpoint: endpoint, scopes: scopes)
        }
    }
}

final class ONVIFElement {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [ONVIFElement] = []
    var value: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    init(name: String, attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }
    func first(_ name: String) -> ONVIFElement? {
        if self.name == name { return self }
        for child in children { if let found = child.first(name) { return found } }
        return nil
    }
    func all(_ name: String) -> [ONVIFElement] { (self.name == name ? [self] : []) + children.flatMap { $0.all(name) } }
}
final class ONVIFParser: NSObject, XMLParserDelegate {
    private var stack: [ONVIFElement] = []
    private var root: ONVIFElement?
    private var count = 0
    static func parse(_ data: Data) throws -> ONVIFElement {
        guard data.count <= 4 * 1024 * 1024 else { throw ONVIFError.invalidResponse("XML 超过 4 MiB") }
        let delegate = ONVIFParser(); let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { throw ONVIFError.malformedXML }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        count += 1
        guard stack.count < 64, count <= 40000 else { parser.abortParsing(); return }
        let node = ONVIFElement(name: name, attributes: attributes)
        stack.last?.children.append(node)
        if root == nil { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { stack.last?.text += String(decoding: data, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if !stack.isEmpty { stack.removeLast() } }
}

actor ONVIFClient {
    private let endpoint: URL
    private let credentials: ONVIFCredentials
    private let session: URLSession
    private var media: URL?
    private var ptz: URL?
    private var capabilitiesLoaded = false
    init(endpoint: URL, credentials: ONVIFCredentials) {
        self.endpoint = endpoint; self.credentials = credentials
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8; configuration.timeoutIntervalForResource = 8
        configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil
        self.session = URLSession(configuration: configuration)
    }
    private func request(_ service: URL, namespace: String, operation: String, content: String = "") async throws -> ONVIFElement {
        guard !credentials.username.isEmpty, !credentials.password.isEmpty else { throw ONVIFError.missingCredentials }
        guard ONVIFXML.endpoint(service.absoluteString) != nil else { throw ONVIFError.invalidEndpoint }
        let action = "\(namespace)/\(operation)"
        let envelope = """
        <?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Header>\(ONVIFXML.security(credentials))</s:Header><s:Body><m:\(operation) xmlns:m="\(namespace)">\(content)</m:\(operation)></s:Body></s:Envelope>
        """
        // Retry once with HTTP Basic as well after an HTTP 401.
        for basic in [false, true] {
            try Task.checkCancellation()
            var request = URLRequest(url: service, timeoutInterval: 8)
            request.httpMethod = "POST"; request.httpBody = Data(envelope.utf8)
            request.setValue("application/soap+xml; charset=utf-8; action=\"\(action)\"", forHTTPHeaderField: "Content-Type")
            request.setValue("\"\(action)\"", forHTTPHeaderField: "SOAPAction")
            if basic { request.setValue("Basic " + Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
            let data: Data; let response: URLResponse
            do { (data, response) = try await session.data(for: request, delegate: ONVIFRedirectGuard()) }
            catch { if Task.isCancelled { throw CancellationError() }; throw ONVIFError.transport((error as NSError).code) }
            guard let http = response as? HTTPURLResponse else { throw ONVIFError.invalidResponse("缺少 HTTP 状态") }
            if http.statusCode == 401 && !basic { continue }
            let root = try? ONVIFParser.parse(data)
            if let root, let fault = ONVIFXML.fault(root, credentials: credentials, status: http.statusCode) { throw fault }
            guard (200..<300).contains(http.statusCode) else { throw ONVIFError.http(http.statusCode) }
            guard let root else { throw ONVIFError.malformedXML }
            guard root.first(operation + "Response") != nil else { throw ONVIFError.invalidResponse("缺少 \(operation)Response") }
            return root
        }
        throw ONVIFError.http(401)
    }
    private func capabilities() async throws {
        if capabilitiesLoaded { return }
        let root = try await request(endpoint, namespace: "http://www.onvif.org/ver10/device/wsdl", operation: "GetCapabilities", content: "<m:Category>All</m:Category>")
        media = root.first("Media")?.first("XAddr").flatMap { ONVIFXML.endpoint($0.value) }
        ptz = root.first("PTZ")?.first("XAddr").flatMap { ONVIFXML.endpoint($0.value) }
        capabilitiesLoaded = true
    }
    func profiles() async throws -> [ONVIFProfile] {
        try await capabilities()
        guard let media else { throw ONVIFError.missingMediaService }
        let namespace = "http://www.onvif.org/ver10/media/wsdl"
        let root = try await request(media, namespace: namespace, operation: "GetProfiles")
        var result: [ONVIFProfile] = []
        for (token, name) in ONVIFXML.profiles(root) {
            let uri = try await request(media, namespace: namespace, operation: "GetStreamUri", content: "<m:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></m:StreamSetup><m:ProfileToken>\(ONVIFXML.escape(token))</m:ProfileToken>")
            guard let text = uri.first("Uri")?.value, let url = URL(string: text), ["rtsp", "rtsps"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { throw ONVIFError.invalidResponse("缺少有效的 RTSP Uri") }
            result.append(ONVIFProfile(id: token, name: name, streamURL: url))
        }
        return result
    }
    private func ptzRequest(_ operation: String, profileToken: String, extra: String = "") async throws {
        try await capabilities()
        guard let ptz else { throw ONVIFError.unsupportedPTZ }
        guard !profileToken.isEmpty else { throw ONVIFError.invalidResponse("ProfileToken 为空") }
        _ = try await request(ptz, namespace: "http://www.onvif.org/ver20/ptz/wsdl", operation: operation, content: "<m:ProfileToken>\(ONVIFXML.escape(profileToken))</m:ProfileToken>" + extra)
    }
    // ContinuousMove continues until stop() is explicitly called by the caller/device timeout.
    func move(profileToken: String, pan: Double, tilt: Double, zoom: Double) async throws {
        let p=ONVIFXML.velocity(pan),t=ONVIFXML.velocity(tilt),z=ONVIFXML.velocity(zoom)
        if p==0 && t==0 && z==0 { try await stop(profileToken:profileToken);return }
        var axes=""
        if p != 0 || t != 0 { axes += "<tt:PanTilt x=\"\(p)\" y=\"\(t)\"/>" }
        if z != 0 { axes += "<tt:Zoom x=\"\(z)\"/>" }
        try await ptzRequest("ContinuousMove", profileToken: profileToken, extra: "<m:Velocity>\(axes)</m:Velocity><m:Timeout>PT1S</m:Timeout>")
    }
    func stop(profileToken: String) async throws { try await ptzRequest("Stop", profileToken: profileToken, extra: "<m:PanTilt>true</m:PanTilt><m:Zoom>true</m:Zoom>") }
    func home(profileToken: String) async throws { try await ptzRequest("GotoHomePosition", profileToken: profileToken) }
    func presets(profileToken: String) async throws -> [ONVIFPreset] {
        try await capabilities()
        guard let ptz else { throw ONVIFError.unsupportedPTZ }
        guard !profileToken.isEmpty else { throw ONVIFError.invalidResponse("ProfileToken 为空") }
        let root = try await request(ptz, namespace: "http://www.onvif.org/ver20/ptz/wsdl", operation: "GetPresets", content: "<m:ProfileToken>\(ONVIFXML.escape(profileToken))</m:ProfileToken>")
        return root.all("Preset").compactMap { node in
            guard let token = node.attributes["token"], !token.isEmpty else { return nil }
            return ONVIFPreset(id: token, name: node.first("Name")?.value ?? token)
        }
    }
    func gotoPreset(profileToken: String, presetToken: String) async throws {
        guard !presetToken.isEmpty else { throw ONVIFError.invalidResponse("PresetToken 为空") }
        try await ptzRequest("GotoPreset", profileToken: profileToken, extra: "<m:PresetToken>\(ONVIFXML.escape(presetToken))</m:PresetToken>")
    }
}
// Never forward WSSE credentials through redirects.
private final class ONVIFRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

final class ONVIFDiscovery: @unchecked Sendable {
    func discover(timeout: TimeInterval = 3) async throws -> [ONVIFDevice] {
        guard timeout.isFinite, timeout > 0, timeout <= 60 else { throw ONVIFError.discovery("超时必须在 0 到 60 秒之间") }
        let state = ONVIFDiscoveryCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try self.scan(timeout: timeout, state: state)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { state.cancel() })
    }
    private func scan(timeout: TimeInterval, state: ONVIFDiscoveryCancellation) throws -> [ONVIFDevice] {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ONVIFError.discovery("socket errno \(errno)") }
        defer { Darwin.close(fd) }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw ONVIFError.discovery("fcntl errno \(errno)") }
        var local = sockaddr_in()
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); local.sin_family = sa_family_t(AF_INET)
        let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw ONVIFError.discovery("bind errno \(errno)") }
        var ttl: UInt8 = 1
        guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout.size(ofValue: ttl))) == 0 else { throw ONVIFError.discovery("multicast errno \(errno)") }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); target.sin_family = sa_family_t(AF_INET); target.sin_port = UInt16(3702).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &target.sin_addr)
        let probe = Data("""
        <?xml version="1.0" encoding="UTF-8"?><s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://schemas.xmlsoap.org/ws/2004/08/addressing" xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery" xmlns:dn="http://www.onvif.org/ver10/network/wsdl"><s:Header><a:MessageID>urn:uuid:\(UUID().uuidString)</a:MessageID><a:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To><a:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action></s:Header><s:Body><d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe></s:Body></s:Envelope>
        """.utf8)
        if state.isCancelled { throw CancellationError() }
        let sent = probe.withUnsafeBytes { bytes in withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        guard sent == probe.count else { throw ONVIFError.discovery("sendto errno \(errno)") }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var devices: [String: ONVIFDevice] = [:]; var buffer = [UInt8](repeating: 0, count: 65536); var packets = 0
        while ProcessInfo.processInfo.systemUptime < deadline && packets < 2048 {
            if state.isCancelled { throw CancellationError() }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(max(1, min(100, remaining * 1000))))
            if ready < 0 { if errno == EINTR { continue }; throw ONVIFError.discovery("poll errno \(errno)") }
            if ready == 0 { continue }
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count < 0 { if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue }; throw ONVIFError.discovery("recv errno \(errno)") }
            packets += 1
            if let root = try? ONVIFParser.parse(Data(buffer.prefix(count))) { for device in ONVIFXML.devices(root) { devices[device.endpoint.absoluteString] = device } }
        }
        if state.isCancelled { throw CancellationError() }
        return devices.values.sorted { $0.endpoint.absoluteString < $1.endpoint.absoluteString }
    }
}
private final class ONVIFDiscoveryCancellation: @unchecked Sendable {
    private let lock = NSLock(); private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}
