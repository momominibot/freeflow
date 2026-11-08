import Foundation

struct FFError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs the speech engine as a child process so the model stays loaded on the GPU.
/// Both engines (whisper.cpp and the Qwen3-ASR script) answer the same two requests.
final class WhisperServer {
    let port: Int
    private(set) var engine: SpeechEngine = .whisper
    var onStateChange: (() -> Void)?

    private let lock = NSLock()
    private var ready = false
    private var error: String?
    private var process: Process?
    private var quitting = false
    private var restarts = 0
    private let session: URLSession

    init(port: Int = 8178) {
        self.port = port
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 120
        session = URLSession(configuration: c)
    }

    var isReady: Bool { lock.lock(); defer { lock.unlock() }; return ready }
    var lastError: String? { lock.lock(); defer { lock.unlock() }; return error }

    static var binaryPath: String? {
        ["/opt/homebrew/bin/whisper-server", "/usr/local/bin/whisper-server"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var qwenScript: String? {
        let path = (Bundle.main.resourcePath ?? "") + "/qwen_server.py"
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    static var qwenInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Paths.qwenPython.path) && qwenScript != nil
    }

    /// Stops the running engine (if any) and starts the chosen one.
    func switchTo(_ engine: SpeechEngine) {
        stop()
        self.engine = engine
        restarts = 0
        start()
    }

    func start() {
        let exe: String
        let args: [String]
        switch engine {
        case .whisper:
            guard let bin = Self.binaryPath else {
                return setState(ready: false, error: "Speech engine missing (brew install whisper-cpp)")
            }
            guard FileManager.default.fileExists(atPath: Paths.model.path) else {
                return setState(ready: false, error: "Speech model missing")
            }
            exe = bin
            args = ["-m", Paths.model.path, "--host", "127.0.0.1", "--port", String(port), "-nt", "-l", "en", "-t", "6"]
        case .qwen:
            guard Self.qwenInstalled, let script = Self.qwenScript else {
                return setState(ready: false, error: "Qwen engine not installed (menu: Speech engine)")
            }
            exe = Paths.qwenPython.path
            args = [script, "--port", String(port)]
        }
        killStale()
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let logURL = Paths.logs.appendingPathComponent("whisper-server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async { self?.didExit(proc) }
        }
        do { try p.run() } catch {
            return setState(ready: false, error: "Couldn't start speech engine")
        }
        process = p
        quitting = false
        setState(ready: false, error: nil)
        DispatchQueue.global(qos: .userInitiated).async { self.waitForReady(p) }
    }

    func stop() {
        quitting = true
        let old = process
        process = nil
        old?.terminate()
        old?.waitUntilExit()
        setState(ready: false, error: nil)
    }

    func transcribe(_ url: URL, language: String, prompt: String,
                    completion: @escaping (Result<String, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var waited = 0.0
            while !self.isReady, self.lastError == nil, waited < 60 {
                Thread.sleep(forTimeInterval: 0.2)
                waited += 0.2
            }
            guard self.isReady else {
                return completion(.failure(FFError(message: self.lastError ?? "Speech engine not ready")))
            }
            guard let audio = try? Data(contentsOf: url) else {
                return completion(.failure(FFError(message: "Recording missing")))
            }
            // Mixed English and Chinese: Whisper detects per recording; the Qwen script maps "zh-en" itself.
            let lang = (self.engine == .whisper && language == "zh-en") ? "auto" : language
            let fields = [("response_format", "json"), ("temperature", "0.0"),
                          ("language", lang), ("prompt", prompt)]
            self.session.dataTask(with: self.request(audio: audio, fields: fields)) { data, _, err in
                if let err = err { return completion(.failure(err)) }
                guard let data = data,
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return completion(.failure(FFError(message: "Unreadable reply from speech engine")))
                }
                if let text = obj["text"] as? String {
                    completion(.success(text))
                } else {
                    completion(.failure(FFError(message: obj["error"] as? String ?? "No text returned")))
                }
            }.resume()
        }
    }

    // MARK: - Internals

    private func setState(ready: Bool, error: String?) {
        lock.lock(); self.ready = ready; self.error = error; lock.unlock()
        DispatchQueue.main.async { self.onStateChange?() }
    }

    private func killStale() {
        let k = Process()
        k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        k.arguments = ["-f", "(whisper-server|qwen_server.py).*--port \(port)"]
        try? k.run()
        k.waitUntilExit()
        // A dying engine can still hold the port for a moment; starting on top of it fails silently.
        for _ in 0..<30 where portInUse() { Thread.sleep(forTimeInterval: 0.1) }
    }

    private func portInUse() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return r == 0
    }

    private func waitForReady(_ p: Process) {
        for _ in 0..<(engine == .qwen ? 720 : 240) {
            guard p.isRunning else { return }
            if ping() {
                warmUp()
                restarts = 0
                return setState(ready: true, error: nil)
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        setState(ready: false, error: "Speech engine didn't start (see ~/Library/Logs/FreeFlow)")
    }

    private func didExit(_ proc: Process) {
        // An engine we stopped on purpose (a switch) is not a crash.
        guard proc === process else { return }
        setState(ready: false, error: lastError)
        guard !quitting else { return }
        restarts += 1
        if restarts <= 3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.start() }
        } else {
            setState(ready: false, error: "Speech engine stopped (see ~/Library/Logs/FreeFlow)")
        }
    }

    private func ping() -> Bool {
        var ok = false
        let done = DispatchSemaphore(value: 0)
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/")!)
        req.timeoutInterval = 1
        session.dataTask(with: req) { _, resp, _ in
            ok = (resp as? HTTPURLResponse)?.statusCode == 200
            done.signal()
        }.resume()
        done.wait()
        return ok
    }

    /// The first inference after loading is slow; spend it on half a second of silence.
    private func warmUp() {
        let done = DispatchSemaphore(value: 0)
        let req = request(audio: Self.silentWav(seconds: 0.5),
                          fields: [("response_format", "json"), ("language", "en"), ("prompt", "")])
        session.dataTask(with: req) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 30)
    }

    private func request(audio: Data, fields: [(String, String)]) -> URLRequest {
        let boundary = "freeflow-\(UUID().uuidString)"
        var body = Data()
        func add(_ s: String) { body.append(s.data(using: .utf8)!) }
        for (k, v) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        add("Content-Type: audio/wav\r\n\r\n")
        body.append(audio)
        add("\r\n--\(boundary)--\r\n")
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        r.httpMethod = "POST"
        r.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        r.httpBody = body
        r.timeoutInterval = 120
        return r
    }

    private static func silentWav(seconds: Double) -> Data {
        let rate: UInt32 = 16000
        let dataBytes = UInt32(Double(rate) * seconds) * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append("RIFF".data(using: .ascii)!); u32(36 + dataBytes)
        d.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(1)
        u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append("data".data(using: .ascii)!); u32(dataBytes)
        d.append(Data(count: Int(dataBytes)))
        return d
    }
}
