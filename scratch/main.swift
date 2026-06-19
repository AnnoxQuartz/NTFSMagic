import Foundation

print("Starting NTFS Magic IPC Test...")
let client = NTFSDaemonClient(socketPath: "/tmp/ntfsmagicd.sock")

print("Connecting to daemon socket...")
guard client.connect() else {
    print("Error: Could not connect to daemon socket at /tmp/ntfsmagicd.sock.")
    print("Make sure the helper daemon is running as root:")
    print("sudo /Library/PrivilegedHelperTools/ntfsmagicd")
    exit(1)
}
print("Connected!")

// 1. Mount /dev/disk4s1
print("Sending mount request for /dev/disk4s1...")
var mountPayload = Data()
var devPath = "/dev/disk4s1"
if devPath.count < 128 {
    devPath = devPath.padding(toLength: 128, withPad: "\0", startingAt: 0)
}
mountPayload.append(devPath.data(using: .utf8)!.prefix(128))

guard let mountResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_MOUNT.rawValue, payload: mountPayload) else {
    print("Error: Mount request failed.")
    exit(1)
}

let status = mountResp.readInt32(at: 0)
guard status == 0 else {
    print("Error: Mount returned status code: \(status) (POSIX error \(abs(status))).")
    if status == -EPERM {
        print("Note: Mount was rejected (permission denied).")
    }
    exit(1)
}

let rootIno = mountResp.readUInt64(at: 4)
print("Mount successful! Root inode: \(rootIno)")

// 2. Create/Write a file named "test_magic.txt"
let fileName = "test_magic.txt"
print("Checking if '\(fileName)' already exists...")

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
    print("File '\(fileName)' exists (inode \(fileIno)). We will write new contents into it.")
} else {
    print("File '\(fileName)' not found. Creating file...")
    var createPayload = Data()
    var parentVar = rootIno
    createPayload.append(Data(bytes: &parentVar, count: 8))
    var modeVar = UInt32(0)
    createPayload.append(Data(bytes: &modeVar, count: 4))
    createPayload.append(namePadding.data(using: .utf8)!.prefix(256))
    
    guard let createResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_CREATE.rawValue, payload: createPayload) else {
        print("Error: Create request failed.")
        exit(1)
    }
    
    let createStatus = createResp.readInt32(at: 0)
    guard createStatus == 0 else {
        print("Error: Create failed with status \(createStatus).")
        exit(1)
    }
    fileIno = createResp.readUInt64(at: 4)
    print("File created successfully! Inode: \(fileIno)")
}

// 3. Write data
let testContent = "Hello NTFS! Written via NTFS Magic on \(Date()).\n"
print("Writing test content to file...")
let contentData = testContent.data(using: .utf8)!

var writePayload = Data()
var fileInoVar = fileIno
writePayload.append(Data(bytes: &fileInoVar, count: 8))
var offsetVar = UInt64(0)
writePayload.append(Data(bytes: &offsetVar, count: 8))
var sizeVar = UInt32(contentData.count)
writePayload.append(Data(bytes: &sizeVar, count: 4))
writePayload.append(contentData)

guard let writeResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_WRITE.rawValue, payload: writePayload) else {
    print("Error: Write request failed.")
    exit(1)
}

let writeStatus = writeResp.readInt32(at: 0)
guard writeStatus == 0 else {
    print("Error: Write failed with status \(writeStatus).")
    exit(1)
}
let written = writeResp.readUInt32(at: 4)
print("Successfully wrote \(written) bytes.")

// 4. Read back data
print("Reading file back to verify...")
var readPayload = Data()
var fileInoVar2 = fileIno
readPayload.append(Data(bytes: &fileInoVar2, count: 8))
var offsetVar2 = UInt64(0)
readPayload.append(Data(bytes: &offsetVar2, count: 8))
var readSizeVar = UInt32(512)
readPayload.append(Data(bytes: &readSizeVar, count: 4))

guard let readResp = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_READ.rawValue, payload: readPayload) else {
    print("Error: Read request failed.")
    exit(1)
}

let readStatus = readResp.readInt32(at: 0)
guard readStatus == 0 else {
    print("Error: Read failed with status \(readStatus).")
    exit(1)
}
let bytesRead = readResp.readUInt32(at: 4)
let readText = readResp.readString(at: 8, length: Int(bytesRead))
print("Read back \(bytesRead) bytes:")
print("------------------------------")
print(readText)
print("------------------------------")

// 5. Unmount
print("Unmounting...")
var unmountPayload = Data(repeating: 0, count: 8)
_ = client.sendRequest(type: ntfs_msg_type.NTFS_MSG_UNMOUNT.rawValue, payload: unmountPayload)
print("Unmounted. Test complete.")
