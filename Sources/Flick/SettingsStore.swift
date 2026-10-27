import AppKit
import Combine
import FlickCore
import Foundation
import os

/// Holds Flick's settings, kept in FlickSettings.fileURL. Changes made here are
/// written back shortly after the last one, so dragging a slider writes the
/// file once, editing only the changed keys' lines; changes made to the file —
/// by hand, or by a `git pull` of synced dotfiles — are picked up as they
/// happen. A file that doesn't parse leaves the current settings alone and is
/// never overwritten: changes made here then stay unsaved, with a beep.
@MainActor
final class SettingsStore: ObservableObject {
    @Published private(set) var settings: FlickSettings

    let url: URL
    private var pendingSave: DispatchWorkItem?
    private var directoryWatch: DispatchSourceFileSystemObject?
    private var fileWatch: DispatchSourceFileSystemObject?
    private let logger = Logger(subsystem: "info.junz.flick", category: "settings")

    init(url: URL = FlickSettings.fileURL()) {
        self.url = url
        settings = FlickSettings()
        reload()
        watch()
    }

    func update(_ change: (inout FlickSettings) -> Void) {
        var next = settings
        change(&next)
        next = next.clamped()
        guard next != settings else { return }
        settings = next
        pendingSave?.cancel()
        let save = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.save() }
        }
        pendingSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: save)
    }

    private func save() {
        pendingSave = nil
        let existing = try? String(contentsOf: url, encoding: .utf8)
        let text: String
        do {
            text = try settings.toml(updating: existing)
        } catch {
            logger.error("not saving over \(self.url.path, privacy: .public), which has an error at \(error.description, privacy: .public)")
            NSSound.beep()
            return
        }
        guard text != existing else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            logger.error("saving \(self.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reload() {
        // Mid-edit, the file still holds the settings before the edit.
        guard pendingSave == nil else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            settings = FlickSettings()
            return
        }
        do {
            let loaded = try FlickSettings.decode(toml: text)
            if loaded != settings { settings = loaded }
        } catch {
            logger.error("reading \(self.url.path, privacy: .public): \(error.description, privacy: .public)")
        }
    }

    /// Watches the directory, which sees the file replaced (atomic saves,
    /// `git checkout`) or created, and the file itself, which sees it written
    /// in place.
    private func watch() {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directoryWatch = source(for: directory.path, events: .write)
        watchFile()
    }

    private func watchFile() {
        fileWatch?.cancel()
        fileWatch = source(for: url.path, events: [.write, .delete, .rename, .extend])
    }

    private func source(for path: String,
                        events: DispatchSource.FileSystemEvent) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: events,
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.reload()
                // A replaced file is a new one to watch.
                self?.watchFile()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }
}
