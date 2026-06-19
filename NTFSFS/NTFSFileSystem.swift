import FSKit
import Foundation

@objc(NTFSFileSystem)
class NTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations, FSManageableResourceMaintenanceOperations {
    
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
    
    // MARK: FSManageableResourceMaintenanceOperations Conformance
    
    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        print("[NTFSFileSystem] startCheck called")
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        return progress
    }
    
    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        print("[NTFSFileSystem] startFormat called")
        let progress = Progress(totalUnitCount: 1)
        progress.completedUnitCount = 1
        return progress
    }
}
