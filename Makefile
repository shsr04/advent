IncludeFlags = -I range-v3/include
LibFlags =
Libs = 
DefFlags = 
LibraryPath =

ifeq ($(parallel),1)
	IncludeFlags += -I parallelstl/include -I tbb/include
	LibFlags += -L tbb/build/linux_intel64_gcc_cc8.3.0_libc2.28_kernel4.19.0_release
	Libs += -ltbb
	DefFlags += -D USE_PARALLEL_STL
	LibraryPath = tbb/build/$(shell (cd tbb && make info | grep prefix | sed -E 's_(.+)=(.+)_\2_'))_release
endif

ifeq ($(bigint),1)
	Libs += -lgmpxx -lgmp
	DefFlags += -D USE_GMP
endif

ifdef prog
	Prog := $(prog)
else
	Prog := day5
endif 

Default = $(Prog)

ifeq ($(bear),1)
	Default = bear
endif

default: $(Default)
.SILENT: run bear
.PHONY: run bear

bear:
	bear -a make *

%: %.cpp
	clang++ -std=c++17 -Werror -g -Ofast $(IncludeFlags) $(LibFlags) $(DefFlags) -o $@ $^ $(Libs)

run: $(Default)
	echo --- Running $(Prog) ---
	export LD_LIBRARY_PATH=$(LibraryPath) && ./$(Prog) $(Prog)_input
