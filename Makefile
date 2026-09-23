TARGET := iphone:clang:latest:17.0
ARCHS := arm64e
THEOS_PACKAGE_SCHEME := roothide

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := RadromRingProbe

RadromRingProbe_FILES := Probe.m
RadromRingProbe_CFLAGS := -fobjc-arc
RadromRingProbe_FRAMEWORKS := Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
