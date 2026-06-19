import SwiftUI

class AppState: ObservableObject {
    @Published var isDaemonActive = false
    @Published var isExtensionRegistered = false
    @Published var isDiskConnected = false
    @Published var isCopied = false
    var timer: Timer? = nil
}

struct ContentView: View {
    @StateObject private var state = AppState()
    
    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("NTFS MAGIC")
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .foregroundColor(.primary)
                    Text("Kext-less NTFS Read/Write Driver for macOS")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                
                // Logo Container (prominent, clean, neutral backdrop)
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.03))
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                    if let imagePath = Bundle.main.path(forResource: "logo", ofType: "png"),
                       let nsImage = NSImage(contentsOfFile: imagePath) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 42, height: 42)
                    } else {
                        Image(systemName: "opticaldisc.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 4)
            
            // Divider
            Divider()
                .background(Color.primary.opacity(0.1))
            
            // Status Grid
            VStack(spacing: 12) {
                StatusCard(
                    title: "Helper Daemon Status",
                    subtitle: "IPC Socket (/tmp/ntfsmagicd.sock)",
                    isActive: state.isDaemonActive,
                    activeMessage: "ACTIVE & LISTENING",
                    inactiveMessage: "NOT RUNNING"
                )
                
                StatusCard(
                    title: "FSKit Extension Registration",
                    subtitle: "com.ntfsmagic.NTFSFS",
                    isActive: state.isExtensionRegistered,
                    activeMessage: "REGISTERED",
                    inactiveMessage: "NOT REGISTERED"
                )
                
                StatusCard(
                    title: "NTFS Disk Connection",
                    subtitle: "Detects Windows_NTFS partitions",
                    isActive: state.isDiskConnected,
                    activeMessage: "NTFS DISK DETECTED",
                    inactiveMessage: "NO NTFS DISKS FOUND"
                )
            }
            
            // Instructions
            VStack(alignment: .leading, spacing: 10) {
                Text("How to start the Helper Daemon for testing:")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.primary)
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("Run the helper daemon binary as root via Terminal:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text("sudo /Library/PrivilegedHelperTools/ntfsmagicd")
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundColor(Color(red: 0.2, green: 0.8, blue: 0.2))
                        
                        Spacer()
                        
                        Button(action: {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString("sudo /Library/PrivilegedHelperTools/ntfsmagicd", forType: .string)
                            state.isCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                state.isCopied = false
                            }
                        }) {
                            Image(systemName: state.isCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(state.isCopied ? .green : .white.opacity(0.6))
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .help("Copy to Clipboard")
                    }
                    .padding(10)
                    .background(Color(white: 0.12))
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    )
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.02))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
            
            Spacer()
        }
        .padding(24)
        .background(Color(NSColor.windowBackgroundColor))
        .onAppear {
            updateStatus()
            state.timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                updateStatus()
            }
        }
        .onDisappear {
            state.timer?.invalidate()
        }
    }
    
    private func updateStatus() {
        // 1. Daemon
        state.isDaemonActive = FileManager.default.fileExists(atPath: "/tmp/ntfsmagicd.sock")
        
        // 2. Extension
        let pkProcess = Process()
        pkProcess.launchPath = "/usr/bin/pluginkit"
        pkProcess.arguments = ["-m", "-i", "com.ntfsmagic.NTFSFS"]
        let pkPipe = Pipe()
        pkProcess.standardOutput = pkPipe
        pkProcess.launch()
        pkProcess.waitUntilExit()
        let pkData = pkPipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: pkData, encoding: .utf8) {
            state.isExtensionRegistered = !output.isEmpty
        } else {
            state.isExtensionRegistered = false
        }
        
        // 3. Target Disk
        let duProcess = Process()
        duProcess.launchPath = "/usr/sbin/diskutil"
        duProcess.arguments = ["list"]
        let duPipe = Pipe()
        duProcess.standardOutput = duPipe
        duProcess.launch()
        duProcess.waitUntilExit()
        let duData = duPipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: duData, encoding: .utf8) {
            state.isDiskConnected = output.contains("Windows_NTFS")
        } else {
            state.isDiskConnected = false
        }
    }
}

struct StatusCard: View {
    let title: String
    let subtitle: String
    let isActive: Bool
    let activeMessage: String
    let inactiveMessage: String
    
    var body: some View {
        HStack(spacing: 16) {
            // Minimal Dot (no neon glow)
            Circle()
                .fill(isActive ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Technical monospaced status badge
            Text(isActive ? activeMessage : inactiveMessage)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(isActive ? .green : .red)
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isActive ? Color.green.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 1)
                        .background(isActive ? Color.green.opacity(0.04) : Color.red.opacity(0.04))
                )
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
