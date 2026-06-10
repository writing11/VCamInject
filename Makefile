ARCHS = arm64 arm64e
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamInject
VCamInject_FILES = Tweak.xm VCamFrameProvider.mm VCamVideoPicker.mm VCamLicense.mm
VCamInject_CFLAGS = -fobjc-arc -Wall -Wextra
VCamInject_CCFLAGS = -std=gnu++14
VCamInject_CXXFLAGS = -std=gnu++14
VCamInject_FRAMEWORKS = AVFoundation CoreMedia CoreVideo CoreImage ImageIO UIKit PhotosUI QuartzCore

include $(THEOS_MAKE_PATH)/tweak.mk

TOOL_NAME = vcamreceiverd
vcamreceiverd_FILES = vcamreceiverd.c
vcamreceiverd_CFLAGS = -Wall -Wextra -O2
vcamreceiverd_FRAMEWORKS = CoreFoundation
vcamreceiverd_INSTALL_PATH = /usr/local/bin

include $(THEOS_MAKE_PATH)/tool.mk

before-package::
	mkdir -p $(THEOS_STAGING_DIR)/DEBIAN
	cp postinst $(THEOS_STAGING_DIR)/DEBIAN/postinst
	cp prerm $(THEOS_STAGING_DIR)/DEBIAN/prerm
	chmod 0755 $(THEOS_STAGING_DIR)/DEBIAN/postinst $(THEOS_STAGING_DIR)/DEBIAN/prerm
	mkdir -p $(THEOS_STAGING_DIR)/usr/local/bin
	cp vcamreceiverd_launch.sh $(THEOS_STAGING_DIR)/usr/local/bin/vcamreceiverd_launch.sh
	chmod 0755 $(THEOS_STAGING_DIR)/usr/local/bin/vcamreceiverd_launch.sh
