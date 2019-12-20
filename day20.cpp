#include "_main.hpp"
#include <queue>
#include <thread>

struct coord {
    int x, y;
    bool operator<(coord const &p) const {
        return x < p.x || (x == p.x && y < p.y);
    }
    bool operator==(coord const &p) const { return x == p.x && y == p.y; }
    bool operator!=(coord const &p) const { return x != p.x || y != p.y; }
};
ostream &operator<<(ostream &o, coord const &p) {
    o << p.y + 1 << "," << p.x + 1;
    return o;
}

optional<coord> get_adjacent_uppercase(map<coord, char> const &tiles,
                                       coord pos) {
    vector<coord> neighbors = {{pos.x, pos.y + 1},
                               {pos.x, pos.y - 1},
                               {pos.x + 1, pos.y},
                               {pos.x - 1, pos.y}};
    for (coord &v : neighbors) {
        if (tiles.find(v) != tiles.end() && isupper(tiles.at(v)))
            return v;
    }
    return {};
}
optional<coord> get_adjacent_period(map<coord, char> const &tiles, coord p) {
    vector<coord> neighbors = {
        {p.x, p.y + 1}, {p.x, p.y - 1}, {p.x + 1, p.y}, {p.x - 1, p.y}};
    for (coord &v : neighbors) {
        if (tiles.find(v) != tiles.end() && tiles.at(v) == '.')
            return v;
    }
    return {};
}

bool are_grouped(coord a, coord b) {
    vector<coord> neighbors = {
        a, {a.x, a.y + 1}, {a.x, a.y - 1}, {a.x + 1, a.y}, {a.x - 1, a.y}};
    for (coord &v : neighbors)
        if (v == b)
            return true;
    return false;
}

bool is_outer_edge(map<coord, char> const &tiles, coord pos) {
    auto grid_size = r::max_element(tiles, [](auto x, auto y) {
                         return x.first < y.first;
                     })->first;
    if (pos.x < 5 || pos.y < 5 || pos.x >= grid_size.x - 5 ||
        pos.y >= grid_size.y - 5)
        return true;
    return false;
}

void print_grid(map<coord, char> const &tiles, coord marker, char symbol) {
    auto grid_size =
        r::max_element(tiles, [](auto x, auto y) { return x < y; })->first;
    cout << "\033[2J\033[1;1H";
    for (auto y : nums(0, grid_size.y)) {
        for (auto x : nums(0, grid_size.x)) {
            if (marker == coord{x, y})
                cout << symbol;
            else
                cout << tiles.at({x, y});
        }
        cout << "\n";
    }
}

/// Get the pair's coordinate, but excluding the `exclude` coordinate.
/// This is used to find the corresponding other label of a label.
optional<coord> get_corresponding_pair(map<coord, char> const &tiles,
                                       coord exclude, char first, char second) {
    auto label = r::find_if(tiles, [first, second, exclude, &tiles](auto &x) {
        return !are_grouped(x.first, exclude) && x.second == first &&
               tiles.at(get_adjacent_uppercase(tiles, x.first).value()) ==
                   second;
    });
    if (label == tiles.end())
        return {};

    auto path_tile = get_adjacent_period(tiles, label->first);
    if (!path_tile)
        path_tile = get_adjacent_period(
            tiles, get_adjacent_uppercase(tiles, label->first).value());
    return path_tile.value();
}

/// @param teleporter One end of one side of a teleporter (e.g. the `B` tile of
/// a BC teleporter)
optional<coord> get_other_end(map<coord, char> const &tiles, coord teleporter) {
    auto first = teleporter,
         second = get_adjacent_uppercase(tiles, teleporter).value();
    if (first.x > second.x || first.y > second.y)
        swap(first, second);
    auto other_end = get_corresponding_pair(tiles, teleporter, tiles.at(first),
                                            tiles.at(second));
    return other_end;
}

optional<int> distance(map<coord, char> const &tiles, coord from, coord to) {
    struct elem {
        coord u;
        int level;
        int dist;
        elem(coord p_u, int p_l, int p_d) : u(p_u), level(p_l), dist(p_d) {}
    };

    set<pair<coord, int>> visited;
    visited.insert({from, 0});
    deque<elem> q;
    q.push_back({from, 0, 0});

    while (!q.empty()) {
        auto [u, level, dist] = q.front();
        q.pop_front();
        // cout << u << " L" << level << "\n";
        if (u == to && level == 0)
            return dist;

        vector<coord> neighbors = {
            {u.x, u.y + 1}, {u.x, u.y - 1}, {u.x + 1, u.y}, {u.x - 1, u.y}};
        for (coord &v : neighbors) {
            if (tiles.find(v) == tiles.end() ||
                !(isupper(tiles.at(v)) || tiles.at(v) == '.'))
                continue;

            auto l = level;
            if (isupper(tiles.at(v))) {
                if (l == 0 && is_outer_edge(tiles, v))
                    continue;
                auto w = get_other_end(tiles, v);
                if (!w)
                    continue;
                visited.insert({v, l});
                l += is_outer_edge(tiles, v) ? -1 : 1;
                v = w.value();
            }

            if (visited.count({v, l}))
                continue;
            visited.insert({v, l});
            q.push_back({v, l, dist + 1});
        }
    }
    return {};
}

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    map<coord, char> tiles;
    string line;
    coord c_tile = {0, 0};
    coord dimensions = {0, 0};
    while (getline(in, line)) {
        c_tile.x = 0;
        for (char a : line) {
            tiles[c_tile] = a;
            c_tile.x++;
            dimensions.x = max(c_tile.x, dimensions.x);
        }
        c_tile.y++;
        dimensions.y = max(c_tile.y, dimensions.y);
    }
    auto start = get_corresponding_pair(tiles, {0, 0}, 'A', 'A').value(),
         end = get_corresponding_pair(tiles, {0, 0}, 'Z', 'Z').value();
    cout << "Start: " << start << ", End: " << end << "\n";
    cout << distance(tiles, start, end).value() << "\n";
}
