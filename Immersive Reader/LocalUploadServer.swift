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
    typealias APICompletion = (Result<Data, Error>) -> Void

    let port: UInt16
    var onUploadFinished: ((URL, String) -> Void)?
    var onBooksRequested: (((@escaping APICompletion) -> Void))?
    var onRenameRequested: ((UUID, String, @escaping APICompletion) -> Void)?
    var onDeleteRequested: ((UUID, @escaping APICompletion) -> Void)?
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
        uploadConnection.onBooksRequested = onBooksRequested
        uploadConnection.onRenameRequested = onRenameRequested
        uploadConnection.onDeleteRequested = onDeleteRequested
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
    typealias APICompletion = LocalUploadServer.APICompletion

    var onUploadFinished: ((URL, String) -> Void)?
    var onBooksRequested: (((@escaping APICompletion) -> Void))?
    var onRenameRequested: ((UUID, String, @escaping APICompletion) -> Void)?
    var onDeleteRequested: ((UUID, @escaping APICompletion) -> Void)?
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

        if method == "GET", target == "/api/books" {
            requestBooks()
            return
        }

        if method == "POST", let renameRequest = renameRequest(from: target) {
            requestRename(bookId: renameRequest.bookId, filename: renameRequest.filename)
            return
        }

        if method == "DELETE", let bookId = deleteBookId(from: target) {
            requestDelete(bookId: bookId)
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

    private func requestBooks() {
        guard let onBooksRequested else {
            finishWithHTTP(status: 500, body: "Book listing is not available")
            return
        }

        onBooksRequested { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                self.finishWithJSON(data)
            case .failure(let error):
                self.finishWithHTTP(status: 400, body: error.localizedDescription)
            }
        }
    }

    private func requestRename(bookId: UUID, filename: String) {
        guard let onRenameRequested else {
            finishWithHTTP(status: 500, body: "Rename is not available")
            return
        }

        onRenameRequested(bookId, filename) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                self.finishWithJSON(data)
            case .failure(let error):
                self.finishWithHTTP(status: 400, body: error.localizedDescription)
            }
        }
    }

    private func requestDelete(bookId: UUID) {
        guard let onDeleteRequested else {
            finishWithHTTP(status: 500, body: "Delete is not available")
            return
        }

        onDeleteRequested(bookId) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                self.finishWithJSON(data)
            case .failure(let error):
                self.finishWithHTTP(status: 400, body: error.localizedDescription)
            }
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

    private func finishWithJSON(_ data: Data) {
        finish(status: 200, contentType: "application/json; charset=utf-8", body: data)
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

    private func renameRequest(from target: String) -> (bookId: UUID, filename: String)? {
        guard let components = URLComponents(string: "http://localhost\(target)") else {
            return nil
        }

        let pathParts = components.path.split(separator: "/").map(String.init)
        guard pathParts.count == 4,
              pathParts[0] == "api",
              pathParts[1] == "books",
              pathParts[3] == "rename",
              let bookId = UUID(uuidString: pathParts[2]),
              let filename = components.queryItems?.first(where: { $0.name == "filename" })?.value
        else {
            return nil
        }

        return (bookId, AppStorage.sanitizedFilename(filename))
    }

    private func deleteBookId(from target: String) -> UUID? {
        guard let components = URLComponents(string: "http://localhost\(target)") else {
            return nil
        }

        let pathParts = components.path.split(separator: "/").map(String.init)
        guard pathParts.count == 3,
              pathParts[0] == "api",
              pathParts[1] == "books"
        else {
            return nil
        }

        return UUID(uuidString: pathParts[2])
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
          <title>Immersive Reader Files</title>
          <style>
            :root { color-scheme: light; }
            * { box-sizing: border-box; }
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 0; min-height: 100vh; background: #f5f1e8; color: #211a12; }
            main { width: min(980px, calc(100vw - 32px)); margin: 32px auto; }
            header { margin-bottom: 22px; }
            h1 { margin: 0 0 8px; font-size: clamp(32px, 7vw, 56px); letter-spacing: -.04em; }
            h2 { margin: 0 0 14px; font-size: 22px; }
            p { color: #6b6258; line-height: 1.5; }
            section { background: white; border-radius: 24px; padding: 24px; box-shadow: 0 24px 80px rgba(60, 38, 15, .14); margin-bottom: 18px; }
            .drop { border: 2px dashed #b88a44; border-radius: 18px; padding: 26px; text-align: center; background: #fffaf1; }
            input { max-width: 100%; }
            button { border: 0; border-radius: 999px; padding: 10px 14px; background: #1e5bff; color: white; font-weight: 700; cursor: pointer; }
            button.secondary { background: #eadfce; color: #33261a; }
            button.danger { background: #c93528; }
            button:disabled { opacity: .45; cursor: not-allowed; }
            #status { min-height: 24px; margin-top: 14px; font-weight: 700; }
            #status.error { color: #c93528; }
            #status.success { color: #20764c; }
            .toolbar { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 12px; }
            .books { display: grid; gap: 12px; }
            .book { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 16px; align-items: center; padding: 16px; border: 1px solid #eee4d3; border-radius: 18px; background: #fffdf8; }
            .title { font-weight: 800; font-size: 17px; }
            .meta { margin-top: 4px; color: #786f66; font-size: 13px; overflow-wrap: anywhere; }
            .actions { display: flex; gap: 8px; flex-wrap: wrap; justify-content: flex-end; }
            .empty { color: #786f66; padding: 18px; border: 1px dashed #d8c7ad; border-radius: 18px; background: #fffaf1; }
            @media (max-width: 640px) {
              main { width: min(100vw - 20px, 980px); margin: 18px auto; }
              section { padding: 18px; border-radius: 20px; }
              .book { grid-template-columns: 1fr; }
              .actions { justify-content: flex-start; }
            }
          </style>
        </head>
        <body>
          <main>
            <header>
              <h1>Immersive Reader Files</h1>
              <p>Upload, rename, and delete EPUB files stored on this iPhone. Keep Immersive Reader open while managing files.</p>
            </header>

            <section>
              <h2>Upload EPUB</h2>
              <div class="drop">
                <strong>Select an .epub file</strong><br><br>
                <input id="file" type="file" accept=".epub,application/epub+zip">
                <br><br>
                <button id="upload">Upload</button>
                <div id="status"></div>
              </div>
            </section>

            <section>
              <div class="toolbar">
                <h2>Files on iPhone</h2>
                <button class="secondary" id="refresh">Refresh</button>
              </div>
              <div id="books" class="books"></div>
            </section>
          </main>
          <script>
            const input = document.getElementById('file');
            const button = document.getElementById('upload');
            const refresh = document.getElementById('refresh');
            const status = document.getElementById('status');
            const books = document.getElementById('books');

            function setStatus(message, type = '') {
              status.textContent = message;
              status.className = type;
            }

            function escapeHTML(value) {
              return String(value).replace(/[&<>'"]/g, character => ({
                '&': '&amp;',
                '<': '&lt;',
                '>': '&gt;',
                "'": '&#39;',
                '"': '&quot;'
              }[character]));
            }

            function formatBytes(bytes) {
              if (!bytes) return '0 B';
              const units = ['B', 'KB', 'MB', 'GB'];
              let value = bytes;
              let unit = 0;
              while (value >= 1024 && unit < units.length - 1) {
                value /= 1024;
                unit += 1;
              }
              return `${value.toFixed(value >= 10 || unit === 0 ? 0 : 1)} ${units[unit]}`;
            }

            async function requestText(url, options = {}) {
              const response = await fetch(url, options);
              if (!response.ok) {
                throw new Error(await response.text());
              }
              return response;
            }

            async function loadBooks() {
              books.innerHTML = '<div class="empty">Loading files...</div>';
              try {
                const response = await requestText('/api/books');
                const payload = await response.json();
                renderBooks(payload.books || []);
              } catch (error) {
                books.innerHTML = `<div class="empty">Could not load files: ${escapeHTML(error.message)}</div>`;
              }
            }

            function renderBooks(items) {
              if (!items.length) {
                books.innerHTML = '<div class="empty">No EPUB files are imported yet.</div>';
                return;
              }

              books.innerHTML = items.map(book => `
                <article class="book" data-id="${escapeHTML(book.id)}" data-filename="${escapeHTML(book.filename)}">
                  <div>
                    <div class="title">${escapeHTML(book.title)}</div>
                    <div class="meta">${escapeHTML(book.filename)} &middot; ${formatBytes(book.fileSize)}${book.hasMediaOverlay ? ` &middot; Read-aloud ready (${book.mediaOverlayClipCount} clips)` : ''}</div>
                  </div>
                  <div class="actions">
                    <button class="secondary" data-action="rename">Rename</button>
                    <button class="danger" data-action="delete">Delete</button>
                  </div>
                </article>
              `).join('');
            }

            books.onclick = async event => {
              const action = event.target.dataset.action;
              if (!action) return;

              const row = event.target.closest('.book');
              const id = row.dataset.id;
              const currentFilename = row.dataset.filename;

              try {
                if (action === 'rename') {
                  const filename = prompt('Rename EPUB file:', currentFilename);
                  if (!filename) return;
                  const response = await requestText(`/api/books/${encodeURIComponent(id)}/rename?filename=${encodeURIComponent(filename)}`, { method: 'POST' });
                  const payload = await response.json();
                  renderBooks(payload.books || []);
                  setStatus('Renamed file.', 'success');
                }

                if (action === 'delete') {
                  if (!confirm(`Delete ${currentFilename} from this iPhone?`)) return;
                  const response = await requestText(`/api/books/${encodeURIComponent(id)}`, { method: 'DELETE' });
                  const payload = await response.json();
                  renderBooks(payload.books || []);
                  setStatus('Deleted file.', 'success');
                }
              } catch (error) {
                setStatus(error.message, 'error');
              }
            };

            button.onclick = async () => {
              const file = input.files[0];
              if (!file) { setStatus('Choose a file first.', 'error'); return; }
              if (!file.name.toLowerCase().endsWith('.epub')) { setStatus('Only .epub files are supported.', 'error'); return; }
              button.disabled = true;
              setStatus('Uploading...');
              try {
                const response = await fetch('/upload?filename=' + encodeURIComponent(file.name), {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/epub+zip' },
                  body: file
                });
                const text = await response.text();
                if (!response.ok) throw new Error(text);
                setStatus(text, 'success');
                input.value = '';
                await loadBooks();
              } catch (error) {
                setStatus('Upload failed: ' + error.message, 'error');
              } finally {
                button.disabled = false;
              }
            };

            refresh.onclick = loadBooks;
            loadBooks();
          </script>
        </body>
        </html>
        """
    }
}
