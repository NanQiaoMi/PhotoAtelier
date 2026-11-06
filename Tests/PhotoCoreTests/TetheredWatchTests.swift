import XCTest
@testable import PhotoCore

final class TetheredWatchTests: XCTestCase {

    private var tempFolder: URL!

    override func setUp() {
        super.setUp()
        let uniqueID = "tethered_test_\(UUID().uuidString)"
        tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent(uniqueID, isDirectory: true)
        try? FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempFolder {
            try? FileManager.default.removeItem(at: tempFolder)
        }
        super.tearDown()
    }

    func testConfigurationDefaultsAndCodable() throws {
        let config = TetheredWatchConfiguration(folderURL: tempFolder)
        XCTAssertEqual(config.folderURL, tempFolder)
        XCTAssertFalse(config.includeSubfolders)
        XCTAssertTrue(config.autoSelectLatest)
        XCTAssertEqual(config.fileStabilityDelay, 0.4, accuracy: 0.001)

        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TetheredWatchConfiguration.self, from: data)
        XCTAssertEqual(config, decoded)
    }

    func testStateProperties() {
        let idle = TetheredWatchState.idle
        XCTAssertFalse(idle.isWatching)
        XCTAssertNil(idle.folderURL)
        XCTAssertEqual(idle.title, "未监视")

        let watching = TetheredWatchState.watching(tempFolder)
        XCTAssertTrue(watching.isWatching)
        XCTAssertEqual(watching.folderURL, tempFolder)
        XCTAssertTrue(watching.title.contains("正在监视"))

        let paused = TetheredWatchState.paused
        XCTAssertFalse(paused.isWatching)
        XCTAssertNil(paused.folderURL)
        XCTAssertEqual(paused.title, "监视已暂停")

        let error = TetheredWatchState.error("测试错误")
        XCTAssertFalse(error.isWatching)
        XCTAssertNil(error.folderURL)
        XCTAssertEqual(error.title, "错误：测试错误")
    }

    func testStartWithMissingOrInvalidFolderThrows() {
        let manager = TetheredWatchManager()

        // 1. Missing folder URL
        let emptyConfig = TetheredWatchConfiguration(folderURL: nil)
        XCTAssertThrowsError(try manager.start(configuration: emptyConfig)) { err in
            guard case AtelierError.invalidConfiguration = err else {
                XCTFail("Expected AtelierError.invalidConfiguration but got \(err)")
                return
            }
        }
        XCTAssertEqual(manager.state, .error("未指定监视文件夹路径"))

        // 2. Non-existent directory
        let fakeURL = tempFolder.appendingPathComponent("non_existent_dir_12345")
        let missingConfig = TetheredWatchConfiguration(folderURL: fakeURL)
        XCTAssertThrowsError(try manager.start(configuration: missingConfig)) { err in
            guard case AtelierError.invalidConfiguration = err else {
                XCTFail("Expected AtelierError.invalidConfiguration but got \(err)")
                return
            }
        }
        if case .error(let msg) = manager.state {
            XCTAssertTrue(msg.contains("不存在"))
        } else {
            XCTFail("Expected .error state but got \(manager.state)")
        }
    }

    func testNormalLifecycleStartStopPauseResume() throws {
        let manager = TetheredWatchManager()
        var states: [TetheredWatchState] = []
        let stateExpectation = expectation(description: "State changes")
        stateExpectation.expectedFulfillmentCount = 4

        manager.onStateChange = { state in
            states.append(state)
            stateExpectation.fulfill()
        }

        let config = TetheredWatchConfiguration(folderURL: tempFolder)
        try manager.start(configuration: config)
        XCTAssertTrue(manager.state.isWatching)

        manager.pause()
        XCTAssertEqual(manager.state, .paused)

        manager.resume()
        XCTAssertTrue(manager.state.isWatching)

        manager.stop()
        XCTAssertEqual(manager.state, .idle)

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(states, [.watching(tempFolder), .paused, .watching(tempFolder), .idle])
    }

    func testExistingPhotosAreIgnoredOnStart() throws {
        // Create 2 fake files before starting
        let file1 = tempFolder.appendingPathComponent("IMG_0001.JPG")
        let file2 = tempFolder.appendingPathComponent("IMG_0002.CR3")
        try "dummy content 1".data(using: .utf8)?.write(to: file1)
        try "dummy content 2".data(using: .utf8)?.write(to: file2)

        let manager = TetheredWatchManager()
        var discovered: [URL] = []
        manager.onNewPhotos = { urls in
            discovered.append(contentsOf: urls)
        }

        let config = TetheredWatchConfiguration(folderURL: tempFolder, fileStabilityDelay: 0)
        try manager.start(configuration: config)

        // Existing files should already be known
        XCTAssertEqual(manager.knownCount, 2)
        XCTAssertTrue(manager.isKnown(file1))
        XCTAssertTrue(manager.isKnown(file2))

        manager.manualScan()

        // Wait brief instant
        let exp = expectation(description: "Scan completion wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            exp.fulfill()
        }
        waitForExpectations(timeout: 1.0)

        XCTAssertTrue(discovered.isEmpty, "Existing files should not trigger new-photo callbacks")
        manager.stop()
    }

    func testNewPhotoDetectionAndStability() throws {
        let manager = TetheredWatchManager()
        var reportedURLs: [URL] = []
        let arrivalExpectation = expectation(description: "New photo arrival")

        manager.onNewPhotos = { urls in
            reportedURLs.append(contentsOf: urls)
            arrivalExpectation.fulfill()
        }

        let config = TetheredWatchConfiguration(folderURL: tempFolder, fileStabilityDelay: 0)
        try manager.start(configuration: config)

        // Now write a new image file into tempFolder
        let newFile = tempFolder.appendingPathComponent("CAPTURE_9999.JPG")
        try "fake image payload".data(using: .utf8)?.write(to: newFile)

        manager.manualScan()

        waitForExpectations(timeout: 2.0)
        XCTAssertEqual(reportedURLs.count, 1)
        XCTAssertEqual(reportedURLs.first?.lastPathComponent, "CAPTURE_9999.JPG")
        XCTAssertTrue(manager.isKnown(newFile))

        // Scanning again should not re-report the same file
        manager.manualScan()
        let waitExp = expectation(description: "Second scan wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            waitExp.fulfill()
        }
        waitForExpectations(timeout: 1.0)
        XCTAssertEqual(reportedURLs.count, 1, "Should not duplicate reported URLs")

        manager.stop()
    }

    func testSubdirectoryScanHonorsConfig() throws {
        let subfolder = tempFolder.appendingPathComponent("SubSession", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let subFile = subfolder.appendingPathComponent("SUB_0001.JPG")
        try "sub content".data(using: .utf8)?.write(to: subFile)

        // 1. When includeSubfolders is false
        let manager1 = TetheredWatchManager()
        let configWithoutSub = TetheredWatchConfiguration(folderURL: tempFolder, includeSubfolders: false, fileStabilityDelay: 0)
        try manager1.start(configuration: configWithoutSub)
        XCTAssertEqual(manager1.knownCount, 0, "Subfolder files should be ignored when includeSubfolders is false")
        manager1.stop()

        // 2. When includeSubfolders is true
        let manager2 = TetheredWatchManager()
        let configWithSub = TetheredWatchConfiguration(folderURL: tempFolder, includeSubfolders: true, fileStabilityDelay: 0)
        try manager2.start(configuration: configWithSub)
        XCTAssertEqual(manager2.knownCount, 1, "Subfolder files should be included when includeSubfolders is true")
        XCTAssertTrue(manager2.isKnown(subFile))
        manager2.stop()
    }

    func testZeroByteFileIsIgnoredUntilPopulated() throws {
        let manager = TetheredWatchManager()
        var reportedURLs: [URL] = []

        let config = TetheredWatchConfiguration(folderURL: tempFolder, fileStabilityDelay: 0)
        try manager.start(configuration: config)

        let zeroByteFile = tempFolder.appendingPathComponent("STREAMING_0001.JPG")
        // Create 0-byte file
        FileManager.default.createFile(atPath: zeroByteFile.path, contents: Data())

        manager.onNewPhotos = { urls in
            reportedURLs.append(contentsOf: urls)
        }

        manager.manualScan()

        // Verify it was NOT reported while 0 bytes
        let waitZero = expectation(description: "Wait zero byte scan")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            waitZero.fulfill()
        }
        wait(for: [waitZero], timeout: 1.0)
        XCTAssertTrue(reportedURLs.isEmpty, "0-byte file must not be reported")

        // Now populate the file
        let arrivalExpectation = expectation(description: "New photo arrival after non-empty")
        manager.onNewPhotos = { urls in
            reportedURLs.append(contentsOf: urls)
            arrivalExpectation.fulfill()
        }

        try "now written complete".data(using: .utf8)?.write(to: zeroByteFile)

        manager.manualScan()

        wait(for: [arrivalExpectation], timeout: 2.0)
        XCTAssertEqual(reportedURLs.count, 1)
        XCTAssertEqual(reportedURLs.first?.lastPathComponent, "STREAMING_0001.JPG")

        manager.stop()
    }
}
