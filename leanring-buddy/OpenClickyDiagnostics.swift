import AppKit
import Foundation
import os

@MainActor
enum OpenClickyDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.openclicky.app",
        category: "Diagnostics"
    )
    private static let maximumLogSizeInBytes: UInt64 = 2 * 1_024 * 1_024

    static var logFileURL: URL {
        let libraryURL = FileManager.default.urls(
            for: .libraryDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
        return libraryURL
            .appendingPathComponent("Logs/OpenClicky", isDirectory: true)
            .appendingPathComponent("OpenClicky.log")
    }

    static func record(_ event: String, metadata: [String: CustomStringConvertible] = [:]) {
        let metadataText = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let line = metadataText.isEmpty ? event : "\(event) \(metadataText)"
        logger.info("\(line, privacy: .public)")

        do {
            try prepareLogFileForAppending()
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let data = Data("\(timestamp) \(line)\n".utf8)
            let fileHandle = try FileHandle(forWritingTo: logFileURL)
            try fileHandle.seekToEnd()
            try fileHandle.write(contentsOf: data)
            try fileHandle.close()
        } catch {
            logger.error("Could not write local diagnostic log: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func revealLog() {
        record("diagnostics.reveal")
        NSWorkspace.shared.activateFileViewerSelecting([logFileURL])
    }

    private static func prepareLogFileForAppending() throws {
        let fileManager = FileManager.default
        let logDirectoryURL = logFileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: logDirectoryURL,
            withIntermediateDirectories: true
        )

        if let attributes = try? fileManager.attributesOfItem(atPath: logFileURL.path),
           let fileSize = attributes[.size] as? UInt64,
           fileSize >= maximumLogSizeInBytes {
            let previousLogURL = logDirectoryURL.appendingPathComponent("OpenClicky.previous.log")
            try? fileManager.removeItem(at: previousLogURL)
            try fileManager.moveItem(at: logFileURL, to: previousLogURL)
        }

        if !fileManager.fileExists(atPath: logFileURL.path) {
            _ = fileManager.createFile(atPath: logFileURL.path, contents: nil)
        }
    }
}
