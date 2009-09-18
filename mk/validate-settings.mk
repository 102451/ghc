# DO NOT EDIT!  Instead, create a file mk/validate.mk, whose settings will
# override these.  See also mk/custom-settings.mk.

WERROR          = -Werror

HADDOCK_DOCS    = YES
SRC_CC_OPTS     += -Wall $(WERROR)
SRC_HC_OPTS     += -Wall $(WERROR) -H64m -O0 -fasm

GhcStage1HcOpts += -O -fasm

GhcStage2HcOpts += -O -fasm
# Using -O (rather than -O0) here bringes my validate down from 22mins to 16 mins.
# Compiling stage2 takes longer, but we gain a faster haddock, faster
# running of the tests, and faster building of the utils to be installed

GhcLibHcOpts    += -O -fasm -dcore-lint
GhcLibWays     := $(filter v dyn,$(GhcLibWays))
SplitObjs       = NO
NoFibWays       =
STRIP           = :

CHECK_PACKAGES = YES

ifeq "$(ValidateHpc)" "YES"
GhcStage2HcOpts += -fhpc -hpcdir $(TOP)/testsuite/hpc_output/
endif
ifeq "$(ValidateSlow)" "YES"
GhcStage2HcOpts += -XGenerics -DDEBUG
GhcLibHcOpts    += -XGenerics
endif

# Temporarily turn off unused-do-bind warnings for the time package
libraries/time_dist-install_EXTRA_HC_OPTS += -fno-warn-unused-do-bind
# On Windows, there are also some unused import warnings
libraries/time_dist-install_EXTRA_HC_OPTS += -fno-warn-unused-imports

libraries/haskeline_dist-install_EXTRA_HC_OPTS += -fno-warn-unused-imports

# Temporarily turn off unused-import warnings for the binary package
libraries/binary_dist-boot_EXTRA_HC_OPTS += -fno-warn-unused-imports
libraries/binary_dist-install_EXTRA_HC_OPTS += -fno-warn-unused-imports
