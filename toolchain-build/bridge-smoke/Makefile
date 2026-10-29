ARCHS = arm64
# Smoke harness only: match the available local iPhoneOS 15.6 SDK.
# The Minis Xcode target remains at iOS 16.0.
TARGET = iphone:latest:15.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = OMBridgeSmoke
OMBridgeSmoke_FILES = main.m OMToolchain.mm
OMBridgeSmoke_CFLAGS = -fobjc-arc -DOM_TOOLCHAIN_ENABLED=0 -Wall -Wextra
OMBridgeSmoke_CCFLAGS = -std=c++17
OMBridgeSmoke_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/application.mk
