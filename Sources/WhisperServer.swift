import Foundation

struct FFError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Runs whisper.cpp's server as a child process so the model stays loaded on the GPU.
final class WhisperServer {
    let port: Int
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

    func start() {
        guard let bin = Self.binaryPath else {
            return setState(ready: false, error: "Speech engine missing (brew install whisper-cpp)")
        }
        guard FileManager.default.fileExists(atPath: Paths.model.path) else {
            return setState(ready: false, error: "Speech model missing")
        }
        killStale()
        try? FileManager.default.createDirectory(at: Paths.logs, withIntermediateDirectories: true)
        let logURL = Paths.logs.appendingPathComponent("whisper-server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["-m", Paths.model.path, "--host", "127.0.0.1", "--port", String(port),
                       "-nt", "-l", "en", "-t", "6"]
        p.standardOutput = log
        p.standardError = log
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.didExit() }
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
        process?.terminate()
        process = nil
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
            let fields = [("response_format", "json"), ("temperature", "0.0"),
                          ("language", language), ("prompt", prompt)]
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
        k.arguments = ["-f", "whisper-server.*--port \(port)"]
        try? k.run()
        k.waitUntilExit()
    }

    private func waitForReady(_ p: Process) {
        for _ in 0..<240 {
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

    private func didExit() {
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
