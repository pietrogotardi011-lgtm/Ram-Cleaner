TARGET := iphone:clang:latest:13.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PhotoFace
PhotoFace_FILES = Tweak.x
PhotoFace_CFLAGS = -fobjc-arc
PhotoFace_FRAMEWORKS = UIKit AVFoundation Vision CoreImage CoreMedia CoreVideo Security

TOOL_NAME = pfenroll
pfenroll_FILES = pfenroll.c

include $(THEOS_MAKE_PATH)/tweak.mk
include $(THEOS_MAKE_PATH)/tool.mk

before-package::
	@chmod 0755 $(THEOS_STAGING_DIR)/DEBIAN/postinst
