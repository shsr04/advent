#include <atomic>
#include <fstream>
#include <functional>
#include <iostream>
#include <map>
#include <optional>
#include <queue>
#include <set>
#include <string>
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
using big_int = int;
#endif

#include <range/v3/action.hpp>
#include <range/v3/algorithm.hpp>
#include <range/v3/iterator.hpp>
#include <range/v3/numeric.hpp>
#include <range/v3/view.hpp>

using namespace std;
namespace r = ranges;
namespace v = ranges::views;
namespace ra = ranges::actions;

#include "_graph.hpp"
