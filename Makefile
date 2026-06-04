ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamInject
VCamInject_FILES = Tweak.xm VCamFrameProvider.mm
VCamInject_CFLAGS = -fobjc-arc -Wall -Wextra
VCamInject_FRAMEWORKS = AVFoundation CoreMedia CoreVideo UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
