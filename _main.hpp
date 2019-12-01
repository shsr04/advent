#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <string>
#include <atomic>
#include <vector>

#ifdef USE_PARALLEL_STL
#include <pstl/execution>
#include <pstl/algorithm>
#include <pstl/numeric>
#include <pstl/memory>
#endif

#include <gmpxx.h>
using big_int = mpz_class;

#include <range/v3/action.hpp>
#include <range/v3/algorithm.hpp>
#include <range/v3/iterator.hpp>
#include <range/v3/numeric.hpp>
#include <range/v3/view.hpp>

using namespace std;
namespace r = ranges;
namespace v = ranges::views;
namespace a = ranges::actions;
