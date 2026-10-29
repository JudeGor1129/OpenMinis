ARCHS = arm64 arm64e
TARGET = iphone:clang:latest:15.4
# Release builds must use Apple's real arm64e compiler/linker. A patched
# CPU-subtype header on Linux lld is not an arm64e ABI implementation.
ifeq ($(shell uname -s),Darwin)
else
ifeq ($(ALLOW_EXPERIMENTAL_LINUX),1)
else
$(error Release builds require macOS + Xcode; Linux arm64e output failed on-device)
endif
endif
THEOS_PACKAGE_SCHEME = rootless
FINALPACKAGE = 1
DEBUG = 0

include $(THEOS)/makefiles/common.mk
TOOL_NAME = ictrld
# A daemon does not run inside SpringBoard; use normal arm64 ABI on A12+ too.
ictrld_ARCHS = arm64
ictrld_FILES = daemon/main.m daemon/ICNAuth.m shared/ICNProtocol.m vendor/ictrl/x25519.c vendor/ictrl/sha256.c vendor/ictrl/util.c
ictrld_CFLAGS = -fobjc-arc -Ishared -Idaemon -Ivendor/ictrl -Wall -Wextra -Wno-unused-parameter
ictrld_FRAMEWORKS = Foundation Security
ictrld_INSTALL_PATH = /usr/libexec
ictrld_CODESIGN_FLAGS = -Sdaemon/entitlements.plist

TWEAK_NAME = iCTRLBridge
iCTRLBridge_FILES = bridge/ICNBridge.m shared/ICNProtocol.m
iCTRLBridge_CFLAGS = -fobjc-arc -Ishared -Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations
iCTRLBridge_FRAMEWORKS = Foundation UIKit CoreFoundation

include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/tweak.mk

before-package::
	chmod 0755 $(THEOS_STAGING_DIR)/DEBIAN/postinst
	chmod 0755 $(THEOS_STAGING_DIR)/DEBIAN/prerm

after-stage::
	chmod 0755 $(THEOS_STAGING_DIR)/usr/libexec/ictrld
	chmod 0755 $(THEOS_STAGING_DIR)/Library/MobileSubstrate/DynamicLibraries/iCTRLBridge.dylib
	chmod 0755 $(THEOS_STAGING_DIR)/usr/share/ictrl-native/ictrl
	chmod 0755 $(THEOS_STAGING_DIR)/usr/share/ictrl-native/ictrl.sh
	chmod 0644 $(THEOS_STAGING_DIR)/Library/LaunchDaemons/com.judegor.ictrl-native.plist
	chown -R 0:0 $(THEOS_STAGING_DIR)/Library $(THEOS_STAGING_DIR)/usr $(THEOS_STAGING_DIR)/var 2>/dev/null || true
