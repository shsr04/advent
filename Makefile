IncludeFlags := -I range-v3/include
LibFlags :=
Libs := -lgmpxx -lgmp

Default := day1
$(Default):
.SILENT: run

%: %.cpp
	clang++ -std=c++17 -Werror -Ofast -flto $(IncludeFlags) $(LibFlags) -o $@ $^ $(Libs)

run: $(Default)
	./$< $(Default)_input

# (for high-performance:)
# IncludeFlags := -I range-v3/include -I parallelstl/include -I tbb/include
# LibFlags := -L tbb/build/linux_intel64_gcc_cc8.3.0_libc2.28_kernel4.19.0_release
# Libs := -ltbb -lgmpxx -lgmp
