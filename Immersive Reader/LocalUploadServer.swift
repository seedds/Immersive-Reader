//
//  LocalUploadServer.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation
import Network

enum LocalUploadServerError: LocalizedError {
    case invalidPort
    case failedToStart(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            "The upload server port is invalid."
        case .failedToStart(let reason):
            "The upload server failed to start: \(reason)"
        }
    }
}

final class LocalUploadServer {
    let port: UInt16
    var onUploadFinished: ((URL, String) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "ImmersiveReader.LocalUploadServer")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPUploadConnection] = [:]

    init(port: UInt16 = 8080) {
        self.port = port
    }

    func start() throws {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw LocalUploadServerError.invalidPort
        }

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                if case .failed(let error) = state {
                    self?.onError?(error.localizedDescription)
                    self?.stop()
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            throw LocalUploadServerError.failedToStart(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        let uploadConnection = HTTPUploadConnection(connection: connection)
        let id = ObjectIdentifier(uploadConnection)
        connections[id] = uploadConnection

        uploadConnection.onUploadFinished = { [weak self] url, filename in
            self?.onUploadFinished?(url, filename)
        }
        uploadConnection.onError = { [weak self] message in
            self?.onError?(message)
        }
        uploadConnection.onComplete = { [weak self] in
            self?.connections.removeValue(forKey: id)
        }

        uploadConnection.start(queue: queue)
    }
}

private final class HTTPUploadConnection {
    var onUploadFinished: ((URL, String) -> Void)?
    var onError: ((String) -> Void)?
    var onComplete: (() -> Void)?

    private let connection: NWConnection
    private var headerData = Data()
    private var uploadFileHandle: FileHandle?
    private var uploadTempURL: URL?
    private var uploadFilename: String?
    private var expectedBodyLength: Int64 = 0
    private var receivedBodyLength: Int64 = 0

    init(connection: NWConnection) {
        self.connection = connection
    }

    func start(queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                self?.finishWithError(error.localizedDescription)
            } else if case .cancelled = state {
                self?.cleanup()
            }
        }
        connection.start(queue: queue)
        receiveHeader()
    }

    func cancel() {
        connection.cancel()
        cleanup()
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                finishWithError(error.localizedDescription)
                return
            }

            if let data, !data.isEmpty {
                headerData.append(data)
                if let range = headerData.range(of: Data("\r\n\r\n".utf8)) {
                    let header = headerData[..<range.lowerBound]
                    let bodyStart = range.upperBound
                    let initialBody = headerData[bodyStart...]
                    handleRequest(headerData: Data(header), initialBody: Data(initialBody))
                    return
                }
            }

            if isComplete {
                finishWithHTTP(status: 400, body: "Bad Request")
            } else {
                receiveHeader()
            }
        }
    }

    private func handleRequest(headerData: Data, initialBody: Data) {
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            finishWithHTTP(status: 400, body: "Bad Request")
            return
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            finishWithHTTP(status: 400, body: "Bad Request")
            return
        }

        let requestParts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard requestParts.count >= 2 else {
            finishWithHTTP(status: 400, body: "Bad Request")
            return
        }

        let method = requestParts[0].uppercased()
        let target = requestParts[1]
        let headers = parseHeaders(lines.dropFirst())

        if method == "GET", target == "/" {
            finishWithHTML(uploadPageHTML)
            return
        }

        guard method == "POST" else {
            finishWithHTTP(status: 405, body: "Method Not Allowed")
            return
        }

        guard target.hasPrefix("/upload") else {
            finishWithHTTP(status: 404, body: "Not Found")
            return
        }

        guard headers["transfer-encoding"]?.lowercased() != "chunked" else {
            finishWithHTTP(status: 411, body: "Chunked uploads are not supported")
            return
        }

        guard let lengthText = headers["content-length"], let contentLength = Int64(lengthText), contentLength >= 0 else {
            finishWithHTTP(status: 411, body: "Content-Length is required")
            return
        }

        guard let filename = filename(from: target), filename.lowercased().hasSuffix(".epub") else {
            finishWithHTTP(status: 415, body: "Only .epub uploads are supported")
            return
        }

        do {
            try beginUpload(filename: filename, contentLength: contentLength)
            try writeBody(initialBody)
        } catch {
            finishWithError(error.localizedDescription)
            return
        }

        if receivedBodyLength >= expectedBodyLength {
            finishUpload()
        } else {
            receiveBody()
        }
    }

    private func receiveBody() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                finishWithError(error.localizedDescription)
                return
            }

            do {
                if let data, !data.isEmpty {
                    try writeBody(data)
                }
            } catch {
                finishWithError(error.localizedDescription)
                return
            }

            if receivedBodyLength >= expectedBodyLength {
                finishUpload()
            } else if isComplete {
                finishWithHTTP(status: 400, body: "Upload ended before all bytes were received")
            } else {
                receiveBody()
            }
        }
    }

    private func beginUpload(filename: String, contentLength: Int64) throws {
        let uploadsDirectory = try AppStorage.uploadsDirectory()
        let tempURL = AppStorage.uniqueFileURL(named: ".upload-\(UUID().uuidString)-\(filename)", in: uploadsDirectory)
        FileManager.default.createFile(atPath: tempURL.path, contents: nil)

        uploadFileHandle = try FileHandle(forWritingTo: tempURL)
        uploadTempURL = tempURL
        uploadFilename = filename
        expectedBodyLength = contentLength
        receivedBodyLength = 0
    }

    private func writeBody(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let remaining = expectedBodyLength - receivedBodyLength
        guard remaining > 0 else { return }

        let dataToWrite: Data
        if Int64(data.count) > remaining {
            dataToWrite = data.prefix(Int(remaining))
        } else {
            dataToWrite = data
        }

        try uploadFileHandle?.write(contentsOf: dataToWrite)
        receivedBodyLength += Int64(dataToWrite.count)
    }

    private func finishUpload() {
        do {
            try uploadFileHandle?.close()
            uploadFileHandle = nil

            guard let uploadTempURL, let uploadFilename else {
                finishWithHTTP(status: 500, body: "Upload state was lost")
                return
            }

            let uploadsDirectory = try AppStorage.uploadsDirectory()
            let finalURL = AppStorage.uniqueFileURL(named: uploadFilename, in: uploadsDirectory)
            try FileManager.default.moveItem(at: uploadTempURL, to: finalURL)
            onUploadFinished?(finalURL, uploadFilename)
            finishWithHTTP(status: 200, body: "Uploaded \(uploadFilename)")
        } catch {
            finishWithError(error.localizedDescription)
        }
    }

    private func finishWithHTML(_ html: String) {
        finish(status: 200, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    private func finishWithHTTP(status: Int, body: String) {
        finish(status: status, contentType: "text/plain; charset=utf-8", body: Data(body.utf8))
    }

    private func finish(status: Int, contentType: String, body: Data) {
        let reason = reasonPhrase(for: status)
        let header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.cleanup()
        })
    }

    private func finishWithError(_ message: String) {
        onError?(message)
        try? uploadFileHandle?.close()
        uploadFileHandle = nil
        if let uploadTempURL {
            try? FileManager.default.removeItem(at: uploadTempURL)
        }
        finishWithHTTP(status: 500, body: message)
    }

    private func cleanup() {
        try? uploadFileHandle?.close()
        uploadFileHandle = nil
        onComplete?()
    }

    private func parseHeaders(_ lines: ArraySlice<String>) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return headers
    }

    private func filename(from target: String) -> String? {
        guard let components = URLComponents(string: "http://localhost\(target)"), components.path == "/upload" else {
            return nil
        }
        return components.queryItems?
            .first(where: { $0.name == "filename" })?
            .value
            .map(AppStorage.sanitizedFilename)
    }

    private func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 411: "Length Required"
        case 415: "Unsupported Media Type"
        case 500: "Internal Server Error"
        default: "HTTP Response"
        }
    }

    private var uploadPageHTML: String {
        """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Immersive Reader Upload</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; min-height: 100vh; display: grid; place-items: center; background: #f5f1e8; color: #211a12; }
            main { width: min(640px, calc(100vw - 32px)); background: white; border-radius: 24px; padding: 32px; box-shadow: 0 24px 80px rgba(60, 38, 15, .16); }
            h1 { margin: 0 0 8px; font-size: 32px; }
            p { color: #6b6258; line-height: 1.5; }
            .drop { border: 2px dashed #b88a44; border-radius: 18px; padding: 36px; text-align: center; background: #fffaf1; }
            input { margin-top: 18px; }
            button { margin-top: 18px; border: 0; border-radius: 999px; padding: 12px 18px; background: #1e5bff; color: white; font-weight: 700; cursor: pointer; }
            button:disabled { opacity: .45; cursor: not-allowed; }
            #status { margin-top: 18px; font-weight: 600; }
          </style>
        </head>
        <body>
          <main>
            <h1>Upload EPUB</h1>
            <p>Choose an EPUB file from this computer. Keep Immersive Reader open while the upload finishes.</p>
            <div class="drop">
              <strong>Select an .epub file</strong><br>
              <input id="file" type="file" accept=".epub,application/epub+zip">
              <br>
              <button id="upload">Upload</button>
              <div id="status"></div>
            </div>
          </main>
          <script>
            const input = document.getElementById('file');
            const button = document.getElementById('upload');
            const status = document.getElementById('status');
            button.onclick = async () => {
              const file = input.files[0];
              if (!file) { status.textContent = 'Choose a file first.'; return; }
              if (!file.name.toLowerCase().endsWith('.epub')) { status.textContent = 'Only .epub files are supported.'; return; }
              button.disabled = true;
              status.textContent = 'Uploading...';
              try {
                const response = await fetch('/upload?filename=' + encodeURIComponent(file.name), {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/epub+zip' },
                  body: file
                });
                const text = await response.text();
                status.textContent = response.ok ? text : 'Upload failed: ' + text;
              } catch (error) {
                status.textContent = 'Upload failed: ' + error;
              } finally {
                button.disabled = false;
              }
            };
          </script>
        </body>
        </html>
        """
    }
}
