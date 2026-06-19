import FSKit
import Foundation

class NTFSItem: FSItem {
    let ino: UInt64
    init(ino: UInt64) {
        self.ino = ino
        super.init()
    }
}

class NTFSVolume: FSVolume, FSVolume.Operations, FSVolume.ReadWriteOperations {
    let client: NTFSDaemonClient
    let devicePath: String
    private(set) var isVolumeMounted = false
    
    private var blockSize: UInt32 = 4096
    private var totalBlocks: UInt64 = 62500000
    private var freeBlocks: UInt64 = 50000000
    
    // MARK: FSVolumePathConfOperations
    var maximumLinkCount: Int { return 1 }
    var maximumNameLength: Int { return 255 }
    var restrictsOwnershipChanges: Bool { return true }
    var truncatesLongNames: Bool { return false }
    
    // MARK: FSVolume.Operations Properties
    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsSymbolicLinks = false
        caps.supportsHardLinks = false
        caps.supportsJournal = false
        caps.supportsActiveJournal = false
        caps.doesNotSupportRootTimes = false
        caps.supportsSparseFiles = true
        caps.supportsZeroRuns = false
        caps.supportsFastStatFS = true
        caps.supports2TBFiles = true
        caps.supportsOpenDenyModes = false
        return caps
    }
    
    var volumeStatistics: FSStatFSResult {
        let stats = FSStatFSResult(fileSystemTypeName: "NTFS")
        stats.blockSize = Int(blockSize)
        stats.ioSize = 65536
        stats.totalBlocks = totalBlocks
        stats.availableBlocks = freeBlocks
        stats.freeBlocks = freeBlocks
        stats.usedBlocks = totalBlocks > freeBlocks ? totalBlocks - freeBlocks : 0
        stats.totalBytes = stats.totalBlocks * UInt64(stats.blockSize)
        stats.freeBytes = stats.freeBlocks * UInt64(stats.blockSize)
        stats.availableBytes = stats.availableBlocks * UInt64(stats.blockSize)
        stats.usedBytes = stats.usedBlocks * UInt64(stats.blockSize)
        return stats
    }
    
    init(volumeID: FSVolume.Identifier, volumeName: FSFileName, devicePath: String) throws {
        self.client = NTFSDaemonClient()
        self.devicePath = devicePath
        super.init(volumeID: volumeID, volumeName: volumeName)
    }
    
    func activate(options: FSTaskOptions) async throws -> FSItem {
        print("[NTFSVolume] Activating volume for \(devicePath)...")
        guard client.connect() else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTCONN), userInfo: nil)
        }
        
        var payload = Data()
        var devPath = devicePath
        if devPath.count < 128 {
            devPath = devPath.padding(toLength: 128, withPad: "\0", startingAt: 0)
        }
        payload.append(devPath.data(using: .utf8)!.prefix(128))
        
        guard let resp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_MOUNT.rawValue, payload: payload) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: nil)
        }
        
        let status = resp.readInt32(at: 0)
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(abs(status)), userInfo: nil)
        }
        
        let rootIno = resp.readUInt64(at: 4)
        
        if resp.count >= 32 {
            self.blockSize = resp.readUInt32(at: 12)
            self.totalBlocks = resp.readUInt64(at: 16)
            self.freeBlocks = resp.readUInt64(at: 24)
        }
        
        isVolumeMounted = true
        print("[NTFSVolume] Volume activated successfully. Root Inode: \(rootIno), Block Size: \(self.blockSize), Total Blocks: \(self.totalBlocks), Free Blocks: \(self.freeBlocks)")
        return NTFSItem(ino: rootIno)
    }
    
    func deactivate(options: FSDeactivateOptions) async throws {
        print("[NTFSVolume] Deactivating volume with options \(options.rawValue)...")
        if isVolumeMounted {
            let payload = Data(repeating: 0, count: 8)
            _ = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_UNMOUNT.rawValue, payload: payload)
            isVolumeMounted = false
        }
        client.disconnect()
    }
    
    func mount(options: FSTaskOptions) async throws {
        print("[NTFSVolume] mount(options:) called")
    }
    
    func unmount() async {
        print("[NTFSVolume] unmount() called")
    }
    
    func synchronize(flags: FSSyncFlags) async throws {
        print("[NTFSVolume] synchronize(flags: \(flags.rawValue)) called")
        let payload = Data(repeating: 0, count: 8)
        _ = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_SYNC.rawValue, payload: payload)
    }
    
    func reclaimItem(_ item: FSItem) async throws {
        // No-op for now
    }
    
    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest, linkContents: FSFileName) async throws -> (FSItem, FSFileName) {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP), userInfo: nil)
    }
    
    func createLink(to item: FSItem, named name: FSFileName, inDirectory directory: FSItem) async throws -> FSFileName {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP), userInfo: nil)
    }
    
    func readSymbolicLink(_ item: FSItem) async throws -> FSFileName {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP), userInfo: nil)
    }
    
    func lookupItem(named name: FSFileName, inDirectory directory: FSItem) async throws -> (FSItem, FSFileName) {
        let parentIno = (directory as! NTFSItem).ino
        guard let nameStr = name.string else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
        }
        
        var payload = Data()
        var parentVar = parentIno
        payload.append(Data(bytes: &parentVar, count: 8))
        var namePadding = nameStr
        if namePadding.count < 256 {
            namePadding = namePadding.padding(toLength: 256, withPad: "\0", startingAt: 0)
        }
        payload.append(namePadding.data(using: .utf8)!.prefix(256))
        
        guard let resp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_LOOKUP.rawValue, payload: payload) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: nil)
        }
        
        let status = resp.readInt32(at: 0)
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(abs(status)), userInfo: nil)
        }
        
        let ino = resp.readUInt64(at: 4)
        return (NTFSItem(ino: ino), name)
    }
    
    func attributes(_ desiredAttributes: FSItem.GetAttributesRequest, of item: FSItem) async throws -> FSItem.Attributes {
        let ino = (item as! NTFSItem).ino
        
        var payload = Data()
        var inoVar = ino
        payload.append(Data(bytes: &inoVar, count: 8))
        
        guard let resp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_GETATTR.rawValue, payload: payload) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: nil)
        }
        
        let status = resp.readInt32(at: 0)
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(abs(status)), userInfo: nil)
        }
        
        let size = resp.readUInt64(at: 4)
        let mode = resp.readUInt32(at: 12)
        let nlink = resp.readUInt32(at: 16)
        let mtime = resp.readUInt64(at: 20)
        let ctime = resp.readUInt64(at: 28)
        let atime = resp.readUInt64(at: 36)
        
        let attrs = FSItem.Attributes()
        attrs.uid = 501
        attrs.gid = 20
        attrs.mode = mode
        
        if (mode & UInt32(S_IFDIR)) != 0 {
            attrs.type = .directory
        } else if (mode & UInt32(S_IFLNK)) != 0 {
            attrs.type = .symlink
        } else {
            attrs.type = .file
        }
        
        attrs.linkCount = nlink
        attrs.size = size
        attrs.allocSize = size
        attrs.fileID = FSItem.Identifier(rawValue: ino)!
        attrs.parentID = FSItem.Identifier(rawValue: 5)!
        
        attrs.modifyTime = timespec(tv_sec: Int(mtime), tv_nsec: 0)
        attrs.changeTime = timespec(tv_sec: Int(ctime), tv_nsec: 0)
        attrs.accessTime = timespec(tv_sec: Int(atime), tv_nsec: 0)
        attrs.birthTime = timespec(tv_sec: Int(ctime), tv_nsec: 0)
        
        return attrs
    }
    
    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest, on item: FSItem) async throws -> FSItem.Attributes {
        let ino = (item as! NTFSItem).ino
        
        if newAttributes.isValid(.size) {
            let newSize = newAttributes.size
            var payload = Data()
            var inoVar = ino
            payload.append(Data(bytes: &inoVar, count: 8))
            var sizeVar = newSize
            payload.append(Data(bytes: &sizeVar, count: 8))
            
            guard let resp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_TRUNCATE.rawValue, payload: payload) else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: nil)
            }
            
            let status = resp.readInt32(at: 0)
            guard status == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(abs(status)), userInfo: nil)
            }
            
            newAttributes.consumedAttributes.insert(.size)
        }
        
        let req = FSItem.GetAttributesRequest()
        req.wantedAttributes = [.size, .mode, .type]
        return try await attributes(req, of: item)
    }
    
    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie, verifier: FSDirectoryVerifier, attributes: FSItem.GetAttributesRequest?, packer: FSDirectoryEntryPacker) async throws -> FSDirectoryVerifier {
        let ino = (directory as! NTFSItem).ino
        let offset = cookie.rawValue
        
        var payload = Data()
        var inoVar = ino
        payload.append(Data(bytes: &inoVar, count: 8))
        var offsetVar = offset
        payload.append(Data(bytes: &offsetVar, count: 8))
        
        guard let resp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_READDIR.rawValue, payload: payload) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: nil)
        }
        
        let status = resp.readInt32(at: 0)
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(abs(status)), userInfo: nil)
        }
        
        let count = resp.readUInt32(at: 4)
        
        var nextCookieVal = offset
        for i in 0..<Int(count) {
            let offsetBase = 8 + i * 268
            let entryIno = resp.readUInt64(at: offsetBase)
            let entryType = resp.readUInt32(at: offsetBase + 8)
            let entryName = resp.readString(at: offsetBase + 12, length: 256)
            
            nextCookieVal += 1
            
            let name = FSFileName(string: entryName)
            var itemType: FSItem.ItemType = .file
            if entryType == 4 {
                itemType = .directory
            } else if entryType == 10 {
                itemType = .symlink
            }
            
            let success = packer.packEntry(name: name,
                                           itemType: itemType,
                                           itemID: FSItem.Identifier(rawValue: entryIno)!,
                                           nextCookie: FSDirectoryCookie(rawValue: nextCookieVal),
                                           attributes: nil)
            if !success {
                break
            }
        }
        
        return verifier
    }
    
    func createItem(named name: FSFileName, type: FSItem.ItemType, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        let parentIno = (directory as! NTFSItem).ino
        guard let nameStr = name.string else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
        }
        
        var payload = Data()
        var parentVar = parentIno
        payload.append(Data(bytes: &parentVar, count: 8))
        var modeVar = UInt32(0)
        payload.append(Data(bytes: &modeVar, count: 4))
        var namePadding = nameStr
        if namePadding.count < 256 {
            namePadding = namePadding.padding(toLength: 256, withPad: "\0", startingAt: 0)
        }
        payload.append(namePadding.data(using: .utf8)!.prefix(256))
        
        let msgType = type == .directory ? ntfs_msg_type.NTFS_MSG_MKDIR.rawValue : ntfs_msg_type.NTFS_MSG_CREATE.rawValue
        
        guard let resp = client.sendRequest(type: UInt32(msgType), payload: payload) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: nil)
        }
        
        let status = resp.readInt32(at: 0)
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(abs(status)), userInfo: nil)
        }
        
        let ino = resp.readUInt64(at: 4)
        return (NTFSItem(ino: ino), name)
    }
    
    func createDirectory(named name: FSFileName, inDirectory directory: FSItem, attributes: FSItem.SetAttributesRequest) async throws -> (FSItem, FSFileName) {
        return try await createItem(named: name, type: .directory, inDirectory: directory, attributes: attributes)
    }
    
    func removeItem(_ item: FSItem, named name: FSFileName, fromDirectory directory: FSItem) async throws -> Void {
        let parentIno = (directory as! NTFSItem).ino
        guard let nameStr = name.string else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
        }
        
        var payload = Data()
        var parentVar = parentIno
        payload.append(Data(bytes: &parentVar, count: 8))
        var namePadding = nameStr
        if namePadding.count < 256 {
            namePadding = namePadding.padding(toLength: 256, withPad: "\0", startingAt: 0)
        }
        payload.append(namePadding.data(using: .utf8)!.prefix(256))
        
        let attrs = try await attributes(FSItem.GetAttributesRequest(), of: item)
        let msgType = attrs.type == .directory ? ntfs_msg_type.NTFS_MSG_RMDIR.rawValue : ntfs_msg_type.NTFS_MSG_UNLINK.rawValue
        
        guard let resp = client.sendRequest(type: UInt32(msgType), payload: payload) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: nil)
        }
        
        let status = resp.readInt32(at: 0)
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(abs(status)), userInfo: nil)
        }
    }
    
    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem, named sourceName: FSFileName, to destinationName: FSFileName, inDirectory destinationDirectory: FSItem, overItem: FSItem?) async throws -> FSFileName {
        let oldParentIno = (sourceDirectory as! NTFSItem).ino
        let newParentIno = (destinationDirectory as! NTFSItem).ino
        
        guard let oldNameStr = sourceName.string, let newNameStr = destinationName.string else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EINVAL), userInfo: nil)
        }
        
        var payload = Data()
        var oldParentVar = oldParentIno
        payload.append(Data(bytes: &oldParentVar, count: 8))
        var newParentVar = newParentIno
        payload.append(Data(bytes: &newParentVar, count: 8))
        
        var oldNamePadding = oldNameStr
        if oldNamePadding.count < 256 {
            oldNamePadding = oldNamePadding.padding(toLength: 256, withPad: "\0", startingAt: 0)
        }
        payload.append(oldNamePadding.data(using: .utf8)!.prefix(256))
        
        var newNamePadding = newNameStr
        if newNamePadding.count < 256 {
            newNamePadding = newNamePadding.padding(toLength: 256, withPad: "\0", startingAt: 0)
        }
        payload.append(newNamePadding.data(using: .utf8)!.prefix(256))
        
        guard let resp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_RENAME.rawValue, payload: payload) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: nil)
        }
        
        let status = resp.readInt32(at: 0)
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(abs(status)), userInfo: nil)
        }
        
        return destinationName
    }
    
    // MARK: FSVolume.ReadWriteOperations
    
    func read(from item: FSItem, at offset: off_t, length: Int, into buffer: FSMutableFileDataBuffer) async throws -> Int {
        let ino = (item as! NTFSItem).ino
        
        var payload = Data()
        var inoVar = ino
        payload.append(Data(bytes: &inoVar, count: 8))
        var offsetVar = offset
        payload.append(Data(bytes: &offsetVar, count: 8))
        var lengthVar = UInt32(length)
        payload.append(Data(bytes: &lengthVar, count: 4))
        
        guard let resp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_READ.rawValue, payload: payload) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: nil)
        }
        
        let status = resp.readInt32(at: 0)
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(abs(status)), userInfo: nil)
        }
        
        let bytesRead = Int(resp.readUInt32(at: 4))
        if bytesRead > 0 {
            let dataStartOffset = 8
            resp.withUnsafeBytes { ptr in
                let src = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self) + dataStartOffset
                buffer.withUnsafeMutableBytes { dstPtr in
                    if let dst = dstPtr.baseAddress {
                        memcpy(dst, src, bytesRead)
                    }
                }
            }
        }
        
        return bytesRead
    }
    
    func write(contents: Data, to item: FSItem, at offset: off_t) async throws -> Int {
        let ino = (item as! NTFSItem).ino
        
        var payload = Data()
        var inoVar = ino
        payload.append(Data(bytes: &inoVar, count: 8))
        var offsetVar = offset
        payload.append(Data(bytes: &offsetVar, count: 8))
        var sizeVar = UInt32(contents.count)
        payload.append(Data(bytes: &sizeVar, count: 4))
        payload.append(contents)
        
        guard let resp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_WRITE.rawValue, payload: payload) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO), userInfo: nil)
        }
        
        let status = resp.readInt32(at: 0)
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(abs(status)), userInfo: nil)
        }
        
        let bytesWritten = Int(resp.readUInt32(at: 4))
        return bytesWritten
    }
}
