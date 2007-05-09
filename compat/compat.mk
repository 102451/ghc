# Settings for using the libghccompat.a library elsewhere in the build
# tree: this file is just included into Makefiles, see 
# utils/ghc-pkg/Makefile for example.
#
# This is a poor-mans package, but simpler because we don't
# have to deal with variations in the package support of different
# versions of GHC.

ifneq "$(UseStage1)" "YES"

SRC_HC_OPTS += -DUSING_COMPAT

# Use libghccompat.a:
SRC_HC_OPTS += -i$(GHC_COMPAT_DIR)
SRC_LD_OPTS += -L$(GHC_COMPAT_DIR) -lghccompat

# Do *not* use the installed Cabal:
ifeq "$(ghc_ge_603)" "YES"
SRC_HC_OPTS += -ignore-package Cabal
endif

# And similarly for when booting from .hc files:
HC_BOOT_LD_OPTS += -L$(GHC_COMPAT_DIR)
HC_BOOT_LIBS += -lghccompat

ifeq "$(Windows)" "YES"
# not very nice, but required for -lghccompat on Windows
SRC_LD_OPTS += -lshell32
HC_BOOT_LIBS += -lshell32
endif

# This is horrible.  We ought to be able to omit the entire directory
# from mkDependHS.
SRC_MKDEPENDHS_OPTS += \
	-optdep--exclude-module=Compat.RawSystem \
	-optdep--exclude-module=Compat.Directory \
	-optdep--exclude-module=Compat.Unicode \
	-optdep--exclude-module=Distribution.Compat.FilePath \
	-optdep--exclude-module=Distribution.Compat.ReadP \
	-optdep--exclude-module=Distribution.Extension \
	-optdep--exclude-module=Distribution.GetOpt \
	-optdep--exclude-module=Distribution.InstalledPackageInfo \
	-optdep--exclude-module=Distribution.License \
	-optdep--exclude-module=Distribution.Package \
	-optdep--exclude-module=Distribution.ParseUtils \
	-optdep--exclude-module=Distribution.Compiler \
	-optdep--exclude-module=Distribution.Version \
	-optdep--exclude-module=System.FilePath \
	-optdep--exclude-module=System.FilePath.Posix \
	-optdep--exclude-module=System.FilePath.Windows \
	-optdep--exclude-module=System.Directory.Internals

PACKAGE_CABAL =

else

PACKAGE_CABAL = -package Cabal

endif

