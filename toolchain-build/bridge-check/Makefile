# Local compile/link check only. The console-style test entry point is NOT an
# iOS UI app: do not install/launch the IPA. Host assertions run via check-macos.sh.
# Refresh OMToolchain.h/mm snapshots from src/ios/Vendor/OMToolchain before building.
ARCHS = arm64
TARGET = iphone:latest:15.0

include $(THEOS)/makefiles/common.mk
APPLICATION_NAME = OMBridgeCheckCompile
OMBridgeCheckCompile_FILES = DisabledBridgeTests.mm OMToolchain.mm
OMBridgeCheckCompile_CFLAGS = -fobjc-arc -DOM_TOOLCHAIN_ENABLED=0 -Wall -Wextra -Werror
OMBridgeCheckCompile_CCFLAGS = -std=c++17
OMBridgeCheckCompile_FRAMEWORKS = Foundation
include $(THEOS_MAKE_PATH)/application.mk
