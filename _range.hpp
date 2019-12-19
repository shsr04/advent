namespace hacked_ranges {
#define HACKED_CONT(name)                                                      \
    template <class C> auto name(C &&c) { return name(begin(c), end(c)); }
#define HACKED_CONT_WITH_1_ARG(name)                                           \
    template <class C, class T> auto name(C &&c, T &&t) {                      \
        return name(begin(c), end(c), forward<T>(t));                          \
    }
#define HACKED_CONT_WITH_2_ARGS(name)                                          \
    template <class C, class T, class U> auto name(C &&c, T &&t, U &&u) {      \
        return name(begin(c), end(c), forward<T>(t), forward<U>(u));           \
    }

HACKED_CONT(reverse)
HACKED_CONT(is_sorted)
HACKED_CONT(adjacent_find)
HACKED_CONT(next_permutation)

HACKED_CONT_WITH_1_ARG(copy)
HACKED_CONT_WITH_1_ARG(for_each)
HACKED_CONT_WITH_1_ARG(find)
HACKED_CONT_WITH_1_ARG(find_if)
HACKED_CONT_WITH_1_ARG(remove_if)
HACKED_CONT_WITH_1_ARG(max_element)
HACKED_CONT_WITH_1_ARG(min_element)
HACKED_CONT_WITH_1_ARG(partition)
HACKED_CONT_WITH_1_ARG(count)
HACKED_CONT_WITH_1_ARG(count_if)

HACKED_CONT_WITH_2_ARGS(accumulate)
HACKED_CONT_WITH_2_ARGS(transform)
HACKED_CONT_WITH_2_ARGS(copy_if)

} // namespace hacked_ranges
