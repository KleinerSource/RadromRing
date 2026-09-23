TARGET := iphone:clang:latest:17.0
ARCHS := arm64e
THEOS_PACKAGE_SCHEME := roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := RadromRingProbe

RadromRingProbe_FILES := Probe.m core/RRSelection.c
RadromRingProbe_CFLAGS := -fobjc-arc
RadromRingProbe_FRAMEWORKS := Foundation

include $(THEOS_MAKE_PATH)/tweak.mk

BUNDLE_NAME := RadromRingPrefs

RadromRingPrefs_FILES := Prefs/RRRootListController.m
RadromRingPrefs_FRAMEWORKS := UIKit
RadromRingPrefs_PRIVATE_FRAMEWORKS := Preferences
RadromRingPrefs_INSTALL_PATH := /Library/PreferenceBundles
RadromRingPrefs_RESOURCE_DIRS := Prefs/Resources
RadromRingPrefs_CFLAGS := -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
