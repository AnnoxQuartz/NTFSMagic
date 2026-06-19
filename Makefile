# Paths
WD = $(shell pwd)
APP_BUNDLE = $(WD)/NTFSMagic.app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
EXTENSIONS_DIR = $(CONTENTS)/Extensions
APPEX_BUNDLE = $(EXTENSIONS_DIR)/NTFSFS.appex
APPEX_CONTENTS = $(APPEX_BUNDLE)/Contents
APPEX_MACOS_DIR = $(APPEX_CONTENTS)/MacOS

# Tools
SWIFTC = swiftc
SDK_PATH = $(shell xcrun --show-sdk-path)
TARGET = arm64-apple-macos15.4

.PHONY: all clean ntfsmagicd ntfsfs hostapp bundle pkg

all: bundle

3rdparty/build/lib/libntfs-3g.a:
	@echo "3rdparty dependencies not found. Building them first..."
	cd 3rdparty && $(MAKE) -f Makefile.ntfs3g

ntfsmagicd: 3rdparty/build/lib/libntfs-3g.a
	@echo "Building helper daemon (ntfsmagicd)..."
	cd ntfsmagicd && clang -O2 -Wall -target $(TARGET) \
		-I../3rdparty/build/include \
		-L../3rdparty/build/lib \
		-o ntfsmagicd ntfsmagicd.c -lntfs-3g -lpthread -framework CoreFoundation

ntfsfs:
	@echo "Building FSKit App Extension (NTFSFS)..."
	cd NTFSFS && $(SWIFTC) -sdk $(SDK_PATH) -target $(TARGET) \
		-emit-executable -o NTFSFS \
		NTFSFileSystem.swift NTFSVolume.swift NTFSDaemonClient.swift \
		-framework FSKit -Xlinker -e -Xlinker _NSExtensionMain

hostapp:
	@echo "Building Host App (NTFSMagic)..."
	cd NTFSMagic && $(SWIFTC) -sdk $(SDK_PATH) -target $(TARGET) \
		-emit-executable -o NTFSMagic \
		NTFSMagicApp.swift ContentView.swift

bundle: ntfsmagicd ntfsfs hostapp
	@echo "Creating NTFSMagic.app bundle..."
	mkdir -p "$(MACOS_DIR)"
	mkdir -p "$(EXTENSIONS_DIR)"
	mkdir -p "$(APPEX_MACOS_DIR)"
	
	# Copy Info.plists
	cp NTFSMagic/NTFSMagic-Info.plist "$(CONTENTS)/Info.plist"
	cp NTFSFS/NTFSFS-Info.plist "$(APPEX_CONTENTS)/Info.plist"
	
	# Copy Resources (icons & logos)
	mkdir -p "$(CONTENTS)/Resources"
	cp NTFSMagic/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	cp NTFSMagic/logo_128.png "$(CONTENTS)/Resources/logo.png"
	
	# Copy executables
	cp NTFSMagic/NTFSMagic "$(MACOS_DIR)/NTFSMagic"
	cp NTFSFS/NTFSFS "$(APPEX_MACOS_DIR)/NTFSFS"
	
	# Ad-hoc sign the bundles
	codesign --force --sign - "$(APPEX_BUNDLE)"
	codesign --force --sign - "$(APP_BUNDLE)"
	
	@echo "Build complete: NTFSMagic.app"

pkg: bundle
	@echo "Creating PKG installer payload..."
	rm -rf pkg_root
	mkdir -p pkg_root/Applications
	mkdir -p pkg_root/Library/LaunchDaemons
	mkdir -p pkg_root/Library/PrivilegedHelperTools
	
	# Copy components to payload root
	cp -R NTFSMagic.app pkg_root/Applications/
	cp com.ntfsmagic.ntfsmagicd.plist pkg_root/Library/LaunchDaemons/
	cp ntfsmagicd/ntfsmagicd pkg_root/Library/PrivilegedHelperTools/
	
	@echo "Building NTFSMagic.pkg package..."
	pkgbuild --root pkg_root \
		--identifier com.ntfsmagic.NTFSMagicInstaller \
		--version 1.0 \
		--scripts packaging \
		NTFSMagic.pkg
	
	rm -rf pkg_root
	@echo "Installer package built: NTFSMagic.pkg"

clean:
	rm -rf NTFSMagic/NTFSMagic NTFSFS/NTFSFS ntfsmagicd/ntfsmagicd NTFSMagic.app NTFSMagic.pkg pkg_root
