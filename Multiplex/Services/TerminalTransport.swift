import Foundation

/// The byte pipe under one terminal tab — the SSH PTY or a mosh session.
/// Only the interactive surface is shared: exec and SFTP remain SSH-only
/// capabilities (probing, file drops), which mosh tabs simply don't have.
protocol TerminalTransport: Actor {
    func write(_ data: Data) async throws
    func resize(cols: Int, rows: Int) async throws
    func close() async
}

extension SSHConnection: TerminalTransport {}
