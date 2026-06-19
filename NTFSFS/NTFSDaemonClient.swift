import Foundation
import FSKit

enum ntfs_msg_type: UInt32 {
    case NTFS_MSG_MOUNT = 1
    case NTFS_MSG_UNMOUNT
    case NTFS_MSG_GETATTR
    case NTFS_MSG_LOOKUP
    case NTFS_MSG_READDIR
    case NTFS_MSG_READ
    case NTFS_MSG_WRITE
    case NTFS_MSG_CREATE
    case NTFS_MSG_MKDIR
    case NTFS_MSG_UNLINK
    case NTFS_MSG_RMDIR
    case NTFS_MSG_RENAME
    case NTFS_MSG_TRUNCATE
    case NTFS_MSG_SYNC
    case NTFS_MSG_SYMLINK
    case NTFS_MSG_READLINK
    case NTFS_MSG_CHECK
    case NTFS_MSG_FORMAT
}

struct ntfs_msg_header {
    var length: UInt32
    var type: UInt32
    var request_id: UInt64
}

struct ntfs_msg_read_req {
    var ino: UInt64
    var offset: UInt64
    var size: UInt32
}

struct ntfs_msg_write_req_shm {
    var ino: UInt64
    var offset: UInt64
    var size: UInt32
}

class NTFSDaemonClient {
    private let socketPath: String
    private var clientFd: Int32 = -1
    private var requestId: UInt64 = 0
    private let lock = NSLock()
    
    // Shared Memory variables
    private var shmPtr: UnsafeMutableRawPointer? = nil
    private let shmSize: Int = 2 * 1024 * 1024
    private var shmFd: Int32 = -1
    
    init(socketPath: String = "/tmp/ntfsmagicd.sock") {
        self.socketPath = socketPath
    }
    
    deinit {
        disconnect()
    }
    
    func connect() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        
        if clientFd >= 0 { return true }
        
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        let pathBytes = socketPath.utf8CString
        let limit = MemoryLayout.size(ofValue: addr.sun_path)
        if pathBytes.count > limit {
            close(fd)
            return false
        }
        
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for i in 0..<pathBytes.count {
                rawPtr[i] = pathBytes[i]
            }
        }
        
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let res = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, addrSize)
            }
        }
        
        if res < 0 {
            close(fd)
            return false
        }
        
        clientFd = fd
        return true
    }
    
    func disconnect() {
        lock.lock()
        defer { lock.unlock() }
        
        cleanupShm()
        
        if clientFd >= 0 {
            close(clientFd)
            clientFd = -1
        }
    }
    
    func setupShm(path: String) {
        lock.lock()
        defer { lock.unlock() }
        
        cleanupShm()
        
        let fd = Darwin.open(path, O_RDWR)
        if fd >= 0 {
            let ptr = mmap(nil, shmSize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0)
            if ptr != MAP_FAILED {
                shmPtr = ptr
                shmFd = fd
                print("[NTFSDaemonClient] Successfully mapped shared memory: \(path)")
            } else {
                Darwin.close(fd)
            }
        } else {
            print("[NTFSDaemonClient] Failed to open shm file: \(path), errno=\(errno)")
        }
    }
    
    private func cleanupShm() {
        if let ptr = shmPtr {
            munmap(ptr, shmSize)
            shmPtr = nil
        }
        if shmFd >= 0 {
            Darwin.close(shmFd)
            shmFd = -1
        }
    }
    
    func sendRequest(type: UInt32, payload: Data) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        
        guard clientFd >= 0 || connect() else {
            return nil
        }
        
        requestId += 1
        let reqId = requestId
        let totalLength = UInt32(MemoryLayout<ntfs_msg_header>.size + payload.count)
        
        var header = ntfs_msg_header(length: totalLength, type: type, request_id: reqId)
        let headerData = Data(bytes: &header, count: MemoryLayout<ntfs_msg_header>.size)
        let writeData = headerData + payload
        
        let bytesWritten = writeData.withUnsafeBytes { ptr in
            Darwin.write(clientFd, ptr.baseAddress!, writeData.count)
        }
        
        if bytesWritten != writeData.count {
            close(clientFd)
            clientFd = -1
            guard connect() else { return nil }
            
            let bytesWrittenRetry = writeData.withUnsafeBytes { ptr in
                Darwin.write(clientFd, ptr.baseAddress!, writeData.count)
            }
            if bytesWrittenRetry != writeData.count {
                close(clientFd)
                clientFd = -1
                return nil
            }
        }
        
        // Read response header
        var respHeader = ntfs_msg_header(length: 0, type: 0, request_id: 0)
        var respHeaderData = Data(repeating: 0, count: MemoryLayout<ntfs_msg_header>.size)
        
        let bytesRead = respHeaderData.withUnsafeMutableBytes { ptr in
            Darwin.read(clientFd, ptr.baseAddress!, MemoryLayout<ntfs_msg_header>.size)
        }
        
        if bytesRead != MemoryLayout<ntfs_msg_header>.size {
            close(clientFd)
            clientFd = -1
            return nil
        }
        
        respHeaderData.withUnsafeBytes { ptr in
            respHeader = ptr.load(as: ntfs_msg_header.self)
        }
        
        if respHeader.request_id != reqId {
            close(clientFd)
            clientFd = -1
            return nil
        }
        
        let respPayloadLen = Int(respHeader.length) - MemoryLayout<ntfs_msg_header>.size
        if respPayloadLen <= 0 {
            return Data()
        }
        
        var respPayload = Data(repeating: 0, count: respPayloadLen)
        var totalRead = 0
        while totalRead < respPayloadLen {
            let r = respPayload.withUnsafeMutableBytes { ptr in
                Darwin.read(clientFd, ptr.baseAddress! + totalRead, respPayloadLen - totalRead)
            }
            if r <= 0 {
                close(clientFd)
                clientFd = -1
                return nil
            }
            totalRead += r
        }
        
        return respPayload
    }
    
    func readShm(ino: UInt64, offset: Int64, length: Int, into buffer: FSMutableFileDataBuffer) -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        guard clientFd >= 0, let shm = shmPtr else {
            print("[NTFSDaemonClient] SHM not available for read, clientFd=\(clientFd), shmPtr=\(String(describing: shmPtr))")
            return -1
        }
        
        requestId += 1
        let reqId = requestId
        
        var req = ntfs_msg_read_req(ino: ino, offset: UInt64(offset), size: UInt32(length))
        let totalLength = UInt32(MemoryLayout<ntfs_msg_header>.size + MemoryLayout<ntfs_msg_read_req>.size)
        
        var header = ntfs_msg_header(length: totalLength, type: ntfs_msg_type.NTFS_MSG_READ.rawValue, request_id: reqId)
        
        var writeData = Data()
        writeData.append(Data(bytes: &header, count: MemoryLayout<ntfs_msg_header>.size))
        writeData.append(Data(bytes: &req, count: MemoryLayout<ntfs_msg_read_req>.size))
        
        let bytesWritten = writeData.withUnsafeBytes { ptr in
            Darwin.write(clientFd, ptr.baseAddress!, writeData.count)
        }
        
        if bytesWritten != writeData.count {
            return -1
        }
        
        // Read response header
        var respHeader = ntfs_msg_header(length: 0, type: 0, request_id: 0)
        var respHeaderData = Data(repeating: 0, count: MemoryLayout<ntfs_msg_header>.size)
        let bytesRead = respHeaderData.withUnsafeMutableBytes { ptr in
            Darwin.read(clientFd, ptr.baseAddress!, MemoryLayout<ntfs_msg_header>.size)
        }
        
        if bytesRead != MemoryLayout<ntfs_msg_header>.size {
            return -1
        }
        
        respHeaderData.withUnsafeBytes { ptr in
            respHeader = ptr.load(as: ntfs_msg_header.self)
        }
        
        if respHeader.request_id != reqId {
            return -1
        }
        
        let respPayloadLen = Int(respHeader.length) - MemoryLayout<ntfs_msg_header>.size
        if respPayloadLen <= 0 {
            return -1
        }
        
        var respData = Data(repeating: 0, count: respPayloadLen)
        var totalRead = 0
        while totalRead < respPayloadLen {
            let r = respData.withUnsafeMutableBytes { ptr in
                Darwin.read(clientFd, ptr.baseAddress! + totalRead, respPayloadLen - totalRead)
            }
            if r <= 0 { return -1 }
            totalRead += r
        }
        
        let status = respData.readInt32(at: 0)
        guard status == 0 else { return -1 }
        
        let bytesReadCount = Int(respData.readUInt32(at: 4))
        if bytesReadCount > 0 {
            buffer.withUnsafeMutableBytes { dstPtr in
                if let dst = dstPtr.baseAddress {
                    memcpy(dst, shm, bytesReadCount)
                }
            }
        }
        return bytesReadCount
    }
    
    func writeShm(ino: UInt64, contents: Data, offset: Int64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        guard clientFd >= 0, let shm = shmPtr else {
            print("[NTFSDaemonClient] SHM not available for write, clientFd=\(clientFd), shmPtr=\(String(describing: shmPtr))")
            return -1
        }
        
        let writeLength = min(contents.count, shmSize)
        contents.withUnsafeBytes { srcPtr in
            if let src = srcPtr.baseAddress {
                memcpy(shm, src, writeLength)
            }
        }
        
        requestId += 1
        let reqId = requestId
        
        var req = ntfs_msg_write_req_shm(ino: ino, offset: UInt64(offset), size: UInt32(writeLength))
        let totalLength = UInt32(MemoryLayout<ntfs_msg_header>.size + MemoryLayout<ntfs_msg_write_req_shm>.size)
        
        var header = ntfs_msg_header(length: totalLength, type: ntfs_msg_type.NTFS_MSG_WRITE.rawValue, request_id: reqId)
        
        var writeData = Data()
        writeData.append(Data(bytes: &header, count: MemoryLayout<ntfs_msg_header>.size))
        writeData.append(Data(bytes: &req, count: MemoryLayout<ntfs_msg_write_req_shm>.size))
        
        let bytesWritten = writeData.withUnsafeBytes { ptr in
            Darwin.write(clientFd, ptr.baseAddress!, writeData.count)
        }
        
        if bytesWritten != writeData.count {
            return -1
        }
        
        // Read response header
        var respHeader = ntfs_msg_header(length: 0, type: 0, request_id: 0)
        var respHeaderData = Data(repeating: 0, count: MemoryLayout<ntfs_msg_header>.size)
        let bytesRead = respHeaderData.withUnsafeMutableBytes { ptr in
            Darwin.read(clientFd, ptr.baseAddress!, MemoryLayout<ntfs_msg_header>.size)
        }
        
        if bytesRead != MemoryLayout<ntfs_msg_header>.size {
            return -1
        }
        
        respHeaderData.withUnsafeBytes { ptr in
            respHeader = ptr.load(as: ntfs_msg_header.self)
        }
        
        if respHeader.request_id != reqId {
            return -1
        }
        
        let respPayloadLen = Int(respHeader.length) - MemoryLayout<ntfs_msg_header>.size
        if respPayloadLen <= 0 {
            return -1
        }
        
        var respData = Data(repeating: 0, count: respPayloadLen)
        var totalRead = 0
        while totalRead < respPayloadLen {
            let r = respData.withUnsafeMutableBytes { ptr in
                Darwin.read(clientFd, ptr.baseAddress! + totalRead, respPayloadLen - totalRead)
            }
            if r <= 0 { return -1 }
            totalRead += r
        }
        
        let status = respData.readInt32(at: 0)
        guard status == 0 else { return -1 }
        
        let bytesWrittenCount = Int(respData.readUInt32(at: 4))
        return bytesWrittenCount
    }
    
    func readData(ino: UInt64, offset: Int64, length: Int) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        
        guard clientFd >= 0, let shm = shmPtr else { return nil }
        
        requestId += 1
        let reqId = requestId
        
        var req = ntfs_msg_read_req(ino: ino, offset: UInt64(offset), size: UInt32(length))
        let totalLength = UInt32(MemoryLayout<ntfs_msg_header>.size + MemoryLayout<ntfs_msg_read_req>.size)
        var header = ntfs_msg_header(length: totalLength, type: ntfs_msg_type.NTFS_MSG_READ.rawValue, request_id: reqId)
        
        var writeData = Data()
        writeData.append(Data(bytes: &header, count: MemoryLayout<ntfs_msg_header>.size))
        writeData.append(Data(bytes: &req, count: MemoryLayout<ntfs_msg_read_req>.size))
        
        let bytesWritten = writeData.withUnsafeBytes { ptr in
            Darwin.write(clientFd, ptr.baseAddress!, writeData.count)
        }
        
        if bytesWritten != writeData.count {
            return nil
        }
        
        // Read response header
        var respHeader = ntfs_msg_header(length: 0, type: 0, request_id: 0)
        var respHeaderData = Data(repeating: 0, count: MemoryLayout<ntfs_msg_header>.size)
        let bytesRead = respHeaderData.withUnsafeMutableBytes { ptr in
            Darwin.read(clientFd, ptr.baseAddress!, MemoryLayout<ntfs_msg_header>.size)
        }
        
        if bytesRead != MemoryLayout<ntfs_msg_header>.size {
            return nil
        }
        
        respHeaderData.withUnsafeBytes { ptr in
            respHeader = ptr.load(as: ntfs_msg_header.self)
        }
        
        if respHeader.request_id != reqId {
            return nil
        }
        
        let respPayloadLen = Int(respHeader.length) - MemoryLayout<ntfs_msg_header>.size
        if respPayloadLen <= 0 {
            return nil
        }
        
        var respData = Data(repeating: 0, count: respPayloadLen)
        var totalRead = 0
        while totalRead < respPayloadLen {
            let r = respData.withUnsafeMutableBytes { ptr in
                Darwin.read(clientFd, ptr.baseAddress! + totalRead, respPayloadLen - totalRead)
            }
            if r <= 0 { return nil }
            totalRead += r
        }
        
        let status = respData.readInt32(at: 0)
        guard status == 0 else { return nil }
        
        let bytesReadCount = Int(respData.readUInt32(at: 4))
        if bytesReadCount > 0 {
            return Data(bytes: shm, count: bytesReadCount)
        }
        return Data()
    }
    
    func writeData(ino: UInt64, contents: Data, offset: Int64) -> Int {
        lock.lock()
        defer { lock.unlock() }
        
        guard clientFd >= 0, let shm = shmPtr else { return -1 }
        
        let writeLength = min(contents.count, shmSize)
        contents.withUnsafeBytes { srcPtr in
            if let src = srcPtr.baseAddress {
                memcpy(shm, src, writeLength)
            }
        }
        
        requestId += 1
        let reqId = requestId
        
        var req = ntfs_msg_write_req_shm(ino: ino, offset: UInt64(offset), size: UInt32(writeLength))
        let totalLength = UInt32(MemoryLayout<ntfs_msg_header>.size + MemoryLayout<ntfs_msg_write_req_shm>.size)
        var header = ntfs_msg_header(length: totalLength, type: ntfs_msg_type.NTFS_MSG_WRITE.rawValue, request_id: reqId)
        
        var writeData = Data()
        writeData.append(Data(bytes: &header, count: MemoryLayout<ntfs_msg_header>.size))
        writeData.append(Data(bytes: &req, count: MemoryLayout<ntfs_msg_write_req_shm>.size))
        
        let bytesWritten = writeData.withUnsafeBytes { ptr in
            Darwin.write(clientFd, ptr.baseAddress!, writeData.count)
        }
        
        if bytesWritten != writeData.count {
            return -1
        }
        
        // Read response header
        var respHeader = ntfs_msg_header(length: 0, type: 0, request_id: 0)
        var respHeaderData = Data(repeating: 0, count: MemoryLayout<ntfs_msg_header>.size)
        let bytesRead = respHeaderData.withUnsafeMutableBytes { ptr in
            Darwin.read(clientFd, ptr.baseAddress!, MemoryLayout<ntfs_msg_header>.size)
        }
        
        if bytesRead != MemoryLayout<ntfs_msg_header>.size {
            return -1
        }
        
        respHeaderData.withUnsafeBytes { ptr in
            respHeader = ptr.load(as: ntfs_msg_header.self)
        }
        
        if respHeader.request_id != reqId {
            return -1
        }
        
        let respPayloadLen = Int(respHeader.length) - MemoryLayout<ntfs_msg_header>.size
        if respPayloadLen <= 0 {
            return -1
        }
        
        var respData = Data(repeating: 0, count: respPayloadLen)
        var totalRead = 0
        while totalRead < respPayloadLen {
            let r = respData.withUnsafeMutableBytes { ptr in
                Darwin.read(clientFd, ptr.baseAddress! + totalRead, respPayloadLen - totalRead)
            }
            if r <= 0 { return -1 }
            totalRead += r
        }
        
        let status = respData.readInt32(at: 0)
        guard status == 0 else { return -1 }
        
        let bytesWrittenCount = Int(respData.readUInt32(at: 4))
        return bytesWrittenCount
    }
}

extension Data {
    func readInt32(at offset: Int) -> Int32 {
        var val: Int32 = 0
        withUnsafeMutablePointer(to: &val) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr)
            let dest = UnsafeMutableRawBufferPointer(start: rawPtr, count: 4)
            self.copyBytes(to: dest, from: offset..<(offset + 4))
        }
        return val
    }
    
    func readUInt32(at offset: Int) -> UInt32 {
        var val: UInt32 = 0
        withUnsafeMutablePointer(to: &val) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr)
            let dest = UnsafeMutableRawBufferPointer(start: rawPtr, count: 4)
            self.copyBytes(to: dest, from: offset..<(offset + 4))
        }
        return val
    }
    
    func readUInt64(at offset: Int) -> UInt64 {
        var val: UInt64 = 0
        withUnsafeMutablePointer(to: &val) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr)
            let dest = UnsafeMutableRawBufferPointer(start: rawPtr, count: 8)
            self.copyBytes(to: dest, from: offset..<(offset + 8))
        }
        return val
    }
    
    func readString(at offset: Int, length: Int) -> String {
        return self.withUnsafeBytes { ptr in
            let raw = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self) + offset
            return String(cString: raw)
        }
    }
}
