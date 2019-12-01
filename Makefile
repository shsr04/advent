IncludeFlags := -I range-v3/include

%: %.cpp
	clang++ -std=c++17 -Werror -Ofast $(IncludeFlags) -o $@ $^
