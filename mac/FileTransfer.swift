import Foundation

final class FileTransfer {
    private let session: URLSession
    private let code: String
    private let baseURL: URL

    init?(url: URL, code: String, fingerprint: String) {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = "https"
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let root = components.url else { return nil }
        self.baseURL = root
        self.code = code
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        self.session = URLSession(configuration: config, delegate: Pin(fingerprint), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func invalidate() {
        session.invalidateAndCancel()
    }

    func upload(fileURL: URL, destination: String, setClipboard: Bool, batchID: String?,
                completion: @escaping (Result<String, Error>) -> Void) {
        guard let endpoint = URL(string: "/file", relativeTo: baseURL) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        if !code.isEmpty {
            request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        }
        let escapedName = fileURL.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? fileURL.lastPathComponent
        request.setValue(escapedName, forHTTPHeaderField: "X-Conector-Filename")
        request.setValue(destination, forHTTPHeaderField: "X-Conector-Destination")
        request.setValue(setClipboard ? "1" : "0", forHTTPHeaderField: "X-Conector-Clipboard")
        if let batchID {
            request.setValue(batchID, forHTTPHeaderField: "X-Conector-Batch")
        }
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            request.setValue(String(size), forHTTPHeaderField: "Content-Length")
        }
        session.uploadTask(with: request, fromFile: fileURL) { data, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse else {
                DispatchQueue.main.async { completion(.failure(URLError(.badServerResponse))) }
                return
            }
            guard http.statusCode == 200 else {
                let err = NSError(domain: "ConectorFileTransfer", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }
            let savedName: String
            if let data,
               let parsed = try? JSONDecoder().decode([String: AnyDecodableString].self, from: data),
               let name = parsed["name"]?.value, !name.isEmpty {
                savedName = name
            } else {
                savedName = fileURL.lastPathComponent
            }
            DispatchQueue.main.async { completion(.success(savedName)) }
        }.resume()
    }

    func download(file: OfferedFile, into directory: URL, completion: @escaping (Result<URL, Error>) -> Void) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            completion(.failure(URLError(.badURL)))
            return
        }
        components.path = "/file/download"
        components.queryItems = [URLQueryItem(name: "id", value: file.id)]
        guard let endpoint = components.url else {
            completion(.failure(URLError(.badURL)))
            return
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 300
        if !code.isEmpty {
            request.setValue("Bearer \(code)", forHTTPHeaderField: "Authorization")
        }
        session.downloadTask(with: request) { tempURL, response, error in
            if let error {
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            guard let http = response as? HTTPURLResponse, let tempURL else {
                DispatchQueue.main.async { completion(.failure(URLError(.badServerResponse))) }
                return
            }
            guard http.statusCode == 200 else {
                let err = NSError(domain: "ConectorFileTransfer", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
                DispatchQueue.main.async { completion(.failure(err)) }
                return
            }
            do {
                let fm = FileManager.default
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let rawName = URL(fileURLWithPath: file.name).lastPathComponent
                let safeName = (rawName.isEmpty || rawName == "." || rawName == "..") ? "file" : rawName
                let destination = Self.uniqueDestination(in: directory, name: safeName)
                try fm.moveItem(at: tempURL, to: destination)
                DispatchQueue.main.async { completion(.success(destination)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    static func uniqueDestination(in directory: URL, name: String) -> URL {
        let fm = FileManager.default
        let first = directory.appendingPathComponent(name)
        if !fm.fileExists(atPath: first.path) {
            return first
        }
        let base = URL(fileURLWithPath: name)
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        let cleanStem = stem.isEmpty ? "file" : stem
        for n in 2..<10000 {
            let candidateName = ext.isEmpty ? "\(cleanStem) (\(n))" : "\(cleanStem) (\(n)).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return directory.appendingPathComponent(UUID().uuidString + "-" + name)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 {
            return "\(bytes) Б"
        }
        let kb = Double(bytes) / 1024.0
        if kb < 1024.0 {
            return String(format: "%.0f КБ", kb)
        }
        let mb = kb / 1024.0
        if mb < 100.0 {
            return String(format: "%.1f МБ", mb)
        }
        return String(format: "%.0f МБ", mb)
    }
}

private struct AnyDecodableString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(String.self)
    }
}
