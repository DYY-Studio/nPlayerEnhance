TARGET := iphone:clang:latest:13.0
ARCHS = arm64
INSTALL_TARGET_PROCESSES = com.newin.nplayer.basic


include $(THEOS)/makefiles/common.mk

TWEAK_NAME = nPlayerEnhance

nPlayerEnhance_FILES = Tweak.x
nPlayerEnhance_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/tweak.mk
