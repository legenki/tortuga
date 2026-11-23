import Darwin
import Foundation
import Security
import Synchronization

/// The code-signing identifiers of a flow's process's parent, grandparent, …
/// up to launchd, so that a listed app's child processes count as the app:
/// Firefox's WebRTC runs in org.mozilla.plugincontainer, and curl started
/// from a listed Terminal reports com.apple.curl.
///
/// `handleNewFlow` is synchronous and hot, so results are cached: a process's
/// chain by (pid, pidversion) from its audit token, each ancestor's identifier
/// by pid, both for 30 s and both capped. Any call that fails just shortens
/// the chain.
enum ProcessLineage {
    static let maxHops = 16
    static let lifetime: TimeInterval = 30
    static let capacity = 512

    private struct ProcessKey: Hashable {
        var pid: pid_t
        var version: Int32
    }

    private struct Cache {
        var chains: [ProcessKey: (ancestors: [String], expires: Date)] = [:]
        var identities: [pid_t: (id: String?, expires: Date)] = [:]
        var loggedFailure = false
    }

    private static let cache = Mutex(Cache())

    /// The ancestors' identifiers, nearest first, for the process in
    /// `auditToken` (a flow's `sourceAppAuditToken`); empty when unknown.
    static func ancestors(auditToken: Data?) -> [String] {
        guard let auditToken, auditToken.count == MemoryLayout<audit_token_t>.size else { return [] }
        let token = auditToken.withUnsafeBytes { $0.loadUnaligned(as: audit_token_t.self) }
        let key = ProcessKey(pid: audit_token_to_pid(token), version: audit_token_to_pidversion(token))
        guard key.pid > 1 else { return [] }
        let now = Date.now
        if let hit = cache.withLock({ $0.chains[key] }), hit.expires > now { return hit.ancestors }

        var chain: [String] = []
        var pid = key.pid
        for _ in 0..<maxHops {
            guard let next = parent(of: pid), next > 1, next != pid else { break }
            pid = next
            if let id = identity(of: pid, now: now) { chain.append(id) }
        }
        cache.withLock { cache in
            if cache.chains.count >= capacity { cache.chains = cache.chains.filter { $0.value.expires > now } }
            if cache.chains.count >= capacity { cache.chains.removeAll() }
            cache.chains[key] = (chain, now.addingTimeInterval(lifetime))
        }
        return chain
    }

    /// The parent's pid, from the kernel's process table.
    private static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else {
            logFailure("sysctl for a parent failed: errno \(errno)")
            return nil
        }
        // size 0: no such process (it exited).
        return size > 0 ? info.kp_eproc.e_ppid : nil
    }

    /// A running process's code-signing identifier, cached by pid.
    private static func identity(of pid: pid_t, now: Date) -> String? {
        if let hit = cache.withLock({ $0.identities[pid] }), hit.expires > now { return hit.id }
        let id = signingIdentifier(of: pid)
        cache.withLock { cache in
            if cache.identities.count >= capacity { cache.identities = cache.identities.filter { $0.value.expires > now } }
            if cache.identities.count >= capacity { cache.identities.removeAll() }
            cache.identities[pid] = (id, now.addingTimeInterval(lifetime))
        }
        return id
    }

    private static func signingIdentifier(of pid: pid_t) -> String? {
        var code: SecCode?
        let status = SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code)
        guard status == errSecSuccess, let code else {
            // The process may simply have exited; anything else is worth one log line.
            if status != errSecCSNoSuchCode { logFailure("code for an ancestor not found: \(status)") }
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoIdentifier as String] as? String
    }

    /// Once per run, at .error: if the sandbox blocks these calls, child
    /// processes don't count as their apps, and this says why.
    private static func logFailure(_ message: String) {
        let first = cache.withLock { cache in
            defer { cache.loggedFailure = true }
            return !cache.loggedFailure
        }
        if first { proxyLog.error("process lineage: \(message, privacy: .public)") }
    }
}
