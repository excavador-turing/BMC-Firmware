# Buildroot's cargo infrastructure (package/pkg-cargo.mk, PKG_CARGO_ENV) sets
# CARGO_PROFILE_RELEASE_OPT_LEVEL from the toolchain's BR2_OPTIMIZE_* choice,
# CARGO_PROFILE_RELEASE_LTO from BR2_ENABLE_LTO, and
# CARGO_PROFILE_RELEASE_CODEGEN_UNITS to 16. Environment variables outrank the
# manifest, so bmcd's and tpi's own [profile.release] (fat LTO, one codegen
# unit, opt-level "z") never applied to the image: it was built at -O2, with no
# LTO and 16 codegen units. (panic and strip are not set by Buildroot, so the
# manifest's already applied; Buildroot strips the target afterwards anyway.)
#
# A package that wants its manifest's profile puts this word last in its
# <PKG>_CARGO_ENV: `env` unsets those three variables for the cargo that
# follows it, and cargo reads the manifest. The profile then lives in one
# place, the package's own Cargo.toml, and changing it there is enough.
TP2BMC_CARGO_OWN_PROFILE = env \
	-u CARGO_PROFILE_RELEASE_OPT_LEVEL \
	-u CARGO_PROFILE_RELEASE_LTO \
	-u CARGO_PROFILE_RELEASE_CODEGEN_UNITS

include $(sort $(wildcard $(BR2_EXTERNAL_TP2BMC_PATH)/package/*/*.mk))
