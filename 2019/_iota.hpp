template <class T> struct simple_iterator {
    T &val_;
    function<T(T)> f_;
    simple_iterator(T &val, function<T(T)> f) : val_(val), f_(move(f)) {}
    auto &operator*() const { return val_; }
    auto operator++() {
        val_ = f_(val_);
        return *this;
    }
    bool operator!=(simple_iterator<T> const &p) const { return val_ != p.val_; }
};

template <class T> struct iterator_traits<simple_iterator<T>> {
    using difference_type = long long;
    using iterator_category = input_iterator_tag;
};

template <class T> struct nums {
    T from_, to_;
    nums(T from, T to) : from_(from), to_(to) {}
    auto begin() {
        return simple_iterator<T>(from_, [](auto &&x) { return x + 1; });
    }
    auto end() {
        return simple_iterator<T>(to_, [](auto &&x) { return x + 1; });
    }
};
