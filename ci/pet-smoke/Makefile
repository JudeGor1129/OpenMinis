TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PetSmoke
PetSmoke_FILES = Tweak.m
PetSmoke_FRAMEWORKS = Foundation UIKit
PetSmoke_LDFLAGS = -Wl,-no_fixup_chains

include $(THEOS_MAKE_PATH)/tweak.mk
