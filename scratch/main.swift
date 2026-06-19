import Foundation

func runSanityTests(client: NTFSDaemonClient, rootIno: UInt64) {
    print("\n=== Running Sanity Tests ===")
    
    let dirName = "test_dir"
    let fileName = "nested_file.txt"
    let renamedFileName = "renamed_file.txt"
    let textContent = "Sanity Check!"
    
    var namePaddingDir = dirName
    if namePaddingDir.count < 256 {
        namePaddingDir = namePaddingDir.padding(toLength: 256, withPad: "\0", startingAt: 0)
    }
    
    var namePaddingFile = fileName
    if namePaddingFile.count < 256 {
        namePaddingFile = namePaddingFile.padding(toLength: 256, withPad: "\0", startingAt: 0)
    }
    
    var namePaddingRenamed = renamedFileName
    if namePaddingRenamed.count < 256 {
        namePaddingRenamed = namePaddingRenamed.padding(toLength: 256, withPad: "\0", startingAt: 0)
    }
    
    // Cleanup existing test_dir if left over from previous failed run
    var lookupDirPayload = Data()
    var rootVarTemp = rootIno
    lookupDirPayload.append(Data(bytes: &rootVarTemp, count: 8))
    lookupDirPayload.append(namePaddingDir.data(using: .utf8)!.prefix(256))
    if let lookupDirResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_LOOKUP.rawValue, payload: lookupDirPayload),
       lookupDirResp.readInt32(at: 0) == 0 {
        let existingDirIno = lookupDirResp.readUInt64(at: 4)
        print("Cleaning up old 'test_dir' (inode \(existingDirIno)) from previous run...")
        
        // Read directory entries for diagnostics
        var readdirPayload = Data()
        var existingDirInoVarTemp = existingDirIno
        readdirPayload.append(Data(bytes: &existingDirInoVarTemp, count: 8))
        var offsetVarTemp = UInt64(0)
        readdirPayload.append(Data(bytes: &offsetVarTemp, count: 8))
        if let readdirResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_READDIR.rawValue, payload: readdirPayload),
           readdirResp.readInt32(at: 0) == 0 {
            let count = readdirResp.readUInt32(at: 4)
            print("Cleanup: 'test_dir' contains \(count) entries:")
            for i in 0..<Int(count) {
                let offsetBase = 8 + i * 268
                let entryName = readdirResp.readString(at: offsetBase + 12, length: 256)
                print(" - \(entryName)")
            }
        }
        
        // Try to unlink both files just in case
        var unlinkFilePayload = Data()
        var existingDirInoVar = existingDirIno
        unlinkFilePayload.append(Data(bytes: &existingDirInoVar, count: 8))
        unlinkFilePayload.append(namePaddingFile.data(using: .utf8)!.prefix(256))
        if let unlinkResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_UNLINK.rawValue, payload: unlinkFilePayload) {
            let status = unlinkResp.readInt32(at: 0)
            print("Cleanup: Unlink nested_file.txt returned \(status)")
        }
        
        var unlinkRenamedPayload = Data()
        var existingDirInoVar2 = existingDirIno
        unlinkRenamedPayload.append(Data(bytes: &existingDirInoVar2, count: 8))
        unlinkRenamedPayload.append(namePaddingRenamed.data(using: .utf8)!.prefix(256))
        if let unlinkRenamedResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_UNLINK.rawValue, payload: unlinkRenamedPayload) {
            let status = unlinkRenamedResp.readInt32(at: 0)
            print("Cleanup: Unlink renamed_file.txt returned \(status)")
        }
        
        // rmdir test_dir
        var rmdirPayload = Data()
        var rootVarTemp2 = rootIno
        rmdirPayload.append(Data(bytes: &rootVarTemp2, count: 8))
        rmdirPayload.append(namePaddingDir.data(using: .utf8)!.prefix(256))
        if let rmdirResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_RMDIR.rawValue, payload: rmdirPayload) {
            let status = rmdirResp.readInt32(at: 0)
            print("Cleanup: RMDIR test_dir returned \(status)")
        }
    }

    // 1. Create Directory (MKDIR)
    print("Creating directory '\(dirName)'...")
    var mkdirPayload = Data()
    var rootVar = rootIno
    mkdirPayload.append(Data(bytes: &rootVar, count: 8))
    mkdirPayload.append(namePaddingDir.data(using: .utf8)!.prefix(256))
    
    guard let mkdirResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_MKDIR.rawValue, payload: mkdirPayload) else {
        print("Sanity failed: MKDIR request failed.")
        exit(1)
    }
    let mkdirStatus = mkdirResp.readInt32(at: 0)
    guard mkdirStatus == 0 else {
        print("Sanity failed: MKDIR failed with status \(mkdirStatus) (POSIX error \(abs(mkdirStatus))).")
        exit(1)
    }
    let dirIno = mkdirResp.readUInt64(at: 4)
    print("Directory created. Inode: \(dirIno)")
    
    // 2. Create File (CREATE)
    print("Creating nested file '\(fileName)' in test_dir...")
    var createPayload = Data()
    var dirInoVar = dirIno
    createPayload.append(Data(bytes: &dirInoVar, count: 8))
    var modeVar = UInt32(0)
    createPayload.append(Data(bytes: &modeVar, count: 4))
    createPayload.append(namePaddingFile.data(using: .utf8)!.prefix(256))
    
    guard let createResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_CREATE.rawValue, payload: createPayload) else {
        print("Sanity failed: CREATE request failed.")
        exit(1)
    }
    let createStatus = createResp.readInt32(at: 0)
    guard createStatus == 0 else {
        print("Sanity failed: CREATE failed with status \(createStatus) (POSIX error \(abs(createStatus))).")
        exit(1)
    }
    let fileIno = createResp.readUInt64(at: 4)
    print("File created. Inode: \(fileIno)")
    
    // 3. Write data to nested file (WRITE)
    print("Writing contents to nested file...")
    let contentData = textContent.data(using: .utf8)!
    let bytesWritten = client.writeData(ino: fileIno, contents: contentData, offset: 0)
    guard bytesWritten == contentData.count else {
        print("Sanity failed: WRITE failed.")
        exit(1)
    }
    print("Successfully wrote \(bytesWritten) bytes.")
    
    // 4. Read data back (READ)
    print("Reading data back...")
    guard let readData = client.readData(ino: fileIno, offset: 0, length: 512) else {
        print("Sanity failed: READ failed.")
        exit(1)
    }
    let readText = String(data: readData, encoding: .utf8) ?? ""
    print("Read back content: '\(readText)'")
    guard readText == textContent else {
        print("Sanity failed: Read content doesn't match written content.")
        exit(1)
    }
    
    // 5. Truncate (TRUNCATE)
    print("Truncating file to 6 bytes...")
    var truncPayload = Data()
    var fileInoVar3 = fileIno
    truncPayload.append(Data(bytes: &fileInoVar3, count: 8))
    var truncSizeVar = UInt64(6)
    truncPayload.append(Data(bytes: &truncSizeVar, count: 8))
    
    guard let truncResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_TRUNCATE.rawValue, payload: truncPayload),
          truncResp.readInt32(at: 0) == 0 else {
        print("Sanity failed: TRUNCATE failed.")
        exit(1)
    }
    
    // Read back after truncate
    print("Reading back after truncate...")
    guard let readData2 = client.readData(ino: fileIno, offset: 0, length: 512) else {
        print("Sanity failed: READ after truncate failed.")
        exit(1)
    }
    let readText2 = String(data: readData2, encoding: .utf8) ?? ""
    print("Read back content (truncated): '\(readText2)'")
    guard readData2.count == 6 && readText2 == "Sanity" else {
        print("Sanity failed: Truncated content is '\(readText2)' of size \(readData2.count), expected 'Sanity' of size 6")
        exit(1)
    }
    
    // 6. Rename (RENAME)
    print("Renaming '\(fileName)' to '\(renamedFileName)'...")
    var renamePayload = Data()
    var oldParentVar = dirIno
    renamePayload.append(Data(bytes: &oldParentVar, count: 8))
    var newParentVar = dirIno
    renamePayload.append(Data(bytes: &newParentVar, count: 8))
    renamePayload.append(namePaddingFile.data(using: .utf8)!.prefix(256))
    renamePayload.append(namePaddingRenamed.data(using: .utf8)!.prefix(256))
    
    guard let renameResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_RENAME.rawValue, payload: renamePayload) else {
        print("Sanity failed: RENAME request failed.")
        exit(1)
    }
    let renameStatus = renameResp.readInt32(at: 0)
    guard renameStatus == 0 else {
        print("Sanity failed: RENAME failed with status \(renameStatus) (POSIX error \(abs(renameStatus))).")
        exit(1)
    }
    print("Rename successful.")
    
    // 7. Readdir (READDIR)
    print("Listing directory content...")
    var readdirPayload = Data()
    var dirInoVar2 = dirIno
    readdirPayload.append(Data(bytes: &dirInoVar2, count: 8))
    var offsetVar3 = UInt64(0)
    readdirPayload.append(Data(bytes: &offsetVar3, count: 8))
    
    guard let readdirResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_READDIR.rawValue, payload: readdirPayload),
          readdirResp.readInt32(at: 0) == 0 else {
        print("Sanity failed: READDIR failed.")
        exit(1)
    }
    let count = readdirResp.readUInt32(at: 4)
    print("Directory contains \(count) entries:")
    var foundRenamed = false
    for i in 0..<Int(count) {
        let offsetBase = 8 + i * 268
        let entryName = readdirResp.readString(at: offsetBase + 12, length: 256)
        print(" - \(entryName)")
        if entryName == renamedFileName {
            foundRenamed = true
        }
    }
    guard foundRenamed else {
        print("Sanity failed: Renamed file not found in directory listing.")
        exit(1)
    }
    // 7b. Symlink and Readlink Test
    print("Creating symlink 'test_symlink' pointing to '\(renamedFileName)'...")
    var symlinkPayload = Data()
    var dirInoVar4 = dirIno
    symlinkPayload.append(Data(bytes: &dirInoVar4, count: 8))
    var namePaddingSymlink = "test_symlink"
    if namePaddingSymlink.count < 256 {
        namePaddingSymlink = namePaddingSymlink.padding(toLength: 256, withPad: "\0", startingAt: 0)
    }
    symlinkPayload.append(namePaddingSymlink.data(using: .utf8)!.prefix(256))
    
    var linkTargetPadding = renamedFileName
    if linkTargetPadding.count < 1024 {
        linkTargetPadding = linkTargetPadding.padding(toLength: 1024, withPad: "\0", startingAt: 0)
    }
    symlinkPayload.append(linkTargetPadding.data(using: .utf8)!.prefix(1024))
    
    guard let symlinkResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_SYMLINK.rawValue, payload: symlinkPayload) else {
        print("Sanity failed: SYMLINK request failed.")
        exit(1)
    }
    let symlinkStatus = symlinkResp.readInt32(at: 0)
    guard symlinkStatus == 0 else {
        print("Sanity failed: SYMLINK failed with status \(symlinkStatus).")
        exit(1)
    }
    let symlinkIno = symlinkResp.readUInt64(at: 4)
    print("Symlink created. Inode: \(symlinkIno)")
    
    print("Reading symlink target...")
    var readlinkPayload = Data()
    var symlinkInoVar = symlinkIno
    readlinkPayload.append(Data(bytes: &symlinkInoVar, count: 8))
    
    guard let readlinkResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_READLINK.rawValue, payload: readlinkPayload) else {
        print("Sanity failed: READLINK request failed.")
        exit(1)
    }
    let readlinkStatus = readlinkResp.readInt32(at: 0)
    guard readlinkStatus == 0 else {
        print("Sanity failed: READLINK failed with status \(readlinkStatus).")
        exit(1)
    }
    let targetText = readlinkResp.readString(at: 4, length: 1024)
    print("Readlink target: '\(targetText)'")
    guard targetText == renamedFileName else {
        print("Sanity failed: Readlink target '\(targetText)' doesn't match expected '\(renamedFileName)'.")
        exit(1)
    }
    
    print("Deleting symlink...")
    var unlinkSymlinkPayload = Data()
    var dirInoVar5 = dirIno
    unlinkSymlinkPayload.append(Data(bytes: &dirInoVar5, count: 8))
    unlinkSymlinkPayload.append(namePaddingSymlink.data(using: .utf8)!.prefix(256))
    guard let unlinkSymlinkResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_UNLINK.rawValue, payload: unlinkSymlinkPayload),
          unlinkSymlinkResp.readInt32(at: 0) == 0 else {
        print("Sanity failed: UNLINK symlink failed.")
        exit(1)
    }
    print("Symlink deleted successfully.")
    
    // 8. Delete file (UNLINK)
    print("Deleting renamed file...")
    var unlinkPayload = Data()
    var dirInoVar3 = dirIno
    unlinkPayload.append(Data(bytes: &dirInoVar3, count: 8))
    unlinkPayload.append(namePaddingRenamed.data(using: .utf8)!.prefix(256))
    
    guard let unlinkResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_UNLINK.rawValue, payload: unlinkPayload),
          unlinkResp.readInt32(at: 0) == 0 else {
        print("Sanity failed: UNLINK failed.")
        exit(1)
    }
    print("File deleted successfully.")
    
    // 9. Delete directory (RMDIR)
    print("Deleting directory...")
    var rmdirPayload = Data()
    var rootVar2 = rootIno
    rmdirPayload.append(Data(bytes: &rootVar2, count: 8))
    rmdirPayload.append(namePaddingDir.data(using: .utf8)!.prefix(256))
    
    guard let rmdirResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_RMDIR.rawValue, payload: rmdirPayload) else {
        print("Sanity failed: RMDIR request failed.")
        exit(1)
    }
    let rmdirStatus = rmdirResp.readInt32(at: 0)
    guard rmdirStatus == 0 else {
        print("Sanity failed: RMDIR failed with status \(rmdirStatus) (POSIX error \(abs(rmdirStatus))).")
        exit(1)
    }
    print("Directory deleted successfully.")
    
    // 10. Send sync (SYNC)
    print("Sending sync request...")
    var syncPayload = Data(repeating: 0, count: 8)
    guard let syncResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_SYNC.rawValue, payload: syncPayload),
          syncResp.readInt32(at: 0) == 0 else {
        print("Sanity failed: SYNC failed.")
        exit(1)
    }
    print("Sync complete.")
    print("=== Sanity Tests Passed! ===\n")
}

func runBenchmark() {
    print("=== NTFS Magic Benchmark ===")
    let client = NTFSDaemonClient(socketPath: "/tmp/ntfsmagicd.sock")
    
    print("Connecting to daemon...")
    guard client.connect() else {
        print("Error: Could not connect to daemon socket.")
        exit(1)
    }
    
    // 1. Mount
    var mountPayload = Data()
    var devPath = "/dev/disk4s1"
    if devPath.count < 128 {
        devPath = devPath.padding(toLength: 128, withPad: "\0", startingAt: 0)
    }
    mountPayload.append(devPath.data(using: .utf8)!.prefix(128))
    
    guard let mountResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_MOUNT.rawValue, payload: mountPayload) else {
        print("Error: Mount failed.")
        exit(1)
    }
    let status = mountResp.readInt32(at: 0)
    guard status == 0 || status == -16 else {
        print("Error: Mount returned \(status).")
        exit(1)
    }
    var rootIno = mountResp.readUInt64(at: 4)
    if status == -16 && rootIno == 0 {
        rootIno = 5
    }
    print("Mounted successfully. Root inode: \(rootIno)")
    
    if mountResp.count >= 160 {
        let shmPath = mountResp.readString(at: 32, length: 128)
        let cleanPath = shmPath.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        if !cleanPath.isEmpty {
            client.setupShm(path: cleanPath)
            print("Mapped shared memory for test/benchmark: \(cleanPath)")
        }
    }
    
    // Check if there is block size / disk size returned
    if mountResp.count >= 32 {
        let blockSize = mountResp.readUInt32(at: 12)
        let totalBlocks = mountResp.readUInt64(at: 16)
        let freeBlocks = mountResp.readUInt64(at: 24)
        print("Daemon reports size info:")
        print(" - Block size: \(blockSize) bytes")
        print(" - Total blocks: \(totalBlocks) (\(Double(totalBlocks * UInt64(blockSize)) / 1_000_000_000.0) GB)")
        print(" - Free blocks: \(freeBlocks) (\(Double(freeBlocks * UInt64(blockSize)) / 1_000_000_000.0) GB)")
    } else {
        print("Daemon does not yet report size info in mount response.")
    }
    
    // Run Sanity Tests before Benchmark
    runSanityTests(client: client, rootIno: rootIno)
    
    let fileName = "benchmark.bin"
    
    // Lookup/create file
    var lookupPayload = Data()
    var rootVar = rootIno
    lookupPayload.append(Data(bytes: &rootVar, count: 8))
    var namePadding = fileName
    if namePadding.count < 256 {
        namePadding = namePadding.padding(toLength: 256, withPad: "\0", startingAt: 0)
    }
    lookupPayload.append(namePadding.data(using: .utf8)!.prefix(256))
    
    var fileIno: UInt64 = 0
    if let lookupResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_LOOKUP.rawValue, payload: lookupPayload),
       lookupResp.readInt32(at: 0) == 0 {
        fileIno = lookupResp.readUInt64(at: 4)
    } else {
        var createPayload = Data()
        var parentVar = rootIno
        createPayload.append(Data(bytes: &parentVar, count: 8))
        var modeVar = UInt32(0)
        createPayload.append(Data(bytes: &modeVar, count: 4))
        createPayload.append(namePadding.data(using: .utf8)!.prefix(256))
        
        guard let createResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_CREATE.rawValue, payload: createPayload),
              createResp.readInt32(at: 0) == 0 else {
            print("Error: Could not create benchmark file.")
            exit(1)
        }
        fileIno = createResp.readUInt64(at: 4)
    }
    
    // Perform benchmark
    let totalSize = 20 * 1024 * 1024 // 20 MB for quick test
    let chunkSizes = [64 * 1024, 256 * 1024, 1024 * 1024] // different chunk sizes
    
    for chunkSize in chunkSizes {
        print("\n--- Testing Chunk Size: \(chunkSize / 1024) KB ---")
        
        // 1. Write Benchmark
        let randomBuffer = Data(repeating: 0x41, count: chunkSize) // 'A'
        let numChunks = totalSize / chunkSize
        
        print("Writing \(totalSize / (1024 * 1024)) MB sequentially...")
        let writeStart = Date()
        var offset: UInt64 = 0
        
        for _ in 0..<numChunks {
            let bytesWritten = client.writeData(ino: fileIno, contents: randomBuffer, offset: Int64(offset))
            guard bytesWritten == chunkSize else {
                print("Error during write benchmark at offset \(offset)")
                exit(1)
            }
            offset += UInt64(chunkSize)
        }
        let writeDuration = Date().timeIntervalSince(writeStart)
        let writeSpeed = Double(totalSize) / (1024.0 * 1024.0) / writeDuration
        print("Write: \(String(format: "%.2f", writeDuration)) seconds (\(String(format: "%.2f", writeSpeed)) MB/s)")
        
        // 2. Read Benchmark
        print("Reading \(totalSize / (1024 * 1024)) MB sequentially...")
        let readStart = Date()
        offset = 0
        
        for _ in 0..<numChunks {
            guard let _ = client.readData(ino: fileIno, offset: Int64(offset), length: chunkSize) else {
                print("Error during read benchmark at offset \(offset)")
                exit(1)
            }
            offset += UInt64(chunkSize)
        }
        let readDuration = Date().timeIntervalSince(readStart)
        let readSpeed = Double(totalSize) / (1024.0 * 1024.0) / readDuration
        print("Read:  \(String(format: "%.2f", readDuration)) seconds (\(String(format: "%.2f", readSpeed)) MB/s)")
    }
    
    // Clean up
    print("\nCleaning up benchmark file...")
    var unlinkPayload = Data()
    var rootVar2 = rootIno
    unlinkPayload.append(Data(bytes: &rootVar2, count: 8))
    unlinkPayload.append(namePadding.data(using: .utf8)!.prefix(256))
    _ = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_UNLINK.rawValue, payload: unlinkPayload)
    
    // Unmount
    print("Unmounting...")
    var unmountPayload = Data(repeating: 0, count: 8)
    _ = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_UNMOUNT.rawValue, payload: unmountPayload)
    print("Benchmark complete!")
}

runBenchmark()
