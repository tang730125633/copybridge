import AppKit
import Darwin
import CryptoKit
import Security
import ImageIO
import UniformTypeIdentifiers

let MiB: Int64 = 1_048_576
let support = option("--data").map { URL(fileURLWithPath:$0,isDirectory:true).standardizedFileURL } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CopyBridge")
let received = option("--data") == nil ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("CopyBridge Received") : support.appendingPathComponent("Received")
let configURL = URL(fileURLWithPath:option("--config") ?? support.appendingPathComponent("config.json").path)
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
struct Config: Codable {
    var url: String; var deviceId: String; var certificateSha256: String; var keychainAccount: String
    var certificateFile: String? = nil; var peerDeviceId: String? = nil; var deviceName: String? = nil; var formatVersion: Int? = nil
}
struct SyncSettings: Codable, Equatable {
    var revision: Int64; var macToWindows: Bool; var windowsToMac: Bool; var text: Bool; var image: Bool; var file: Bool; var paused: Bool
    func allows(_ kind: String, sending: Bool) -> Bool {
        !paused && (sending ? macToWindows : windowsToMac) && (kind == "text" ? text : kind == "image" ? image : kind == "file" ? file : false)
    }
    func request(expectedRevision: Int64) -> [String:Any] {
        ["expectedRevision":expectedRevision,"macToWindows":macToWindows,"windowsToMac":windowsToMac,"text":text,"image":image,"file":file,"paused":paused]
    }
}
func privateOrigin(_ value: String) -> Bool {
    guard let u = URLComponents(string:value), u.scheme == "https", u.user == nil, u.password == nil, u.path.isEmpty, u.query == nil, u.fragment == nil,
          let host = u.host, let port = u.port, (1...65535).contains(port), value == "https://\(host):\(port)" else { return false }
    let parts = host.split(separator:".",omittingEmptySubsequences:false)
    guard parts.count == 4 else { return false }
    var octets: [Int] = []
    for p in parts { guard let n = Int(p), (0...255).contains(n), String(n) == p else { return false }; octets.append(n) }
    return octets[0] == 10 || octets[0] == 127 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1]))
}
func certificateDER(_ pem: String, expectedHash: String) throws -> Data {
    let clean = pem.trimmingCharacters(in:.whitespacesAndNewlines)
    guard clean.hasPrefix("-----BEGIN CERTIFICATE-----"), clean.hasSuffix("-----END CERTIFICATE-----"),
          clean.components(separatedBy:"-----BEGIN CERTIFICATE-----").count == 2, clean.components(separatedBy:"-----END CERTIFICATE-----").count == 2 else { throw BridgeError("INVALID_CERTIFICATE") }
    let base64 = clean.components(separatedBy:.newlines).filter { !$0.hasPrefix("-----") }.joined()
    guard let der = Data(base64Encoded:base64), SecCertificateCreateWithData(nil,der as CFData) != nil,
          expectedHash.count == 64, expectedHash.allSatisfy({ "0123456789abcdef".contains($0) }), hex(SHA256.hash(data:der)) == expectedHash else { throw BridgeError("TLS_PIN_MISMATCH") }
    return der
}
struct Invitation: Codable {
    var version: Int; var url: String; var deviceId: String; var deviceName: String; var certificatePem: String; var certificateSha256: String; var token: String; var expiresAt: String
    func validate(now: Date = Date()) throws {
        guard version == 1, privateOrigin(url), UUID(uuidString:deviceId) != nil,
              !deviceName.trimmingCharacters(in:.whitespaces).isEmpty, deviceName.count <= 80,
              !deviceName.unicodeScalars.contains(where:{ $0.value < 32 || $0.value == 127 }),
              token.utf8.count == 64, token.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw BridgeError("INVALID_INVITATION") }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        let fractional = formatter.date(from:expiresAt); formatter.formatOptions = [.withInternetDateTime]
        guard expiresAt.range(of:"(Z|[+-][0-9]{2}:[0-9]{2})$",options:.regularExpression) != nil,
              let expiry = fractional ?? formatter.date(from:expiresAt), expiry > now, expiry.timeIntervalSince(now) <= 630 else { throw BridgeError("INVITATION_EXPIRED_OR_INVALID_TIME") }
        _ = try certificateDER(certificatePem,expectedHash:certificateSha256)
    }
    static func decode(_ text: String, now: Date = Date()) throws -> Invitation {
        guard text.utf8.count <= 16384 else { throw BridgeError("INVITATION_SIZE_LIMIT") }
        let clean = text.trimmingCharacters(in:.whitespacesAndNewlines)
        guard clean.hasPrefix("COPYBRIDGE1:") else { throw BridgeError("INVALID_INVITATION") }
        let payload = String(clean.dropFirst(12).filter { !$0.isWhitespace })
        guard !payload.isEmpty, payload.count % 4 != 1, payload.allSatisfy({ "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".contains($0) }) else { throw BridgeError("INVALID_INVITATION") }
        let base64 = payload.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/") + String(repeating:"=",count:(4-payload.count%4)%4)
        guard let bytes = Data(base64Encoded:base64), bytes.count <= 12288 else { throw BridgeError("INVITATION_SIZE_LIMIT") }
        let invite: Invitation
        do { invite = try JSONDecoder().decode(Invitation.self,from:bytes) } catch { throw BridgeError("INVALID_INVITATION") }
        try invite.validate(now:now); return invite
    }
}

func invitationText(at url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom:url); defer { try? file.close() }
    let bytes = try file.read(upToCount:16385) ?? Data()
    guard bytes.count <= 16384 else { throw BridgeError("INVITATION_SIZE_LIMIT") }
    guard let text = String(data:bytes,encoding:.utf8) else { throw BridgeError("INVALID_INVITATION") }
    return text
}
struct QuickEnvelope: Codable { let version: Int; let sealed: String }
enum QuickPair {
    static let context = "CopyBridge quick pairing v1"
    static let alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    static func code(_ value: String) throws -> String {
        let clean = String(value.uppercased().filter { !$0.isWhitespace && $0 != "-" })
        guard clean.count == 20, clean.allSatisfy({ alphabet.contains($0) }) else { throw BridgeError("QUICK_CODE_INVALID") }
        return clean
    }
    static func origin(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in:.whitespacesAndNewlines)
        let result = value.hasPrefix("https://") ? value : "https://" + value + (value.contains(":") ? "" : ":43861")
        guard privateOrigin(result) else { throw BridgeError("QUICK_ADDRESS_INVALID") }
        return result
    }
    static func open(_ data: Data, code value: String, origin address: String) throws -> Invitation {
        guard data.count <= 32768 else { throw BridgeError("RESPONSE_SIZE_LIMIT") }
        let packet = try JSONDecoder().decode(QuickEnvelope.self,from:data)
        guard packet.version == 1, let bytes = Data(base64Encoded:packet.sealed), bytes.count >= 28, bytes.count <= 16412 else { throw BridgeError("QUICK_PACKET_INVALID") }
        let key = SymmetricKey(data:SHA256.hash(data:Data((context + "\n" + (try code(value))).utf8)))
        let plain: Data
        do { plain = try AES.GCM.open(AES.GCM.SealedBox(combined:bytes),using:key,authenticating:Data(context.utf8)) }
        catch { throw BridgeError("QUICK_CODE_WRONG") }
        guard let text = String(data:plain,encoding:.utf8) else { throw BridgeError("QUICK_PACKET_INVALID") }
        let invitation = try Invitation.decode(text)
        guard invitation.url == (try origin(address)) else { throw BridgeError("QUICK_ADDRESS_MISMATCH") }
        return invitation
    }
    static func fetch(address: String, code value: String) async throws -> Invitation {
        let address = try origin(address), normalized = try code(value)
        let output = support.appendingPathComponent("quick-\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath:output.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw BridgeError("LOCAL_IO_FAILED") }
        defer { try? FileManager.default.removeItem(at:output) }
        let process = Process(), result = Pipe(), job = CurlJob()
        process.executableURL = URL(fileURLWithPath:"/usr/bin/curl")
        // This unauthenticated request carries no secrets and accepts only AEAD ciphertext.
        // The code authenticates the embedded certificate before normal pinned TLS pairing.
        process.arguments = ["-q","--insecure","--silent","--noproxy","*","--proto","=https","--max-redirs","0","--connect-timeout","4","--max-time","10","--max-filesize","32768","--output",output.path,"--write-out","%{http_code}",address + "/v1/pairing/quick"]
        process.standardOutput = result; process.standardError = FileHandle.nullDevice
        let status: Int = try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    let bytes = result.fileHandleForReading.readDataToEndOfFile()
                    try? result.fileHandleForReading.close()
                    job.finish {
                        if finished.terminationStatus == 0, let code = Int(String(decoding:bytes,as:UTF8.self)) { continuation.resume(returning:code) }
                        else { continuation.resume(throwing:BridgeError("QUICK_NETWORK_FAILED")) }
                    }
                }
                do { try job.start(process) } catch { process.terminationHandler = nil; job.finish { continuation.resume(throwing:error) } }
            }
        },onCancel:{ job.cancel() })
        try Task.checkCancellation()
        guard status == 200 else { throw BridgeError(status == 409 ? "QUICK_UNAVAILABLE" : "QUICK_NETWORK_FAILED") }
        let bytes = try invitationSizedData(output)
        return try open(bytes,code:normalized,origin:address)
    }
    static func invitationSizedData(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom:url);defer { try? file.close() }
        let bytes = try file.read(upToCount:32769) ?? Data()
        guard bytes.count <= 32768 else { throw BridgeError("RESPONSE_SIZE_LIMIT") };return bytes
    }
}

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
    let certificateURL: URL
    var token = ""
    private(set) var publicKeyPin = ""
    let jobsLock = NSLock(); var jobs: [UUID:CurlJob] = [:]
    init(_ config: Config, certificateURL: URL? = nil) throws {
        guard let url = URL(string:config.url), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              UUID(uuidString:config.deviceId) != nil, config.certificateSha256.count == 64,
              config.certificateSha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw BridgeError("INVALID_CONFIG") }
        self.config = config
        if let certificateURL { self.certificateURL = certificateURL }
        else if let name = config.certificateFile {
            guard safeName(name), name.hasSuffix(".pem") else { throw BridgeError("INVALID_CONFIG") }
            self.certificateURL = support.appendingPathComponent("TrustedDevices").appendingPathComponent(name)
        } else { self.certificateURL = support.appendingPathComponent("device.pem") }
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
        _ = try certificateDER(String(contentsOf:certificateURL,encoding:.utf8),expectedHash:config.certificateSha256)
        return certificateURL
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

@MainActor final class SettingsWindow: NSObject, NSTextFieldDelegate {
    unowned let app: App
    let window: NSWindow
    let tabs = NSSegmentedControl(labels:["首页","连接设备","同步设置","使用帮助"],trackingMode:.selectOne,target:nil,action:nil)
    let homeDevice = NSTextField(wrappingLabelWithString:"")
    let homeHint = NSTextField(wrappingLabelWithString:"")
    let homePause = NSButton(title:"暂停同步",target:nil,action:nil)
    let liveStatus = NSTextField(wrappingLabelWithString:"")
    let connectionInfo = NSTextField(wrappingLabelWithString:"")
    let invitationField = NSSecureTextField()
    let addressField = NSTextField()
    let quickCodeField = NSSecureTextField()
    let legacyConnectButton = NSButton(title:"连接这台 Windows",target:nil,action:nil)
    var legacySection: NSView!
    var quickTask: Task<Void,Never>?
    let previewInfo = NSTextField(wrappingLabelWithString:"粘贴后会自动显示电脑名称，无需手动输入长码。")
    let pairingFeedback = NSTextField(wrappingLabelWithString:"")
    let importButton = NSButton(title:"选择配对文件…",target:nil,action:nil)
    let pasteButton = NSButton(title:"粘贴配对码",target:nil,action:nil)
    let connectButton = NSButton(title:"连接这台 Windows",target:nil,action:nil)
    let saveButton = NSButton(title:"保存到两台设备",target:nil,action:nil)
    let settingsFeedback = NSTextField(wrappingLabelWithString:"连接设备后，即可设置同步范围。")
    let revisionLabel = NSTextField(labelWithString:"")
    var controls: [String:NSButton] = [:]
    var pages: [NSView] = []
    var pendingInvite: Invitation?
    var draftRevision: Int64 = 0
    var dirty = false
    init(app: App) {
        self.app = app
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:760,height:740),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        super.init()
        window.title = "CopyBridge"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width:720,height:700)
        window.appearance = NSAppearance(named:.aqua); window.backgroundColor = NSColor(calibratedRed:0.96,green:0.97,blue:0.99,alpha:1)
        window.setAccessibilityIdentifier("copybridge_settings_window")
        let content = window.contentView!
        let root = stack([],spacing:18); content.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:32),root.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-32),root.topAnchor.constraint(equalTo:content.topAnchor,constant:28),root.bottomAnchor.constraint(lessThanOrEqualTo:content.bottomAnchor,constant:-24)])
        let brandIcon = NSImageView()
        if let path = Bundle.main.path(forResource:"AppIcon",ofType:"png") { brandIcon.image = NSImage(contentsOfFile:path) }
        brandIcon.setAccessibilityLabel("CopyBridge 图标")
        NSLayoutConstraint.activate([brandIcon.widthAnchor.constraint(equalToConstant:48),brandIcon.heightAnchor.constraint(equalToConstant:48)])
        root.addArrangedSubview(stack([brandIcon,label("CopyBridge",size:28,weight:.semibold)],spacing:12,horizontal:true))
        root.addArrangedSubview(label("两台电脑，用原来的方式复制粘贴",size:13,color:.secondaryLabelColor))
        liveStatus.font = .systemFont(ofSize:12,weight:.medium); liveStatus.textColor = NSColor(calibratedRed:0.15,green:0.40,blue:0.34,alpha:1)
        liveStatus.setAccessibilityIdentifier("connection_status"); root.addArrangedSubview(liveStatus)
        tabs.selectedSegment = 0; tabs.target = self; tabs.action = #selector(selectTab); tabs.segmentStyle = .rounded; tabs.setAccessibilityIdentifier("settings_tabs")
        root.addArrangedSubview(tabs)
        let pageHost = NSView(); pageHost.translatesAutoresizingMaskIntoConstraints = false; root.addArrangedSubview(pageHost)
        NSLayoutConstraint.activate([pageHost.widthAnchor.constraint(equalTo:root.widthAnchor),pageHost.heightAnchor.constraint(greaterThanOrEqualToConstant:430)])
        pages = [homePage(),connectionPage(),syncPage(),principlesPage()]
        for (index,page) in pages.enumerated() {
            pageHost.addSubview(page); page.isHidden = index != 0
            NSLayoutConstraint.activate([page.leadingAnchor.constraint(equalTo:pageHost.leadingAnchor),page.trailingAnchor.constraint(equalTo:pageHost.trailingAnchor),page.topAnchor.constraint(equalTo:pageHost.topAnchor),page.bottomAnchor.constraint(lessThanOrEqualTo:pageHost.bottomAnchor)])
        }
        for view in root.arrangedSubviews { view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo:root.widthAnchor).isActive = true }
        window.center(); updateStatus(); updateSettings(force:true)
    }
    func label(_ text: String,size: CGFloat = 13,weight: NSFont.Weight = .regular,color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString:text); label.font = .systemFont(ofSize:size,weight:weight); label.textColor = color
        label.setContentCompressionResistancePriority(.required,for:.vertical); return label
    }
    func stack(_ views: [NSView],spacing: CGFloat = 14,horizontal: Bool = false) -> NSStackView {
        let s = NSStackView(views:views); s.translatesAutoresizingMaskIntoConstraints = false; s.orientation = horizontal ? .horizontal : .vertical
        s.alignment = horizontal ? .centerY : .leading; s.spacing = spacing; return s
    }
    func page(_ views: [NSView]) -> NSStackView {
        let s = stack(views)
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo:s.widthAnchor).isActive = true }
        return s
    }
    func card(_ views: [NSView]) -> NSView {
        let box = NSBox(); box.boxType = .custom; box.borderColor = NSColor(calibratedWhite:0.86,alpha:1); box.borderWidth = 1; box.cornerRadius = 12
        box.fillColor = .white; box.contentViewMargins = .zero; box.translatesAutoresizingMaskIntoConstraints = false
        let inner = stack(views,spacing:10); box.contentView!.addSubview(inner)
        NSLayoutConstraint.activate([inner.leadingAnchor.constraint(equalTo:box.contentView!.leadingAnchor,constant:16),inner.trailingAnchor.constraint(equalTo:box.contentView!.trailingAnchor,constant:-16),inner.topAnchor.constraint(equalTo:box.contentView!.topAnchor,constant:14),inner.bottomAnchor.constraint(equalTo:box.contentView!.bottomAnchor,constant:-14)])
        for view in views { view.translatesAutoresizingMaskIntoConstraints = false; view.widthAnchor.constraint(equalTo:inner.widthAnchor).isActive = true }
        return box
    }
    func connectionPage() -> NSView {
        addressField.placeholderString = "Windows 地址，例如 192.168.0.121"
        if let text = app.config?.url, let url = URL(string:text), let host = url.host { addressField.stringValue = host + ((url.port ?? 43861) == 43861 ? "" : ":\(url.port!)") }
        quickCodeField.placeholderString = "粘贴 Windows 显示的 20 位连接口令"
        addressField.setAccessibilityIdentifier("quick_address"); addressField.setAccessibilityLabel("Windows 地址")
        quickCodeField.setAccessibilityIdentifier("quick_code"); quickCodeField.setAccessibilityLabel("短连接口令")
        for field in [addressField,quickCodeField] { field.font = .systemFont(ofSize:14); field.heightAnchor.constraint(equalToConstant:36).isActive = true }
        pasteButton.title = "粘贴连接信息"; pasteButton.target = self; pasteButton.action = #selector(pasteQuickConnection); pasteButton.bezelStyle = .rounded
        pasteButton.setAccessibilityIdentifier("paste_connection")
        connectButton.title = "连接"; connectButton.target = self; connectButton.action = #selector(connectQuick); connectButton.bezelStyle = .rounded; connectButton.bezelColor = .systemBlue
        connectButton.setAccessibilityIdentifier("connect_quick")
        pairingFeedback.font = .systemFont(ofSize:13); pairingFeedback.textColor = .secondaryLabelColor; pairingFeedback.setAccessibilityIdentifier("pairing_feedback")
        invitationField.placeholderString = "旧版完整配对码"; invitationField.delegate = self; invitationField.setAccessibilityIdentifier("invitation_input"); invitationField.setAccessibilityLabel("旧版配对码")
        let legacyPaste = NSButton(title:"粘贴旧配对码",target:self,action:#selector(pasteInvitation)); legacyPaste.bezelStyle = .rounded
        importButton.bezelStyle = .rounded; importButton.target = self; importButton.action = #selector(importInvitation)
        legacyConnectButton.bezelStyle = .rounded; legacyConnectButton.target = self; legacyConnectButton.action = #selector(connectInvitation); legacyConnectButton.isEnabled = false
        legacySection = page([invitationField,stack([legacyPaste,importButton],horizontal:true),previewInfo,legacyConnectButton]); legacySection.isHidden = true
        let legacyToggle = NSButton(title:"旧版配对码或文件…",target:self,action:#selector(toggleLegacy)); legacyToggle.bezelStyle = .rounded
        connectionInfo.font = .systemFont(ofSize:12); connectionInfo.textColor = .secondaryLabelColor
        return page([label("连接你的 Windows",size:20,weight:.semibold),label("在 Windows 点击「复制连接信息」。\n到这台 Mac 复制那行文字，点击下面粘贴，再点连接。",color:.secondaryLabelColor),stack([pasteButton],horizontal:true),label("Windows 地址",weight:.medium),addressField,label("连接口令",weight:.medium),quickCodeField,stack([connectButton],horizontal:true),pairingFeedback,stack([legacyToggle],horizontal:true),legacySection])
    }
    @objc func toggleLegacy() { legacySection.isHidden.toggle() }
    @objc func pasteQuickConnection() {
        readQuickConnection(from:.general)
    }
    func readQuickConnection(from board: NSPasteboard) {
        quickCodeField.stringValue = ""
        guard let text = board.string(forType:.string), !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { pairingFeedback.stringValue = "先复制 Windows 的连接信息，再点这里。"; return }
        if text.trimmingCharacters(in:.whitespacesAndNewlines).hasPrefix("COPYBRIDGE1:") { legacySection.isHidden = false; readInvitation(from:board); return }
        let parts = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        do {
            if parts.count > 1 { _ = try QuickPair.origin(parts[0]); addressField.stringValue = parts[0]; quickCodeField.stringValue = try QuickPair.code(parts.dropFirst().joined()) }
            else { quickCodeField.stringValue = try QuickPair.code(text) }
            pairingFeedback.stringValue = "已填好，点击「连接」即可。"
        } catch { pairingFeedback.stringValue = "没有识别到连接信息，请在 Windows 点击「复制连接信息」后重试。" }
    }
    @objc func connectQuick() {
        let address = addressField.stringValue, code = quickCodeField.stringValue
        do { _ = try QuickPair.origin(address); _ = try QuickPair.code(code) }
        catch { pairingFeedback.stringValue = errorCode(error) == "QUICK_ADDRESS_INVALID" ? "请填写 Windows 显示的地址。" : "请输入 Windows 显示的 20 位连接口令，或直接粘贴连接信息。"; return }
        pairingBusy(true); pairingFeedback.stringValue = "正在连接 Windows…"
        quickTask = Task {
            do { let invite = try await QuickPair.fetch(address:address,code:code); await app.pair(invite) }
            catch {
                pairingBusy(false)
                switch errorCode(error) {
                case "QUICK_CODE_WRONG", "QUICK_CODE_INVALID": pairingFeedback.stringValue = "连接口令不对，请在 Windows 重新复制连接信息。"
                case "QUICK_UNAVAILABLE", "INVITATION_EXPIRED_OR_INVALID_TIME": pairingFeedback.stringValue = "连接信息已过期或已使用，请在 Windows 重新准备连接。"
                default: pairingFeedback.stringValue = "没有连上 Windows，请确认地址、同一网络，以及 Windows 已打开新版 CopyBridge。"
                }
            }
            quickTask = nil
        }
    }
    func homePage() -> NSView {
        homeDevice.font = .systemFont(ofSize:19,weight:.semibold)
        homeHint.font = .systemFont(ofSize:13); homeHint.textColor = .secondaryLabelColor
        homeHint.setAccessibilityIdentifier("home_next_step")
        let connect = NSButton(title:"查看连接设备",target:self,action:#selector(openConnection))
        let files = NSButton(title:"打开收到的文件",target:app,action:#selector(App.openReceived))
        homePause.target = app; homePause.action = #selector(App.togglePause)
        for button in [connect,files,homePause] { button.bezelStyle = .rounded }
        return page([
            label("复制一下，换台电脑继续",size:23,weight:.semibold),
            card([homeDevice,homeHint,stack([connect,homePause],horizontal:true)]),
            label("这样开始",size:16,weight:.semibold),
            label("1   在这台 Mac 复制\n      选中文字、截图或一个文件，按 ⌘ C",size:15),
            label("2   等待上方显示「Windows 可粘贴」\n      大文件需要多等一会儿",size:15),
            label("3   去 Windows 按 Ctrl + V\n      反过来也一样：Windows 复制，Mac 按 ⌘ V",size:15),
            stack([files],horizontal:true),
            label("关闭窗口后仍会同步。下次双击桌面的 CopyBridge 就能回来。\n刚连接或恢复同步时，请重新复制一次。",size:12,color:.secondaryLabelColor)
        ])
    }
    @objc func openConnection() { tabs.selectedSegment = 1; selectTab() }
    func checkbox(_ key: String,_ title: String) -> NSButton {
        let b = NSButton(checkboxWithTitle:title,target:self,action:#selector(settingsEdited)); b.font = .systemFont(ofSize:13)
        b.setAccessibilityIdentifier("setting_" + key); controls[key] = b; return b
    }
    func syncPage() -> NSView {
        saveButton.bezelStyle = .rounded; saveButton.target = self; saveButton.action = #selector(saveSettings); saveButton.setAccessibilityIdentifier("save_settings")
        settingsFeedback.font = .systemFont(ofSize:12); settingsFeedback.textColor = .secondaryLabelColor; settingsFeedback.setAccessibilityIdentifier("settings_feedback")
        revisionLabel.font = .systemFont(ofSize:11); revisionLabel.textColor = .tertiaryLabelColor
        return page([label("决定同步什么",size:20,weight:.semibold),label("在任意一台设备修改，另一台也会同步更新。",color:.secondaryLabelColor),card([label("同步方向",weight:.semibold),checkbox("macToWindows","Mac 复制 → Windows 粘贴"),checkbox("windowsToMac","Windows 复制 → Mac 粘贴")]),card([label("内容范围",weight:.semibold),stack([checkbox("text","文字与链接"),checkbox("image","截图与图片内容"),checkbox("file","单个文件")],spacing:20,horizontal:true)]),checkbox("paused","暂停两台设备之间的同步"),stack([saveButton,revisionLabel],spacing:14,horizontal:true),settingsFeedback])
    }
    func principlesPage() -> NSView {
        let steps = [("1  正常复制","在正在使用的电脑按原来的复制快捷键。"),("2  加密直传","只发给已配对的设备，经局域网直接传输。"),("3  收齐并核对","文字、图片和文件完整收到后，才更新剪贴板。"),("4  正常粘贴","看到“可粘贴”后，在另一台电脑正常粘贴。")]
        return page([label("重启电脑后怎么开始",size:20,weight:.semibold),label("在 Mac 和 Windows 各双击桌面的 CopyBridge。\n程序会沿用原配对尝试连接，连上后请重新复制一次。\n关闭窗口仍会同步，菜单中选择「退出」才会停止。",color:.secondaryLabelColor),card(steps.map { label($0.0 + "\n" + $0.1,size:13) }),label("不改快捷键，不自动发送消息，也不会打开收到的文件。\n复制了更新的内容时，旧传输会被放弃。",color:.secondaryLabelColor),label("单个文件上限 2 GiB，暂不支持文件夹和多文件批次。\n提前粘贴可能仍是旧内容；图片、视频能否插入取决于目标软件。",size:12,color:.secondaryLabelColor)])
    }
    func show() { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps:true); updateStatus() }
    @objc func selectTab() { for (index,page) in pages.enumerated() { page.isHidden = index != tabs.selectedSegment }; if tabs.selectedSegment == 2 { updateSettings() } }
    func controlTextDidChange(_ notification: Notification) {
        previewInvitation()
    }
    @objc func pasteInvitation() { readInvitation(from:.general) }
    func readInvitation(from board: NSPasteboard) {
        guard let text = board.string(forType:.string), !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            pendingInvite = nil; legacyConnectButton.isEnabled = false; invitationField.stringValue = ""
            previewInfo.stringValue = "还没有复制到配对码"; pairingFeedback.stringValue = "先在这台 Mac 复制完整配对码，再点「粘贴配对码」。"; return
        }
        invitationField.stringValue = text
        previewInvitation()
    }
    @objc func importInvitation() {
        let panel = NSOpenPanel(); panel.title = "选择 Windows 导出的配对文件"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for:window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let text = try invitationText(at:url); self.invitationField.stringValue = text; self.previewInvitation()
            } catch { self.pendingInvite = nil; self.legacyConnectButton.isEnabled = false; self.pairingFeedback.stringValue = friendlyError(error) }
        }
    }
    @objc func previewInvitation() {
        pendingInvite = nil; legacyConnectButton.isEnabled = false
        let text = invitationField.stringValue
        if text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            previewInfo.stringValue = "等待粘贴配对码"; pairingFeedback.stringValue = "点击「粘贴配对码」，或在输入框按 ⌘V。"; return
        }
        do {
            let invite = try Invitation.decode(text); pendingInvite = invite
            previewInfo.stringValue = "找到电脑：\(invite.deviceName)\n是你的电脑，就点下面的连接按钮。"
            pairingFeedback.stringValue = "已完整读取配对码（\(text.count) 个字符）。"; legacyConnectButton.isEnabled = true
        } catch {
            previewInfo.stringValue = "已收到 \(text.count) 个字符"
            switch errorCode(error) {
            case "INVITATION_EXPIRED_OR_INVALID_TIME": pairingFeedback.stringValue = "配对码已过期，请在 Windows 刷新后重新复制。"
            case "INVITATION_SIZE_LIMIT": pairingFeedback.stringValue = "复制的内容太长，请只复制 COPYBRIDGE1: 开头的配对码。"
            default: pairingFeedback.stringValue = "这不是完整配对码，请重新复制 COPYBRIDGE1: 开头的整段内容。"
            }
        }
    }
    @objc func connectInvitation() {
        guard let invite = pendingInvite else { return }
        Task { await app.pair(invite) }
    }
    func pairingBusy(_ busy: Bool) { addressField.isEnabled = !busy; quickCodeField.isEnabled = !busy; connectButton.isEnabled = !busy; invitationField.isEnabled = !busy; importButton.isEnabled = !busy; pasteButton.isEnabled = !busy; legacyConnectButton.isEnabled = !busy && pendingInvite != nil }
    func pairingFinished(_ error: Error?) {
        pairingBusy(false)
        if let error { pairingFeedback.stringValue = friendlyError(error) + "；原来的本机连接配置已保留。" }
        else { quickCodeField.stringValue = ""; invitationField.stringValue = ""; pendingInvite = nil; legacyConnectButton.isEnabled = false; pairingFeedback.stringValue = "配对成功。现在可以复制新内容。"; tabs.selectedSegment = 0; selectTab(); updateStatus(); updateSettings(force:true) }
    }
    func updateStatus() {
        liveStatus.stringValue = app.stateText + "  ·  局域网直连"
        homeDevice.stringValue = "这台 Mac  ↔  " + (app.config?.deviceName ?? "等待连接 Windows")
        homeHint.stringValue = app.config == nil ? "先点「查看连接设备」，按提示连接你的 Windows。" : app.paused ? "同步已暂停。点「恢复同步」后，重新复制需要的内容。" : app.epoch == nil ? "正在等待 Windows。请确认两端都已打开，并连接同一网络。" : "两台设备已连接。现在可以复制新内容，按下面三步试一试。"
        homePause.title = app.paused ? "恢复同步" : "暂停同步"
        homePause.isEnabled = app.settings != nil && !app.savingSettings
        if let c = app.config { connectionInfo.stringValue = "\(app.settings == nil ? "上次设备" : "当前设备")：\(c.deviceName ?? "Windows")  ·  \(c.url)" }
        else { connectionInfo.stringValue = "本机 Mac 尚未连接 Windows。关闭此窗口后，CopyBridge 仍在菜单栏。" }
    }
    func updateSettings(force: Bool = false) {
        updateStatus()
        let s = app.settings
        for control in controls.values { control.isEnabled = s != nil && !app.savingSettings }
        saveButton.isEnabled = s != nil && !app.savingSettings
        guard let s else {
            dirty = false; draftRevision = 0; revisionLabel.stringValue = "未连接设备"
            for control in controls.values { control.state = .off }
            settingsFeedback.stringValue = "连接设备后，即可设置同步范围。"
            return
        }
        if dirty && !force {
            if draftRevision != s.revision { settingsFeedback.stringValue = "另一台设备已修改设置。保存时会检查冲突。" }
            return
        }
        dirty = false; draftRevision = s.revision
        let states = ["macToWindows":s.macToWindows,"windowsToMac":s.windowsToMac,"text":s.text,"image":s.image,"file":s.file,"paused":s.paused]
        for (key,value) in states { controls[key]?.state = value ? .on : .off }
        revisionLabel.stringValue = "两端设置已对齐 · 第 \(s.revision) 次更新"
        if force { settingsFeedback.stringValue = "设置生效后，请重新复制需要同步的内容。" }
    }
    @objc func settingsEdited() { dirty = true; settingsFeedback.stringValue = "有未保存的更改。" }
    @objc func saveSettings() {
        guard var s = app.settings else { return }
        s.macToWindows = controls["macToWindows"]?.state == .on; s.windowsToMac = controls["windowsToMac"]?.state == .on
        s.text = controls["text"]?.state == .on; s.image = controls["image"]?.state == .on; s.file = controls["file"]?.state == .on; s.paused = controls["paused"]?.state == .on
        let expected = draftRevision
        Task { await app.saveSettings(s,expectedRevision:expected) }
    }
}
func friendlyError(_ error: Error) -> String {
    switch errorCode(error) {
    case "INVITATION_SIZE_LIMIT": return "配对文件过大，请重新从 Windows 导出"
    case "INVITATION_EXPIRED_OR_INVALID_TIME": return "配对码已到期或时间不正确，请生成新码"
    case "INVALID_INVITATION": return "配对码格式不正确，或地址不是局域网地址"
    case "INVALID_CERTIFICATE", "TLS_PIN_MISMATCH", "TLS_VALIDATION_FAILED": return "设备身份验证未通过，请重新核对配对码"
    case "AUTH_FAILED", "PAIRING_REQUIRED": return "配对信息失效，请生成新的配对码"
    case "SETTINGS_CONFLICT": return "另一台设备已经修改设置，请重新选择后保存"
    case "SESSION_LOCKED": return "Windows 已锁定，请解锁后重新复制"
    case "KEYCHAIN_FAILED": return "系统钥匙串没有允许保存连接，请在本机确认权限"
    default: return "操作未完成，请检查两台电脑连接后重试"
    }
}

@MainActor final class App: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!; var statusRow: NSMenuItem!; var pauseRow: NSMenuItem!
    var settingsWindow: SettingsWindow?; var settings: SyncSettings?; var credentialsAttempted = false; var pairing = false; var savingSettings = false; var lastSettingsPoll = 0.0
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
    func status(_ text: String) {
        var display = text
        if text.contains("SESSION_LOCKED") { display = "Windows 已锁定，请解锁后重新复制" }
        else if text.contains("LOCAL_CLIPBOARD_CHANGED") || text.contains("SUPERSEDED") { display = "复制内容已更新，请以最新一次为准" }
        else if text.contains("TYPE_DISABLED") { display = "本次内容已关闭同步，可在设置中修改" }
        else if text.contains("PAIRING_REQUIRED") || text.contains("AUTH_FAILED") { display = "请生成新配对码，连接 Windows" }
        else if text.contains("NETWORK_FAILED") { display = "未连接，请检查两台电脑的局域网" }
        else if text.contains("TLS_") { display = "设备身份验证未通过，请重新核对配对码" }
        stateText = display; statusRow?.title = display; statusItem?.button?.title = paused ? "CopyBridge ⏸" : "CopyBridge ↔"; settingsWindow?.updateStatus()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        menu()
        do {
            try FileManager.default.createDirectory(at:support,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try FileManager.default.createDirectory(at:received,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            instanceLock = open(support.appendingPathComponent("instance.lock").path,O_CREAT | O_RDWR,0o600)
            guard instanceLock >= 0, flock(instanceLock,LOCK_EX | LOCK_NB) == 0 else { NSApplication.shared.terminate(nil); return }
            lastCount = NSPasteboard.general.changeCount
            timer = Timer.scheduledTimer(withTimeInterval:0.1,repeats:true) { [weak self] _ in Task { @MainActor in self?.observe() } }
            loopTask = Task { await self.loop() }
            if let path = option("--diagnostics") { diagnosticURL = URL(fileURLWithPath:path) }
            if FileManager.default.fileExists(atPath:configURL.path) {
                config = try JSONDecoder().decode(Config.self,from:Data(contentsOf:configURL))
                net = try Network(config)
            }
            if config == nil { status("尚未连接设备"); showSettings() }
            else if config.formatVersion != 2 && option("--pair-token-file") == nil { status("请导入新配对码，保留原有连接凭据"); showSettings() }
            else if !CommandLine.arguments.contains("--background") || CommandLine.arguments.contains("--show-settings") { showSettings() }
        } catch { status("连接配置暂不可用，请重新配对"); log("CONFIG_FAILED"); showSettings() }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool { showSettings(); return false }
    func installApplicationMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem(); let applicationMenu = NSMenu(title:"CopyBridge")
        applicationMenu.addItem(withTitle:"退出 CopyBridge",action:#selector(quit),keyEquivalent:"q").target = self
        applicationItem.submenu = applicationMenu; main.addItem(applicationItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title:"编辑")
        for (title,action,key) in [("撤销","undo:","z"),("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] {
            edit.addItem(withTitle:title,action:Selector(action),keyEquivalent:key)
        }
        editItem.submenu = edit; main.addItem(editItem); NSApplication.shared.mainMenu = main
    }
    func menu() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength); statusItem.button?.title = "CopyBridge ↔"
        let menu = NSMenu(); menu.autoenablesItems = false; statusRow = NSMenuItem(title:stateText,action:nil,keyEquivalent:""); menu.addItem(statusRow)
        menu.addItem(NSMenuItem(title:"Mac ⇄ Windows · 局域网直连",action:nil,keyEquivalent:"")); menu.addItem(.separator())
        let openSettings = NSMenuItem(title:"打开 CopyBridge…",action:#selector(showSettings),keyEquivalent:","); openSettings.target = self; menu.addItem(openSettings)
        pauseRow = NSMenuItem(title:"暂停同步",action:#selector(togglePause),keyEquivalent:""); pauseRow.target = self; pauseRow.isEnabled = false; menu.addItem(pauseRow)
        for (title,action) in [("打开收到的文件",#selector(openReceived)),("取消当前传输",#selector(cancelCurrent)),("解除配对",#selector(unpair)),("退出",#selector(quit))] {
            let item = NSMenuItem(title:title,action:action,keyEquivalent:""); item.target = self; menu.addItem(item)
        }
        statusItem.menu = menu
    }
    @objc func showSettings() { if settingsWindow == nil { settingsWindow = SettingsWindow(app:self) }; settingsWindow?.show() }
    @objc func openReceived() { NSWorkspace.shared.open(received) }
    @objc func quit() { settingsWindow?.quickTask?.cancel(); cancelWork(); loopTask?.cancel(); net?.cancelAll(); NSApplication.shared.terminate(nil) }
    @objc func cancelCurrent() { cancelWork(); status("已取消，请重新复制") }
    func cancelWork() {
        if let id = incomingID { reverseDiscard.insert(id) }; incomingID = nil
        outgoingTask?.cancel(); incomingTask?.cancel(); outgoingTask = nil; incomingTask = nil
        if let id = transferID, let e = epoch, let network = net { Task { _ = try? await network.json("POST","/v1/transfers/\(id)/cancel",body:[:],epoch:e) } }
        transferID = nil
    }
    func resetBaseline() {
        lastCount = NSPasteboard.general.changeCount; previousPollSerial = localSerial; previousPollCount = lastCount
        reverseSeen.removeAll(); reverseDiscard.removeAll(); reversePublished.removeAll(); lastOutgoing = nil
    }
    @objc func togglePause() {
        guard var next = settings else { showSettings(); return }; next.paused.toggle()
        Task { await saveSettings(next,expectedRevision:next.revision) }
    }
    @objc func unpair() {
        guard let network = net, let activeConfig = config else { return }
        Task {
            do {
                _ = try await network.json("POST","/v1/unpair",body:[:])
                guard net === network else { return }
                cancelWork(); network.cancelAll(); network.token = ""; epoch = nil
                net = nil; config = nil; settings = nil; paused = false; credentialsAttempted = false; resetBaseline()
                pauseRow.isEnabled = false; settingsWindow?.updateSettings(force:true)
                var cleanupFailed = false
                if activeConfig.formatVersion == 2 {
                    do { _ = try credential(activeConfig.keychainAccount,remove:true) } catch { cleanupFailed = true }
                }
                if FileManager.default.fileExists(atPath:configURL.path) {
                    do { try FileManager.default.removeItem(at:configURL) } catch { cleanupFailed = true }
                }
                status(cleanupFailed ? "连接已解除，本机旧凭据尚未完全清理" : "已解除配对，收到的文件仍保留")
            } catch { status("解除配对未完成，请检查连接") }
        }
    }
    func authenticationInvalidated() {
        cancelWork(); net?.cancelAll(); net?.token = ""; epoch = nil; settings = nil; paused = false; credentialsAttempted = true; resetBaseline()
        pauseRow.isEnabled = false; settingsWindow?.updateSettings(force:true); status("连接已解除或凭据失效，请重新配对")
    }
    func disconnect(_ event: String) {
        if event == "AUTH_FAILED" { authenticationInvalidated() }
        else { cancelWork(); epoch = nil; resetBaseline(); status(event == "SESSION_LOCKED" ? event : "未连接，请重新复制") }
        log(event)
    }
    func applySettings(_ value: SyncSettings) throws {
        guard value.revision > 0 else { throw BridgeError("INVALID_SETTINGS") }
        if let current = settings {
            if value.revision < current.revision { return }
            if value.revision == current.revision {
                guard value == current else { throw BridgeError("INVALID_SETTINGS") }; return
            }
        }
        cancelWork(); epoch = nil; settings = value; paused = value.paused; resetBaseline()
        pauseRow.title = paused ? "恢复同步" : "暂停同步"; pauseRow.isEnabled = true
        status(paused ? "已暂停，可在任一端恢复" : "设置已更新，请复制新内容")
        settingsWindow?.updateSettings(); log("SETTINGS_UPDATED")
    }
    func fetchSettings() async throws {
        guard let network = net, !network.token.isEmpty else { throw BridgeError("PAIRING_REQUIRED") }
        let bytes: Data
        do { bytes = try await network.json("GET","/v1/settings") }
        catch { if net === network && errorCode(error) == "AUTH_FAILED" { authenticationInvalidated() }; throw error }
        guard net === network else { throw CancellationError() }
        let value = try JSONDecoder().decode(SyncSettings.self,from:bytes)
        try applySettings(value); lastSettingsPoll = ProcessInfo.processInfo.systemUptime
    }
    func saveSettings(_ value: SyncSettings,expectedRevision: Int64) async {
        guard !savingSettings, let network = net, !network.token.isEmpty else { return }
        savingSettings = true; settingsWindow?.settingsFeedback.stringValue = "正在保存…"; settingsWindow?.updateSettings()
        defer { savingSettings = false; settingsWindow?.updateSettings() }
        do {
            let bytes = try await network.json("POST","/v1/settings",body:value.request(expectedRevision:expectedRevision))
            guard net === network else { throw CancellationError() }
            let saved = try JSONDecoder().decode(SyncSettings.self,from:bytes)
            guard saved.revision > expectedRevision else { throw BridgeError("INVALID_SETTINGS") }
            try applySettings(saved); settingsWindow?.updateSettings(force:true)
            settingsWindow?.settingsFeedback.stringValue = "已保存。另一台设备会自动更新，请重新复制内容。"
        } catch {
            if net === network && errorCode(error) == "AUTH_FAILED" { authenticationInvalidated() }
            if errorCode(error) == "SETTINGS_CONFLICT" { try? await fetchSettings(); settingsWindow?.updateSettings(force:true) }
            settingsWindow?.settingsFeedback.stringValue = friendlyError(error)
        }
    }
    func pair(_ invite: Invitation) async {
        guard !pairing else { return }
        pairing = true; settingsWindow?.pairingBusy(true); settingsWindow?.pairingFeedback.stringValue = "正在验证并连接设备…"
        cancelWork(); net?.cancelAll(); epoch = nil; resetBaseline()
        let fm = FileManager.default; let attempt = UUID().uuidString
        let temporary = support.appendingPathComponent("Pairing").appendingPathComponent(attempt)
        let trustedDirectory = support.appendingPathComponent("TrustedDevices")
        let permanentCertificate = trustedDirectory.appendingPathComponent(attempt + ".pem")
        let account = "copybridge-ui-" + attempt
        var storedCredential = false; var committed = false
        defer {
            try? fm.removeItem(at:temporary)
            if !committed { if storedCredential { _ = try? credential(account,remove:true) }; try? fm.removeItem(at:permanentCertificate) }
            pairing = false
        }
        do {
            try invite.validate()
            try fm.createDirectory(at:temporary,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let certificate = temporary.appendingPathComponent("device.pem")
            try Data(invite.certificatePem.utf8).write(to:certificate,options:.atomic)
            var proposed = Config(url:invite.url,deviceId:UUID().uuidString,certificateSha256:invite.certificateSha256,keychainAccount:account)
            proposed.peerDeviceId = invite.deviceId; proposed.deviceName = invite.deviceName; proposed.formatVersion = 2; proposed.certificateFile = attempt + ".pem"
            let testing = try Network(proposed,certificateURL:certificate)
            let response = try await testing.json("POST","/v1/pair",body:["deviceId":proposed.deviceId,"token":invite.token])
            guard let object = try JSONSerialization.jsonObject(with:response) as? [String:Any], let value = object["token"] as? String,
                  value.utf8.count >= 32, value.utf8.count <= 512, value.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }),
                  let peer = object["deviceId"] as? String, UUID(uuidString:peer) == UUID(uuidString:invite.deviceId) else { throw BridgeError("PAIR_FAILED") }
            testing.token = value
            let settingsBytes = try await testing.json("GET","/v1/settings")
            let values = try JSONDecoder().decode(SyncSettings.self,from:settingsBytes)
            guard values.revision > 0 else { throw BridgeError("INVALID_SETTINGS") }
            try fm.createDirectory(at:trustedDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try Data(invite.certificatePem.utf8).write(to:permanentCertificate,options:.atomic)
            let ready = try Network(proposed); ready.token = value
            _ = try credential(account,save:value); storedCredential = true
            try JSONEncoder().encode(proposed).write(to:configURL,options:.atomic)
            committed = true
            net?.cancelAll(); net = ready; config = proposed; settings = nil; credentialsAttempted = true
            try applySettings(values); resetBaseline(); log("PAIRED")
            settingsWindow?.pairingFinished(nil)
        } catch { log(errorCode(error)); settingsWindow?.pairingFinished(error) }
    }
    func loop() async {
        while !Task.isCancelled {
            if net != nil && !pairing {
                if epoch == nil { await connect() }
                else {
                    if ProcessInfo.processInfo.systemUptime - lastSettingsPoll >= 1 {
                        do { try await fetchSettings() } catch { disconnect(errorCode(error)) }
                    }
                    if epoch != nil && !paused { await poll() }
                }
            }
            try? await Task.sleep(nanoseconds:epoch == nil ? 1_000_000_000 : 500_000_000)
        }
    }
    func connect() async {
        guard !connecting, !pairing, let network = net, let activeConfig = config else { return }
        connecting = true; defer { connecting = false }
        do {
            if network.token.isEmpty {
                guard !credentialsAttempted else { return }; credentialsAttempted = true
                if activeConfig.formatVersion == 2, let existing = try credential(activeConfig.keychainAccount) { network.token = existing }
                else if let file = option("--pair-token-file") {
                    let data = try Data(contentsOf:URL(fileURLWithPath:file)); let object = try? JSONSerialization.jsonObject(with:data) as? [String:Any]
                    let token = object?["token"] as? String ?? String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
                    guard !token.isEmpty else { throw BridgeError("PAIRING_REQUIRED") }
                    let result = try await network.json("POST","/v1/pair",body:["deviceId":activeConfig.deviceId,"token":token])
                    guard net === network, let response = try JSONSerialization.jsonObject(with:result) as? [String:Any], let value = response["token"] as? String else { throw BridgeError("PAIR_FAILED") }
                    var updated = activeConfig; updated.formatVersion = 2; updated.keychainAccount = "copybridge-ui-" + UUID().uuidString
                    _ = try credential(updated.keychainAccount,save:value); network.token = value
                    try JSONEncoder().encode(updated).write(to:configURL,options:.atomic); config = updated
                    try FileManager.default.removeItem(atPath:file); log("PAIRED")
                } else { throw BridgeError("PAIRING_REQUIRED") }
            }
            try await fetchSettings()
            guard net === network, !paused, !pairing else { return }
            let result = try await network.json("POST","/v1/hello",body:["protocolVersion":1,"deviceId":activeConfig.deviceId,"sourceSessionId":sessionID,"handshakeId":UUID().uuidString,"lastIssuedSourceSeq":sequence])
            guard net === network, !paused, !pairing else { return }
            let hello = try JSONDecoder().decode(Hello.self,from:result)
            guard UUID(uuidString:hello.connectionEpoch) != nil else { throw BridgeError("INVALID_METADATA") }
            if let peer = activeConfig.peerDeviceId { guard UUID(uuidString:hello.deviceId) == UUID(uuidString:peer) else { throw BridgeError("DEVICE_ID_MISMATCH") } }
            epoch = hello.connectionEpoch; sequence = max(sequence,hello.seqFloor); receiverGeneration = hello.receiverGeneration
            resetBaseline(); status("已连接，请复制新内容"); log("CONNECTED")
        } catch { status("未连接：" + errorCode(error)); log(errorCode(error)) }
    }
    func observe() {
        let count = NSPasteboard.general.changeCount
        guard count != lastCount else { return }; lastCount = count; localSerial += 1
        for id in reverseSeen.keys { reverseDiscard.insert(id) }; incomingTask?.cancel(); incomingTask = nil
        cancelWork()
        guard !paused, !pairing, settings?.macToWindows == true, let e = epoch else { return }
        sequence += 1; let id = UUID().uuidString; transferID = id
        let head = Head(connectionEpoch:e, sourceSessionId:sessionID, sourceSeq:sequence, transferId:id, receiverGenAtCopy:receiverGeneration)
        status("准备中，尚不可粘贴"); log("COPY_OBSERVED", id:id)
        outgoingTask = Task { await send(head, count:count) }
    }
    func source(_ count: Int) throws -> Source {
        let p = NSPasteboard.general
        guard p.changeCount == count else { throw BridgeError("SUPERSEDED") }
        let excluded = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword", "de.petermaurer.TransientPasteboardType", "com.copybridge.sensitive"]
        guard !(p.types ?? []).contains(where: { excluded.contains($0.rawValue) }) else { throw BridgeError("SENSITIVE_SOURCE_EXCLUDED") }
        var source: Source
        if let files = p.readObjects(forClasses:[NSURL.self], options:[.urlReadingFileURLsOnly:true]) as? [URL], !files.isEmpty {
            guard settings?.allows("file",sending:true) == true else { throw BridgeError("TYPE_DISABLED") }
            guard files.count == 1 else { throw BridgeError("MULTI_FILE_UNSUPPORTED") }
            let file = files[0]; guard file.isFileURL, safeName(file.lastPathComponent) else { throw BridgeError("INVALID_FILENAME") }
            let mime = fileMIME(file.lastPathComponent)
            source = Source(kind:"file", name:file.lastPathComponent, mime:mime, file:file)
        } else if (p.types ?? []).contains(.png) || (p.types ?? []).contains(.tiff) {
            guard settings?.allows("image",sending:true) == true else { throw BridgeError("TYPE_DISABLED") }
            guard let image = p.data(forType:.png) ?? p.data(forType:.tiff) else { throw BridgeError("IMAGE_INVALID") }
            guard image.count <= 32 * Int(MiB) else { throw BridgeError("SIZE_LIMIT") }
            source = Source(kind:"image", name:"Clipboard.png", mime:"image/png", bytes:image)
        } else if p.availableType(from:[.string]) != nil {
            guard settings?.allows("text",sending:true) == true else { throw BridgeError("TYPE_DISABLED") }
            guard let text = p.string(forType:.string) else { throw BridgeError("SOURCE_UNAVAILABLE") }
            source = Source(kind:"text",name:"clipboard.txt",mime:"text/plain",bytes:Data(text.utf8))
        }
        else { throw BridgeError("TYPE_UNSUPPORTED") }
        guard p.changeCount == count else { throw BridgeError("SUPERSEDED") }; return source
    }
    func eligible(_ head: Head, count: Int, kind: String? = nil) throws {
        try Task.checkCancellation()
        guard !paused, !pairing, settings?.macToWindows == true, kind.map({ settings?.allows($0,sending:true) == true }) ?? true, epoch == head.connectionEpoch, sequence == head.sourceSeq, NSPasteboard.general.changeCount == count else { throw BridgeError("SUPERSEDED") }
    }
    func send(_ head: Head, count: Int) async {
        guard let network = net else { return }
        let start = ProcessInfo.processInfo.systemUptime
        var spool: URL?
        defer { if let spool { try? FileManager.default.removeItem(at:spool.deletingLastPathComponent()) } }
        do {
            _ = try await network.encoded("/v1/head", head, epoch:head.connectionEpoch)
            try eligible(head, count:count)
            let input = try source(count)
            let worker = Task.detached(priority:.userInitiated) { try snapshot(input, id:head.transferId) }
            let prepared = try await withTaskCancellationHandler(operation:{ try await worker.value }, onCancel:{ worker.cancel() })
            spool = prepared.url; try eligible(head,count:count,kind:prepared.kind)
            log("SNAPSHOT_READY", id:head.transferId, kind:prepared.kind, size:prepared.item.sizeBytes)
            let offer = Offer(connectionEpoch:head.connectionEpoch, sourceSessionId:head.sourceSessionId, sourceSeq:head.sourceSeq, transferId:head.transferId, receiverGenAtCopy:head.receiverGenAtCopy, kind:prepared.kind, items:[prepared.item])
            _ = try await network.encoded("/v1/offers", offer, epoch:head.connectionEpoch)
            try eligible(head,count:count,kind:prepared.kind); status("传输中，尚不可粘贴")
            try await network.upload("/v1/transfers/\(head.transferId)/items/f1", snapshot:prepared, epoch:head.connectionEpoch)
            try eligible(head,count:count,kind:prepared.kind); status("校验中，尚不可粘贴")
            let response = try await network.json("POST", "/v1/transfers/\(head.transferId)/complete", body:[:], epoch:head.connectionEpoch)
            try eligible(head,count:count,kind:prepared.kind)
            let object = try JSONSerialization.jsonObject(with:response) as? [String:Any]
            guard object?["state"] as? String == "Published", object?["currentlyOnClipboard"] as? Bool == true else { throw BridgeError("PUBLISH_FAILED") }
            status("Windows 可粘贴"); log("REMOTE_PUBLISHED", id:head.transferId, kind:prepared.kind, size:prepared.item.sizeBytes, elapsed:(ProcessInfo.processInfo.systemUptime-start)*1000)
            transferID = nil
        } catch {
            if head.sourceSeq == sequence, epoch == head.connectionEpoch, !paused { status("本次未同步：" + errorCode(error)); log(errorCode(error), id:head.transferId) }
            _ = try? await network.json("POST", "/v1/transfers/\(head.transferId)/cancel", body:[:], epoch:head.connectionEpoch)
        }
    }
    func poll() async {
        guard let e = epoch, let network = net else { return }
        if reverseSeen.count >= 4096 { disconnect("SESSION_RECORD_BUDGET"); return }
        let serial = localSerial; let count = NSPasteboard.general.changeCount
        do {
            let bytes = try await network.json("GET", "/v1/receiver-state", epoch:e)
            guard net === network, epoch == e, !paused, !pairing else { return }
            let state = try JSONDecoder().decode(State.self, from:bytes)
            guard state.connectionEpoch == e else { throw BridgeError("SESSION_REVOKED") }
            if state.paused == true { try await fetchSettings(); return }
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
            guard settings?.windowsToMac == true, settings?.paused == false else { reverseDiscard.insert(id); return }
            if !out.kind.isEmpty && settings?.allows(out.kind,sending:false) != true { reverseDiscard.insert(id); return }
            guard out.state == "Ready", !reverseDiscard.contains(id), !reversePublished.contains(id), incomingTask == nil else { return }
            let expected = reverseSeen[id]!
            incomingID = id; incomingTask = Task { await receive(out, epoch:e, expectedCount:expected) }
        } catch { if epoch == e && !paused { disconnect(errorCode(error)) } }
    }
    func receive(_ out: Outgoing, epoch e: String, expectedCount: Int) async {
        guard let network = net else { return }
        let id = out.transferId; let start = ProcessInfo.processInfo.systemUptime
        guard let epochID = UUID(uuidString:e)?.uuidString, let transferID = UUID(uuidString:id)?.uuidString else { log("INVALID_METADATA",id:id); return }
        let dir = received.appendingPathComponent(epochID).appendingPathComponent(transferID); var protected = false; var created = false
        defer { if incomingID == id { incomingTask = nil; incomingID = nil }; if created && !protected { try? FileManager.default.removeItem(at:dir) } }
        do {
            guard settings?.allows(out.kind,sending:false) == true, !pairing else { throw BridgeError("TYPE_DISABLED") }
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
            try await network.download("/v1/outgoing/\(id)/items/f1", epoch:e, destination:part, expected:item.sizeBytes)
            let worker = Task.detached { () throws -> (Int64,String) in if out.kind == "image" { try checkImage(part) }; return try hashFile(part) }
            let (size, hash) = try await withTaskCancellationHandler(operation:{ try await worker.value }, onCancel:{ worker.cancel() })
            guard size == item.sizeBytes, hash == item.sha256 else { throw BridgeError("HASH_MISMATCH") }
            try Task.checkCancellation()
            // Refresh remote generation immediately before publishing; no timestamp comparison.
            let data = try await network.json("GET", "/v1/receiver-state", epoch:e)
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
            guard !paused, !pairing, net === network, settings?.allows(out.kind,sending:false) == true, epoch == e, lastOutgoing == id, !reverseDiscard.contains(id), NSPasteboard.general.changeCount == expectedCount else { throw BridgeError("LOCAL_CLIPBOARD_CHANGED") }
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
    for origin in ["https://192.168.1.100:43861","https://10.1.2.3:443","https://172.16.0.2:1","https://127.0.0.1:8443"] {
        guard privateOrigin(origin) else { throw BridgeError("SELFTEST_INVITATION_ORIGIN") }
    }
    for origin in ["https://8.8.8.8:443","https://172.32.0.1:443","https://example.com:443","http://192.168.0.1:443","https://192.168.0.1","https://192.168.0.1:443/","https://192.168.0.1:443?a=b","https://user@192.168.0.1:443","https://192.168.00.1:443"] {
        guard !privateOrigin(origin) else { throw BridgeError("SELFTEST_INVITATION_ORIGIN") }
    }
    var preferences = SyncSettings(revision:1,macToWindows:true,windowsToMac:true,text:true,image:true,file:true,paused:false)
    guard preferences.allows("text",sending:true), preferences.allows("file",sending:false) else { throw BridgeError("SELFTEST_SETTINGS") }
    preferences.macToWindows = false
    guard !preferences.allows("text",sending:true), preferences.allows("text",sending:false) else { throw BridgeError("SELFTEST_SETTINGS") }
    preferences.text = false
    guard !preferences.allows("text",sending:false), preferences.allows("image",sending:false) else { throw BridgeError("SELFTEST_SETTINGS") }
    preferences.paused = true
    guard !preferences.allows("image",sending:false), !preferences.allows("file",sending:true), !preferences.allows("unknown",sending:false) else { throw BridgeError("SELFTEST_SETTINGS") }
    for code in ["COPYBRIDGE1:bad=payload","COPYBRIDGE2:abcd",String(repeating:"x",count:16385)] {
        do { _ = try Invitation.decode(code); throw BridgeError("SELFTEST_INVITATION_REJECTION") } catch let e as BridgeError { guard e.code != "SELFTEST_INVITATION_REJECTION" else { throw e } }
    }

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
    print("PASS: names, path boundary, size boundary, local-copy conflict guard, UTF8 stable snapshot, generic file streaming, curl escaping/cancel/once, settings enforcement, invitation boundaries, SHA256; no clipboard touched")
}
if let path = option("--check-invitation") {
    do {
        let value = try Invitation.decode(invitationText(at:URL(fileURLWithPath:path)))
        let result: [String:Any] = ["valid":true,"deviceName":value.deviceName,"url":value.url,"expiresAt":value.expiresAt]
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self)); exit(0)
    } catch {
        let result = ["error":errorCode(error)]
        print(String(decoding:try! JSONSerialization.data(withJSONObject:result),as:UTF8.self)); exit(1)
    }
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
if let fixturePath = option("--quick-pair-test-fixture") {
    MainActor.assumeIsolated {
        do {
            struct Fixture: Decodable { let address: String; let code: String; let packet: QuickEnvelope; let invitation: String }
            let value = try JSONDecoder().decode(Fixture.self,from:Data(contentsOf:URL(fileURLWithPath:fixturePath)))
            let packet = try JSONEncoder().encode(value.packet)
            _ = try QuickPair.open(packet,code:value.code,origin:value.address)
            let wrong = String(repeating:value.code.first == "A" ? "B" : "A",count:20)
            do { _ = try QuickPair.open(packet,code:wrong,origin:value.address); throw BridgeError("SELFTEST_WRONG_CODE_ACCEPTED") }
            catch { guard errorCode(error) == "QUICK_CODE_WRONG" else { throw error } }
            do { _ = try QuickPair.open(packet,code:value.code,origin:"127.0.0.2:43863"); throw BridgeError("SELFTEST_WRONG_ADDRESS_ACCEPTED") }
            catch { guard errorCode(error) == "QUICK_ADDRESS_MISMATCH" else { throw error } }
            let app = App(); app.installApplicationMenu(); let view = SettingsWindow(app:app)
            let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
            board.setString(value.address + " " + value.code,forType:.string); view.readQuickConnection(from:board)
            guard view.addressField.stringValue == value.address,view.quickCodeField.stringValue == value.code else { throw BridgeError("SELFTEST_QUICK_PASTE") }
            board.clearContents();board.setString("bad",forType:.string);view.readQuickConnection(from:board)
            guard view.quickCodeField.stringValue.isEmpty else { throw BridgeError("SELFTEST_STALE_CODE") }
            board.clearContents();board.setString(value.invitation,forType:.string);view.readInvitation(from:board)
            guard view.invitationField.stringValue == value.invitation, view.pendingInvite != nil,view.legacyConnectButton.isEnabled else { throw BridgeError("SELFTEST_LONG_PASTE") }
            let long = "COPYBRIDGE1:" + String(repeating:"A",count:16000)
            board.clearContents();board.setString(long,forType:.string);view.readInvitation(from:board)
            guard view.invitationField.stringValue.count == long.count,view.pendingInvite == nil,!view.legacyConnectButton.isEnabled else { throw BridgeError("SELFTEST_LONG_FIELD") }
            let menu = NSApplication.shared.mainMenu!
            guard menu.items.contains(where: { $0.submenu?.items.contains(where: { $0.keyEquivalent == "v" && $0.action == Selector(("paste:")) }) == true }) else { throw BridgeError("SELFTEST_PASTE_MENU") }
            print("PASS: cross-platform authenticated short pairing; wrong-code/address rejection; short paste; stale-code clearing; full legacy paste; 16012-character field; standard paste menu")
            exit(0)
        } catch { fputs("Quick-pair test failed: \(errorCode(error))\n",stderr);exit(1) }
    }
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
