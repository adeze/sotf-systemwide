import Foundation

/// Resolve the HAL capture flag from one daemon snapshot.
public enum ConfigBarHALCaptureStatus {
    public static func resolve(driver: [String: Any], transport: [String: Any]) -> Bool? {
        (driver["capture_active"] as? Bool)
            ?? (transport["hal_capture_active"] as? Bool)
    }
}

/// UI-independent policy for the native menu-bar pill. Recording takes
/// precedence if callers ever observe overlapping playback/capture flags.
public enum ConfigBarMenuBarPillAppearance: Equatable {
    case transparent
    case playing
    case recording

    public static func resolve(
        isPlaying: Bool,
        isRecording: Bool,
        hasIssue: Bool
    ) -> Self {
        guard !hasIssue else { return .transparent }
        if isRecording { return .recording }
        if isPlaying { return .playing }
        return .transparent
    }
}

/// Shared decision logic for startup adoption. A reachable socket belongs to
/// the daemon already listening on it; the Configbar must not replace that
/// process unless it is the process it launched itself.
public enum ConfigBarDaemonAdoption {
    public static func shouldAdopt(
        reachable: Bool,
        managedProcessRunning: Bool
    ) -> Bool {
        reachable && !managedProcessRunning
    }
}

/// Shared decision logic for the IPC health watchdog. Probes are taken every
/// few seconds; a single failure can be a transient hiccup while the daemon
/// restarts under launchd, so a restart is only requested after repeated
/// consecutive failures.
public enum ConfigBarDaemonWatchdog {
    public static let restartThreshold = 2

    public static func shouldRestart(consecutiveFailures: Int) -> Bool {
        consecutiveFailures >= restartThreshold
    }

    /// Consecutive latched-recovery probes before escalating to a daemon
    /// restart. Reachability alone is not health: after a failed cold start
    /// the daemon stays reachable but latched in `pipeline_recovery`, and
    /// only a daemon restart (or a successful apply, which needs the user to
    /// change something) clears it. Two probes (~10 s) ride out the bounded
    /// cold-start retry window without restarting a daemon that is still
    /// legitimately starting.
    public static let recoveryEscalationThreshold = 2

    public static func shouldEscalateRecovery(consecutiveLatchedProbes: Int) -> Bool {
        consecutiveLatchedProbes >= recoveryEscalationThreshold
    }
}

/// Extract the pipeline-recovery error from a `get_snapshot` diagnostics
/// dictionary. Returns nil when the daemon reports no latched recovery.
public enum ConfigBarPipelineRecovery {
    public static func error(fromDiagnostics diagnostics: [String: Any]) -> String? {
        guard let recovery = diagnostics["pipeline_recovery"] as? [String: Any] else {
            return nil
        }
        return recovery["error"] as? String
    }
}

/// Dispatch a potentially blocking daemon operation away from SwiftUI's main
/// thread and deliver its result back on the main queue.
public enum ConfigBarAsyncOperation {
    public static func perform<Result>(
        on queue: DispatchQueue,
        work: @escaping () -> Result,
        completion: @escaping (Result) -> Void
    ) {
        queue.async {
            let result = work()
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }
}

/// Result of an optimistic Configbar mutation.  A stale completion is
/// represented by `nil` from `ConfigBarMutationState.resolve`, so an older
/// daemon response cannot roll back a newer user selection.
public enum ConfigBarMutationResult<Value: Equatable>: Equatable {
    case confirmed(Value)
    case rolledBack(Value)
}

/// Small, UI-independent state machine shared by the Configbar mutation
/// tests.  The production view keeps its SwiftUI `@State` values separate,
/// but must obey these same invariants: one generation per request, only the
/// current generation may commit, and a rejection restores the last value
/// confirmed by the daemon.
public struct ConfigBarMutationState<Value: Equatable> {
    public private(set) var confirmed: Value
    private var generation: UInt64 = 0

    public init(confirmed: Value) {
        self.confirmed = confirmed
    }

    @discardableResult
    public mutating func begin(_ requested: Value) -> UInt64 {
        generation &+= 1
        return generation
    }

    public mutating func resolve(
        generation: UInt64,
        requested: Value,
        succeeded: Bool
    ) -> ConfigBarMutationResult<Value>? {
        guard generation == self.generation else { return nil }
        if succeeded {
            confirmed = requested
            return .confirmed(requested)
        }
        return .rolledBack(confirmed)
    }
}

/// Watermark for asynchronous status snapshots. A snapshot is allowed to
/// reconcile mutable UI state only when it was requested after the latest
/// user mutation began. This keeps a slow status/device/config response from
/// overwriting a newer optimistic value.
public struct ConfigBarStatusWatermark: Equatable {
    public private(set) var generation: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func beginMutation() -> UInt64 {
        generation &+= 1
        return generation
    }

    public func accepts(snapshotGeneration: UInt64) -> Bool {
        snapshotGeneration == generation
    }
}

let configBarVirtualDevicePatterns = [
    "SotF",
    "BlackHole",
    "Loopback",
    "Virtual",
    "Soundflower",
    "Background Music",
    "Audio Bridge",
    "ZoomAudio",
]

public func isConfigBarVirtualDevice(_ name: String) -> Bool {
    configBarVirtualDevicePatterns.contains { pattern in
        name.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

public func sanitizeConfigBarPeaks(_ peaks: [Double], maxChannels: Int = 32) -> [Double] {
    let limit = min(max(maxChannels, 1), 32)
    return peaks.prefix(limit).map { peak in
        guard peak.isFinite, peak > 0 else { return 0.0 }
        return min(peak, 2.0)
    }
}

public func decayConfigBarPeaks(_ peaks: [Double], factor: Double = 0.85) -> [Double] {
    peaks.map { peak in
        let next = max(peak, 0.0) * factor
        return next < 0.00001 ? 0.0 : next
    }
}

public func updateConfigBarPeakHolds(previous: [Double], current: [Double]) -> [Double] {
    current.enumerated().map { index, peak in
        let oldValue = index < previous.count ? previous[index] : 0.0
        if peak >= oldValue {
            return peak
        }
        let decayed = oldValue * 0.96
        return max(peak, decayed < 0.00001 ? 0.0 : decayed)
    }
}

/// Prevent a failed Toggle mutation from triggering a second daemon request
/// when SwiftUI observes the programmatic rollback.
public struct EncryptionToggleGuard {
    private var ignoreNextChange = false

    public init() {}

    public mutating func markProgrammaticChange() {
        ignoreNextChange = true
    }

    public mutating func consumeProgrammaticChange() -> Bool {
        guard ignoreNextChange else { return false }
        ignoreNextChange = false
        return true
    }
}

/// Coalesces authoritative rack refreshes without dropping a request that
/// arrives while an earlier daemon read is still in flight.
public struct ConfigBarRefreshGate {
    public private(set) var isRefreshing = false
    public private(set) var hasPendingRefresh = false

    public init() {}

    /// Returns true when the caller should start a daemon read immediately.
    @discardableResult
    public mutating func request() -> Bool {
        guard !isRefreshing else {
            hasPendingRefresh = true
            return false
        }
        isRefreshing = true
        return true
    }

    /// Completes one daemon read. Returns true when one coalesced follow-up
    /// read must start immediately; the gate remains busy in that case.
    @discardableResult
    public mutating func complete() -> Bool {
        guard isRefreshing else { return false }
        if hasPendingRefresh {
            hasPendingRefresh = false
            return true
        }
        isRefreshing = false
        return false
    }
}

public func isConfigBarGenerationConflict(_ daemonError: String?) -> Bool {
    daemonError?.localizedCaseInsensitiveContains("generation conflict") == true
}

public func configBarMutationErrorMessage(
    daemonError: String?,
    fallback: String
) -> String {
    guard let daemonError else { return fallback }
    if isConfigBarGenerationConflict(daemonError) {
        return "The pipeline changed while this view was open. Refreshed to the current version; please retry."
    }
    return daemonError
}

/// Whether a failed `apply_configuration` reply warrants one resend against
/// a refreshed pipeline generation. Only a generation conflict with retries
/// remaining retries: the requested values are still valid against fresh
/// state (cold start, driver reconfigure, another client committed first).
/// Every other failure (validation, device, transport) must surface
/// immediately so the UI can roll back optimistic state.
public func configBarShouldRetryApplyConfiguration(
    success: Bool,
    daemonError: String?,
    mayRetry: Bool
) -> Bool {
    mayRetry && !success && isConfigBarGenerationConflict(daemonError)
}

/// Pure window-dismissal policy used by the AppKit window subclass. Keeping
/// the decision outside AppKit makes the accessory-app lifecycle behavior
/// testable without creating a live NSWindow in a test process.
public enum ConfigBarWindowPolicy {
    public static func shouldDismissCommandW(
        hasCommandModifier: Bool,
        charactersIgnoringModifiers: String?
    ) -> Bool {
        hasCommandModifier && charactersIgnoringModifiers == "w"
    }
}

/// Pure output-profile policy shared by the Outputs master list and the
/// daemon store contract. Device keys mirror the daemon exactly: a stable
/// UID key when one is known, otherwise a name key. Resolution prefers the
/// UID assignment, then the name assignment, then the default profile.
public enum ConfigBarOutputProfiles {
    public static let defaultProfileID = "default"

    public static func deviceKey(uid: String?, name: String) -> String {
        let trimmedUID = uid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedUID.isEmpty {
            return "uid:\(trimmedUID)"
        }
        return "name:\(name.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    public static func resolveProfileID(
        assignments: [String: String],
        uid: String?,
        name: String,
        knownProfileIDs: Set<String>
    ) -> String? {
        let trimmedUID = uid?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedUID.isEmpty,
           let assigned = assignments["uid:\(trimmedUID)"],
           knownProfileIDs.contains(assigned) {
            return assigned
        }
        let nameKey = "name:\(name.trimmingCharacters(in: .whitespacesAndNewlines))"
        if let assigned = assignments[nameKey],
           knownProfileIDs.contains(assigned) {
            return assigned
        }
        return knownProfileIDs.contains(defaultProfileID) ? defaultProfileID : nil
    }
}

/// Pure delay-editor policy. A delay node either applies one time to every
/// channel (scalar `delay_ms`) or an independent time per channel
/// (`channel_delays_ms`, used for speaker time alignment). Per-channel mode
/// is a pure routing delay in the DSP: it rejects any effect controls
/// alongside it, so the editor must emit the constrained parameter set the
/// engine accepts (feedback zero, mix one, no LFO/allpass/pitch-preserving).
/// Keeping the mapping here makes the parameter contract unit-testable
/// without hosting a SwiftUI view.
public enum ConfigBarDelayParameters {
    public static let channelDelaysKey = "channel_delays_ms"
    public static let scalarDelayKey = "delay_ms"
    public static let maxDelayMs = 5000.0
    public static let maxChannels = 64

    public static func doubleValue(_ raw: Any?) -> Double? {
        if let double = raw as? Double {
            return double
        }
        if let float = raw as? Float {
            return Double(float)
        }
        if let int = raw as? Int {
            return Double(int)
        }
        if let number = raw as? NSNumber {
            return number.doubleValue
        }
        if let string = raw as? String {
            return Double(string)
        }
        return nil
    }

    public static func clampedDelayMs(_ raw: Any?, fallback: Double = 0) -> Double {
        guard let value = doubleValue(raw), value.isFinite else { return fallback }
        return min(max(value, 0), maxDelayMs)
    }

    public static func isPerChannel(_ parameters: [String: Any]) -> Bool {
        guard let array = parameters[channelDelaysKey] as? [Any] else { return false }
        return !array.isEmpty
    }

    public static func scalarDelayMs(_ parameters: [String: Any]) -> Double {
        clampedDelayMs(parameters[scalarDelayKey])
    }

    /// Per-channel delays sized to `channelCount`. Existing entries are kept
    /// (clamped); missing entries fall back to the scalar delay so switching
    /// modes never invents silence or a surprise echo.
    public static func channelDelays(
        _ parameters: [String: Any],
        channelCount: Int
    ) -> [Double] {
        let count = min(max(channelCount, 1), maxChannels)
        let fallback = scalarDelayMs(parameters)
        let stored = (parameters[channelDelaysKey] as? [Any] ?? []).map {
            clampedDelayMs($0, fallback: fallback)
        }
        if stored.count >= count {
            return Array(stored.prefix(count))
        }
        return stored + Array(repeating: fallback, count: count - stored.count)
    }

    /// Uniform update: one time for every channel. Drops any per-channel
    /// array so the DSP leaves scalar mode.
    public static func applyingUniformDelay(
        _ parameters: [String: Any],
        delayMs: Double
    ) -> [String: Any] {
        var next = parameters
        next[scalarDelayKey] = clampedDelayMs(delayMs)
        next.removeValue(forKey: channelDelaysKey)
        return next
    }

    /// Per-channel update: independent times, sized by the caller to the
    /// node channel count, with the pure-delay constraints the DSP requires.
    /// An empty array is a no-op so the node can never be left in a state
    /// the engine rejects for a missing length.
    public static func applyingPerChannelDelays(
        _ parameters: [String: Any],
        delaysMs: [Double]
    ) -> [String: Any] {
        guard !delaysMs.isEmpty else { return parameters }
        var next = parameters
        let clamped = delaysMs.map { clampedDelayMs($0) }
        next[channelDelaysKey] = clamped
        next[scalarDelayKey] = clamped[0]
        next["feedback"] = 0.0
        next["mix"] = 1.0
        next["lfo_rate_hz"] = 0.0
        next["lfo_depth_ms"] = 0.0
        next["allpass_feedback"] = false
        next["pitch_preserving"] = false
        return next
    }
}

/// Pure EQ-editor policy. An EQ node either applies one filter list to every
/// channel (`filters`) or an independent filter list per channel
/// (`channel_filters`, one entry per node channel). The DSP accepts
/// `channel_filters` only when its length matches the node channel count, so
/// the editor sizes the array to the channel count and falls back to the
/// uniform list when switching modes. Per-channel mode keeps `filters` as a
/// channel-0 mirror (like the delay editor keeps `delay_ms`) so older
/// readers still see a usable list; uniform mode drops `channel_filters` so
/// the DSP leaves per-channel mode. Keeping the mapping here makes the
/// parameter contract unit-testable without hosting a SwiftUI view.
public enum ConfigBarEQParameters {
    public static let filtersKey = "filters"
    public static let channelFiltersKey = "channel_filters"
    public static let maxChannels = 32
    public static let maxFilters = 20

    /// Filter dicts tolerate JSON bridging (`[[String: Any]]` or `[Any]` of
    /// `[String: Any]`); anything else yields an empty list.
    public static func filterList(_ raw: Any?) -> [[String: Any]] {
        if let typed = raw as? [[String: Any]] {
            return typed
        }
        guard let array = raw as? [Any] else { return [] }
        return array.compactMap { $0 as? [String: Any] }
    }

    public static func isPerChannel(_ parameters: [String: Any]) -> Bool {
        guard let array = parameters[channelFiltersKey] as? [Any] else { return false }
        return !array.isEmpty
    }

    public static func uniformFilters(_ parameters: [String: Any]) -> [[String: Any]] {
        filterList(parameters[filtersKey])
    }

    /// Per-channel filter lists sized to `channelCount`. Existing channels
    /// are kept; missing channels fall back to the uniform list (or the last
    /// stored channel, or empty) so switching modes never invents bands.
    public static func channelFilters(
        _ parameters: [String: Any],
        channelCount: Int
    ) -> [[[String: Any]]] {
        let count = min(max(channelCount, 1), maxChannels)
        let uniform = uniformFilters(parameters)
        let stored: [[[String: Any]]]
        if let typed = parameters[channelFiltersKey] as? [[[String: Any]]] {
            stored = typed
        } else if let outer = parameters[channelFiltersKey] as? [Any] {
            stored = outer.map { filterList($0) }
        } else {
            stored = []
        }
        if stored.count >= count {
            return Array(stored.prefix(count))
        }
        let filler: [[String: Any]] = uniform.isEmpty ? (stored.last ?? []) : uniform
        return stored + Array(repeating: filler, count: count - stored.count)
    }

    /// Uniform update: one filter list for every channel. Drops any
    /// per-channel array so the DSP leaves per-channel mode.
    public static func applyingUniformFilters(
        _ parameters: [String: Any],
        filters: [[String: Any]]
    ) -> [String: Any] {
        var next = parameters
        next[filtersKey] = filters
        next.removeValue(forKey: channelFiltersKey)
        return next
    }

    /// Per-channel update: independent filter lists, sized by the caller to
    /// the node channel count, with `filters` kept as a channel-0 mirror.
    /// An empty array is a no-op so the node can never be left in a state
    /// the engine rejects for a missing length.
    public static func applyingPerChannelFilters(
        _ parameters: [String: Any],
        channelFilters: [[[String: Any]]]
    ) -> [String: Any] {
        guard !channelFilters.isEmpty else { return parameters }
        var next = parameters
        let clamped = Array(channelFilters.prefix(maxChannels))
        next[channelFiltersKey] = clamped
        next[filtersKey] = clamped[0]
        return next
    }
}

/// Mute/solo/dim state for one matrix output channel. Wire form is
/// `{"muted": Bool, "soloed": Bool, "dimmed": Bool}`.
public struct MatrixChannelState: Equatable {
    public var muted: Bool
    public var soloed: Bool
    public var dimmed: Bool

    public init(muted: Bool = false, soloed: Bool = false, dimmed: Bool = false) {
        self.muted = muted
        self.soloed = soloed
        self.dimmed = dimmed
    }

    public static func parse(_ raw: Any?) -> MatrixChannelState {
        guard let dict = raw as? [String: Any] else { return MatrixChannelState() }
        return MatrixChannelState(
            muted: boolValue(dict["muted"]),
            soloed: boolValue(dict["soloed"]),
            dimmed: boolValue(dict["dimmed"])
        )
    }

    public var wire: [String: Any] {
        ["muted": muted, "soloed": soloed, "dimmed": dimmed]
    }

    private static func boolValue(_ raw: Any?) -> Bool {
        if let bool = raw as? Bool { return bool }
        if let number = raw as? NSNumber { return number.boolValue }
        return false
    }
}

/// Pure matrix-mixer policy, mirroring the engine (`sotf-engine
/// plugins/matrix.rs`) and the app-gpui matrix picker so every frontend
/// computes the same presets, labels, and dB text. Gains are row-major
/// linear coefficients: `gains[out * inCount + in]`. Keeping the mapping
/// here makes the parameter contract unit-testable without hosting a
/// SwiftUI view.
public enum ConfigBarMatrixParameters {
    public static let matrixKey = "matrix"
    public static let inputChannelsKey = "input_channels"
    public static let outputChannelsKey = "output_channels"
    public static let channelStatesKey = "channel_states"
    public static let minDb = -60.0
    public static let maxDb = 6.0
    public static let silenceThreshold = 0.001
    public static let presetTolerance = 0.001
    /// The grid renders at most this many rows/columns; wider matrices keep
    /// their full data and remain editable through the route pickers.
    public static let maxRenderChannels = 32

    public static func intValue(_ raw: Any?) -> Int? {
        if let int = raw as? Int { return int }
        if let double = raw as? Double, double.isFinite { return Int(double) }
        if let number = raw as? NSNumber { return number.intValue }
        if let string = raw as? String { return Int(string) }
        return nil
    }

    public static func inputChannels(_ parameters: [String: Any], fallback: Int) -> Int {
        max(intValue(parameters[inputChannelsKey]) ?? fallback, 1)
    }

    public static func outputChannels(_ parameters: [String: Any], fallback: Int) -> Int {
        max(intValue(parameters[outputChannelsKey]) ?? fallback, 1)
    }

    public static func cellIndex(input: Int, output: Int, inputCount: Int) -> Int {
        output * inputCount + input
    }

    /// Gains normalized to exactly `inputChannels * outputChannels` entries.
    /// Stored values are kept as a flat prefix; diagonal cells without a
    /// stored value read as unity (mirroring the engine's resize fill) so a
    /// truncated list still renders a usable grid.
    public static func gains(
        _ parameters: [String: Any],
        inputChannels: Int,
        outputChannels: Int
    ) -> [Double] {
        let stored = (parameters[matrixKey] as? [Any] ?? []).map {
            ConfigBarDelayParameters.doubleValue($0) ?? 0.0
        }
        return normalizedGains(stored, inputChannels: inputChannels, outputChannels: outputChannels)
    }

    public static func normalizedGains(
        _ stored: [Double],
        inputChannels: Int,
        outputChannels: Int
    ) -> [Double] {
        let count = inputChannels * outputChannels
        guard stored.count != count else { return stored.map { $0.isFinite ? $0 : 0.0 } }
        var next = [Double](repeating: 0.0, count: count)
        for index in 0..<min(stored.count, count) {
            next[index] = stored[index].isFinite ? stored[index] : 0.0
        }
        for channel in 0..<min(inputChannels, outputChannels) {
            let index = cellIndex(input: channel, output: channel, inputCount: inputChannels)
            if index >= stored.count {
                next[index] = 1.0
            }
        }
        return next
    }

    /// Output channel states sized to `outputChannels`; missing entries
    /// default to unmuted/unsoloed/undimmed.
    public static func channelStates(
        _ parameters: [String: Any],
        outputChannels: Int
    ) -> [MatrixChannelState] {
        let stored = (parameters[channelStatesKey] as? [Any] ?? []).map {
            MatrixChannelState.parse($0)
        }
        if stored.count >= outputChannels {
            return Array(stored.prefix(outputChannels))
        }
        return stored + Array(
            repeating: MatrixChannelState(),
            count: outputChannels - stored.count
        )
    }

    /// Full matrix update. Unknown keys (e.g. the master `gain`) round-trip
    /// untouched; only the routing keys are replaced.
    public static func applyingMatrix(
        _ parameters: [String: Any],
        inputChannels: Int,
        outputChannels: Int,
        gains: [Double],
        channelStates: [MatrixChannelState]
    ) -> [String: Any] {
        var next = parameters
        next[inputChannelsKey] = max(inputChannels, 1)
        next[outputChannelsKey] = max(outputChannels, 1)
        next[matrixKey] = normalizedGains(
            gains,
            inputChannels: max(inputChannels, 1),
            outputChannels: max(outputChannels, 1)
        )
        next[channelStatesKey] = channelStates.prefix(max(outputChannels, 1)).map(\.wire)
        return next
    }

    public static func availablePresets(inputChannels: Int, outputChannels: Int) -> [String] {
        var presets = ["Identity"]
        if inputChannels >= 2 && outputChannels >= 2 {
            presets.append("Swap L/R")
        }
        if inputChannels > 1 {
            presets.append("Mono Mix")
        }
        if inputChannels >= 2 && outputChannels >= 2 {
            presets.append("M/S Encode")
            presets.append("M/S Decode")
        }
        return presets
    }

    public static func detectPreset(
        inputChannels: Int,
        outputChannels: Int,
        gains: [Double]
    ) -> String {
        if isIdentityMatrix(inputChannels: inputChannels, outputChannels: outputChannels, gains: gains) {
            return "Identity"
        } else if isSwapMatrix(inputChannels: inputChannels, outputChannels: outputChannels, gains: gains) {
            return "Swap L/R"
        } else if isMonoMixMatrix(inputChannels: inputChannels, outputChannels: outputChannels, gains: gains) {
            return "Mono Mix"
        } else if isMsEncodeMatrix(inputChannels: inputChannels, outputChannels: outputChannels, gains: gains) {
            return "M/S Encode"
        } else if isMsDecodeMatrix(inputChannels: inputChannels, outputChannels: outputChannels, gains: gains) {
            return "M/S Decode"
        } else {
            return "Custom"
        }
    }

    /// Fresh gain list for `preset`, sized to the channel counts. Unknown
    /// names (including "Custom") fall back to identity, like the engine.
    public static func applyPreset(
        _ preset: String,
        inputChannels: Int,
        outputChannels: Int
    ) -> [Double] {
        var next = [Double](repeating: 0.0, count: inputChannels * outputChannels)
        guard inputChannels > 0, outputChannels > 0 else { return next }
        switch preset {
        case "Identity":
            for channel in 0..<min(inputChannels, outputChannels) {
                next[cellIndex(input: channel, output: channel, inputCount: inputChannels)] = 1.0
            }
        case "Swap L/R":
            if inputChannels >= 2 && outputChannels >= 2 {
                next[cellIndex(input: 1, output: 0, inputCount: inputChannels)] = 1.0
                next[cellIndex(input: 0, output: 1, inputCount: inputChannels)] = 1.0
                for channel in 2..<min(inputChannels, outputChannels) {
                    next[cellIndex(input: channel, output: channel, inputCount: inputChannels)] = 1.0
                }
            }
        case "Mono Mix":
            let gain = 1.0 / Double(inputChannels)
            next = [Double](repeating: gain, count: inputChannels * outputChannels)
        case "M/S Encode":
            if inputChannels >= 2 && outputChannels >= 2 {
                next[cellIndex(input: 0, output: 0, inputCount: inputChannels)] = 0.5
                next[cellIndex(input: 1, output: 0, inputCount: inputChannels)] = 0.5
                next[cellIndex(input: 0, output: 1, inputCount: inputChannels)] = 0.5
                next[cellIndex(input: 1, output: 1, inputCount: inputChannels)] = -0.5
                for channel in 2..<min(inputChannels, outputChannels) {
                    next[cellIndex(input: channel, output: channel, inputCount: inputChannels)] = 1.0
                }
            }
        case "M/S Decode":
            if inputChannels >= 2 && outputChannels >= 2 {
                next[cellIndex(input: 0, output: 0, inputCount: inputChannels)] = 1.0
                next[cellIndex(input: 1, output: 0, inputCount: inputChannels)] = 1.0
                next[cellIndex(input: 0, output: 1, inputCount: inputChannels)] = 1.0
                next[cellIndex(input: 1, output: 1, inputCount: inputChannels)] = -1.0
                for channel in 2..<min(inputChannels, outputChannels) {
                    next[cellIndex(input: channel, output: channel, inputCount: inputChannels)] = 1.0
                }
            }
        default:
            for channel in 0..<min(inputChannels, outputChannels) {
                next[cellIndex(input: channel, output: channel, inputCount: inputChannels)] = 1.0
            }
        }
        return next
    }

    private static func isIdentityMatrix(inputChannels: Int, outputChannels: Int, gains: [Double]) -> Bool {
        guard gains.count == inputChannels * outputChannels else { return false }
        for output in 0..<outputChannels {
            for input in 0..<inputChannels {
                let expected = (input == output) ? 1.0 : 0.0
                if abs(gains[cellIndex(input: input, output: output, inputCount: inputChannels)] - expected) > presetTolerance {
                    return false
                }
            }
        }
        return true
    }

    private static func isSwapMatrix(inputChannels: Int, outputChannels: Int, gains: [Double]) -> Bool {
        guard inputChannels >= 2, outputChannels >= 2,
              gains.count == inputChannels * outputChannels else { return false }
        for output in 0..<outputChannels {
            for input in 0..<inputChannels {
                let swapped = (output == 0 && input == 1) || (output == 1 && input == 0)
                    || (output >= 2 && input == output)
                let expected = swapped ? 1.0 : 0.0
                if abs(gains[cellIndex(input: input, output: output, inputCount: inputChannels)] - expected) > presetTolerance {
                    return false
                }
            }
        }
        return true
    }

    private static func isMonoMixMatrix(inputChannels: Int, outputChannels: Int, gains: [Double]) -> Bool {
        guard gains.count == inputChannels * outputChannels, inputChannels > 0 else { return false }
        let expected = 1.0 / Double(inputChannels)
        return gains.allSatisfy { abs($0 - expected) <= presetTolerance }
    }

    private static func isMsEncodeMatrix(inputChannels: Int, outputChannels: Int, gains: [Double]) -> Bool {
        guard inputChannels >= 2, outputChannels >= 2,
              gains.count == inputChannels * outputChannels else { return false }
        for output in 0..<outputChannels {
            for input in 0..<inputChannels {
                let expected: Double
                switch (output, input) {
                case (0, 0), (0, 1), (1, 0): expected = 0.5
                case (1, 1): expected = -0.5
                default: expected = (output >= 2 && input == output) ? 1.0 : 0.0
                }
                if abs(gains[cellIndex(input: input, output: output, inputCount: inputChannels)] - expected) > presetTolerance {
                    return false
                }
            }
        }
        return true
    }

    private static func isMsDecodeMatrix(inputChannels: Int, outputChannels: Int, gains: [Double]) -> Bool {
        guard inputChannels >= 2, outputChannels >= 2,
              gains.count == inputChannels * outputChannels else { return false }
        for output in 0..<outputChannels {
            for input in 0..<inputChannels {
                let expected: Double
                switch (output, input) {
                case (0, 0), (0, 1), (1, 0): expected = 1.0
                case (1, 1): expected = -1.0
                default: expected = (output >= 2 && input == output) ? 1.0 : 0.0
                }
                if abs(gains[cellIndex(input: input, output: output, inputCount: inputChannels)] - expected) > presetTolerance {
                    return false
                }
            }
        }
        return true
    }

    /// dB text for a cell, mirroring the app-gpui matrix grid: silence reads
    /// "-∞", unity reads "0", and negative (phase-inverted) gains keep a
    /// minus prefix.
    public static func formatGainDb(_ linear: Double) -> String {
        guard linear.isFinite else { return "-∞" }
        if abs(linear) < silenceThreshold {
            return "-∞"
        }
        let sign = linear < 0 ? "-" : ""
        let db = 20.0 * log10(abs(linear))
        if abs(db) < 0.05 {
            return "\(sign)0"
        }
        return String(format: "\(sign)%.1f", db)
    }

    public static func dbToLinear(_ db: Double) -> Double {
        guard db.isFinite else { return 0.0 }
        return pow(10.0, db / 20.0)
    }

    /// dB value for the route gain control: silence floors at `minDb`, and
    /// the magnitude ignores polarity (the polarity switch owns the sign).
    public static func linearToDb(_ linear: Double) -> Double {
        guard linear.isFinite, abs(linear) >= silenceThreshold else { return minDb }
        return 20.0 * log10(abs(linear))
    }

    /// Speaker label for a channel index, mirroring the engine's
    /// channel-count lookup; unknown layouts fall back to "Ch{index}".
    public static func channelLabel(index: Int, total: Int) -> String {
        if let labels = channelLabelsByCount[total], labels.indices.contains(index) {
            return labels[index]
        }
        return "Ch\(index)"
    }

    /// Output groups for the mute/solo/dim sidebar, mirroring the engine's
    /// meter groups; unknown layouts group each channel alone.
    public static func outputGroups(total: Int) -> [(name: String, channels: [Int])] {
        if let groups = outputGroupsByCount[total] {
            return groups
        }
        return (0..<max(total, 1)).map { ("Ch\($0)", [$0]) }
    }

    private static let channelLabelsByCount: [Int: [String]] = [
        1: ["M"],
        2: ["L", "R"],
        3: ["L", "R", "LFE"],
        5: ["L", "R", "C", "SL", "SR"],
        6: ["L", "R", "C", "LFE", "SL", "SR"],
        8: ["L", "R", "C", "LFE", "SL", "SR", "BL", "BR"],
        10: ["L", "R", "C", "LFE", "SL", "SR", "TFL", "TFR", "TBL", "TBR"],
        12: ["L", "R", "C", "LFE", "SL", "SR", "BL", "BR", "TFL", "TFR", "TBL", "TBR"],
        14: ["L", "R", "WL", "WR", "C", "LFE", "SL", "SR", "BL", "BR", "TFL", "TFR", "TBL", "TBR"],
        16: ["L", "R", "WL", "WR", "C", "LFE", "SL", "SR", "BL", "BR", "TFL", "TFR", "TML", "TMR", "TBL", "TBR"],
    ]

    private static let outputGroupsByCount: [Int: [(name: String, channels: [Int])]] = [
        1: [("Mono", [0])],
        2: [("L/R", [0, 1])],
        3: [("L/R", [0, 1]), ("LFE", [2])],
        5: [("L/R", [0, 1]), ("Center", [2]), ("Surrounds", [3, 4])],
        6: [("L/R", [0, 1]), ("Center", [2]), ("LFE", [3]), ("Surrounds", [4, 5])],
        8: [("L/R", [0, 1]), ("Center", [2]), ("LFE", [3]), ("Side", [4, 5]), ("Rear", [6, 7])],
        10: [("L/R", [0, 1]), ("Center", [2]), ("LFE", [3]), ("Surrounds", [4, 5]), ("Height", [6, 7, 8, 9])],
        12: [("L/R", [0, 1]), ("Center", [2]), ("LFE", [3]), ("Side", [4, 5]), ("Rear", [6, 7]), ("Height", [8, 9, 10, 11])],
        14: [("Front", [0, 1, 2, 3]), ("Center", [4]), ("LFE", [5]), ("Side", [6, 7]), ("Rear", [8, 9]), ("Height", [10, 11, 12, 13])],
        16: [("Front", [0, 1, 2, 3]), ("Center", [4]), ("LFE", [5]), ("Side", [6, 7]), ("Rear", [8, 9]), ("Top Front", [10, 11]), ("Top Mid", [12, 13]), ("Top Rear", [14, 15])],
    ]
}
