# NTFS Magic

**NTFS Magic** is a modern, kext-less (no kernel extensions), user-space NTFS read-write driver for macOS 15+ (Sequoia) built on top of Apple's **FSKit** framework and utilizing **libntfs-3g**.

Because macOS natively only supports read-only NTFS mounts, this driver bridges the gap, allowing users to write new files, delete files, rename files, and format drives, without needing to disable system security (SIP) or boot into Recovery Mode to install traditional kernel extensions (kexts).

---

## Architecture

To comply with the GNU GPL v2 license of `libntfs-3g` while maintaining a modular structure, the codebase is split across a process boundary:

```
                  ┌─────────────────────────────────────┐
                  │          macOS FSKit Daemon         │
                  └──────────────────┬──────────────────┘
                                     │ FSKit API
                  ┌──────────────────▼──────────────────┐
                  │              NTFSFS.appex           │
                  │       (Proprietary App Extension)   │
                  └──────────────────┬──────────────────┘
                                     │ IPC (Unix Domain Socket)
                  ┌──────────────────▼──────────────────┐
                  │              ntfsmagicd             │
                  │       (GPLv2 root helper daemon)    │
                  └──────────────────┬──────────────────┘
                                     │ C API
                  ┌──────────────────▼──────────────────┐
                  │             libntfs-3g.a            │
                  │       (GPLv2 static library)        │
                  └──────────────────┬──────────────────┘
                                     │ Raw Block I/O
                  ┌──────────────────▼──────────────────┐
                  │          NTFS Disk Partition        │
                  │             (/dev/diskX)            │
                  └─────────────────────────────────────┘
```

1. **`NTFSFS.appex` (FSKit Extension)**: A Swift system extension conforming to FSKit protocols (`FSUnaryFileSystem` and `FSVolume`). It handles mounting events, directory lookups, file creations, reading, and writing. Instead of directly executing low-level disk I/O, it delegates operations over a Unix Domain Socket to `ntfsmagicd`.
2. **`ntfsmagicd` (LaunchDaemon Root Helper)**: A C daemon linking against static `libntfs-3g`. It runs as `root` (managed by `launchd`), which gives it direct access to read and write physical raw block devices (like `/dev/disk4s1`).
3. **`NTFSMagic.app` (Companion App)**: A SwiftUI status bar/window application demonstrating the status of the driver, the helper daemon, and target NTFS disks.

---

## Licensing

* This project is licensed under the **GNU GPL v2 (or later)** due to static linkage with `libntfs-3g`.
* The full license terms are available in the [LICENSE](LICENSE) file.

---

## Directory Structure

* `/3rdparty/` - Contains build scripts to download and compile `libntfs-3g` from source as a static library (`libntfs-3g.a`) for Apple Silicon (`arm64`).
* `/ntfsmagicd/` - Contains the C helper daemon source code (`ntfsmagicd.c` and `ntfsmagicd.h`).
* `/NTFSFS/` - Contains the Swift FSKit app extension source files.
* `/NTFSMagic/` - Contains the SwiftUI host companion application.
* `/scratch/` - Contains testing utilities (such as `test_ipc`).
* `/packaging/` - Contains installer plist and postinstall scripts.

---

## Building and Packaging

### Requirements
* macOS 15.4+ (Sequoia) running on Apple Silicon (`arm64`).
* Xcode Command Line Tools installed (run `xcode-select --install` if needed).

### Compile Everything
To build the daemon, app extension, and companion SwiftUI app:
```bash
make
```
This compiles all targets and structures them into `NTFSMagic.app`.

### Build Installer Package (.pkg)
To compile and package the application into a standard double-clickable macOS installer:
```bash
make pkg
```
This generates `NTFSMagic.pkg` in the project root.

### Automating Builds & Releases (CI/CD)
This repository includes a GitHub Actions workflow that automatically compiles and packages `NTFSMagic.pkg` on commits to `main` and on new Release tags. You can download the latest pre-compiled installer from the **Releases** section on GitHub.

## Local Testing & FSKit Registration (SIP Disabled)

If you are compiling and testing this driver locally without a paid Apple Developer Account, macOS's security manager (`fskitd`) will reject loading the FSKit extension (`NTFSFS.appex`) because it is signed ad-hoc and lacks official developer provisioning.

> [!IMPORTANT]
> **Distribution & Apple Developer ID:**
> To distribute this driver to general users **without requiring them to disable SIP**, all binaries must be signed with a valid **Apple Developer ID** certificate and submitted to Apple for **Notarization** (`xcrun notarytool`). Ad-hoc code signatures (`codesign --force --sign -`) used during local builds are only trusted system-wide when SIP is disabled.

To test the system-wide FSKit integration (Finder and Disk Utility) locally on your Mac:

1. **Disable System Integrity Protection (SIP)**:
   - Shut down your Mac. Press and hold the power button until you see "Loading startup options" to enter **Recovery Mode**.
   - Select **Utilities > Terminal** from the menu bar.
   - Run the following command:
     ```bash
     csrutil disable
     ```
   - Restart your Mac normally.

2. **Install and Register the Extension**:
   - Run `make pkg` to compile the installer.
   - Double-click `NTFSMagic.pkg` to run the installer, placing `NTFSMagic.app` in `/Applications` and starting the background LaunchDaemon service.
   - Launch the companion app to trigger FSKit registration:
     ```bash
     open /Applications/NTFSMagic.app
     ```

3. **Verify Registration**:
   - Run the following command in Terminal to check if macOS recognizes the extension:
     ```bash
     pluginkit -m -i com.ntfsmagic.NTFSFS
     ```
   - Once recognized, when you plug in an NTFS drive (and unmount any read-only macOS default mount via `diskutil unmount /dev/disk4s1`), FSKit will automatically handle it, mounting it read-write in Finder.

---

## Manual Verification (CLI-only)

If you want to test the read/write daemon logic without modifying your system's SIP settings, you can test it directly via the C daemon and IPC client:

1. **Start the Helper Daemon manually**:
   ```bash
   sudo ./ntfsmagicd/ntfsmagicd
   ```
2. **Run the status client or the SwiftUI App**:
   ```bash
   open ./NTFSMagic.app
   ```
3. **Run the integration IPC test**:
   Ensure your test NTFS drive partition (e.g., `/dev/disk4s1`) is unmounted from the read-only handler, and run:
   ```bash
   ./scratch/test_ipc
   ```
