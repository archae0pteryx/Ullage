import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Own on one background actor/queue. No bodies are persisted or exported;
/// source files remain user-managed and a missing file invalidates its cache.
public final class SessionPlaybackReader {
  struct FileState {
    var inode: UInt64 = 0
    var mtime: Double = 0
    var size: UInt64 = 0
    var offset: UInt64 = 0
    var pending = Data()
    var lineOffset: UInt64 = 0
    var events: [PlaybackEvent] = []
    var eventIDs: Set<String> = []
    var records: [[String: Any]] = []
    var malformed = 0
    var oversized = 0
    var droppingLine = false
    var sessionId: String?
    var generation = UUID().uuidString
    var omitted = false
  }

  var files: [String: FileState] = [:]
  private var activeSession: String?
  private struct SnapshotCache {
    var path: String
    var inode: UInt64
    var mtime: Double
    var size: UInt64
    var snapshot: PlaybackRequestSnapshot
  }
  private var selectedSnapshot: SnapshotCache?
  let maxContentBytes = 16 * 1_024 * 1_024
  let maxRefreshBytes = 64 * 1_024 * 1_024
  var remainingRefreshBytes = 0

  public init() {}

  public func read(sessionId: String, sources: [PlaybackSource], recordingDirectory: URL? = nil)
    -> SessionPlayback {
    remainingRefreshBytes = maxRefreshBytes
    if activeSession != sessionId {
      files.removeAll()
      selectedSnapshot = nil
      activeSession = sessionId
    }
    var paths = Set(sources.map(\.path))
    if let recordingDirectory {
      paths.insert(recordingDirectory.appendingPathComponent("index.jsonl").path)
    }
    files = files.filter { paths.contains($0.key) }
    var result = SessionPlayback()
    for source in sources {
      guard source.vendor == Vendor.claudeCode || source.vendor == Vendor.codex else {
        result.notices.append("Playback contents are unavailable for \(source.vendor).")
        continue
      }
      guard
        let state = load(
          path: source.path, source: source, sessionId: sessionId, notices: &result.notices)
      else { continue }
      result.events += state.events
      if !state.pending.isEmpty || state.droppingLine { result.pendingLineCount += 1 }
    }
    if sources.isEmpty {
      result.notices.append("No transcript source was recorded for this session.")
    }
    if let directory = recordingDirectory {
      addRequests(directory: directory, sessionId: sessionId, result: &result)
    }
    result.events.sort {
      if $0.timestamp != $1.timestamp { return ($0.timestamp ?? "") < ($1.timestamp ?? "") }
      return $0.id.localizedStandardCompare($1.id) == .orderedAscending
    }
    retainRecentContent(result: &result)
    result.notices = Array(Set(result.notices)).sorted()
    return result
  }

  private func retainRecentContent(result: inout SessionPlayback) {
    // shortcut: keep 10k steps / 64 MiB in memory; use disk-backed paging for larger histories.
    var retainedBytes = 0
    var retainedCount = 0
    for event in result.events.reversed() {
      let bytes = event.text.utf8.count
      if retainedCount == 10_000 || retainedBytes + bytes > maxRefreshBytes { break }
      retainedBytes += bytes
      retainedCount += 1
    }
    if retainedCount < result.events.count {
      result.events = Array(result.events.suffix(retainedCount))
      let retained = Set(result.events.map(\.id))
      for path in Array(files.keys) {
        guard var state = files[path] else { continue }
        state.events.removeAll { !retained.contains($0.id) }
        state.eventIDs = Set(state.events.map(\.id))
        state.omitted = true
        files[path] = state
      }
    }
    if files.values.contains(where: \.omitted) {
      result.notices.append(
        "Earlier playback content omitted: inspection retains up to 10,000 steps / 64 MiB in memory. "
          + "Original source files are unchanged."
      )
    }
  }

  /// Loads only the selected request. A reference never promises its file still exists.
  public func requestSnapshot(for event: PlaybackEvent, recordingDirectory: URL)
    -> PlaybackRequestSnapshot? {
    guard var snapshot = event.snapshot else { return nil }
    snapshot.body = nil
    snapshot.completeness = .partial
    guard let url = confinedFile(snapshot.sourcePath, directory: recordingDirectory) else {
      selectedSnapshot = nil
      snapshot.notice = "Request file is outside the selected recording directory."
      return snapshot
    }
    do {
      let handle = try regularHandle(url)
      defer { try? handle.close() }
      let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
      let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
      let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
      let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
      if let cached = selectedSnapshot, cached.path == url.path, cached.inode == inode,
        cached.mtime == mtime, cached.size == size {
        return cached.snapshot
      }
      selectedSnapshot = nil
      let data = try handle.read(upToCount: maxContentBytes + 1) ?? Data()
      guard data.count <= maxContentBytes else {
        snapshot.notice = "Request exceeds the 16 MiB inspection limit."
        return snapshot
      }
      guard let body = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        body["messages"] is [Any], body["model"] is String
      else {
        snapshot.notice = "Request file is incomplete or has an unsupported format."
        return snapshot
      }
      snapshot.body = String(data: data, encoding: .utf8)
      snapshot.completeness = .redacted
      selectedSnapshot = SnapshotCache(
        path: url.path, inode: inode, mtime: mtime, size: size, snapshot: snapshot)
      return snapshot
    } catch {
      selectedSnapshot = nil
      snapshot.notice =
        "Request file is missing or unreadable. Recordings remain in their original location."
      return snapshot
    }
  }

  private func addRequests(directory: URL, sessionId: String, result: inout SessionPlayback) {
    let index = directory.appendingPathComponent("index.jsonl").path
    guard confinedFile(index, directory: directory) != nil else {
      result.notices.append("Recording index is outside the selected directory.")
      return
    }
    guard let state = load(path: index, source: nil, sessionId: sessionId, notices: &result.notices)
    else { return }
    if !state.pending.isEmpty { result.pendingLineCount += 1 }
    let anchors = Dictionary(
      grouping: result.events.filter { $0.messageId != nil }, by: { $0.messageId! })
    var joined = Set<String>()
    for row in state.records where row["session_id"] as? String == sessionId {
      guard let message = row["message_id"] as? String, let anchor = anchors[message]?.first,
        let path = row["request_file"] as? String
      else { continue }
      guard let file = confinedFile(path, directory: directory) else {
        result.notices.append("Rejected a request file outside the selected recording directory.")
        continue
      }
      let key = "\(message):\(file.path)"
      guard joined.insert(key).inserted else { continue }
      result.events.append(
        PlaybackEvent(
          id: "\(anchor.id):request:\(file.path)", timestamp: anchor.timestamp,
          agentId: anchor.agentId, kind: .request, title: "Recorded request", messageId: message,
          source: .capturedRequest, completeness: .redacted,
          snapshot: PlaybackRequestSnapshot(sourcePath: file.path),
          usage: anchors[message]?.compactMap(\.usage).first,
          sourcePath: file.path))
    }
  }

  private func confinedFile(_ path: String, directory: URL) -> URL? {
    let base = directory.standardizedFileURL.resolvingSymlinksInPath()
    let file =
      (path.hasPrefix("/") ? URL(fileURLWithPath: path) : directory.appendingPathComponent(path))
      .standardizedFileURL.resolvingSymlinksInPath()
    return file.path.hasPrefix(base.path + "/") ? file : nil
  }

  func regularHandle(_ url: URL) throws -> FileHandle {
    let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
    guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
      close(descriptor)
      throw CocoaError(.fileReadUnsupportedScheme)
    }
    return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  }
}
