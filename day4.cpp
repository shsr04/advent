#include "_main.hpp"

int main(int argc, char **argv) {
    int from, to;
    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    in >> from, in.ignore(), in >> to;
    cout << "passwords from " << from << " to " << to << "\n";
    int sum;
    for (string digits : v::iota(from, to + 1) |
                             v::transform([](int x) { return to_string(x); })) {
        if (!r::is_sorted(digits))
            continue;
        bool ok = false;
        for (auto adj = r::adjacent_find(digits); adj != r::end(digits);) {
            if (*(adj + 2) != *adj) {
                ok = true;
                break;
            }
            adj = r::adjacent_find(
                r::find_if(adj + 2, r::end(digits),
                           [digit = *adj](auto x) { return x != digit; }),
                r::end(digits));
        }
        if (!ok)
            continue;
        sum++;
    }
    cout << sum << "\n";
}
