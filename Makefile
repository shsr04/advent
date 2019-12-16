IncludeFlags = -I rangeless/include
LibFlags =
Libs =
DefFlags = 
LdLibraryPath =

ifeq ($(parallel),1)
	TbbPath := tbb/build/$(shell (cd tbb && make info | grep prefix | sed -E 's_(.+)=(.+)_\2_'))_release
	IncludeFlags += -I parallelstl/include -I tbb/include
	LibFlags += -L $(TbbPath)
	Libs += -ltbb
	DefFlags += -D USE_PARALLEL_STL
	LdLibraryPath += $(TbbPath)
endif

ifeq ($(bigint),1)
	Libs += -lgmpxx -lgmp
	DefFlags += -D USE_GMP
endif

ifdef prog
	Prog := $(prog)
else
	Prog := day14
endif

default: $(Prog)
.SILENT: run tests
.PHONY: run tests

compile_commands.json:
	echo --- Rebuilding $@ ---
	bear make $(patsubst %.cpp, %, $(wildcard day*.cpp)) -B

%: %.cpp
	clang++ -std=c++17 -Werror -g -Ofast $(IncludeFlags) $(LibFlags) $(DefFlags) -o $@ $^ $(Libs)

run: $(Prog)
	echo --- Running $(Prog) ---
	export LD_LIBRARY_PATH=$(LdLibraryPath) && ./$(Prog) $(Prog)_input

tests: day2 day5 day7
	test "$(shell ./day2 day2_input)" = "8444"
	test "$(shell echo 1 |./day5 day5_input | tail -n 1)" = "> 9006673"
	test "$(shell ./day7 day7_input | tail -n 1)" = "14260332"
	echo -- All intcode tests passed.
