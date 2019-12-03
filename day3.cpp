#include "_main.hpp"
#include <iterator>
#include <limits>

struct intersection_info {
    int x, y;
    int steps;
    int dist;
};

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    unordered_map<string, vector<int>> grid;
    unordered_map<string, intersection_info> intersections;
    string line;
    ifstream in(argv[1]);
    size_t n_cable = 1;
    while (getline(in, line)) {
        cout << "CABLE " << n_cable << "\n";
        vector<string> s = a::split(line, ',');
        int x = 0, y = 0;
        int n_steps = 0;
        copy(s.begin(), s.end(), ostream_iterator<string>(cout, " "));
        for (auto &a : s) {
            char dir = a[0];
            function<vector<int>(int, int)> step;
            switch (dir) {
            case 'U':
                step = [](int x, int y) { return vector<int>{x, y + 1}; };
                break;
            case 'D':
                step = [](int x, int y) { return vector<int>{x, y - 1}; };
                break;
            case 'L':
                step = [](int x, int y) { return vector<int>{x - 1, y}; };
                break;
            case 'R':
                step = [](int x, int y) { return vector<int>{x + 1, y}; };
                break;
            default:
                cerr << "unknown dir " << dir << "\n";
                return 1;
            }
            auto len = stoi(a.substr(1));
            // cout << "going " << dir << " " << len << "\n";
            for (int a = 0; a < len; a++) {
                auto b = step(x, y);
                n_steps++;
                x = b[0];
                y = b[1];
                auto key = to_string(x) + "," + to_string(y);
                if (auto i = grid.find(key); i == grid.end())
                    grid[key] = {0, n_steps};
                if (grid[key][0] & ~n_cable) {
                    intersections[key] = {x, y, grid[key][1] + n_steps,
                                          abs(x) + abs(y)};
                    cout << "intersection at " << key << "; " << intersections[key].steps
                         << "\n";
                }
                grid[key][0] |= n_cable;
            }
        }
        n_cable <<= 1;
    }
    intersection_info min_dist = {.dist = numeric_limits<int>::max()};
    intersection_info min_steps = {.steps = numeric_limits<int>::max()};
    for (auto &[k, i] : intersections) {
        if (i.dist < min_dist.dist)
            min_dist = i;
        if (i.steps < min_steps.steps)
            min_steps = i;
    }
    cout << "min dist: " << min_dist.x << "," << min_dist.y << ": "
         << min_dist.dist << "\n";
    cout << "min steps: " << min_steps.x << "," << min_steps.y << ": "
         << min_steps.steps << "\n";
}
