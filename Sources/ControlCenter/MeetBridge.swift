import Darwin
import Foundation

/// The link between the Device Studio Chrome extension and the running app.
///
/// Chrome starts a "native messaging host" for the extension: this same executable, with the extension's
/// origin as its first argument. That host relays Chrome's length-prefixed JSON messages to a Unix socket
/// the app listens on, and the app's replies back to Chrome. The socket lives in a folder only this user can
/// open; nothing is sent over the network.
enum MeetBridge {
    static let hostName = "com.jackzoppa.devicestudio"
    /// The extension's fixed ID (from the public key in ChromeExtension/manifest.json).
    static let extensionID = "kppiaocbgilnjbipgddhpglfbedniggj"
    static let maxMessageBytes = 256 * 1024

    static var socketURL: URL {
        // The self-test uses its own socket so it never disturbs a running copy of the app.
        if let path = ProcessInfo.processInfo.environment["DEVICESTUDIO_BRIDGE_SOCKET"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeviceStudio/bridge.sock")
    }

    /// Chrome's per-user folder for native messaging host manifests.
    static var chromeHostsFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts")
    }

    static var manifestURL: URL { chromeHostsFolder.appendingPathComponent("\(hostName).json") }

    /// The extension shipped inside the app.
    static var bundledExtension: URL? {
        Bundle.main.resourceURL.map { $0.appendingPathComponent("ChromeExtension") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// A copy of the extension outside the app bundle, which Chrome's "Load unpacked" can open easily.
    static var extensionFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/DeviceStudio/ChromeExtension")
    }

    /// Refresh the copy Chrome loads from, so an updated app updates the extension (Chrome picks the change
    /// up when the extension is reloaded or Chrome restarts).
    static func copyExtension() throws {
        guard let source = bundledExtension else { return }
        let fm = FileManager.default
        let staged = extensionFolder.deletingLastPathComponent().appendingPathComponent("ChromeExtension.new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: source, to: staged)
        if fm.fileExists(atPath: extensionFolder.path) {
            _ = try fm.replaceItemAt(extensionFolder, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: extensionFolder)
        }
    }

    static func manifest(executable: String) -> Data {
        let object: [String: Any] = [
            "name": hostName,
            "description": "Device Studio: names the people on a Google Meet call in your local transcript",
            "path": executable,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    /// Whether Chrome can find this app as the extension's host, and the extension copy is current.
    static var isInstalled: Bool {
        guard hostManifestCurrent else { return false }
        guard let source = bundledExtension else { return true }
        let a = try? Data(contentsOf: source.appendingPathComponent("content.js"))
        let b = try? Data(contentsOf: extensionFolder.appendingPathComponent("content.js"))
        return a == b
    }

    private static var hostManifestCurrent: Bool {
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["path"] as? String == Bundle.main.executablePath
    }

    /// Chrome has run for this user (its profile folder exists).
    static var chromeInstalled: Bool {
        FileManager.default.fileExists(atPath: chromeHostsFolder.deletingLastPathComponent().path)
    }

    /// Write the host manifest so Chrome can start this app for the extension. Only from an installed app
    /// bundle, and only when Chrome is installed.
    @discardableResult
    static func install() throws -> Bool {
        guard let executable = Bundle.main.executablePath, Bundle.main.bundleURL.pathExtension == "app",
              chromeInstalled else { return false }
        try FileManager.default.createDirectory(at: chromeHostsFolder, withIntermediateDirectories: true)
        try manifest(executable: executable).write(to: manifestURL, options: .atomic)
        try copyExtension()
        return true
    }

    // MARK: Native messaging host (runs instead of the app when Chrome starts it)

    /// True when Chrome started this executable as the extension's host.
    static var isHostLaunch: Bool {
        CommandLine.arguments.dropFirst().first?.hasPrefix("chrome-extension://") == true
    }

    /// Relay between Chrome (stdin and stdout) and the app's socket until Chrome closes stdin.
    static func runHost() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        let origin = CommandLine.arguments[1]
        guard origin == "chrome-extension://\(extensionID)/" else { return 1 }
        let link = HostLink()
        // App to Chrome: one JSON object per line on the socket, length-prefixed on stdout.
        Thread.detachNewThread { link.pumpFromApp() }
        // Chrome to app.
        while let message = readChromeMessage() {
            link.send(message)
        }
        return 0
    }

    private static func readChromeMessage() -> Data? {
        var length: UInt32 = 0
        guard readFully(STDIN_FILENO, &length, 4) else { return nil }
        let count = Int(UInt32(littleEndian: length))
        guard count <= maxMessageBytes else { return nil }
        var buffer = [UInt8](repeating: 0, count: count)
        guard buffer.withUnsafeMutableBytes({ readFully(STDIN_FILENO, $0.baseAddress!, count) }) else { return nil }
        return Data(buffer)
    }

    static let stdoutLock = NSLock()

    static func writeChromeMessage(_ data: Data) {
        stdoutLock.lock(); defer { stdoutLock.unlock() }
        var length = UInt32(data.count).littleEndian
        _ = writeFully(STDOUT_FILENO, &length, 4)
        data.withUnsafeBytes { _ = writeFully(STDOUT_FILENO, $0.baseAddress!, data.count) }
    }

    static func readFully(_ fd: Int32, _ pointer: UnsafeMutableRawPointer, _ count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = read(fd, pointer + done, count - done)
            if n > 0 { done += n } else if n < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }

    @discardableResult
    static func writeFully(_ fd: Int32, _ pointer: UnsafeRawPointer, _ count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = write(fd, pointer + done, count - done)
            if n > 0 { done += n } else if n < 0 && errno == EINTR { continue } else { return false }
        }
        return true
    }

    static func connectSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        guard fill(&address, path: socketURL.path) else { close(fd); return nil }
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func fill(_ address: inout sockaddr_un, path: String) -> Bool {
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return true
    }
}

/// The host's connection to the app. Reconnects when the app starts later or restarts; messages that
/// arrive while the app is not running are dropped (the extension sends fresh state often).
private final class HostLink {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private let ready = DispatchSemaphore(value: 0)

    func send(_ message: Data) {
        // One JSON object per line: refuse anything that is not a single JSON object.
        guard (try? JSONSerialization.jsonObject(with: message)) is [String: Any] else { return }
        var line = message.filter { $0 != 0x0A && $0 != 0x0D }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        if fd < 0 { connect() }
        guard fd >= 0 else { return }
        let ok = line.withUnsafeBytes { MeetBridge.writeFully(fd, $0.baseAddress!, line.count) }
        if !ok { close(fd); fd = -1 }
    }

    /// Runs on its own thread: reads the app's lines and hands them to Chrome.
    func pumpFromApp() {
        while true {
            lock.lock()
            if fd < 0 { connect() }
            let current = fd
            lock.unlock()
            if current < 0 {
                Thread.sleep(forTimeInterval: 2)
                continue
            }
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(current, &buffer, buffer.count)
                if n <= 0 { break }
                pending.append(contentsOf: buffer[0..<n])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<newline]
                    pending.removeSubrange(pending.startIndex...newline)
                    if !line.isEmpty, line.count <= MeetBridge.maxMessageBytes { MeetBridge.writeChromeMessage(Data(line)) }
                }
                if pending.count > MeetBridge.maxMessageBytes { pending.removeAll() }
            }
            lock.lock()
            if fd == current { close(fd); fd = -1 }
            lock.unlock()
            // Tell the extension the app went away, so it stops showing it as connected.
            MeetBridge.writeChromeMessage(Data(#"{"type":"app","running":false}"#.utf8))
        }
    }

    /// Caller holds the lock.
    private func connect() {
        if let new = MeetBridge.connectSocket() { fd = new }
    }
}

/// The app side: a Unix socket server. Each connected extension host gets the recording state; every line
/// it sends is decoded and handed to `onMessage` on the main thread.
final class MeetBridgeServer {
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var clients: [Int32] = []
    private var lastState = Data()
    private let onMessage: @MainActor ([String: Any]) -> Void
    private let onClientsChanged: @MainActor (Int) -> Void

    init(onMessage: @escaping @MainActor ([String: Any]) -> Void, onClientsChanged: @escaping @MainActor (Int) -> Void) {
        self.onMessage = onMessage
        self.onClientsChanged = onClientsChanged
    }

    func start() throws {
        let path = MeetBridge.socketURL.path
        let folder = MeetBridge.socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var address = sockaddr_un()
        guard MeetBridge.fill(&address, path: path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            let code = errno; close(fd); throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        listener = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    func stop() {
        if listener >= 0 { close(listener); listener = -1 }
        unlink(MeetBridge.socketURL.path)
        lock.lock(); clients.forEach { close($0) }; clients = []; lock.unlock()
    }

    /// Send a state object to every connected extension, and to any that connects later.
    func broadcast(_ object: [String: Any]) {
        guard var line = try? JSONSerialization.data(withJSONObject: object) else { return }
        line.append(0x0A)
        lock.lock()
        lastState = line
        let targets = clients
        lock.unlock()
        for fd in targets { send(line, to: fd) }
    }

    private func send(_ line: Data, to fd: Int32) {
        let ok = line.withUnsafeBytes { MeetBridge.writeFully(fd, $0.baseAddress!, line.count) }
        if !ok { drop(fd) }
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 { if errno == EINTR { continue } else { return } }
            // Only this user's processes may talk to the app.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            clients.append(fd)
            let count = clients.count, state = lastState
            lock.unlock()
            if !state.isEmpty { send(state, to: fd) }
            Task { @MainActor in self.onClientsChanged(count) }
            Thread.detachNewThread { [weak self] in self?.readLoop(fd) }
        }
    }

    private func readLoop(_ fd: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            pending.append(contentsOf: buffer[0..<n])
            while let newline = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<newline]
                pending.removeSubrange(pending.startIndex...newline)
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    Task { @MainActor in self.onMessage(object) }
                }
            }
            if pending.count > MeetBridge.maxMessageBytes { break }
        }
        drop(fd)
    }

    private func drop(_ fd: Int32) {
        lock.lock()
        let had = clients.contains(fd)
        clients.removeAll { $0 == fd }
        let count = clients.count
        lock.unlock()
        guard had else { return }
        close(fd)
        Task { @MainActor in self.onClientsChanged(count) }
    }
}
