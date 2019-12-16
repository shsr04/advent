#include "_main.hpp"

int main(int argc, char **argv) {
    int from, to;
    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    in >> from, in.ignore(), in >> to;
    cout << "passwords from " << from << " to " << to << "\n";
    int sum;
    vector<string> digit_list;
    for (auto n : nums(from, to + 1))
        digit_list.push_back(to_string(n));
    for (string digits : digit_list) {
        if (!r::is_sorted(digits))
            continue;
        bool ok = false;
        for (auto adj = r::adjacent_find(digits); adj != end(digits);) {
            if (*(adj + 2) != *adj) {
                ok = true;
                break;
            }
            adj = adjacent_find(
                find_if(adj + 2, end(digits),
                           [digit = *adj](auto x) { return x != digit; }),
                end(digits));
        }
        if (!ok)
            continue;
        sum++;
    }
    cout << sum << "\n";
}
