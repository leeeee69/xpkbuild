TARGET = iphone:clang:16.5:14.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = XPPanelKit
XPPanelKit_FILES = Tweak.xm XPPanel.m
XPPanelKit_CFLAGS = -fobjc-arc -I.
XPPanelKit_FRAMEWORKS = UIKit Foundation
XPPanelKit_LIBRARIES = substrate

include $(THEOS_MAKE_PATH)/tweak.mk
