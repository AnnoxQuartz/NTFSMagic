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
        _ = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_UNLINK.rawValue, payload: unlinkFilePayload)
        
        var unlinkRenamedPayload = Data()
        var existingDirInoVar2 = existingDirIno
        unlinkRenamedPayload.append(Data(bytes: &existingDirInoVar2, count: 8))
        unlinkRenamedPayload.append(namePaddingRenamed.data(using: .utf8)!.prefix(256))
        _ = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_UNLINK.rawValue, payload: unlinkRenamedPayload)
        
        // rmdir test_dir
        var rmdirPayload = Data()
        var rootVarTemp2 = rootIno
        rmdirPayload.append(Data(bytes: &rootVarTemp2, count: 8))
        rmdirPayload.append(namePaddingDir.data(using: .utf8)!.prefix(256))
        _ = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_RMDIR.rawValue, payload: rmdirPayload)
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
    var writePayload = Data()
    var fileInoVar = fileIno
    writePayload.append(Data(bytes: &fileInoVar, count: 8))
    var offsetVar = UInt64(0)
    writePayload.append(Data(bytes: &offsetVar, count: 8))
    var sizeVar = UInt32(contentData.count)
    writePayload.append(Data(bytes: &sizeVar, count: 4))
    writePayload.append(contentData)
    
    guard let writeResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_WRITE.rawValue, payload: writePayload),
          writeResp.readInt32(at: 0) == 0 else {
        print("Sanity failed: WRITE failed.")
        exit(1)
    }
    print("Successfully wrote \(writeResp.readUInt32(at: 4)) bytes.")
    
    // 4. Read data back (READ)
    print("Reading data back...")
    var readPayload = Data()
    var fileInoVar2 = fileIno
    readPayload.append(Data(bytes: &fileInoVar2, count: 8))
    var offsetVar2 = UInt64(0)
    readPayload.append(Data(bytes: &offsetVar2, count: 8))
    var readSizeVar = UInt32(512)
    readPayload.append(Data(bytes: &readSizeVar, count: 4))
    
    guard let readResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_READ.rawValue, payload: readPayload),
          readResp.readInt32(at: 0) == 0 else {
        print("Sanity failed: READ failed.")
        exit(1)
    }
    let bytesRead = readResp.readUInt32(at: 4)
    let readText = readResp.readString(at: 8, length: Int(bytesRead))
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
    guard let readResp2 = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_READ.rawValue, payload: readPayload),
          readResp2.readInt32(at: 0) == 0 else {
        print("Sanity failed: READ after truncate failed.")
        exit(1)
    }
    let bytesRead2 = readResp2.readUInt32(at: 4)
    let readText2 = readResp2.readString(at: 8, length: Int(bytesRead2))
    print("Read back content (truncated): '\(readText2)'")
    guard bytesRead2 == 6 && readText2 == "Sanity" else {
        print("Sanity failed: Truncated content is '\(readText2)' of size \(bytesRead2), expected 'Sanity' of size 6")
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
    
    guard let rmdirResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_RMDIR.rawValue, payload: rmdirPayload),
          rmdirResp.readInt32(at: 0) == 0 else {
        print("Sanity failed: RMDIR failed.")
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
    guard status == 0 else {
        print("Error: Mount returned \(status).")
        exit(1)
    }
    let rootIno = mountResp.readUInt64(at: 4)
    print("Mounted successfully. Root inode: \(rootIno)")
    
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
            var writePayload = Data()
            var fileInoVar = fileIno
            writePayload.append(Data(bytes: &fileInoVar, count: 8))
            var offsetVar = offset
            writePayload.append(Data(bytes: &offsetVar, count: 8))
            var sizeVar = UInt32(chunkSize)
            writePayload.append(Data(bytes: &sizeVar, count: 4))
            writePayload.append(randomBuffer)
            
            guard let writeResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_WRITE.rawValue, payload: writePayload),
                  writeResp.readInt32(at: 0) == 0 else {
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
            var readPayload = Data()
            var fileInoVar2 = fileIno
            readPayload.append(Data(bytes: &fileInoVar2, count: 8))
            var offsetVar2 = offset
            readPayload.append(Data(bytes: &offsetVar2, count: 8))
            var readSizeVar = UInt32(chunkSize)
            readPayload.append(Data(bytes: &readSizeVar, count: 4))
            
            guard let readResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_READ.rawValue, payload: readPayload),
                  readResp.readInt32(at: 0) == 0 else {
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
