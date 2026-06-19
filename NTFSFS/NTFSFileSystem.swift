import FSKit
import Foundation

@objc(NTFSFileSystem)
class NTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {
    
    override init() {
        super.init()
        print("[NTFSFileSystem] Initialized")
    }
    
    func probeResource(resource: FSResource, replyHandler: @escaping (FSProbeResult?, Error?) -> Void) {
        guard let blockRes = resource as? FSBlockDeviceResource else {
            replyHandler(FSProbeResult.notRecognized, nil)
            return
        }
        
        print("[NTFSFileSystem] Probing resource: \(blockRes.bsdName)")
        // Recognize any partition (containing 's') to avoid probing raw disk containers (like disk4)
        if blockRes.bsdName.contains("s") {
            let containerID = FSContainerIdentifier()
            let result = FSProbeResult.recognized(name: "NTFS Volume", containerID: containerID)
            replyHandler(result, nil)
        } else {
            replyHandler(FSProbeResult.notRecognized, nil)
        }
    }
    
    func loadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (FSVolume?, Error?) -> Void) {
        guard let blockRes = resource as? FSBlockDeviceResource else {
            replyHandler(nil, NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, userInfo: nil))
            return
        }
        
        print("[NTFSFileSystem] Loading resource: \(blockRes.bsdName)")
        let devicePath = "/dev/\(blockRes.bsdName)"
        let volID = FSVolume.Identifier()
        do {
            let volume = try NTFSVolume(volumeID: volID, volumeName: FSFileName(string: "NTFS Volume"), devicePath: devicePath)
            replyHandler(volume, nil)
        } catch {
            replyHandler(nil, error)
        }
    }
    
    func unloadResource(resource: FSResource, options: FSTaskOptions, replyHandler: @escaping (Error?) -> Void) {
        guard let blockRes = resource as? FSBlockDeviceResource else {
            replyHandler(nil)
            return
        }
        print("[NTFSFileSystem] Unloading resource: \(blockRes.bsdName)")
        replyHandler(nil)
    }
}
