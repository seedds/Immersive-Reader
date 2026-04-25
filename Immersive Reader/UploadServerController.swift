//
//  UploadServerController.swift
//  Immersive Reader
//
//  Created by F2PGOD on 25/4/2026.
//

import Foundation
import Darwin
import Combine
import SwiftData

@MainActor
final class UploadServerController: ObservableObject {
    enum Status: Equatable {
        case stopped
        case running
        case failed(String)

        var title: String {
            switch self {
            case .stopped: "Stopped"
            case .running: "Running"
            case .failed: "Failed"
            }
        }
    }

    struct UploadRecord: Identifiable {
        let id = UUID()
        let filename: String
        let date: Date
    }

    @Published private(set) var status: Status = .stopped
    @Published private(set) var recentUploads: [UploadRecord] = []
    @Published var port: UInt16 = 8080

    private var server: LocalUploadServer?

    var serverURL: URL? {
        guard case .running = status, let ipAddress = Self.localIPAddress() else {
            return nil
        }
        return URL(string: "http://\(ipAddress):\(port)")
    }

    func start(modelContext: ModelContext) {
        guard server == nil else { return }

        let server = LocalUploadServer(port: port)
        server.onUploadFinished = { [weak self] fileURL, filename in
            Task { @MainActor in
                do {
                    try BookImportService.importBooks(from: [fileURL], modelContext: modelContext)
                    try? FileManager.default.removeItem(at: fileURL)
                    self?.recentUploads.insert(UploadRecord(filename: filename, date: Date()), at: 0)
                } catch {
                    self?.status = .failed(error.localizedDescription)
                }
            }
        }
        server.onError = { [weak self] message in
            Task { @MainActor in
                self?.status = .failed(message)
            }
        }

        do {
            try server.start()
            self.server = server
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func stop() {
        server?.stop()
        server = nil
        status = .stopped
    }

    private static func localIPAddress() -> String? {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        for interface in sequence(first: firstInterface, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK
            guard isUp, !isLoopback else { continue }

            let addr = interface.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.pointee.ifa_name)
            guard name == "en0" || name.hasPrefix("en") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var socketAddress = addr
            let result = getnameinfo(
                &socketAddress,
                socklen_t(socketAddress.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                address = String(cString: hostname)
                break
            }
        }

        return address
    }
}
