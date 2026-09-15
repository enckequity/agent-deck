import CoreServices
import Foundation

/// Calls `onChange` on the main queue with the paths that changed under `paths` (FSEvents, coalesced).
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init(paths: [String], onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let changed = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            watcher.onChange(changed)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        stream = FSEventStreamCreate(nil, callback, &context, paths as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
