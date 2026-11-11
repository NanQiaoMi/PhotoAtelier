import Foundation
import Darwin

/// A lightweight, embedded offline HTTP server designed for local and LAN client proofing.
/// It serves static files from a local delivery folder (HTML, JPEG, PDF, JSON, CSS)
/// with zero external dependencies and zero cloud connections.
public final class DeliveryServer {
    public private(set) var isRunning: Bool = false
    public private(set) var port: UInt16 = 0
    public private(set) var rootDirectory: URL?
    public private(set) var localURL: URL?
    public private(set) var lanURL: URL?

    private var serverSocket: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let serverQueue = DispatchQueue(label: "PhotoAtelier.DeliveryServer", qos: .utility)

    public init() {}

    deinit {
        stop()
    }

    /// Resolves the primary local IPv4 address on the Wi-Fi/Ethernet interface (e.g. en0).
    public static func localIPAddress() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var address: String?
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name.starts(with: "en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, socklen_t(0), NI_NUMERICHOST)
                    let ip = String(cString: hostname)
                    if !ip.starts(with: "127.") && !ip.isEmpty {
                        address = ip
                        if name == "en0" { break }
                    }
                }
            }
        }
        return address
    }

    /// Starts serving the specified directory. Tries ports starting from `preferredPort` up to `preferredPort + 10`.
    public func start(directory: URL, preferredPort: UInt16 = 8080) throws {
        stop()

        guard directory.isFileURL else {
            throw AtelierError.invalidConfiguration("交付服务器根目录必须是本地文件夹。")
        }
        let standardizedRoot = directory.standardizedFileURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: standardizedRoot.path, isDirectory: &isDir), isDir.boolValue else {
            throw AtelierError.invalidConfiguration("交付服务器根目录不存在或不是目录。")
        }

        var boundPort: UInt16?
        var fd: Int32 = -1

        for candidatePort in preferredPort...(preferredPort + 10) {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }

            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(candidatePort).bigEndian
            addr.sin_addr.s_addr = in_addr_t(0) // INADDR_ANY: listen on all interfaces

            let bindRes = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }

            if bindRes == 0 && listen(fd, 16) == 0 {
                boundPort = candidatePort
                break
            } else {
                close(fd)
                fd = -1
            }
        }

        guard let activePort = boundPort, fd >= 0 else {
            throw AtelierError.imageWrite("无法在端口 \(preferredPort)...\(preferredPort + 10) 上启动本地预览服务。")
        }

        self.serverSocket = fd
        self.port = activePort
        self.rootDirectory = standardizedRoot
        self.localURL = URL(string: "http://127.0.0.1:\(activePort)/")
        if let lanIP = Self.localIPAddress() {
            self.lanURL = URL(string: "http://\(lanIP):\(activePort)/")
        } else {
            self.lanURL = nil
        }
        self.isRunning = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: serverQueue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler {
            close(fd)
        }
        self.readSource = source
        source.resume()
    }

    public func stop() {
        if isRunning {
            readSource?.cancel()
            readSource = nil
            serverSocket = -1
            isRunning = false
            port = 0
            rootDirectory = nil
            localURL = nil
            lanURL = nil
        }
    }

    private func acceptConnection() {
        guard isRunning, serverSocket >= 0, let root = rootDirectory else { return }

        var clientAddr = sockaddr_in()
        var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                accept(serverSocket, $0, &clientLen)
            }
        }
        guard clientFd >= 0 else { return }

        serverQueue.async {
            defer { close(clientFd) }

            var buffer = [CChar](repeating: 0, count: 4096)
            let readBytes = recv(clientFd, &buffer, buffer.count - 1, 0)
            guard readBytes > 0 else { return }

            let requestString = String(cString: buffer)
            guard let firstLine = requestString.components(separatedBy: "\r\n").first else { return }
            let parts = firstLine.split(separator: " ")
            guard parts.count >= 2, parts[0] == "GET" else {
                Self.sendResponse(clientFd: clientFd, status: 405, statusText: "Method Not Allowed", body: Data("仅支持 GET 请求。".utf8), contentType: "text/plain; charset=utf-8")
                return
            }

            let rawPath = String(parts[1])
            let cleanPath = rawPath.components(separatedBy: "?").first ?? rawPath
            let decodedPath = cleanPath.removingPercentEncoding ?? cleanPath
            let relPath = (decodedPath == "/" || decodedPath.isEmpty) ? "index.html" : decodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

            // Path traversal defense
            let targetURL = root.appendingPathComponent(relPath).standardizedFileURL
            guard targetURL.path.hasPrefix(root.path) else {
                Self.sendResponse(clientFd: clientFd, status: 403, statusText: "Forbidden", body: Data("禁止访问目录外的资源。".utf8), contentType: "text/plain; charset=utf-8")
                return
            }

            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir), !isDir.boolValue else {
                Self.sendResponse(clientFd: clientFd, status: 404, statusText: "Not Found", body: Data("文件未找到。".utf8), contentType: "text/plain; charset=utf-8")
                return
            }

            guard let fileData = try? Data(contentsOf: targetURL) else {
                Self.sendResponse(clientFd: clientFd, status: 500, statusText: "Internal Server Error", body: Data("无法读取文件。".utf8), contentType: "text/plain; charset=utf-8")
                return
            }

            let mimeType = Self.mimeType(for: targetURL.pathExtension)
            Self.sendResponse(clientFd: clientFd, status: 200, statusText: "OK", body: fileData, contentType: mimeType)
        }
    }

    private static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "pdf": return "application/pdf"
        case "json": return "application/json; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "application/javascript"
        default: return "application/octet-stream"
        }
    }

    private static func sendResponse(clientFd: Int32, status: Int, statusText: String, body: Data, contentType: String) {
        let headers = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Connection: close\r
        Server: PhotoAtelier/1.0\r
        Access-Control-Allow-Origin: *\r
        \r\n
        """
        _ = headers.withCString { send(clientFd, $0, strlen($0), 0) }
        body.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress {
                send(clientFd, base, body.count, 0)
            }
        }
    }
}
