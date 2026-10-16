import Foundation

extension Store {
  public func playbackSources(sessionId: String) throws -> [PlaybackSource] {
    try database.query(
      """
      SELECT DISTINCT source_file, vendor, agent_id FROM call
      WHERE session_id = ?1 ORDER BY source_file, agent_id;
      """,
      [.text(sessionId)]
    ) { PlaybackSource(path: $0.text(0), vendor: $0.text(1), agentId: $0.optionalText(2)) }
  }
}
