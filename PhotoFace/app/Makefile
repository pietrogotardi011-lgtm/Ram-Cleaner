TARGET := iphone:clang:latest:13.0
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = PhotoFaceEnroll
PhotoFaceEnroll_FILES = main.m
PhotoFaceEnroll_FRAMEWORKS = UIKit AVFoundation Vision CoreMedia CoreVideo QuartzCore
PhotoFaceEnroll_CFLAGS = -fobjc-arc
PhotoFaceEnroll_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk
