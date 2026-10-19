import AppKit
import Darwin
import CryptoKit
import Security
import ImageIO
import UniformTypeIdentifiers

let MiB: Int64 = 1_048_576
let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CopyBridge")
let received = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("CopyBridge Received")
let marker = NSPasteboard.PasteboardType("com.copybridge.origin")
struct BridgeError: Error { let code: String; init(_ code: String) { self.code = code } }
func hex<D: Sequence>(_ data: D) -> String where D.Element == UInt8 { data.map { String(format: "%02x", $0) }.joined() }
func safeName(_ name: String) -> Bool {
    if name.isEmpty || name.utf16.count > 240 || name == "." || name == ".." || name.hasSuffix(".") || name.hasSuffix(" ") { return false }
    if name.unicodeScalars.contains(where: { $0.value < 32 || "<>:\"/\\|?*".unicodeScalars.contains($0) }) { return false }
    let stem = name.split(separator: ".").first.map(String.init)?.uppercased() ?? ""
    return !(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] }).contains(stem)
}
func fileMIME(_ name: String) -> String {
    ["png":"image/png", "jpg":"image/jpeg", "jpeg":"image/jpeg", "mp4":"video/mp4"][(name as NSString).pathExtension.lowercased()] ?? "application/octet-stream"
}
func validate(kind: String, item: Item) throws {
    guard item.itemId == "f1", safeName(item.name), item.sizeBytes >= 0,
          item.sha256.count == 64, item.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw BridgeError("INVALID_METADATA") }
    let limit: Int64
    switch kind {
    case "text": guard item.mime == "text/plain" else { throw BridgeError("TYPE_UNSUPPORTED") }; limit = MiB
    case "image": guard item.mime == "image/png" else { throw BridgeError("TYPE_UNSUPPORTED") }; limit = 32 * MiB
    case "file": guard fileMIME(item.name) == item.mime else { throw BridgeError("TYPE_UNSUPPORTED") }; limit = 2048 * MiB
    default: throw BridgeError("TYPE_UNSUPPORTED")
    }
    guard item.sizeBytes <= limit else { throw BridgeError("SIZE_LIMIT") }
}
struct Config: Codable { var url: String; var deviceId: String; var certificateSha256: String; var keychainAccount: String }
struct Item: Codable { var itemId = "f1"; var name: String; var mime: String; var sizeBytes: Int64; var sha256: String }
struct Outgoing: Codable { var transferId: String; var generation: Int64; var kind: String; var item: Item?; var state: String }
struct State: Codable { var connectionEpoch: String; var receiverGeneration: Int64; var paused: Bool?; var outgoing: Outgoing?; var status: String? }
struct Hello: Codable { var connectionEpoch: String; var seqFloor: Int64; var receiverGeneration: Int64; var deviceId: String }
struct Snapshot { var kind: String; var item: Item; var url: URL }
struct Source { var kind: String; var name: String; var mime: String; var bytes: Data?; var file: URL? }
struct Head: Codable { var connectionEpoch: String; var sourceSessionId: String; var sourceSeq: Int64; var transferId: String; var receiverGenAtCopy: Int64 }
struct Offer: Codable { var connectionEpoch: String; var sourceSessionId: String; var sourceSeq: Int64; var transferId: String; var receiverGenAtCopy: Int64; var kind: String; var items: [Item] }

func credential(_ account: String, save: String? = nil, remove: Bool = false) throws -> String? {
    let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"CopyBridge", kSecAttrAccount as String:account]
    if remove { let code = SecItemDelete(query as CFDictionary); guard code == errSecSuccess || code == errSecItemNotFound else { throw BridgeError("KEYCHAIN_FAILED") }; return nil }
    if let save {
        let bytes = Data(save.utf8)
        let updated = SecItemUpdate(query as CFDictionary, [kSecValueData as String:bytes] as CFDictionary)
        if updated == errSecItemNotFound {
            var values = query; values[kSecValueData as String] = bytes; values[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(values as CFDictionary, nil) == errSecSuccess else { throw BridgeError("KEYCHAIN_FAILED") }
        } else if updated != errSecSuccess { throw BridgeError("KEYCHAIN_FAILED") }
        return save
    }
    var read = query; read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?; let code = SecItemCopyMatching(read as CFDictionary, &result)
    if code == errSecItemNotFound { return nil }
    guard code == errSecSuccess, let bytes = result as? Data, let value = String(data: bytes, encoding: .utf8) else { throw BridgeError("KEYCHAIN_FAILED") }
    return value
}
func curlQuote(_ value: String) throws -> String {
    guard !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw BridgeError("INVALID_REQUEST") }
    return "\"" + value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"") + "\""
}
final class CurlJob: @unchecked Sendable {
    let lock = NSLock(); var process: Process?; var cancelled = false; var completed = false
    func finish(_ action: () -> Void) { lock.lock(); guard !completed else { lock.unlock(); return }; completed = true; lock.unlock(); action() }
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true; if let process, process.isRunning { process.terminate() } }
    func start(_ process: Process) throws { lock.lock(); defer { lock.unlock() }; guard !cancelled else { throw CancellationError() }; self.process = process; try process.run() }
}
final class Network {
    let config: Config
    var token = ""
    private(set) var publicKeyPin = ""
    let jobsLock = NSLock(); var jobs: [UUID:CurlJob] = [:]
    init(_ config: Config) throws {
        guard let url = URL(string:config.url), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              UUID(uuidString:config.deviceId) != nil, config.certificateSha256.count == 64,
              config.certificateSha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw BridgeError("INVALID_CONFIG") }
        self.config = config
        let ca = try certificate()
        let tool = Process(); tool.executableURL = URL(fileURLWithPath:"/usr/bin/openssl")
        tool.arguments = ["x509","-pubkey","-noout","-in",ca.path]
        let output = Pipe(); tool.standardOutput = output; tool.standardError = FileHandle.nullDevice
        try tool.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); tool.waitUntilExit()
        guard tool.terminationStatus == 0, bytes.count <= 8192, let pem = String(data:bytes,encoding:.utf8), pem.hasPrefix("-----BEGIN PUBLIC KEY-----"),
              let spki = Data(base64Encoded:pem.components(separatedBy:.newlines).filter { !$0.hasPrefix("-----") }.joined()) else { throw BridgeError("TLS_PIN_DERIVATION_FAILED") }
        publicKeyPin = "sha256//" + Data(SHA256.hash(data:spki)).base64EncodedString()
    }
    func register(_ id: UUID, _ job: CurlJob?) { jobsLock.lock(); jobs[id] = job; jobsLock.unlock() }
    func certificate() throws -> URL {
        let path = support.appendingPathComponent("device.pem")
        let text = try String(contentsOf:path,encoding:.utf8)
        let base64 = text.components(separatedBy:.newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard let der = Data(base64Encoded:base64), SecCertificateCreateWithData(nil,der as CFData) != nil,
              hex(SHA256.hash(data:der)) == config.certificateSha256 else { throw BridgeError("TLS_PIN_MISMATCH") }
        return path
    }
    func check(_ data: Data, status: Int) throws {
        guard (200...299).contains(status) else {
            let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any]
            let code = object?["error"] as? String ?? "HTTP_\(status)"
            throw BridgeError(code.range(of:"^[A-Z0-9_]{1,80}$",options:.regularExpression) != nil ? code : "REMOTE_ERROR")
        }
    }
    func perform(_ method: String, _ path: String, body: Data? = nil, epoch: String? = nil, upload: URL? = nil, output: URL, limit: Int64) async throws -> Int {
        try Task.checkCancellation()
        let ca = try certificate()
        let fm = FileManager.default
        guard fm.createFile(atPath:output.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw BridgeError("LOCAL_IO_FAILED") }
        var options = [("url",config.url + path),("request",method),("cacert",ca.path),("pinnedpubkey",publicKeyPin),("noproxy","*"),("proto","=https"),("max-redirs","0"),("connect-timeout","5"),("max-time","3600"),("speed-time","60"),("speed-limit","1"),("max-filesize",String(max(1,limit))),("output",output.path),("write-out","%{http_code}"),("header","Authorization: Bearer " + token)]
        if let epoch { options.append(("header","X-Connection-Epoch: " + epoch)) }
        if let body { guard body.count <= 65536, let text = String(data:body,encoding:.utf8) else { throw BridgeError("REQUEST_SIZE_LIMIT") }; options.append(("header","Content-Type: application/json")); options.append(("data-binary",text)) }
        if let upload { options.append(("header","Content-Type: application/octet-stream")); options.append(("upload-file",upload.path)) }
        let configuration = try options.map { try $0.0 + " = " + curlQuote($0.1) }.joined(separator:"\n") + "\nsilent\nshow-error\nhttp1.1\n"
        let process = Process(); process.executableURL = URL(fileURLWithPath:"/usr/bin/curl"); process.arguments = ["-q","--config","-"]
        let input = Pipe(); let result = Pipe(); process.standardInput = input; process.standardOutput = result; process.standardError = FileHandle.nullDevice
        let id = UUID(); let job = CurlJob(); register(id,job); defer { register(id,nil) }
        let resultCode: Int = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    let bytes = result.fileHandleForReading.readDataToEndOfFile()
                    try? result.fileHandleForReading.close()
                    job.finish {
                    if finished.terminationStatus == 0, let value = Int(String(decoding:bytes,as:UTF8.self)) { continuation.resume(returning:value) }
                    else if finished.terminationStatus == 63 { continuation.resume(throwing:BridgeError("RESPONSE_SIZE_LIMIT")) }
                    else if finished.terminationStatus == 60 || finished.terminationStatus == 51 || finished.terminationStatus == 90 { continuation.resume(throwing:BridgeError("TLS_VALIDATION_FAILED")) }
                    else { continuation.resume(throwing:BridgeError("NETWORK_FAILED_\(finished.terminationStatus)")) }
                    }
                }
                do {
                    try job.start(process)
                    try input.fileHandleForWriting.write(contentsOf:Data(configuration.utf8)); try input.fileHandleForWriting.close()
                } catch {
                    process.terminationHandler = nil; job.cancel(); try? input.fileHandleForWriting.close(); job.finish { continuation.resume(throwing:error) }
                }
            }
        }, onCancel:{ job.cancel() })
        try Task.checkCancellation()
        guard Int64((try output.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? -1) <= limit else { throw BridgeError("RESPONSE_SIZE_LIMIT") }
        return resultCode
    }
    func json(_ method: String, _ path: String, body: Any? = nil, epoch: String? = nil) async throws -> Data {
        let output = support.appendingPathComponent("request-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at:output) }
        let data = try body.map { try JSONSerialization.data(withJSONObject:$0) }
        let code = try await perform(method,path,body:data,epoch:epoch,output:output,limit:65536)
        let response = try Data(contentsOf:output); try check(response,status:code); return response
    }
    func encoded<T: Encodable>(_ path: String, _ body: T, epoch: String) async throws -> Data {
        let object = try JSONSerialization.jsonObject(with:JSONEncoder().encode(body))
        return try await json("POST",path,body:object,epoch:epoch)
    }
    func upload(_ path: String, snapshot: Snapshot, epoch: String) async throws {
        let output = support.appendingPathComponent("request-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at:output) }
        let code = try await perform("PUT",path,epoch:epoch,upload:snapshot.url,output:output,limit:65536)
        try check(try Data(contentsOf:output),status:code)
    }
    func download(_ path: String, epoch: String, destination: URL, expected: Int64) async throws {
        let code = try await perform("GET",path,epoch:epoch,output:destination,limit:expected)
        try check(Data(),status:code)
        guard Int64((try destination.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? -1) == expected else { throw BridgeError("SIZE_MISMATCH") }
    }
    func cancelAll() { jobsLock.lock(); let active = Array(jobs.values); jobsLock.unlock(); active.forEach { $0.cancel() } }
}
func checkImage(_ url: URL) throws {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1,
          let p = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString:Any],
          let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int,
          w > 0, h > 0, w <= 32_000_000 / h else { throw BridgeError("IMAGE_LIMIT_OR_INVALID") }
}
func hashFile(_ url: URL) throws -> (Int64, String) {
    let f = try FileHandle(forReadingFrom: url); defer { try? f.close() }
    var hash = SHA256(); var size: Int64 = 0
    while true {
        let ended = try autoreleasepool { () throws -> Bool in
            try Task.checkCancellation()
            guard let bytes = try f.read(upToCount:1024 * 1024), !bytes.isEmpty else { return true }
            size += Int64(bytes.count); hash.update(data:bytes); return false
        }
        if ended { break }
    }
    return (size, hex(hash.finalize()))
}
func snapshot(_ source: Source, id: String) throws -> Snapshot {
    let fm = FileManager.default
    let dir = support.appendingPathComponent("Spool/\(id)")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
    let url = dir.appendingPathComponent(source.name)
    do {
        if let bytes = source.bytes {
            guard Int64(bytes.count) <= (source.kind == "text" ? MiB : 32 * MiB) else { throw BridgeError("SIZE_LIMIT") }
            if source.kind == "image" {
                guard let input = CGImageSourceCreateWithData(bytes as CFData, nil), CGImageSourceGetCount(input) == 1,
                      let props = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString:Any], let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                      w > 0, h > 0, w <= 32_000_000 / h, let pixels = CGImageSourceCreateImageAtIndex(input, 0, nil),
                      let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw BridgeError("IMAGE_LIMIT_OR_INVALID") }
                CGImageDestinationAddImage(dest, pixels, nil)
                guard CGImageDestinationFinalize(dest) else { throw BridgeError("IMAGE_INVALID") }
            } else { try bytes.write(to: url, options: .atomic) }
        } else if let file = source.file {
            let before = try fm.attributesOfItem(atPath: file.path)
            guard before[.type] as? FileAttributeType == .typeRegular, let size = before[.size] as? NSNumber, size.int64Value <= 2048 * MiB else { throw BridgeError("SOURCE_UNAVAILABLE_OR_SIZE_LIMIT") }
            let resources = try file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
            if resources.isUbiquitousItem == true && resources.ubiquitousItemDownloadingStatus != .current { throw BridgeError("SOURCE_UNAVAILABLE") }
            let free = try fm.attributesOfFileSystem(forPath: dir.path)[.systemFreeSize] as? NSNumber
            guard (free?.int64Value ?? 0) > size.int64Value + 128 * MiB else { throw BridgeError("DISK_FULL") }
            let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
            guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions:0o600]) else { throw BridgeError("DISK_FULL") }
            let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
            var copied: Int64 = 0
            while true {
                let ended = try autoreleasepool { () throws -> Bool in
                    try Task.checkCancellation()
                    guard let data = try input.read(upToCount:1024 * 1024), !data.isEmpty else { return true }
                    copied += Int64(data.count)
                    guard copied <= size.int64Value else { throw BridgeError("SOURCE_CHANGED") }
                    try output.write(contentsOf:data); return false
                }
                if ended { break }
            }
            try output.synchronize(); try output.close()
            let after = try fm.attributesOfItem(atPath: file.path)
            for key: FileAttributeKey in [.size, .modificationDate, .systemFileNumber] {
                guard String(describing: before[key]) == String(describing: after[key]) else { throw BridgeError("SOURCE_CHANGED") }
            }
            guard copied == size.int64Value else { throw BridgeError("SOURCE_CHANGED") }
        } else { throw BridgeError("SOURCE_UNAVAILABLE") }
        if source.kind == "image" { try checkImage(url) }
        let (size, hash) = try hashFile(url)
        let item = Item(name: source.name, mime: source.mime, sizeBytes: size, sha256: hash)
        try validate(kind: source.kind, item: item)
        return Snapshot(kind: source.kind, item: item, url: url)
    } catch { try? fm.removeItem(at: dir); throw error }
}

@MainActor final class App: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!; var statusRow: NSMenuItem!; var pauseRow: NSMenuItem!
    var net: Network!; var config: Config!; var diagnosticURL = support.appendingPathComponent("diagnostics.jsonl")
    let sessionID = UUID().uuidString
    var epoch: String?; var receiverGeneration: Int64 = 0; var sequence: Int64 = 0
    var lastCount = 0; var localSerial = 0; var previousPollSerial = 0; var previousPollCount = 0; var paused = false; var connecting = false
    var incomingID: String?; var instanceLock: Int32 = -1
    var lastOutgoing: String?; var reverseSeen: [String:Int] = [:]; var reverseDiscard = Set<String>(); var reversePublished = Set<String>()
    var outgoingTask: Task<Void,Never>?; var incomingTask: Task<Void,Never>?; var loopTask: Task<Void,Never>?
    var transferID: String?; var timer: Timer?; var stateText = "未连接"
    func log(_ event: String, id: String? = nil, kind: String? = nil, size: Int64? = nil, elapsed: Double? = nil) {
        var entry: [String:Any] = ["timestamp":ISO8601DateFormatter().string(from: Date()), "event":event]
        if let id { entry["transferId"] = id }; if let kind { entry["kind"] = kind }; if let size { entry["bytes"] = size }; if let elapsed { entry["elapsedMs"] = elapsed }
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        if !FileManager.default.fileExists(atPath: diagnosticURL.path) { FileManager.default.createFile(atPath: diagnosticURL.path, contents: nil, attributes: [.posixPermissions:0o600]) }
        if let f = try? FileHandle(forWritingTo: diagnosticURL) { _ = try? f.seekToEnd(); try? f.write(contentsOf: data + Data([10])); try? f.close() }
    }
    func status(_ text: String) { let text = text.contains("SESSION_LOCKED") ? "Windows 已锁定，请解锁后重新复制" : text; stateText = text; statusRow?.title = text; statusItem?.button?.title = paused ? "CopyBridge ⏸" : "CopyBridge ↔" }
    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
            try FileManager.default.createDirectory(at: received, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
            instanceLock = open(support.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else { NSApplication.shared.terminate(nil); return }
            config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: option("--config") ?? support.appendingPathComponent("config.json").path)))
            if let path = option("--diagnostics") { diagnosticURL = URL(fileURLWithPath: path) }
            net = try Network(config)
            lastCount = NSPasteboard.general.changeCount // Baseline only: never read old clipboard.
            menu()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.observe() } }
            loopTask = Task { await self.loop() }
        } catch { menu(); status("配置或钥匙串不可用"); log("CONFIG_FAILED") }
    }
    func menu() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength); statusItem.button?.title = "CopyBridge ↔"
        let menu = NSMenu(); statusRow = NSMenuItem(title: stateText, action: nil, keyEquivalent: ""); menu.addItem(statusRow)
        menu.addItem(NSMenuItem(title:"Mac ⇄ Windows · 局域网直连", action:nil, keyEquivalent:"")); menu.addItem(.separator())
        pauseRow = NSMenuItem(title:"暂停同步", action:#selector(togglePause), keyEquivalent:""); pauseRow.target = self; menu.addItem(pauseRow)
        for (title, action) in [("打开收到的文件", #selector(openReceived)), ("取消当前传输", #selector(cancelCurrent)), ("解除配对", #selector(unpair)), ("退出", #selector(quit))] { let item = NSMenuItem(title:title, action:action, keyEquivalent:""); item.target = self; menu.addItem(item) }
        statusItem.menu = menu
    }
    @objc func openReceived() { NSWorkspace.shared.open(received) }
    @objc func quit() { cancelWork(); loopTask?.cancel(); net?.cancelAll(); NSApplication.shared.terminate(nil) }
    @objc func cancelCurrent() { cancelWork(); status("已取消，请重新复制") }
    func cancelWork() {
        if let id = incomingID { reverseDiscard.insert(id) }; incomingID = nil
        outgoingTask?.cancel(); incomingTask?.cancel(); outgoingTask = nil; incomingTask = nil
        if let id = transferID, let e = epoch { Task { _ = try? await net.json("POST", "/v1/transfers/\(id)/cancel", body: [:], epoch:e) } }
        transferID = nil
    }
    @objc func togglePause() {
        guard net != nil else { return }; paused.toggle(); cancelWork(); lastCount = NSPasteboard.general.changeCount
        pauseRow.title = paused ? "恢复同步" : "暂停同步"; status(paused ? "已暂停" : "重新连接，请重新复制")
        let old = epoch; epoch = nil
        Task { _ = try? await net.json("POST", "/v1/pause", body:["paused":paused], epoch:old) }
    }
    @objc func unpair() {
        guard net != nil else { return }; paused = true; cancelWork(); let old = epoch; epoch = nil
        Task {
            do { _ = try await net.json("POST", "/v1/unpair", body:[:], epoch:old); _ = try credential(config.keychainAccount, remove:true); net.token = ""; status("已解除配对") }
            catch { status("解除配对失败，请检查连接") }
        }
    }
    func disconnect(_ event: String) { cancelWork(); epoch = nil; lastCount = NSPasteboard.general.changeCount; status(event == "SESSION_LOCKED" ? event : "未连接，请重新复制"); log(event) }
    func loop() async {
        while !Task.isCancelled {
            if !paused {
                if epoch == nil { await connect() } else { await poll() }
            }
            try? await Task.sleep(nanoseconds: epoch == nil ? 2_000_000_000 : 500_000_000)
        }
    }
    func connect() async {
        guard !connecting else { return }; connecting = true; defer { connecting = false }
        do {
            if net.token.isEmpty {
                if let existing = try credential(config.keychainAccount) { net.token = existing }
                else if let file = option("--pair-token-file") {
                    let data = try Data(contentsOf: URL(fileURLWithPath:file)); let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any]
                    let token = object?["token"] as? String ?? String(decoding:data, as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
                    guard !token.isEmpty else { throw BridgeError("PAIRING_REQUIRED") }
                    let result = try await net.json("POST", "/v1/pair", body:["deviceId":config.deviceId, "token":token])
                    guard let response = try JSONSerialization.jsonObject(with:result) as? [String:Any], let value = response["token"] as? String else { throw BridgeError("PAIR_FAILED") }
                    _ = try credential(config.keychainAccount, save:value); net.token = value
                    try FileManager.default.removeItem(atPath:file); log("PAIRED")
                } else { throw BridgeError("PAIRING_REQUIRED") }
            }
            let result = try await net.json("POST", "/v1/hello", body:["protocolVersion":1,"deviceId":config.deviceId,"sourceSessionId":sessionID,"handshakeId":UUID().uuidString,"lastIssuedSourceSeq":sequence])
            let hello = try JSONDecoder().decode(Hello.self, from:result)
            guard !paused else { return }
            guard UUID(uuidString:hello.connectionEpoch) != nil else { throw BridgeError("INVALID_METADATA") }
            epoch = hello.connectionEpoch; sequence = max(sequence, hello.seqFloor); receiverGeneration = hello.receiverGeneration
            lastCount = NSPasteboard.general.changeCount; previousPollSerial = localSerial; previousPollCount = lastCount; reverseSeen.removeAll(); reverseDiscard.removeAll(); reversePublished.removeAll(); lastOutgoing = nil
            status("已连接，请复制新内容"); log("CONNECTED")
        } catch { status("未连接：" + errorCode(error)); log(errorCode(error)) }
    }
    func observe() {
        let count = NSPasteboard.general.changeCount
        guard count != lastCount else { return }; lastCount = count; localSerial += 1
        for id in reverseSeen.keys { reverseDiscard.insert(id) }; incomingTask?.cancel(); incomingTask = nil
        cancelWork()
        guard !paused, let e = epoch else { return }
        sequence += 1; let id = UUID().uuidString; transferID = id
        let head = Head(connectionEpoch:e, sourceSessionId:sessionID, sourceSeq:sequence, transferId:id, receiverGenAtCopy:receiverGeneration)
        status("准备中，尚不可粘贴"); log("COPY_OBSERVED", id:id)
        outgoingTask = Task { await send(head, count:count) }
    }
    func source(_ count: Int) throws -> Source {
        let p = NSPasteboard.general
        guard p.changeCount == count else { throw BridgeError("SUPERSEDED") }
        let excluded = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType"]
        guard !(p.types ?? []).contains(where: { excluded.contains($0.rawValue) }) else { throw BridgeError("SENSITIVE_SOURCE_EXCLUDED") }
        var source: Source
        if let files = p.readObjects(forClasses:[NSURL.self], options:[.urlReadingFileURLsOnly:true]) as? [URL], !files.isEmpty {
            guard files.count == 1 else { throw BridgeError("MULTI_FILE_UNSUPPORTED") }
            let file = files[0]; guard file.isFileURL, safeName(file.lastPathComponent) else { throw BridgeError("INVALID_FILENAME") }
            let mime = fileMIME(file.lastPathComponent)
            source = Source(kind:"file", name:file.lastPathComponent, mime:mime, file:file)
        } else if let image = p.data(forType:.png) ?? p.data(forType:.tiff) {
            guard image.count <= 32 * Int(MiB) else { throw BridgeError("SIZE_LIMIT") }
            source = Source(kind:"image", name:"Clipboard.png", mime:"image/png", bytes:image)
        } else if let text = p.string(forType:.string) { source = Source(kind:"text", name:"clipboard.txt", mime:"text/plain", bytes:Data(text.utf8)) }
        else { throw BridgeError("TYPE_UNSUPPORTED") }
        guard p.changeCount == count else { throw BridgeError("SUPERSEDED") }; return source
    }
    func eligible(_ head: Head, count: Int) throws {
        try Task.checkCancellation()
        guard !paused, epoch == head.connectionEpoch, sequence == head.sourceSeq, NSPasteboard.general.changeCount == count else { throw BridgeError("SUPERSEDED") }
    }
    func send(_ head: Head, count: Int) async {
        let start = ProcessInfo.processInfo.systemUptime
        var spool: URL?
        defer { if let spool { try? FileManager.default.removeItem(at:spool.deletingLastPathComponent()) } }
        do {
            _ = try await net.encoded("/v1/head", head, epoch:head.connectionEpoch)
            try eligible(head, count:count)
            let input = try source(count)
            let worker = Task.detached(priority:.userInitiated) { try snapshot(input, id:head.transferId) }
            let prepared = try await withTaskCancellationHandler(operation:{ try await worker.value }, onCancel:{ worker.cancel() })
            spool = prepared.url; try eligible(head, count:count)
            log("SNAPSHOT_READY", id:head.transferId, kind:prepared.kind, size:prepared.item.sizeBytes)
            let offer = Offer(connectionEpoch:head.connectionEpoch, sourceSessionId:head.sourceSessionId, sourceSeq:head.sourceSeq, transferId:head.transferId, receiverGenAtCopy:head.receiverGenAtCopy, kind:prepared.kind, items:[prepared.item])
            _ = try await net.encoded("/v1/offers", offer, epoch:head.connectionEpoch)
            try eligible(head, count:count); status("传输中，尚不可粘贴")
            try await net.upload("/v1/transfers/\(head.transferId)/items/f1", snapshot:prepared, epoch:head.connectionEpoch)
            try eligible(head, count:count); status("校验中，尚不可粘贴")
            let response = try await net.json("POST", "/v1/transfers/\(head.transferId)/complete", body:[:], epoch:head.connectionEpoch)
            try eligible(head, count:count)
            let object = try JSONSerialization.jsonObject(with:response) as? [String:Any]
            guard object?["state"] as? String == "Published", object?["currentlyOnClipboard"] as? Bool == true else { throw BridgeError("PUBLISH_FAILED") }
            status("Windows 可粘贴"); log("REMOTE_PUBLISHED", id:head.transferId, kind:prepared.kind, size:prepared.item.sizeBytes, elapsed:(ProcessInfo.processInfo.systemUptime-start)*1000)
            transferID = nil
        } catch {
            if head.sourceSeq == sequence, epoch == head.connectionEpoch, !paused { status("本次未同步：" + errorCode(error)); log(errorCode(error), id:head.transferId) }
            _ = try? await net.json("POST", "/v1/transfers/\(head.transferId)/cancel", body:[:], epoch:head.connectionEpoch)
        }
    }
    func poll() async {
        guard let e = epoch else { return }
        if reverseSeen.count >= 4096 { disconnect("SESSION_RECORD_BUDGET"); return }
        let serial = localSerial; let count = NSPasteboard.general.changeCount
        do {
            let bytes = try await net.json("GET", "/v1/receiver-state", epoch:e)
            guard epoch == e, !paused else { return }
            let state = try JSONDecoder().decode(State.self, from:bytes)
            guard state.connectionEpoch == e else { throw BridgeError("SESSION_REVOKED") }
            if state.paused == true { paused = true; pauseRow.title = "恢复同步"; disconnect("REMOTE_PAUSED"); status("Windows 已暂停"); return }
            let previousSerial = previousPollSerial; let previousCount = previousPollCount
            previousPollSerial = serial; previousPollCount = count
            receiverGeneration = state.receiverGeneration
            guard let out = state.outgoing else { lastOutgoing = nil; if let old = incomingID { reverseDiscard.insert(old) }; incomingTask?.cancel(); incomingTask = nil; incomingID = nil; return }
            guard UUID(uuidString:out.transferId) != nil, out.generation == state.receiverGeneration else { throw BridgeError("INVALID_METADATA") }
            let id = out.transferId
            if reverseSeen[id] == nil {
                reverseSeen[id] = NSPasteboard.general.changeCount
                if !remoteObservationSafe(previousSerial:previousSerial, currentSerial:localSerial, previousCount:previousCount, currentCount:NSPasteboard.general.changeCount) || serial != localSerial || count != NSPasteboard.general.changeCount { reverseDiscard.insert(id) }
            }
            if lastOutgoing != id { if let old = incomingID { reverseDiscard.insert(old) }; incomingTask?.cancel(); incomingTask = nil; incomingID = nil; lastOutgoing = id }
            guard out.state == "Ready", !reverseDiscard.contains(id), !reversePublished.contains(id), incomingTask == nil else { return }
            let expected = reverseSeen[id]!
            incomingID = id; incomingTask = Task { await receive(out, epoch:e, expectedCount:expected) }
        } catch { if epoch == e && !paused { disconnect(errorCode(error)) } }
    }
    func receive(_ out: Outgoing, epoch e: String, expectedCount: Int) async {
        let id = out.transferId; let start = ProcessInfo.processInfo.systemUptime
        guard let epochID = UUID(uuidString:e)?.uuidString, let transferID = UUID(uuidString:id)?.uuidString else { log("INVALID_METADATA",id:id); return }
        let dir = received.appendingPathComponent(epochID).appendingPathComponent(transferID); var protected = false; var created = false
        defer { if incomingID == id { incomingTask = nil; incomingID = nil }; if created && !protected { try? FileManager.default.removeItem(at:dir) } }
        do {
            guard let item = out.item else { throw BridgeError("INVALID_METADATA") }; try validate(kind:out.kind, item:item)
            guard NSPasteboard.general.changeCount == expectedCount else { throw BridgeError("LOCAL_CLIPBOARD_CHANGED") }
            let fm = FileManager.default
            let usage = (fm.enumerator(at:received, includingPropertiesForKeys:[.fileSizeKey])?.allObjects as? [URL] ?? []).reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
            guard usage + item.sizeBytes < 20 * 1024 * MiB else { throw BridgeError("RECEIVED_BUDGET_LIMIT") }
            let free = try fm.attributesOfFileSystem(forPath:received.path)[.systemFreeSize] as? NSNumber
            guard (free?.int64Value ?? 0) > item.sizeBytes + 128 * MiB else { throw BridgeError("DISK_FULL") }
            try fm.createDirectory(at:dir.deletingLastPathComponent(), withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
            guard mkdir(dir.path,0o700) == 0 else { throw BridgeError("RECEIVED_ID_REUSED_OR_IO_FAILED") }
            created = true
            let part = dir.appendingPathComponent("payload.part"); let final = dir.appendingPathComponent(item.name)
            status("正在接收，尚不可粘贴")
            try await net.download("/v1/outgoing/\(id)/items/f1", epoch:e, destination:part, expected:item.sizeBytes)
            let worker = Task.detached { () throws -> (Int64,String) in if out.kind == "image" { try checkImage(part) }; return try hashFile(part) }
            let (size, hash) = try await withTaskCancellationHandler(operation:{ try await worker.value }, onCancel:{ worker.cancel() })
            guard size == item.sizeBytes, hash == item.sha256 else { throw BridgeError("HASH_MISMATCH") }
            try Task.checkCancellation()
            // Refresh remote generation immediately before publishing; no timestamp comparison.
            let data = try await net.json("GET", "/v1/receiver-state", epoch:e)
            let state = try JSONDecoder().decode(State.self, from:data)
            guard state.connectionEpoch == e, state.receiverGeneration == out.generation, state.outgoing?.transferId == id, state.outgoing?.state == "Ready", state.paused != true else { throw BridgeError("SUPERSEDED") }
            try fm.moveItem(at:part, to:final)
            let pasteItem = NSPasteboardItem()
            if out.kind == "text" {
                guard let value = String(data:try Data(contentsOf:final), encoding:.utf8), !value.contains("\0") else { throw BridgeError("INVALID_TEXT") }
                pasteItem.setString(value, forType:.string)
            } else if out.kind == "image" { pasteItem.setData(try Data(contentsOf:final), forType:.png) }
            else { pasteItem.setString(final.absoluteString, forType:.fileURL) }
            pasteItem.setString(id, forType:marker)
            // Protection intent is durable before the first clipboard mutation. Published files never auto-expire.
            let protection = try JSONSerialization.data(withJSONObject:["transferId":id,"state":"PublishIntent","sizeBytes":size,"sha256":hash])
            try protection.write(to:dir.appendingPathComponent("protection.json"), options:.atomic)
            protected = true
            try Task.checkCancellation()
            guard !paused, epoch == e, lastOutgoing == id, !reverseDiscard.contains(id), NSPasteboard.general.changeCount == expectedCount else { throw BridgeError("LOCAL_CLIPBOARD_CHANGED") }
            // NSPasteboard has no compare-and-swap API; check immediately before its synchronous write.
            let p = NSPasteboard.general; p.clearContents()
            guard p.writeObjects([pasteItem]) else { observe(); throw BridgeError("PUBLISH_FAILED") }
            let writtenCount = p.changeCount
            guard p.string(forType:marker) == id, p.changeCount == writtenCount else {
                observe(); throw BridgeError("LOCAL_CLIPBOARD_CHANGED")
            }
            lastCount = writtenCount; reversePublished.insert(id)
            status("Mac 可粘贴"); log("LOCAL_PUBLISHED", id:id, kind:out.kind, size:size, elapsed:(ProcessInfo.processInfo.systemUptime-start)*1000)
        } catch { reverseDiscard.insert(id); if epoch == e && !paused { status("本次未接收：" + errorCode(error)); log(errorCode(error), id:id) } }
    }
}
func remoteObservationSafe(previousSerial: Int, currentSerial: Int, previousCount: Int, currentCount: Int) -> Bool {
    previousSerial == currentSerial && previousCount == currentCount
}
func errorCode(_ error: Error) -> String {
    if let value = error as? BridgeError { return value.code }
    if error is CancellationError || (error as NSError).code == NSURLErrorCancelled { return "CANCELLED" }
    if (error as NSError).domain == NSURLErrorDomain { return "NETWORK_OR_TLS_FAILED_\((error as NSError).code)" }
    return "LOCAL_IO_OR_FORMAT_FAILED"
}
func option(_ name: String) -> String? { guard let n = CommandLine.arguments.firstIndex(of:name), n + 1 < CommandLine.arguments.count else { return nil }; return CommandLine.arguments[n+1] }
func selfTest() throws {
    let cancelledJob = CurlJob(); cancelledJob.cancel()
    let unstarted = Process(); unstarted.executableURL = URL(fileURLWithPath:"/usr/bin/true")
    do { try cancelledJob.start(unstarted); throw BridgeError("SELFTEST_CANCEL_BEFORE_START") } catch is CancellationError {}
    guard !unstarted.isRunning else { throw BridgeError("SELFTEST_CANCEL_BEFORE_START") }
    var completions = 0; cancelledJob.finish { completions += 1 }; cancelledJob.finish { completions += 1 }
    guard completions == 1 else { throw BridgeError("SELFTEST_DUPLICATE_COMPLETION") }
    guard remoteObservationSafe(previousSerial:2,currentSerial:2,previousCount:10,currentCount:10),
          !remoteObservationSafe(previousSerial:2,currentSerial:3,previousCount:10,currentCount:11),
          !remoteObservationSafe(previousSerial:2,currentSerial:2,previousCount:10,currentCount:11) else { throw BridgeError("SELFTEST_LOCAL_COPY_GUARD") }
    guard try curlQuote("a\"b\\c") == "\"a\\\"b\\\\c\"" else { throw BridgeError("SELFTEST_CURL_QUOTING") }
    do { _ = try curlQuote("bad\nheader"); throw BridgeError("SELFTEST_CURL_QUOTING") } catch let error as BridgeError { guard error.code == "INVALID_REQUEST" else { throw error } }
    for valid in ["测试 图片.png", "hello.mp4", "file.jpeg"] { guard safeName(valid) else { throw BridgeError("SELFTEST_FILENAME") } }
    for invalid in ["../bad.mp4", "A:B.png", "CON.png", "LPT1.mp4", "bad.", "bad ", "x\\y.png"] { guard !safeName(invalid) else { throw BridgeError("SELFTEST_FILENAME") } }
    for size in [2048*MiB-1,2048*MiB] { try validate(kind:"file", item:Item(name:"x.mp4",mime:"video/mp4",sizeBytes:size,sha256:String(repeating:"0",count:64))) }
    do { try validate(kind:"file", item:Item(name:"x.mp4",mime:"video/mp4",sizeBytes:2048*MiB+1,sha256:String(repeating:"0",count:64))); throw BridgeError("SELFTEST_LIMIT") } catch let error as BridgeError { guard error.code == "SIZE_LIMIT" else { throw error } }
    let sample = Data("测试\nCopyBridge 😀".utf8); let id = UUID().uuidString
    let prepared = try snapshot(Source(kind:"text",name:"clipboard.txt",mime:"text/plain",bytes:sample),id:id)
    defer { try? FileManager.default.removeItem(at:prepared.url.deletingLastPathComponent()) }
    guard prepared.item.sha256 == hex(SHA256.hash(data:sample)), try Data(contentsOf:prepared.url) == sample else { throw BridgeError("SELFTEST_SNAPSHOT") }
    let generic = try snapshot(Source(kind:"file",name:"file.txt",mime:fileMIME("file.txt"),file:prepared.url),id:UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:generic.url.deletingLastPathComponent()) }
    guard generic.item.mime == "application/octet-stream", generic.item.sha256 == prepared.item.sha256,
          try Data(contentsOf:generic.url) == sample else { throw BridgeError("SELFTEST_GENERIC_FILE") }
    for name in ["report.pdf", "document.docx", "archive.zip", "noextension"] {
        try validate(kind:"file",item:Item(name:name,mime:fileMIME(name),sizeBytes:42,sha256:prepared.item.sha256))
    }
    guard hex(SHA256.hash(data:Data("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" else { throw BridgeError("SELFTEST_HASH") }
    print("PASS: names, path boundary, size boundary, local-copy conflict guard, UTF8 stable snapshot, generic file streaming, curl escaping/cancel/once, SHA256; no clipboard touched")
}
if let path = option("--spool-test") {
    do {
        let file = URL(fileURLWithPath:path)
        guard safeName(file.lastPathComponent) else { throw BridgeError("INVALID_FILENAME") }
        let start = ProcessInfo.processInfo.systemUptime
        let prepared = try snapshot(Source(kind:"file",name:file.lastPathComponent,mime:fileMIME(file.lastPathComponent),file:file),id:UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:prepared.url.deletingLastPathComponent()) }
        let result: [String:Any] = ["status":"PASS","sizeBytes":prepared.item.sizeBytes,"sha256":prepared.item.sha256,"elapsedMs":(ProcessInfo.processInfo.systemUptime-start)*1000]
        let json = try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
        print(String(decoding:json,as:UTF8.self))
    } catch { fputs("Spool test failed: \(errorCode(error))\n",stderr); exit(1) }
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    do { try selfTest(); exit(0) } catch { fputs("Self-test failed: \(errorCode(error))\n",stderr); exit(1) }
}
if CommandLine.arguments.contains("--network-check") {
    setbuf(stdout,nil)
    print("NETWORK_CHECK_START")
    Task.detached {
        print("NETWORK_CHECK_TASK")
        do {
            let config = try JSONDecoder().decode(Config.self, from:Data(contentsOf:URL(fileURLWithPath:option("--config") ?? support.appendingPathComponent("config.json").path)))
            let network = try Network(config)
            _ = try await network.json("GET", "/v1/receiver-state")
            print("NETWORK_OK"); exit(0)
        } catch {
            if let failure = error as? BridgeError { print("REMOTE_STATUS " + failure.code); exit(failure.code == "AUTH_FAILED" ? 0 : 1) }
            var e = error as NSError
            for _ in 0..<5 {
                print("NETWORK_ERROR domain=\(e.domain) code=\(e.code)")
                print("NETWORK_ERROR_KEYS \(e.userInfo.keys.sorted())")
                if let path = e.userInfo["_NSURLErrorNWPathKey"] { print("NETWORK_PATH \(path)") }
                guard let next = e.userInfo[NSUnderlyingErrorKey] as? NSError else { break }; e = next
            }
            exit(1)
        }
    }
    dispatchMain()
}
MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    let appDelegate = App()
    application.delegate = appDelegate
    withExtendedLifetime(appDelegate) { application.run() }
}
