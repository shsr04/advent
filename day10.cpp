#include "_main.hpp"

using coord = pair<double, double>;

int const DEBUG = 0;
double const EPSILON = 1e-10;

double clamp_to_epsilon(double p) {
    if (abs(p - floor(p)) < EPSILON)
        return p - abs(p - floor(p));
    if (abs(ceil(p) - p) < EPSILON)
        return p + abs(ceil(p) - p);
    return p;
}

optional<coord> first_collision(vector<string> const &grid,
                                map<coord, int> const &sight, coord a,
                                coord b) {
    if (a == b)
        return {};
    auto step_x = double(a.first), step_y = double(a.second);
    auto dest_x = double(b.first), dest_y = double(b.second);
    auto delta_x = dest_x - step_x, delta_y = dest_y - step_y;
    auto sum_deltas = abs(delta_x) + abs(delta_y);
    if (DEBUG > 2)
        cout << step_x << "," << step_y << " -> " << dest_x << "," << dest_y
             << " (+ " << clamp_to_epsilon(delta_x / sum_deltas) << ","
             << clamp_to_epsilon(delta_y / sum_deltas) << ")\n";
    while (true) {
        if (step_x < 0 || step_y < 0 || step_y > double(grid.size()) ||
            step_x > double(grid[step_y].size()))
            break;
        if (step_x == dest_x && step_y == dest_y)
            break;
        step_x += delta_x / sum_deltas;
        step_y += delta_y / sum_deltas;
        step_x = clamp_to_epsilon(step_x);
        step_y = clamp_to_epsilon(step_y);
        if (DEBUG > 3)
            cout << step_x << "," << step_y << "\n";
        if (sight.find({step_x, step_y}) != sight.end())
            return {{step_x, step_y}};
    }
    return {};
}

set<coord> all_in_sight(vector<string> const &grid,
                        map<coord, int> const &sight, coord a) {
    set<coord> collided;
    for (auto b_y : v::iota(0, int(grid.size()))) {
        for (auto b_x : v::iota(0, int(grid[b_y].size()))) {
            auto o_coll = first_collision(grid, sight, a, {b_x, b_y});
            if (!o_coll)
                continue;
            if (auto [c_x, c_y] = *o_coll;
                collided.find({c_x, c_y}) == collided.end()) {
                if (DEBUG > 1)
                    cout << a.first << "," << a.second << ": collision at "
                         << c_x << "," << c_y << "\n";
                collided.insert({c_x, c_y});
            }
        }
    }
    return collided;
}

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    vector<string> grid;
    map<coord, int> sight;
    string line;
    for (int i_y = 0; getline(in, line); i_y++) {
        int i_x = 0;
        r::for_each(line, [&sight, &i_x, &i_y](auto x) {
            if (x == '#')
                sight[coord(i_x, i_y)] = 0;
            i_x++;
        });
        grid.push_back(line);
    }

    for (auto &[a, n_a] : sight)
        n_a = all_in_sight(grid, sight, a).size();
    pair<coord, int> max = {{-1, -1}, -1};
    for (auto &[c, n] : sight) {
        if (DEBUG > 0)
            cout << "asteroid " << c.first << "," << c.second << ": " << n
                 << "\n";
        if (n > max.second)
            max = {c, n};
    }
    cout << "max detection: " << max.first.first << "," << max.first.second
         << ": " << max.second << "\n";

    auto s = max.first;
    int n_vaporized = 0;
    while (sight.size() > 1) {
        vector<coord> visible;
        for (auto &&c : all_in_sight(grid, sight, s))
            visible.push_back(c);
        sort(visible.begin(), visible.end(), [&s](auto &x, auto &y) {
            auto x_angle = atan2(s.second - x.second, s.first - x.first),
                 y_angle = atan2(s.second - y.second, s.first - y.first);
            return x_angle < y_angle;
        });
        auto up = r::find_if(visible, [&s](auto &x) {
            return atan2(s.second - x.second, s.first - x.first) >= M_PI / 2;
        });
        rotate(visible.begin(), up, visible.end());
        for (auto &c : visible) {
            sight.erase(sight.find(c));
            n_vaporized++;
            if (DEBUG > 0)
                cout << "vaporized " << n_vaporized << " " << c.first << ","
                     << c.second << "\n";
            if (n_vaporized == 200)
                cout << "200th vaporized: " << c.first << "," << c.second
                     << " = " << 100 * c.first + c.second << "\n";
        }
    }
}
