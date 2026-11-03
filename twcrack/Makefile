TARGET = iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = TWCrack
TWCrack_FILES = Tweak.xm
TWCrack_CFLAGS = -fobjc-arc -miphoneos-version-min=14.0 -Wno-error=overriding-t-option -Wno-error=unused-function -Wno-error=unused-variable
TWCrack_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
