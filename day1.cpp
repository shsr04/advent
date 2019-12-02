#include "_main.hpp"

#ifdef USE_GMP
big_int fuel(const big_int &x) {
    big_int r = x / 3 - 2;
    if (r / 3 - 2 > 0)
        return r + fuel(r);
    else
        return move(r); 
}
#else
auto fuel(int x) {
    auto r = x / 3 - 2;
    for (auto fuel = r / 3 - 2; fuel > 0; fuel = fuel / 3 - 2) {
        r += fuel;
    }
    return r;
}
#endif

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    big_int r = 0;
    ifstream in(argv[1]);
    for (big_int a = 0; in >> a;)
        r += fuel(a);
    cout << r << "\n";
}
