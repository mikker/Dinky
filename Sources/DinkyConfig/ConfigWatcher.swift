import Foundation

/// Reloads the config selected by a pathname, including changes to any symlink or ancestor along that path.
/// File events cover in-place writes; directory events cover changes to the entries used to reach the file.
/// Rebinding and loading share one debounced transition. Unavailable observations are retried until restored.
/// Results arrive on the main queue; the caller keeps the previous config on error.
public final class ConfigWatcher {
    private let url: URL
    private let onChange: (Result<Config, ConfigError>) -> Void
    private let openObservation: (String) -> Int32
    private let queue = DispatchQueue(label: "dinky.config-watcher")
    private var sources: [DispatchSourceFileSystemObject] = []
    private var snapshot: ConfigPath?
    private var generation = 0
    /// The debounced reload, or the next retry while a path or observation is unavailable.
    private var pending: DispatchWorkItem?

    public convenience init(url: URL, onChange: @escaping (Result<Config, ConfigError>) -> Void) {
        self.init(url: url, openObservation: { open($0, O_EVTONLY) }, onChange: onChange)
    }

    init(url: URL, openObservation: @escaping (String) -> Int32, onChange: @escaping (Result<Config, ConfigError>) -> Void) {
        self.url = url
        self.onChange = onChange
        self.openObservation = openObservation
        queue.sync { _ = watch() }
    }

    deinit {
        for source in sources { source.cancel() }
        pending?.cancel()
    }

    public func stop() {
        queue.sync {
            generation += 1
            for source in sources { source.cancel() }
            sources.removeAll()
            pending?.cancel()
            pending = nil
        }
    }

    @discardableResult
    private func watch() -> Bool {
        let next = generation + 1
        let resolved = ConfigPath(url)
        var replacements: [DispatchSourceFileSystemObject] = []
        var directories: Set<FileIdentity> = []
        var complete = true

        for (directory, identity) in resolved.directories.sorted(by: { $0.key < $1.key }) {
            guard !directories.contains(identity) else { continue }
            if let source = observe(directory, identity: identity, generation: next, file: false) {
                replacements.append(source)
                directories.insert(identity)
            } else {
                complete = false
            }
        }
        if let identity = resolved.file,
           let source = observe(url.path, identity: identity, generation: next, file: true) {
            replacements.append(source)
        } else {
            complete = false
        }

        // Install the new generation before retiring the old one. Queued old events cannot affect it.
        let retired = sources
        sources = replacements
        snapshot = resolved
        generation = next
        for source in retired { source.cancel() }

        if !complete { schedule(after: 0.5) { $0.retry() } }
        // A component can change between resolution and opening its descriptor.
        namespaceChanged()
        return complete
    }

    private func observe(_ name: String, identity: FileIdentity, generation: Int, file: Bool) -> DispatchSourceFileSystemObject? {
        let fd = openObservation(name)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, FileIdentity(info) == identity else {
            close(fd)
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke], queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self, self.generation == generation else { return }
            if file { fileChanged(identity) }
            else { namespaceChanged() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func namespaceChanged() {
        let now = ConfigPath(url)
        guard now != snapshot else { return }
        // Record identity immediately: unrelated directory events must not extend the debounce.
        snapshot = now
        changed()
    }

    private func fileChanged(_ identity: FileIdentity) {
        // An old target may still be open during the debounce after a link changes. Its writes don't count.
        guard FileIdentity.read(url.path) == identity else { return namespaceChanged() }
        changed()
    }

    private func retry() {
        // Identity alone cannot tell us what was written while observation was unavailable.
        if watch() { changed() }
    }

    private func changed() {
        schedule(after: 0.1) { $0.reload() }
    }

    private func schedule(after seconds: Double, _ body: @escaping (ConfigWatcher) -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in if let self { body(self) } }
        pending = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func reload() {
        watch()
        let result = Result { () throws(ConfigError) in try Config.load(from: url) }
        DispatchQueue.main.async { [onChange] in onChange(result) }
    }
}

/// Namespace dependencies, not directory timestamps: a neighbor changing is not a config change.
/// Keep intermediate symlinks too; resolving the whole URL at once would discard their parent entries.
private struct ConfigPath: Equatable {
    let entries: [String: FileIdentity]
    let directories: [String: FileIdentity]
    let file: FileIdentity?

    init(_ url: URL) {
        var entries: [String: FileIdentity] = [:]
        var directories: [String: FileIdentity] = [:]
        if let root = FileIdentity.read("/") {
            entries["/"] = root
            directories["/"] = root
        }
        var remaining = url.path.split(separator: "/").reversed().map(String.init)
        var directory = "/"
        var links = 0
        while let component = remaining.popLast() {
            if component == "." { continue }
            if component == ".." {
                directory = (directory as NSString).deletingLastPathComponent
                if directory.isEmpty { directory = "/" }
                continue
            }
            let name = (directory == "/" ? "" : directory) + "/" + component
            var info = stat()
            guard lstat(name, &info) == 0 else { break }
            let identity = FileIdentity(info)
            entries[name] = identity
            if info.st_mode & S_IFMT == S_IFLNK {
                // Bound expansion even for a broken loop. Its discovered parent entries remain watched.
                links += 1
                guard links <= MAXSYMLINKS,
                      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: name) else { break }
                if target.hasPrefix("/") { directory = "/" }
                remaining.append(contentsOf: target.split(separator: "/").reversed().map(String.init))
            } else if info.st_mode & S_IFMT == S_IFDIR {
                directory = name
                directories[name] = identity
            } else {
                break
            }
        }
        self.entries = entries
        self.directories = directories
        file = FileIdentity.read(url.path)
    }
}

private struct FileIdentity: Hashable {
    let device: dev_t
    let inode: ino_t

    init(_ info: stat) {
        device = info.st_dev
        inode = info.st_ino
    }

    static func read(_ name: String) -> FileIdentity? {
        var info = stat()
        guard stat(name, &info) == 0 else { return nil }
        return FileIdentity(info)
    }
}
