#include "_main.hpp"
#include <cstdlib>

static_assert(sizeof(size_t) == 2 * sizeof(int));

struct intersection_info {
    int x, y;
    int steps;
    int dist;
};

function<void(int &, int &)> step_function(char dir) {
    switch (dir) {
    case 'U':
        return [](int &x, int &y) { y++; };
    case 'D':
        return [](int &x, int &y) { y--; };
    case 'L':
        return [](int &x, int &y) { x--; };
    case 'R':
        return [](int &x, int &y) { x++; };
    default:
        cerr << "unknown dir " << dir << "\n";
        return [](int &, int &) {};
    }
}

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    map<size_t, vector<int>> grid;
    vector<size_t> intersections;
    string line;
    ifstream in(argv[1]);
    size_t n_cable = 1;
    while (in) {
        int x = 0, y = 0, n_steps = 0;
        char dir;
        int len;
        while (in >> dir && in >> len) {
            auto step = step_function(dir);
            for (auto a : v::iota(0, len)) {
                step(x, y);
                n_steps++;
                size_t key =
                    (static_cast<size_t>(unsigned(x)) << 8 * sizeof(int)) |
                    unsigned(y);
                if (auto i = grid.find(key); i == grid.end())
                    grid[key] = {0, 0};
                else if (grid[key][0] & ~n_cable) {
                    intersections.push_back(key);
                }
                grid[key][0] |= n_cable, grid[key][1] += n_steps;
            }
            if (in.get() != ',')
                break;
        }
        n_cable <<= 1;
    }

    intersection_info min_dist = {.dist = numeric_limits<int>::max()};
    intersection_info min_steps = {.steps = numeric_limits<int>::max()};
    for (auto k : intersections) {
        int x = k >> 8 * sizeof(int), y = int(k);
        int dist = abs(x) + abs(y), steps = grid[k][1];
        cout << "intersection at " << x << "," << y << ": " << dist << ";"
             << steps << "\n";
        if (dist < min_dist.dist)
            min_dist = {.x = x, .y = y, .dist = dist};
        if (steps < min_steps.steps)
            min_steps = {.x = x, .y = y, .steps = steps};
    }
    cout << "min dist: " << min_dist.x << "," << min_dist.y << ": "
         << min_dist.dist << "\n";
    cout << "min steps: " << min_steps.x << "," << min_steps.y << ": "
         << min_steps.steps << "\n";
}
