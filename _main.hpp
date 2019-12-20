#pragma once
#include <algorithm>
#include <array>
#include <bitset>
#include <chrono>
#include <cmath>
#include <deque>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <numeric>
#include <optional>
#include <queue>
#include <unordered_set>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#ifdef USE_PARALLEL_STL
#include <pstl/algorithm>
#include <pstl/execution>
#include <pstl/memory>
#include <pstl/numeric>
#endif

#ifdef USE_GMP
#include <gmpxx.h>
using big_int = mpz_class;
#else
using big_int = ssize_t;
#endif

#include <fn.hpp>

using namespace std;
namespace f = rangeless::fn;
using f::operators::operator%;
using f::operators::operator%=;

/// Converts int literal to size_t
size_t operator""_s(unsigned long long p) { return static_cast<size_t>(p); }

#include "_graph.hpp"
#include "_iota.hpp"
#include "_range.hpp"
namespace r = hacked_ranges;
