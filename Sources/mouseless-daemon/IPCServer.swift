import Foundation
import Security

final class IPCClientConnection {

    let socket: Int32
    private var readSource: DispatchSourceRead?
    private var buffer = Data()
    var onCommand: ((DaemonCommand) -> Void)?
    var onDisconnect: (() -> Void)?

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let writeQueue = DispatchQueue(label: "com.mouseless.ipc-write")
    private let maxBufferSize = 65536

    init(socket: Int32) {
        self.socket = socket
    }

    private func sendAll(_ data: Data, to fd: Int32) -> Bool {
        var sent = 0
        while sent < data.count {
            let result = data.withUnsafeBytes { ptr in
                Darwin.send(fd, ptr.baseAddress!.advanced(by: sent), data.count - sent, 0)
            }
            if result <= 0 { return false }
            sent += result
        }
        return true
    }

    func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: socket, queue: DispatchQueue.global(qos: .userInteractive))

        source.setEventHandler { [weak self] in
            self?.handleReadEvent()
        }

        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(self.socket)
        }

        readSource = source
        source.resume()
    }

    private func handleReadEvent() {
        var buf = [UInt8](repeating: 0, count: 4096)
        let bytesRead = recv(socket, &buf, buf.count, 0)

        if bytesRead <= 0 {
            disconnect()
            onDisconnect?()
            return
        }

        buffer.append(contentsOf: buf[0..<bytesRead])

        if buffer.count > maxBufferSize {
            NSLog("IPCServer: client exceeded max buffer size, disconnecting")
            disconnect()
            onDisconnect?()
            return
        }

        processBuffer()
    }

    private func processBuffer() {
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer[buffer.startIndex..<newlineIndex]
            buffer = Data(buffer[(newlineIndex + 1)...])

            guard !lineData.isEmpty else { continue }

            do {
                let command = try decoder.decode(DaemonCommand.self, from: Data(lineData))
                onCommand?(command)
            } catch {
                NSLog("IPCServer: failed to decode command: %@", error.localizedDescription)
            }
        }
    }

    func sendKeyEvent(_ event: KeyEventMessage) {
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                var data = try self.encoder.encode(event)
                data.append(UInt8(ascii: "\n"))
                if !self.sendAll(data, to: self.socket) {
                    NSLog("IPCServer: send failed with errno %d", errno)
                }
            } catch {
                NSLog("IPCServer: failed to encode key event: %@", error.localizedDescription)
            }
        }
    }

    func disconnect() {
        readSource?.cancel()
        readSource = nil
    }
}

final class IPCServer {

    private var listenSocket: Int32 = -1
    private var listenSource: DispatchSourceRead?
    private(set) var activeClient: IPCClientConnection?
    var onCommand: ((DaemonCommand) -> Void)?
    var onClientDisconnected: (() -> Void)?
    private var socketPath: String = ""

    func start(path: String) throws {
        socketPath = path
        unlink(path)

        listenSocket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenSocket >= 0 else {
            throw IPCError.socketCreationFailed
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            sunPathPtr.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { dest in
                for i in 0..<min(pathBytes.count, sunPathSize - 1) {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(listenSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw IPCError.bindFailed(errno)
        }

        let listenResult = Darwin.listen(listenSocket, 1)
        guard listenResult == 0 else {
            throw IPCError.listenFailed(errno)
        }

        chmod(path, 0o666)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenSocket, queue: DispatchQueue.global(qos: .userInteractive))
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            guard let self = self else { return }
            close(self.listenSocket)
            self.listenSocket = -1
        }
        listenSource = source
        source.resume()

        NSLog("IPCServer: listening on %@", path)
    }

    /// Code requirement a non-root client must satisfy: the Glide app signed by
    /// our team. Anyone can ad-hoc sign a binary with this identifier, but not
    /// with an Apple-issued certificate for this team. Forks building their own
    /// app must change both values.
    static let clientRequirement =
        #"anchor apple generic and identifier "com.tienthuan.glide" and certificate leaf[subject.OU] = "3CK2XS2T3D""#

    /// `LOCAL_PEERTOKEN` from <sys/un.h>: the peer's audit token, captured by the
    /// kernel at connect time, so it can't be swapped like a PID lookup.
    private static let localPeerToken: Int32 = 0x006

    private func verifyPeerCredentials(socket: Int32) -> Bool {
        var token = audit_token_t()
        var tokenLen = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(socket, SOL_LOCAL, Self.localPeerToken, &token, &tokenLen) == 0 else {
            NSLog("IPCServer: failed to get peer audit token")
            return false
        }
        // audit_token_t.val: [0] auid, [1] euid, [2] egid, [3] ruid, [4] rgid, [5] pid ...
        let peerUID = token.val.1
        let peerPID = Int32(bitPattern: token.val.5)
        // Root can already read the keyboard directly; allow it (test-seize.sh).
        if peerUID == 0 { return true }

        // The daemon runs as root, but its client — Glide.app — runs as the
        // logged-in console user. Reject other users outright.
        let consoleUID = Self.consoleUserUID()
        guard consoleUID != 0, peerUID == consoleUID else {
            NSLog("IPCServer: rejected pid %d: UID %d is not the console user (%d)", peerPID, peerUID, consoleUID)
            return false
        }

        // Any process of that user could otherwise connect and read keys typed
        // into password fields, so require the signed app itself.
        guard Self.peerSatisfiesRequirement(token) else {
            NSLog("IPCServer: rejected pid %d: not the signed Glide app", peerPID)
            return false
        }
        return true
    }

    private static func peerSatisfiesRequirement(_ token: audit_token_t) -> Bool {
        var token = token
        let tokenData = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        let attributes = [kSecGuestAttributeAudit: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(clientRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            NSLog("IPCServer: invalid client requirement")
            return false
        }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The UID of the user currently logged in at the console (the GUI session),
    /// which is who runs Glide.app. Returns 0 if it can't be determined.
    private static func consoleUserUID() -> uid_t {
        var uid: uid_t = 0
        var gid: gid_t = 0
        // SCDynamicStoreCopyConsoleUser via the store; fall back to the owner
        // of /dev/console which is the console user on macOS.
        var st = stat()
        if stat("/dev/console", &st) == 0 {
            uid = st.st_uid
        }
        _ = gid
        return uid
    }

    private func acceptConnection() {
        let clientSocket = accept(listenSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        guard verifyPeerCredentials(socket: clientSocket) else {
            close(clientSocket)
            return
        }

        activeClient?.disconnect()

        let client = IPCClientConnection(socket: clientSocket)

        client.onCommand = { [weak self] command in
            self?.onCommand?(command)
        }

        client.onDisconnect = { [weak self] in
            NSLog("IPCServer: client disconnected")
            self?.activeClient = nil
            self?.onClientDisconnected?()
        }

        activeClient = client
        client.startReading()

        NSLog("IPCServer: client connected")
    }

    func stop() {
        listenSource?.cancel()
        listenSource = nil
        activeClient?.disconnect()
        activeClient = nil
        if !socketPath.isEmpty {
            unlink(socketPath)
        }
        NSLog("IPCServer: stopped")
    }
}
