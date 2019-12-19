#include "_main.hpp"
#include "fn.hpp"
#include <algorithm>
#include <cctype>
#include <iterator>
#include <limits>
#include <ostream>

struct coord {
    int x, y;
    bool operator<(coord const &p) const {
        return x < p.x || (x == p.x && y < p.y);
    }
    bool operator==(coord const &p) const { return x == p.x && y == p.y; }
    bool operator!=(coord const &p) const { return x != p.x || y != p.y; }
};
ostream &operator<<(ostream &o, coord const &p) {
    o << p.x << "," << p.y;
    return o;
}

template <class T> auto find_key(map<coord, T> const &tiles, T symbol) {
    return r::find_if(tiles, [&symbol](auto &p) { return p.second == symbol; })
        ->first;
}

optional<int> distance(map<coord, char> const &tiles, set<char> const &passable,
                       char from, char to) {
    map<coord, coord> parent;
    deque<coord> q;
    q.push_back(find_key(tiles, from));
    while (!q.empty()) {
        auto u = q.front();
        if (tiles.at(u) == to) {
            auto dist = 0;
            for (auto a = u; tiles.at(a) != from; a = parent.at(a)) {
                dist++;
            }
            return dist;
        }
        q.pop_front();
        vector<coord> neighbors = {
            {u.x, u.y + 1}, {u.x, u.y - 1}, {u.x + 1, u.y}, {u.x - 1, u.y}};
        for (coord &v : neighbors) {
            if (tiles.find(v) == tiles.end() || tiles.at(v) == '#')
                continue;
            if (isupper(tiles.at(v)) && !r::contains(passable, tiles.at(v)))
                continue;
            if (parent.find(v) != parent.end())
                continue;
            parent[v] = u;
            q.push_back(v);
        }
    }
    return {};
}

map<tuple<char, char, set<char>>, int> DISTANCE_MAP;
vector<char> DOORS;

int all_distances(map<coord, char> const &tiles, char from,
                  set<char> const &passable, set<char> const &remaining) {
    cout << "all_distances " << from << " [ ",
        r::copy(passable, ostream_iterator<char>(cout, " ")), cout << "] [ ",
        r::copy(remaining, ostream_iterator<char>(cout, " ")), cout << "]\n";
    if (remaining.empty())
        return 0;
    auto min_dist = 999'999;
    vector<pair<char, int>> q;
    for (char a : remaining)
        if (auto saved =
                DISTANCE_MAP.find({min(from, a), max(from, a), passable});
            saved != DISTANCE_MAP.end())
            q.push_back({a, saved->second});
    for (auto &[to, dist] : q) {
        auto added_door = r::contains(DOORS, toupper(to))
                              ? passable %
                                    f::append(vector<char>{char(toupper(to))}) %
                                    f::to(set<char>())
                              : passable,
             removed_key =
                 remaining % f::where([to = to](auto x) { return x != to; });
        auto l = dist +
                 all_distances(tiles, to, move(added_door), move(removed_key));
        cout << from << " " << to << ": l=" << l << "\n";
        if (l < min_dist)
            min_dist = l;
    }
    cout << "<=  " << min_dist << "    all_distances " << from << " [ ",
        r::copy(passable, ostream_iterator<char>(cout, " ")), cout << "] [ ",
        r::copy(remaining, ostream_iterator<char>(cout, " ")), cout << "]\n";
    return min_dist;
}

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    map<coord, char> tiles;
    string line;
    coord c_tile = {0, 0};
    coord dimensions = {0, 0};
    while (in >> line) {
        c_tile.x = 0;
        for (char a : line) {
            tiles[c_tile] = a;
            c_tile.x++;
            dimensions.x = max(c_tile.x, dimensions.x);
        }
        c_tile.y++;
        dimensions.y = max(c_tile.y, dimensions.y);
    }
    auto [last_coord, last_key] = *r::max_element(
        tiles, [](auto x, auto y) { return x.second < y.second; });
    set<char> keys;
    for (auto c = 'a'; c <= last_key; c++)
        keys.insert(c);

    for (auto &[p, c] : tiles)
        if (isupper(c))
            DOORS.push_back(c);
    cout << "Doors: " << DOORS.size() << "\n";
    set<set<char>> door_sets;
    for (auto n : nums(0_s, 1_s << DOORS.size())) {
        set<char> r;
        for (auto i : nums(0_s, DOORS.size()))
            if (n & (1 << i))
                r.insert(DOORS.at(i));
        door_sets.insert(move(r));
    }
    for (auto a : keys) {
        DISTANCE_MAP[{'@', a, {}}] =
            distance(tiles, {}, '@', a).value_or(999'999);
        for (auto b : keys) {
            if (a >= b)
                continue;
            for (auto c : door_sets) {
                if (auto dist = distance(tiles, c, min(a, b), max(a, b));
                    dist) {
                    DISTANCE_MAP[{min(a, b), max(a, b), c}] = dist.value();
                    cout << "dist " << min(a, b) << " " << max(a, b) << " ",
                        r::copy(c, ostream_iterator<char>(cout, " ")),
                        cout << " = " << DISTANCE_MAP[{min(a, b), max(a, b), c}]
                             << "\n";
                }
            }
        }
    }
    auto n = all_distances(tiles, '@', {}, keys);
    cout << "Steps: " << n << "\n";
}
