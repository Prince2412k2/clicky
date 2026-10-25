import AppKit
import Combine
import Foundation
import Security

enum OpenClickyUpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(build: Int, downloadURL: URL)
    case downloading
    case installing
    case failed(String)
}

@MainActor
final class OpenClickyUpdater: ObservableObject {
    static let shared = OpenClickyUpdater()

    @Published private(set) var state: OpenClickyUpdateState = .idle

    private static let releasesURL = URL(
        string: "https://api.github.com/repos/Prince2412k2/clicky/releases?per_page=10"
    )!
    private static let expectedBundleIdentifier = "org.openclicky.app"
    private static let expectedSigningTeamIdentifier = "935NAK66J6"

    var isRunningFromApplications: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/")
    }

    var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    func checkForUpdates() {
        guard state != .checking && state != .downloading && state != .installing else { return }
        state = .checking
        Task {
            do {
                var request = URLRequest(url: Self.releasesURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("OpenClicky/\(currentBuild)", forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw Self.updaterError("GitHub could not be reached.")
                }
                let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
                guard let latestRelease = releases.first(where: { release in
                    release.prerelease
                        && release.tagName.hasPrefix("openclicky-alpha-")
                        && release.assets.contains(where: { $0.name == "OpenClicky-Alpha.zip" })
                }), let latestBuild = Int(latestRelease.tagName.replacingOccurrences(
                    of: "openclicky-alpha-",
                    with: ""
                )), let asset = latestRelease.assets.first(where: { $0.name == "OpenClicky-Alpha.zip" }) else {
                    state = .upToDate
                    return
                }

                state = latestBuild > currentBuild
                    ? .available(build: latestBuild, downloadURL: asset.browserDownloadURL)
                    : .upToDate
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func installAvailableUpdate() {
        guard case .available(_, let downloadURL) = state else { return }
        state = .downloading
        Task {
            do {
                var request = URLRequest(url: downloadURL)
                request.setValue("OpenClicky/\(currentBuild)", forHTTPHeaderField: "User-Agent")
                let (temporaryURL, response) = try await URLSession.shared.download(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    throw Self.updaterError("The update could not be downloaded.")
                }

                let updateDirectory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("OpenClickyUpdate-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: updateDirectory,
                    withIntermediateDirectories: true
                )
                let archiveURL = updateDirectory.appendingPathComponent("OpenClicky-Alpha.zip")
                try FileManager.default.moveItem(at: temporaryURL, to: archiveURL)
                try await runProcess(
                    executableURL: URL(fileURLWithPath: "/usr/bin/ditto"),
                    arguments: ["-x", "-k", archiveURL.path, updateDirectory.path]
                )
                let applicationURL = updateDirectory.appendingPathComponent("OpenClicky.app")
                try validateApplication(at: applicationURL)
                try await runProcess(
                    executableURL: URL(fileURLWithPath: "/usr/bin/codesign"),
                    arguments: ["--verify", "--deep", "--strict", applicationURL.path]
                )
                try await installApplication(from: applicationURL)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func installCurrentApplication() {
        state = .installing
        Task {
            do {
                try await installApplication(from: Bundle.main.bundleURL)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func installApplication(from sourceApplicationURL: URL) async throws {
        state = .installing
        let destinationURL = URL(fileURLWithPath: "/Applications/OpenClicky.app", isDirectory: true)
        let command = """
        /bin/rm -rf \(shellQuote(destinationURL.path)) && \
        /usr/bin/ditto \(shellQuote(sourceApplicationURL.path)) \(shellQuote(destinationURL.path)) && \
        /usr/bin/xattr -dr com.apple.quarantine \(shellQuote(destinationURL.path))
        """

        if FileManager.default.isWritableFile(atPath: "/Applications") {
            try await runProcess(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: ["-c", command]
            )
        } else {
            let appleScript = "do shell script \(appleScriptQuote(command)) with administrator privileges"
            try await runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", appleScript]
            )
        }

        NSWorkspace.shared.openApplication(
            at: destinationURL,
            configuration: NSWorkspace.OpenConfiguration(),
            completionHandler: nil
        )
        NSApp.terminate(nil)
    }

    private func validateApplication(at applicationURL: URL) throws {
        guard let bundle = Bundle(url: applicationURL),
              bundle.bundleIdentifier == Self.expectedBundleIdentifier else {
            throw Self.updaterError("The downloaded application has an unexpected identity.")
        }
        guard try signingTeamIdentifier(for: applicationURL) == Self.expectedSigningTeamIdentifier else {
            throw Self.updaterError("The downloaded application was not signed by the OpenClicky team.")
        }
        let downloadedBuild = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        guard downloadedBuild > currentBuild else {
            throw Self.updaterError("The downloaded build is not newer than the installed build.")
        }
    }

    private func signingTeamIdentifier(for applicationURL: URL) throws -> String? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            applicationURL as CFURL,
            SecCSFlags(rawValue: 0),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw Self.updaterError("The downloaded application signature could not be read.")
        }

        var signingInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInformation
        )
        guard informationStatus == errSecSuccess,
              let signingInformation = signingInformation as? [CFString: Any] else {
            throw Self.updaterError("The downloaded application signing identity could not be verified.")
        }
        return signingInformation[kSecCodeInfoTeamIdentifier] as? String
    }

    private func runProcess(executableURL: URL, arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            let errorPipe = Pipe()
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let details = String(data: errorData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw Self.updaterError(details?.isEmpty == false ? details ?? "Installation failed." : "Installation failed.")
            }
        }.value
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleScriptQuote(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    nonisolated private static func updaterError(_ message: String) -> NSError {
        NSError(
            domain: "OpenClickyUpdater",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let prerelease: Bool
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case prerelease
        case assets
    }
}

private struct GitHubReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
