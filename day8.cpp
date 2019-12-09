#include "_main.hpp"

int main(int argc, char **argv) {
    if (argc < 4) {
        cerr << "Usage: day8 <image> <width> <height>\n";
        return 99;
    }
    int const WIDTH = stoi(argv[2]), HEIGHT = stoi(argv[3]);
    vector<vector<int>> layers;
    auto i_layer = 0, i_pixel = 0;
    ifstream in(argv[1]);
    char digit;
    while (in >> digit) {
        if (i_layer == layers.size())
            layers.push_back({});
        layers[i_layer].push_back(digit - '0');
        i_pixel++;
        if (i_pixel % (WIDTH * HEIGHT) == 0)
            i_layer++;
    }

    auto min_zeros = *r::min_element(layers, [](auto &x, auto &y) {
        return r::count(x, 0) < r::count(y, 0);
    });
    auto product = r::count(min_zeros, 1) * r::count(min_zeros, 2);
    cout << "1*2 in min-0 layer: " << product << "\n";

    vector<int> image;
    for (auto a : v::iota(0, WIDTH * HEIGHT))
        for (auto &l : layers)
            if (l[a] != 2) {
                image.push_back(l[a]);
                break;
            }
    for (auto i : v::iota(0, WIDTH * HEIGHT)) {
        if (i % WIDTH == 0 && i > 0)
            cout << "\n";
        cout << (image[i] == 0 ? ' ' : '#');
    }
    cout << "\n";
}
