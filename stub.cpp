#include "_main.hpp"

int main() {
    vector<int> v = {1, 4, 9};
    r::for_each(v, [](auto x) { cout << x << "\n"; });
}
