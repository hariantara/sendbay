import Foundation
import XCTest
@testable import MTPKit

final class BytesTests: XCTestCase {
    func testPTPStringRoundTrip() throws {
        for s in ["", "DCIM", "Ünïcødé 📷 folder"] {
            var w = ByteWriter()
            w.string(s)
            var r = ByteReader(w.data)
            XCTAssertEqual(try r.string(), s)
            XCTAssertEqual(r.remaining, 0)
        }
    }

    func testEmptyStringIsSingleZeroByte() {
        var w = ByteWriter()
        w.string("")
        XCTAssertEqual(w.data, Data([0]))
    }

    func testLittleEndianIntegers() throws {
        var w = ByteWriter()
        w.u16(0x1234); w.u32(0xDEADBEEF); w.u64(0x0102030405060708)
        XCTAssertEqual(Array(w.data.prefix(2)), [0x34, 0x12])
        var r = ByteReader(w.data)
        XCTAssertEqual(try r.u16(), 0x1234)
        XCTAssertEqual(try r.u32(), 0xDEADBEEF)
        XCTAssertEqual(try r.u64(), 0x0102030405060708)
    }

    func testTruncatedReadThrows() {
        var r = ByteReader(Data([1, 2]))
        XCTAssertThrowsError(try r.u32()) { XCTAssertEqual($0 as? MTPError, .truncated) }
    }
}

final class ContainerTests: XCTestCase {
    func testCommandContainerLayout() throws {
        let data = Container.make(.command, code: 0x1007, transactionID: 9, params: [1, 0, 0xFFFF_FFFF])
        XCTAssertEqual(data.count, 24)
        let header = try ContainerHeader(parsing: data)
        XCTAssertEqual(header, ContainerHeader(length: 24, type: .command, code: 0x1007, transactionID: 9))
        XCTAssertEqual(try Container.params(of: data), [1, 0, 0xFFFF_FFFF])
    }

    func testDataHeaderUsesUnboundedLengthAbove4GB() throws {
        let header = try ContainerHeader(parsing: Container.dataHeader(code: 0x100D, transactionID: 1, payloadLength: 5_000_000_000))
        XCTAssertTrue(header.isUnbounded)
    }

    func testObjectInfoDatasetRoundTrip() throws {
        let date = PTPDate.parse("20261029T153000")!
        let data = ObjectInfo.dataset(name: "photo.jpg", format: ObjectFormat.undefined, size: 1234, modified: date)
        let info = try ObjectInfo(handle: 7, dataset: data)
        XCTAssertEqual(info.name, "photo.jpg")
        XCTAssertEqual(info.size, 1234)
        XCTAssertEqual(info.modified, date)
        XCTAssertFalse(info.isFolder)
    }
}

final class SessionTests: XCTestCase {
    private func makeSession(_ device: MockMTPDevice = .sample()) throws -> (MTPSession, MockMTPDevice) {
        let session = MTPSession(transport: device)
        try session.open()
        return (session, device)
    }

    func testOpenReadsDeviceInfo() throws {
        let (session, _) = try makeSession()
        XCTAssertEqual(session.deviceInfo?.model, "Sendbay Test Phone")
        XCTAssertTrue(session.deviceInfo?.supports(.getPartialObject64) ?? false)
    }

    func testOpenToleratesAlreadyOpenSession() throws {
        let device = MockMTPDevice.sample()
        try MTPSession(transport: device).open()
        XCTAssertNoThrow(try MTPSession(transport: device).open())
    }

    func testListsStoragesAndRoot() throws {
        let (session, _) = try makeSession()
        let storages = try session.storages()
        XCTAssertEqual(storages.map(\.displayName), ["Internal shared storage", "SD card"])
        let root = try session.list(storage: storages[0].id)
        XCTAssertEqual(Set(root.map(\.name)), ["DCIM", "Download", "Music", "Pictures", ".thumbnails"])
        XCTAssertTrue(root.allSatisfy(\.isFolder))
    }

    func testChunkedDownloadMatchesAndReportsProgress() throws {
        let device = MockMTPDevice()
        device.addStorage(id: 0x10001, name: "Internal")
        let payload = Data((0..<1_000_003).map { UInt8($0 % 251) })
        let handle = device.addFile("big.bin", storage: 0x10001, data: payload)
        let (session, _) = try makeSession(device)
        session.downloadChunk = 64 * 1024

        var received = Data()
        var lastProgress: UInt64 = 0
        try session.download(try session.objectInfo(handle), to: { received.append($0) }, progress: { done, _ in lastProgress = done })
        XCTAssertEqual(received, payload)
        XCTAssertEqual(lastProgress, UInt64(payload.count))
        XCTAssertTrue(device.operationLog.contains(OperationCode.getPartialObject64.rawValue))
        XCTAssertEqual(device.violations, [])
    }

    func testDownloadFallsBackToGetObjectWithoutPartialSupport() throws {
        let device = MockMTPDevice()
        device.supportsPartial64 = false
        device.addStorage(id: 0x10001, name: "Internal")
        // 512 - 12 bytes => container exactly one packet => device sends a ZLP after it.
        let payload = Data(repeating: 3, count: 500)
        let handle = device.addFile("aligned.bin", storage: 0x10001, data: payload)
        let (session, _) = try makeSession(device)
        var received = Data()
        try session.download(try session.objectInfo(handle), to: { received.append($0) })
        XCTAssertEqual(received, payload)
        // A following request must still work, i.e. the ZLP was consumed correctly.
        XCTAssertEqual(try session.storageIDs(), [0x10001])
    }

    func testUploadIsFramedCorrectly() throws {
        for size in [0, 1, 500, 512 * 1024 - 12, 512 * 1024, 1_300_000] {
            let device = MockMTPDevice()
            device.addStorage(id: 0x10001, name: "Internal")
            let (session, _) = try makeSession(device)
            let payload = Data((0..<size).map { UInt8($0 % 199) })
            var offset = 0
            let handle = try session.upload(
                storage: 0x10001, parent: rootParent, name: "up-\(size).bin", size: UInt64(size), modified: Date(),
                source: { n in
                    let end = min(offset + n, payload.count)
                    defer { offset = end }
                    return payload.subdata(in: offset..<end)
                })
            XCTAssertEqual(device.nodes[handle]?.data, payload, "size \(size)")
            XCTAssertEqual(device.violations, [], "size \(size)")
        }
    }

    func testCancelledUploadRemovesPartialFile() throws {
        let device = MockMTPDevice()
        device.addStorage(id: 0x10001, name: "Internal")
        let (session, _) = try makeSession(device)
        let token = CancelToken()
        var calls = 0
        XCTAssertThrowsError(try session.upload(
            storage: 0x10001, parent: rootParent, name: "big.bin", size: 4_000_000, modified: nil,
            source: { n in
                calls += 1
                if calls == 3 { token.cancel() }
                return Data(repeating: 1, count: n)
            }, cancel: token)) { XCTAssertEqual($0 as? MTPError, .cancelled) }
        XCTAssertEqual(device.cancelRequests.count, 1)
        XCTAssertNil(device.node(named: "big.bin"))
    }

    func testCreateFolderRenameAndDelete() throws {
        let (session, device) = try makeSession()
        let storage = try session.storageIDs()[0]
        let folder = try session.createFolder(storage: storage, parent: rootParent, name: "Backup")
        XCTAssertTrue(try session.objectInfo(folder).isFolder)
        try session.rename(folder, to: "Backups 2026")
        XCTAssertEqual(try session.objectInfo(folder).name, "Backups 2026")
        try session.delete(folder)
        XCTAssertNil(device.nodes[folder])
    }

    func testDeviceErrorSurfacesAsResponseError() throws {
        let (session, _) = try makeSession()
        XCTAssertThrowsError(try session.objectInfo(9999)) { error in
            guard case .response(let code, _) = error as? MTPError else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 0x2009)
        }
    }

    func testUnplugIsConnectionLost() throws {
        let (session, device) = try makeSession()
        device.unplug()
        XCTAssertThrowsError(try session.storageIDs()) { error in
            XCTAssertTrue((error as? MTPError)?.isConnectionLost ?? false)
        }
    }
}

final class PhotoImportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sendbay-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testFindsMediaUnderDCIMAndSkipsHidden() throws {
        let device = MockMTPDevice.sample()
        let dcim = device.node(named: "DCIM")!.handle
        let hidden = device.addFolder(".thumbnails", storage: 0x0001_0001, parent: dcim)
        device.addFile("thumb.jpg", storage: 0x0001_0001, parent: hidden, data: Data([1]))
        let session = MTPSession(transport: device)
        try session.open()
        let media = try PhotoImport.findMedia(in: session, storages: try session.storageIDs())
        XCTAssertEqual(media.count, 7)
        XCTAssertFalse(media.contains { $0.name == "thumb.jpg" })
    }

    func testPlanSkipsAlreadyImportedAndRenamesConflicts() throws {
        func obj(_ name: String, _ size: UInt64) -> ObjectInfo {
            ObjectInfo(handle: 1, storageID: 1, parent: 0, format: 0x3000, size: size, name: name, modified: nil)
        }
        try Data(count: 10).write(to: folder.appendingPathComponent("a.jpg"))   // same size: skip
        try Data(count: 99).write(to: folder.appendingPathComponent("b.jpg"))   // different: rename
        let plan = PhotoImport.plan([obj("a.jpg", 10), obj("b.jpg", 20), obj("c.mp4", 5)], into: folder)
        XCTAssertEqual(plan.map(\.destination.lastPathComponent), ["b (1).jpg", "c.mp4"])
    }

    func testIsMedia() {
        XCTAssertTrue(PhotoImport.isMedia("IMG_1.HEIC"))
        XCTAssertTrue(PhotoImport.isMedia("VID.mp4"))
        XCTAssertFalse(PhotoImport.isMedia("notes.txt"))
    }
}
