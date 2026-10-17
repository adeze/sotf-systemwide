import AppKit
import Darwin
import Foundation
import SwiftUI
import XCTest
import ViewInspector
@testable import ConfigBarModels
@testable import ConfigBarUI

final class ConfigBarUITests: XCTestCase {
    private func makeUnixServer(path: String) throws -> Int32 {
        unlink(path)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8
        let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
        XCTAssertLessThan(pathBytes.count + 1, pathCapacity)
        let copiedLength = withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer -> Int in
            path.withCString { pathCString in
                Int(strlcpy(
                    rawBuffer.baseAddress!.assumingMemoryBound(to: CChar.self),
                    pathCString,
                    rawBuffer.count
                ))
            }
        }
        XCTAssertEqual(copiedLength, pathBytes.count)

        let serverFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(serverFD, 0)
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(
                    serverFD,
                    sockaddrPointer,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        XCTAssertEqual(bindResult, 0)
        XCTAssertEqual(Darwin.listen(serverFD, 4), 0)
        return serverFD
    }

    private func readLine(from fd: Int32, timeout: TimeInterval = 1.0) -> Data? {
        var data = Data()
        var byte: UInt8 = 0
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let count = withUnsafeMutableBytes(of: &byte) { buffer in
                Darwin.recv(fd, buffer.baseAddress, 1, 0)
            }
            if count == 1 {
                data.append(byte)
                if byte == 10 { return data }
            } else if count == 0 {
                return data.isEmpty ? nil : data
            } else if errno != EINTR {
                return nil
            }
        }
        return nil
    }

    private func sendLine(_ line: String, on fd: Int32) {
        let bytes = Array(line.utf8)
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < bytes.count {
                let sent = Darwin.send(
                    fd,
                    buffer.baseAddress!.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
                if sent > 0 {
                    offset += sent
                } else if sent < 0 && errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    func testCommandWWindowPolicyOnlyMatchesCommandW() {
        XCTAssertTrue(
            ConfigBarWindowPolicy.shouldDismissCommandW(
                hasCommandModifier: true,
                charactersIgnoringModifiers: "w"
            )
        )
        XCTAssertFalse(
            ConfigBarWindowPolicy.shouldDismissCommandW(
                hasCommandModifier: false,
                charactersIgnoringModifiers: "w"
            )
        )
        XCTAssertFalse(
            ConfigBarWindowPolicy.shouldDismissCommandW(
                hasCommandModifier: true,
                charactersIgnoringModifiers: "q"
            )
        )
    }

    func testUITargetExposesModelBackedConfigurationPolicy() {
        XCTAssertTrue(isConfigBarVirtualDevice("SotF Virtual Audio"))
        XCTAssertFalse(isConfigBarVirtualDevice("Built-in Output"))
    }

    func testLifecycleWorkKeepsMainQueueResponsiveAndCompletesOnMain() {
        let lifecycleStarted = expectation(description: "slow lifecycle work started")
        let mainQueueResponsive = expectation(description: "main queue remains responsive")
        let completion = expectation(description: "lifecycle completion")
        let releaseLifecycleWork = DispatchSemaphore(value: 0)
        let manager = DaemonManager { _ in
            XCTAssertFalse(Thread.isMainThread)
            lifecycleStarted.fulfill()
            XCTAssertEqual(releaseLifecycleWork.wait(timeout: .now() + 1), .success)
            return true
        }

        manager.kickstartAgentForTesting { started in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertTrue(started)
            completion.fulfill()
        }
        DispatchQueue.main.async {
            mainQueueResponsive.fulfill()
        }

        wait(for: [lifecycleStarted, mainQueueResponsive], timeout: 1)
        releaseLifecycleWork.signal()
        wait(for: [completion], timeout: 1)
    }

    func testDaemonManagerAdoptsLiveFixtureAndRemainsResponsive() throws {
        let path = "/tmp/sotf-configbar-adoption-\(getpid()).sock"
        let serverFD = try makeUnixServer(path: path)
        defer {
            Darwin.close(serverFD)
            unlink(path)
        }

        let oldSocketPath = getenv("SOTF_DAEMON_SOCKET_PATH").map { String(cString: $0) }
        let oldDaemonPath = getenv("SOTF_DAEMON_PATH").map { String(cString: $0) }
        setenv("SOTF_DAEMON_SOCKET_PATH", path, 1)
        // If adoption regresses, launchDaemon may only start this harmless
        // executable; its termination would produce a second false callback.
        setenv("SOTF_DAEMON_PATH", "/bin/false", 1)
        defer {
            if let oldSocketPath { setenv("SOTF_DAEMON_SOCKET_PATH", oldSocketPath, 1) }
            else { unsetenv("SOTF_DAEMON_SOCKET_PATH") }
            if let oldDaemonPath { setenv("SOTF_DAEMON_PATH", oldDaemonPath, 1) }
            else { unsetenv("SOTF_DAEMON_PATH") }
        }

        let server = DispatchWorkItem {
            // The first connection is the startDaemon probe. The second is a
            // post-adoption probe proving the fixture stayed responsive.
            for _ in 0..<2 {
                let clientFD = Darwin.accept(serverFD, nil, nil)
                guard clientFD >= 0 else { return }
                defer { Darwin.close(clientFD) }
                guard self.readLine(from: clientFD) != nil else { return }
                self.sendLine(
                    "{\"success\":true,\"data\":{},\"error\":null}\n",
                    on: clientFD
                )
            }
        }
        DispatchQueue.global(qos: .utility).async(execute: server)

        let adopted = expectation(description: "live daemon is adopted")
        var callbackValues: [Bool] = []
        let manager = DaemonManager()
        manager.onStatusChange = { reachable in
            callbackValues.append(reachable)
            if reachable { adopted.fulfill() }
        }

        manager.startDaemon()
        wait(for: [adopted], timeout: 2.0)

        XCTAssertFalse(manager.isDaemonRunning)
        XCTAssertEqual(manager.restartActionTitle, "Reconnect")
        XCTAssertEqual(callbackValues, [true])
        XCTAssertTrue(ConfigBarIPC.probeDaemon(socketPath: path, timeoutMilliseconds: 500))
        XCTAssertEqual(server.wait(timeout: .now() + 1), .success)
        manager.stopDaemon()
    }

    func testStatusAndMeteringPollingReuseOneSocket() throws {
        let path = "/tmp/sotf-configbar-polling-\(getpid()).sock"
        let serverFD = try makeUnixServer(path: path)
        defer {
            AudioEngineClient.resetPollingConnectionForTests()
            Darwin.close(serverFD)
            unlink(path)
        }

        let oldSocketPath = getenv("SOTF_DAEMON_SOCKET_PATH").map { String(cString: $0) }
        setenv("SOTF_DAEMON_SOCKET_PATH", path, 1)
        defer {
            if let oldSocketPath { setenv("SOTF_DAEMON_SOCKET_PATH", oldSocketPath, 1) }
            else { unsetenv("SOTF_DAEMON_SOCKET_PATH") }
        }

        let lock = NSLock()
        var acceptedConnections = 0
        let server = DispatchWorkItem {
            let clientFD = Darwin.accept(serverFD, nil, nil)
            guard clientFD >= 0 else { return }
            lock.lock()
            acceptedConnections += 1
            lock.unlock()
            defer { Darwin.close(clientFD) }

            for _ in 0..<2 {
                guard let request = self.readLine(from: clientFD),
                      let command = try? JSONSerialization.jsonObject(with: request) as? [String: Any]
                else { return }
                let response: String
                if command["command"] as? String == "get_snapshot" {
                    response = "{\"success\":true,\"data\":{\"schema_version\":1,\"generation\":8,\"desired\":{\"input_channels\":2,\"output_channels\":2},\"applied\":{\"generation\":7},\"observed\":{\"engine\":{\"state\":\"Idle\",\"volume\":1.0,\"muted\":false}}},\"error\":null}\n"
                } else {
                    response = "{\"success\":true,\"data\":{\"generation\":8},\"error\":null}\n"
                }
                self.sendLine(response, on: clientFD)
            }
        }
        DispatchQueue.global(qos: .utility).async(execute: server)

        let statusDone = expectation(description: "status poll completes")
        let meteringDone = expectation(description: "metering poll completes")
            AudioEngineClient.pollStatus { status, reachable in
                XCTAssertEqual(status.state, .idle)
                XCTAssertEqual(status.generation, 8)
                XCTAssertTrue(reachable)
            statusDone.fulfill()
        }
        AudioEngineClient.pollMetering { metering in
            XCTAssertNotNil(metering)
            XCTAssertEqual(metering?.generation, 8)
            meteringDone.fulfill()
        }

        wait(for: [statusDone, meteringDone], timeout: 2.0)
        XCTAssertEqual(server.wait(timeout: .now() + 1), .success)

        // The polling queue is serial and both commands were completed on the
        // same accepted stream. No timer tick may create another connection.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        lock.lock()
        let count = acceptedConnections
        lock.unlock()
        XCTAssertEqual(count, 1)
    }

    /// UI-before-daemon start order: status polling must report unreachable
    /// (fast, without hanging) while no socket exists, then adopt the
    /// daemon once its socket appears.
    func testPollStatusAdoptsDaemonThatStartsAfterTheUI() throws {
        let path = "/tmp/sotf-configbar-late-daemon-\(getpid()).sock"
        unlink(path)
        let oldSocketPath = getenv("SOTF_DAEMON_SOCKET_PATH").map { String(cString: $0) }
        setenv("SOTF_DAEMON_SOCKET_PATH", path, 1)
        defer {
            AudioEngineClient.resetPollingConnectionForTests()
            if let oldSocketPath { setenv("SOTF_DAEMON_SOCKET_PATH", oldSocketPath, 1) }
            else { unsetenv("SOTF_DAEMON_SOCKET_PATH") }
            unlink(path)
        }
        AudioEngineClient.resetPollingConnectionForTests()

        let unreachable = expectation(description: "absent daemon polls unreachable")
        AudioEngineClient.pollStatus { _, reachable in
            XCTAssertFalse(reachable)
            unreachable.fulfill()
        }
        wait(for: [unreachable], timeout: 3.0)

        let serverFD = try makeUnixServer(path: path)
        defer { Darwin.close(serverFD) }
        let server = DispatchWorkItem {
            let clientFD = Darwin.accept(serverFD, nil, nil)
            guard clientFD >= 0 else { return }
            defer { Darwin.close(clientFD) }
            while self.readLine(from: clientFD) != nil {
                self.sendLine(
                    "{\"success\":true,\"data\":{\"schema_version\":1,\"generation\":8,\"desired\":{\"input_channels\":2,\"output_channels\":2},\"applied\":{\"generation\":7},\"observed\":{\"engine\":{\"state\":\"Idle\",\"volume\":1.0,\"muted\":false}}},\"error\":null}\n",
                    on: clientFD
                )
            }
        }
        DispatchQueue.global(qos: .utility).async(execute: server)

        AudioEngineClient.resetPollingConnectionForTests()
        let adopted = expectation(description: "late daemon polls reachable")
        AudioEngineClient.pollStatus { status, reachable in
            XCTAssertTrue(reachable)
            XCTAssertEqual(status.generation, 8)
            adopted.fulfill()
        }
        wait(for: [adopted], timeout: 3.0)
    }

    /// Daemon-dies-mid-session start order: after a healthy poll, the
    /// socket vanishing must flip polling to unreachable, not hang or crash.
    func testPollStatusSurvivesDaemonDisappearingMidSession() throws {
        let path = "/tmp/sotf-configbar-dying-daemon-\(getpid()).sock"
        unlink(path)
        let oldSocketPath = getenv("SOTF_DAEMON_SOCKET_PATH").map { String(cString: $0) }
        setenv("SOTF_DAEMON_SOCKET_PATH", path, 1)
        defer {
            AudioEngineClient.resetPollingConnectionForTests()
            if let oldSocketPath { setenv("SOTF_DAEMON_SOCKET_PATH", oldSocketPath, 1) }
            else { unsetenv("SOTF_DAEMON_SOCKET_PATH") }
            unlink(path)
        }

        let serverFD = try makeUnixServer(path: path)
        let server = DispatchWorkItem {
            let clientFD = Darwin.accept(serverFD, nil, nil)
            guard clientFD >= 0 else { return }
            _ = self.readLine(from: clientFD)
            self.sendLine(
                "{\"success\":true,\"data\":{\"schema_version\":1,\"generation\":8,\"desired\":{\"input_channels\":2,\"output_channels\":2},\"applied\":{\"generation\":7},\"observed\":{\"engine\":{\"state\":\"Idle\",\"volume\":1.0,\"muted\":false}}},\"error\":null}\n",
                on: clientFD
            )
            Darwin.close(clientFD)
        }
        DispatchQueue.global(qos: .utility).async(execute: server)

        AudioEngineClient.resetPollingConnectionForTests()
        let healthy = expectation(description: "daemon polls healthy")
        AudioEngineClient.pollStatus { _, reachable in
            XCTAssertTrue(reachable)
            healthy.fulfill()
        }
        wait(for: [healthy], timeout: 3.0)
        _ = server.wait(timeout: .now() + 2)

        // The daemon dies: listener closed, socket file removed.
        Darwin.close(serverFD)
        unlink(path)
        AudioEngineClient.resetPollingConnectionForTests()

        let gone = expectation(description: "dead daemon polls unreachable")
        AudioEngineClient.pollStatus { _, reachable in
            XCTAssertFalse(reachable)
            gone.fulfill()
        }
        wait(for: [gone], timeout: 5.0)
    }
}


/// Scripted Unix-socket daemon for hosted-view tests. Deliberately not
/// actor-isolated: it owns its listener thread and lock-protected state so
/// tests stay free of MainActor/Sendable friction.
final class FixtureDaemonServer: @unchecked Sendable {
    private var serverFD: Int32 = -1
    private let lock = NSLock()
    private var running = false
    private var acceptThread: Thread?

    init(path: String) {
        unlink(path)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &address.sun_path) { raw in
            path.withCString { strlcpy(raw.baseAddress!.assumingMemoryBound(to: CChar.self), $0, raw.count) }
        }
        serverFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, "fixture daemon bind failed")
        XCTAssertEqual(Darwin.listen(serverFD, 8), 0)
        lock.lock()
        running = true
        lock.unlock()
        let thread = Thread { [self] in
            while true {
                lock.lock()
                let isRunning = running
                lock.unlock()
                guard isRunning else { return }
                let clientFD = Darwin.accept(serverFD, nil, nil)
                guard clientFD >= 0 else { return }
                Thread.detachNewThread { [self] in serve(clientFD) }
            }
        }
        thread.start()
        acceptThread = thread
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }
    }

    private func serve(_ clientFD: Int32) {
        var buffer = Data()
        var byte: UInt8 = 0
        while true {
            let count = withUnsafeMutableBytes(of: &byte) { Darwin.recv(clientFD, $0.baseAddress, 1, 0) }
            if count == 1 {
                buffer.append(byte)
                if byte == 10 {
                    respond(to: buffer, on: clientFD)
                    buffer.removeAll()
                }
            } else if count == 0 {
                break
            } else if errno != EINTR {
                break
            }
        }
        Darwin.close(clientFD)
    }

    private func respond(to request: Data, on fd: Int32) {
        let command = (try? JSONSerialization.jsonObject(with: request) as? [String: Any])?["command"] as? String
        let body: String
        switch command {
        case "get_snapshot":
            body = "{\"success\":true,\"data\":{\"schema_version\":1,\"generation\":8,\"desired\":{\"input_channels\":2,\"output_channels\":2},\"applied\":{\"generation\":7},\"observed\":{\"engine\":{\"state\":\"Idle\",\"volume\":1.0,\"muted\":false}}},\"error\":null}\n"
        case "get_output_profiles":
            body = "{\"success\":true,\"data\":{\"profiles\":[],\"assignments\":{}},\"error\":null}\n"
        case "get_hal_config":
            body = "{\"success\":true,\"data\":{\"sample_rate\":96000,\"buffer_frames\":512,\"actual_sample_rate\":96000,\"actual_buffer_frames\":512,\"supported_sample_rates\":[44100,48000,88200,96000,176400,192000],\"driver_ready\":true,\"active\":false},\"error\":null}\n"
        case "get_plugins", "list_plugins", "get_available_plugins":
            body = "{\"success\":true,\"data\":{\"topology\":\"rack\",\"plugins\":[],\"generation\":8},\"error\":null}\n"
        default:
            body = "{\"success\":true,\"data\":{\"generation\":8},\"error\":null}\n"
        }
        body.withCString { cString in
            _ = Darwin.send(fd, cString, strlen(cString), 0)
        }
    }
}

// MARK: - Hosted-view regression tests
//
// These tests instantiate real SwiftUI views in an NSHostingView and assert
// on the accessibility tree (labels, identifiers, frames). They cover the
// class of bug the pure-model suites cannot see: sections dropped from the
// configuration window, controls overflowing their labels, and the outputs
// detail pane drifting out of sync with the live route. Daemon traffic goes
// to a fixture Unix-socket server through the SOTF_DAEMON_SOCKET_PATH seam.

@MainActor
final class ConfigBarHostedViewTests: XCTestCase {
    private var fixtureServer: FixtureDaemonServer?
    private var socketPath = ""
    private var oldSocketPath: String?

    override func setUp() {
        super.setUp()
        socketPath = "/tmp/sotf-configbar-hosted-\(getpid())-\(UInt32.random(in: 0..<UInt32.max)).sock"
        fixtureServer = FixtureDaemonServer(path: socketPath)
        oldSocketPath = getenv("SOTF_DAEMON_SOCKET_PATH").map { String(cString: $0) }
        setenv("SOTF_DAEMON_SOCKET_PATH", socketPath, 1)
        setenv("SOTF_DAEMON_PATH", "/bin/false", 1)
    }

    override func tearDown() {
        AudioEngineClient.resetPollingConnectionForTests()
        if let oldSocketPath { setenv("SOTF_DAEMON_SOCKET_PATH", oldSocketPath, 1) }
        else { unsetenv("SOTF_DAEMON_SOCKET_PATH") }
        unsetenv("SOTF_DAEMON_PATH")
        fixtureServer?.stop()
        fixtureServer = nil
        unlink(socketPath)
        super.tearDown()
    }

    // MARK: Inspection helpers

    private func pumpRunLoop(seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func allText(in view: some View) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // MARK: Tests

    func testConfigurationWindowContainsAllSections() throws {
        // Regression: a cleanup once dropped four of the five sections,
        // leaving an empty window that every model test still passed.
        let view = ConfigurationView(
            client: AudioEngineClient(),
            onClose: {},
            onRestartDaemon: {},
            restartActionTitle: { "Reconnect" },
            onViewDaemonLog: {},
            onViewConfigBarLog: {}
        )
        let texts = try allText(in: view)
        for section in [
            "HAL Input (from macOS apps)",
            "Audio Output (to speakers)",
            "Outputs & DSP Profiles",
            "Security",
            "HAL Driver Configuration",
        ] {
            XCTAssertTrue(
                texts.contains(section),
                "configuration window must contain section \(section)"
            )
        }
    }

    func testSampleRatePickerWidthScalesWithRateCount() throws {
        // Regression: a fixed 250 pt frame made the segmented control
        // overflow over its "Sample Rate:" label once the daemon reported
        // six rates. The width must be rate-count based (88 pt per rate,
        // three fallback rates before the daemon table arrives).
        let view = ConfigurationView(
            client: AudioEngineClient(),
            onClose: {},
            onRestartDaemon: {},
            restartActionTitle: { "Reconnect" },
            onViewDaemonLog: {},
            onViewConfigBarLog: {}
        )
        let picker = try view.inspect().find(viewWithAccessibilityIdentifier: "hal.sampleRatePicker")
        XCTAssertEqual(try picker.fixedWidth(), 3 * 88, accuracy: 0.5)
    }

    final class EntriesBox: ObservableObject {
        @Published var entries: [OutputRouteEntry]
        init(entries: [OutputRouteEntry]) { self.entries = entries }
    }

    struct EntriesHarness: View {
        @ObservedObject var box: EntriesBox
        var body: some View {
            OutputProfilesView(
                client: AudioEngineClient(),
                entries: box.entries,
                profiles: [],
                outputChannels: 2,
                availableOutputChannels: 94,
                refreshTrigger: 0,
                onSwitchRoute: { _, _ in },
                onAssignProfile: { _, _ in },
                onSaveProfile: { _, completion in completion(true) },
                onCreateProfile: { _ in },
                onRenameProfile: { _, _ in },
                onDeleteProfile: { _ in }
            )
        }
    }

    func testOutputProfilesDetailFollowsLiveRoute() throws {
        // Regression: the detail pane kept editing the previously selected
        // interface after the live route switched elsewhere.
        var adam = OutputRouteEntry(id: "adam", name: "ADAM Audio D3V", uid: "adam", channels: 2, profileID: nil, isLiveRoute: true)
        var fireface = OutputRouteEntry(id: "fireface", name: "Fireface UFX+", uid: "fireface", channels: 94, profileID: nil, isLiveRoute: false)
        let box = EntriesBox(entries: [adam, fireface])
        let harness = EntriesHarness(box: box)
        ViewHosting.host(view: harness, size: CGSize(width: 900, height: 400))
        defer { ViewHosting.expel() }
        pumpRunLoop(seconds: 0.3)

        func headerMenuText() throws -> String {
            let menu = try harness.inspect().find(viewWithAccessibilityIdentifier: "outputDetail.switchMenu")
            return try menu.findAll(ViewType.Text.self).map { try $0.string() }.joined(separator: " ")
        }
        XCTAssertTrue(try headerMenuText().contains("ADAM Audio D3V"))

        adam.isLiveRoute = false
        fireface.isLiveRoute = true
        box.entries = [fireface, adam]
        pumpRunLoop(seconds: 0.3)

        XCTAssertTrue(
            try headerMenuText().contains("Fireface UFX+"),
            "detail pane must follow the live route after a switch"
        )
    }
}



// MARK: - Snapshot rendering tests
//
// Dependency-free image snapshots: key views are hosted in a window with a
// forced light appearance, rendered to PNG, and compared against checked-in
// references under __Snapshots__. Set SOTF_RECORD_SNAPSHOTS=1 to (re)record
// references; set SOTF_SKIP_SNAPSHOTS=1 on machines whose rendering stack
// differs (different macOS major version) to render without comparing.

@MainActor
final class ConfigBarSnapshotTests: XCTestCase {
    private struct SnapshotFailure: Error {}
    private var oldSocketPath: String?

    override func setUp() {
        super.setUp()
        // Snapshot views must never reach a real daemon: point the client at
        // a socket that does not exist so any accidental IPC fails fast and
        // renders stay machine-independent.
        oldSocketPath = getenv("SOTF_DAEMON_SOCKET_PATH").map { String(cString: $0) }
        setenv("SOTF_DAEMON_SOCKET_PATH", "/tmp/sotf-no-daemon-\(getpid()).sock", 1)
    }

    override func tearDown() {
        AudioEngineClient.resetPollingConnectionForTests()
        if let oldSocketPath { setenv("SOTF_DAEMON_SOCKET_PATH", oldSocketPath, 1) }
        else { unsetenv("SOTF_DAEMON_SOCKET_PATH") }
        super.tearDown()
    }

    private func render<V: View>(_ view: V, size: NSSize) -> NSBitmapImageRep {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 40, y: 40), size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        // Programmatic windows release themselves on close by default; with
        // ARC also owning this instance that double-releases and segfaults
        // in XCTest's teardown memory checker.
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        defer { window.close() }
        let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)!
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return rep
    }

    private func snapshotDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("__Snapshots__", isDirectory: true)
    }

    private func assertSnapshot(_ rep: NSBitmapImageRep, named name: String) throws {
        let directory = snapshotDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let referenceURL = directory.appendingPathComponent("\(name).png")
        guard let actualPNG = rep.representation(using: .png, properties: [:]) else {
            XCTFail("could not encode snapshot \(name)")
            throw SnapshotFailure()
        }
        let recording = ProcessInfo.processInfo.environment["SOTF_RECORD_SNAPSHOTS"] == "1"
        if recording || !FileManager.default.fileExists(atPath: referenceURL.path) {
            try actualPNG.write(to: referenceURL)
            if !recording {
                XCTFail("recorded new snapshot reference \(name); review and commit it")
            }
            return
        }
        if ProcessInfo.processInfo.environment["SOTF_SKIP_SNAPSHOTS"] == "1" {
            return
        }
        let referenceData = try Data(contentsOf: referenceURL)
        guard let reference = NSBitmapImageRep(data: referenceData) else {
            XCTFail("could not decode snapshot reference \(name)")
            throw SnapshotFailure()
        }
        XCTAssertEqual(rep.pixelsWide, reference.pixelsWide, "snapshot \(name) width changed")
        XCTAssertEqual(rep.pixelsHigh, reference.pixelsHigh, "snapshot \(name) height changed")
        guard rep.pixelsWide == reference.pixelsWide, rep.pixelsHigh == reference.pixelsHigh else {
            return
        }
        var differing = 0
        let total = rep.pixelsWide * rep.pixelsHigh
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let a = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                let b = reference.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                guard let a, let b else { continue }
                if abs(a.redComponent - b.redComponent) > 0.04
                    || abs(a.greenComponent - b.greenComponent) > 0.04
                    || abs(a.blueComponent - b.blueComponent) > 0.04
                    || abs(a.alphaComponent - b.alphaComponent) > 0.04 {
                    differing += 1
                }
            }
        }
        let fraction = Double(differing) / Double(max(total, 1))
        if fraction > 0.01 {
            let actualURL = directory.appendingPathComponent("\(name).actual.png")
            try? actualPNG.write(to: actualURL)
            XCTFail("snapshot \(name) differs in \(fraction * 100)% of pixels; actual written to \(actualURL.path)")
        }
    }

    private struct SliderHarness: View {
        @State var value = 1.0
        var body: some View {
            HighContrastSlider(value: $value, range: 0...2, step: 0.05)
                .frame(width: 300)
                .padding(10)
                .background(Color.white)
        }
    }

    func testHighContrastSliderThumbIsAccentFilled() throws {
        let rep = render(SliderHarness(), size: NSSize(width: 320, height: 42))
        try assertSnapshot(rep, named: "high-contrast-slider")

        // The thumb center (mid-range) must be the solid accent color, not
        // the near-white system knob that vanished on light backgrounds.
        let scale = CGFloat(rep.pixelsWide) / 320.0
        let thumbX = Int((10 + 9 + 0.5 * (300 - 18)) * scale)
        let thumbY = Int(21 * scale)
        let color = rep.colorAt(x: thumbX, y: thumbY)?.usingColorSpace(.deviceRGB)
        XCTAssertNotNil(color)
        XCTAssertGreaterThan(color?.blueComponent ?? 0, 0.6, "thumb must be accent-filled")
        XCTAssertLessThan(color?.redComponent ?? 1, 0.4, "thumb must contrast with the pale track")
    }

    func testOutputsMasterDetailSnapshot() throws {
        // No live route and no stored profile: the detail pane renders its
        // empty state without any daemon traffic, keeping the snapshot
        // deterministic (a live entry would render the real chain fetched
        // from whatever daemon happens to be running).
        let entries = [
            OutputRouteEntry(id: "fireface", name: "Fireface UFX+", uid: "fireface", channels: 94, profileID: nil, isLiveRoute: false),
            OutputRouteEntry(id: "adam", name: "ADAM Audio D3V", uid: "adam", channels: 2, profileID: nil, isLiveRoute: false),
            OutputRouteEntry(id: "evo8", name: "EVO8", uid: "evo8", isPresent: false, profileID: nil, isLiveRoute: false),
        ]
        let view = OutputProfilesView(
            client: AudioEngineClient(),
            entries: entries,
            profiles: [],
            outputChannels: 2,
            availableOutputChannels: 94,
            refreshTrigger: 0,
            onSwitchRoute: { _, _ in },
            onAssignProfile: { _, _ in },
            onSaveProfile: { _, completion in completion(true) },
            onCreateProfile: { _ in },
            onRenameProfile: { _, _ in },
            onDeleteProfile: { _ in }
        )
        .frame(width: 880, height: 320)
        .background(Color(NSColor.windowBackgroundColor))
        let rep = render(view, size: NSSize(width: 880, height: 320))
        try assertSnapshot(rep, named: "outputs-master-detail")
    }
}
