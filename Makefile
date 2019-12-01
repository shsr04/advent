IncludeFlags := -I range-v3/include
LibFlags :=
Libs := -lgmpxx -lgmp

%: %.cpp
	clang++ -std=c++17 -Werror -Ofast -flto $(IncludeFlags) $(LibFlags) -o $@ $^ $(Libs)

# (for high-performance:)
# IncludeFlags := -I range-v3/include -I parallelstl/include -I tbb/include
# LibFlags := -L tbb/build/linux_intel64_gcc_cc8.3.0_libc2.28_kernel4.19.0_release
# Libs := -ltbb -lgmpxx -lgmp
