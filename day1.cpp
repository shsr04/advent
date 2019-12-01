#include "_main.hpp"

int main() {
    vector<int> mass;
    ifstream in("day1_input");
    int a = 0;
    while (in >> a) {
        mass.push_back(a);
    }
    int r = r::accumulate(mass | v::transform([](int x) {
                              int r = x / 3 - 2;
                              for (int fuel = r / 3 - 2; fuel > 0;
                                   fuel = fuel / 3 - 2) {
                                  r += fuel;
                              }
                              return r;
                          }),
                          0);
    cout << r << "\n";
}
