namespace hacked_ranges {
#define HACKED_CONT(name)                                                      \
    template <class C> auto name(C &&c) { return name(begin(c), end(c)); }
#define HACKED_CONTS(name)                                                     \
    template <class C, class D> auto name(C &&c, D &&d) {                      \
        return name(begin(c), end(c), begin(d), end(d));                       \
    }
#define HACKED_CONTS_WITH_1_ARG(name)                                                     \
    template <class C, class D,class T> auto name(C &&c, D &&d,T&&t) {                      \
        return name(begin(c), end(c), begin(d), end(d),forward<T>(t));                       \
    }
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
HACKED_CONT(unique)
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
HACKED_CONT_WITH_1_ARG(iota)

HACKED_CONT_WITH_2_ARGS(accumulate)
HACKED_CONT_WITH_2_ARGS(transform)
HACKED_CONT_WITH_2_ARGS(copy_if)

HACKED_CONTS(mismatch)
HACKED_CONTS(find_first_of)

HACKED_CONTS_WITH_1_ARG(find_first_of)

template <class C, class T> auto contains(C &&c, T &&t) {
    return find(begin(c), end(c), forward<T>(t)) != end(c);
}

} // namespace hacked_ranges
