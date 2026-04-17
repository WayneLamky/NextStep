import CoreServices
import Foundation

/// Thin wrapper around `FSEventStream` so we can observe external edits
/// to the projects folder (e.g. VS Code, `mv`, iCloud Drive).
///
/// Callbacks fire on the main queue (we set the dispatch queue explicitly
/// via `FSEventStreamSetDispatchQueue`). All state is touched only from
/// main — marked `nonisolated(unsafe)` so we can reach it from the C
/// callback without Swift 6 flagging a false-positive data race.
final class FSWatcher: @unchecked Sendable {
    typealias Handler = @MainActor (Set<String>) -> Void

    private nonisolated(unsafe) var stream: FSEventStreamRef?
    private let handler: Handler
    private let debounce: TimeInterval
    private nonisolated(unsafe) var pending: Set<String> = []
    private nonisolated(unsafe) var flushWorkItem: DispatchWorkItem?

    init(debounce: TimeInterval = 0.35, handler: @escaping Handler) {
        self.debounce = debounce
        self.handler = handler
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Start observing the given directory. If already running, the old
    /// stream is stopped first so you can hot-swap the watched folder.
    @MainActor
    func start(watching url: URL) {
        stopInternal()

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let paths = [url.path] as CFArray
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            FSWatcher.callback,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            // Latency: 0.1s. Our own debounce does the real smoothing.
            0.1,
            flags
        ) else {
            NSLog("FSWatcher: FSEventStreamCreate returned nil")
            return
        }

        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    @MainActor
    func stop() { stopInternal() }

    @MainActor
    private func stopInternal() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        flushWorkItem?.cancel()
        flushWorkItem = nil
        pending.removeAll()
    }

    // C callback — fires on the main queue (we set that above). We shuttle
    // the raw pointer through `Int(bitPattern:)` so Swift 6 sees a Sendable
    // value crossing the isolation boundary into the Task { @MainActor }.
    private static let callback: FSEventStreamCallback = {
        _, clientCallBackInfo, numEvents, eventPaths, _, _ in
        guard let info = clientCallBackInfo else { return }
        guard let paths = unsafeBitCast(eventPaths, to: CFArray.self) as? [String] else {
            return
        }
        let batch = Array(paths.prefix(Int(numEvents)))
        let rawInfo = Int(bitPattern: info)

        Task { @MainActor in
            guard let ptr = UnsafeMutableRawPointer(bitPattern: rawInfo) else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(ptr).takeUnretainedValue()
            watcher.enqueue(batch)
        }
    }

    @MainActor
    private func enqueue(_ paths: [String]) {
        for p in paths { pending.insert(p) }

        flushWorkItem?.cancel()
        let h = handler
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let batch = self.pending
                self.pending.removeAll()
                h(batch)
            }
        }
        flushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
