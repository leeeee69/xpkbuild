TARGET = iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XPPanelKit
XPPanelKit_FILES = Tweak.xm XPPanel.m
XPPanelKit_CFLAGS = -fobjc-arc -I. -miphoneos-version-min=14.0 -Wno-error=overriding-t-option -Wno-error=unused-function -Wno-error=unused-variable
XPPanelKit_FRAMEWORKS = UIKit Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
