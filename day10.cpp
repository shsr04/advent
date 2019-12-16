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
    for (auto b_y : nums(0, int(grid.size()))) {
        for (auto b_x : nums(0, int(grid[b_y].size()))) {
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
                sight[{i_x, i_y}] = 0;
            i_x++;
        });
        grid.push_back(line);
    }

    for (auto &[a, n_a] : sight)
        n_a = all_in_sight(grid, sight, a).size();
    coord max = {-1, -1};
    int n_max = -1;
    for (auto &[c, n] : sight) {
        if (DEBUG > 0)
            cout << "asteroid " << c.first << "," << c.second << ": " << n
                 << "\n";
        if (n > n_max)
            max = c, n_max = n;
    }
    cout << "max detection: " << max.first << "," << max.first << ": " << n_max
         << "\n";

    int n_vaporized = 0;
    while (sight.size() > 1) {
        vector<coord> visible;
        for (auto &&c : all_in_sight(grid, sight, max))
            visible.push_back(c);
        sort(visible.begin(), visible.end(), [&max](auto &x, auto &y) {
            /// atan2: (y,x) -> phi
            ///  => r*cos(phi) = x, r*sin(phi) = y
            ///  where r=sqrt(x^2+y^2) is the length of (x,y)
            /// Short: angle between (x,y) and the x axis
            /// In detail:
            ///     if x>0, atan2 = arctan(y/x)
            ///     if x<0 and y>=0, atan2 = arctan(y/x)+pi
            ///     if x<0 and y<0, atan2 = arctan(y/x)-pi
            ///     if x=0 and y>0, atan2 = pi/2
            ///     if x=0 and y<0, atan2 = -pi/2
            /// Explanation:
            ///     atan2 computes the argument of a complex number x+iy.
            ///     arg(x+iy) = any real number phi for which
            ///         x+iy = r(cos(phi)+i*sin(phi)).
            ///     The arg function is multi-valued (invariant to full-circle rotations),
            ///     so atan2 restricts itself to the interval [pi,-pi].
            auto x_angle = atan2(max.second - x.second, max.first - x.first),
                 y_angle = atan2(max.second - y.second, max.first - y.first);
            return x_angle < y_angle;
        });
        auto up = r::find_if(visible, [&max](auto &x) {
            return atan2(max.second - x.second, max.first - x.first) >=
                   M_PI / 2;
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

    /*
    coord laser = {0, -1}; // length is 1
    int n_vaporized = 0;
    while (sight.size() > 1) {
        auto angle = asin(laser.second);
        auto delta = -M_PI/180;
        auto x1 = laser.first, y1 = laser.second;
        // cout << x1 << " " << y1 << " " << angle << " => ";
        auto x2 = x1 * cos(delta) - y1 * sin(delta),
             y2 = x1 * sin(delta) + y1 * cos(delta);
        // cout << x2 << " " << y2 << " " << angle + delta << "\n";
        auto f = first_collision(
            grid, sight, max,
            {max.first + laser.first, max.second + laser.second});
        laser = {x2, y2};
        if (!f)
            continue;
        auto c = *f;
        sight.erase(sight.find(c));
        n_vaporized++;
        // if (DEBUG > 0)
        cout << "vaporized " << n_vaporized << " " << c.first << "," << c.second
             << "\n";
        if (n_vaporized == 200)
            cout << "200th vaporized: " << c.first << "," << c.second << " = "
                 << 100 * c.first + c.second << "\n";
    }
    */
}
