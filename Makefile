TARGET := iphone:clang:latest:17.0
ARCHS := arm64e
THEOS_PACKAGE_SCHEME := roothide

RR_VERSION := $(shell sed -n 's/^Version:[[:space:]]*//p' control)
RR_AUTHOR := $(shell sed -n 's/^Author:[[:space:]]*//p' control)

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := RandomRingProbe

RandomRingProbe_FILES := Probe.m core/RRSelection.c
RandomRingProbe_CFLAGS := -fobjc-arc
RandomRingProbe_FRAMEWORKS := Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME := RandomRingPrefs

RandomRingPrefs_FILES := Prefs/RRRootListController.m
RandomRingPrefs_FRAMEWORKS := UIKit
RandomRingPrefs_INSTALL_PATH := /Library/PreferenceBundles
RandomRingPrefs_RESOURCE_DIRS := Prefs/Resources
RandomRingPrefs_CFLAGS := -fobjc-arc -DRR_VERSION='"$(RR_VERSION)"' -DRR_AUTHOR='"$(RR_AUTHOR)"'
RandomRingPrefs_LDFLAGS := -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/bundle.mk

before-package::
	chmod 0755 $(THEOS_STAGING_DIR)/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/postrm
