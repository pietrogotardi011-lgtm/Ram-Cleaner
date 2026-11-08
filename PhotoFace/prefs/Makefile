TARGET := iphone:clang:latest:13.0
ARCHS = arm64
include $(THEOS)/makefiles/common.mk

BUNDLE_NAME = PhotoFacePrefs
PhotoFacePrefs_FILES = PFRootListController.m
PhotoFacePrefs_FRAMEWORKS = UIKit
PhotoFacePrefs_LDFLAGS = -Wl,-undefined,dynamic_lookup
PhotoFacePrefs_INSTALL_PATH = /Library/PreferenceBundles
PhotoFacePrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
