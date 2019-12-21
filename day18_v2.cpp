#include "_main.hpp"
#include "fn.hpp"
#include <algorithm>
#include <limits>

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

set<pair<coord, int>> reachable_without(map<coord, char> const &tiles,
                                        coord from, set<char> remaining) {
    set<pair<coord, int>> reachable;
    set<coord> visited;
    visited.insert(from);
    deque<pair<coord, int>> q;
    q.push_back({from, 0});
    while (!q.empty()) {
        auto [u, dist] = q.front();
        q.pop_front();
        if (remaining.count(tiles.at(u)))
            reachable.insert({u, dist});

        vector<coord> neighbors = {
            {u.x, u.y + 1}, {u.x, u.y - 1}, {u.x + 1, u.y}, {u.x - 1, u.y}};
        for (coord &v : neighbors) {
            if (tiles.find(v) == tiles.end() || tiles.at(v) == '#')
                continue;
            if (isupper(tiles.at(v)) && remaining.count(tolower(tiles.at(v))))
                continue;
            if (visited.count(v))
                continue;
            visited.insert(v);
            q.push_back({v, dist + 1});
        }
    }
    return reachable;
}

struct edge {
    char taken;
    int weight;
    set<char> const &remaining;
    bool operator<(edge const &p) const {
        return taken < p.taken || weight < p.weight || remaining < p.remaining;
    }
};

int shortest_path(map<coord, char> const &tiles,
                  map<set<char>, set<edge>> const &graph, set<char> from,
                  set<char> to) {
    set<set<char>> unvisited;
    map<set<char>, int> dist = {{from, 0}};
    for (auto &[v, e] : graph) {
        unvisited.insert(v);
        dist[v] = 9999;
    }
    dist[from] = 0;
    auto u = from;
    while (true) {
        for (auto c : u)
            cout << c;
        cout << "\n";
        for (auto &e : graph.at(u)) {
            if (!unvisited.count(e.remaining))
                continue;
            if (dist[e.remaining] > dist.at(u) + e.weight) {
                dist[e.remaining] = dist.at(u) + e.weight;
                cout << " w(";
                for (auto a : e.remaining)
                    cout << a;
                cout << ") = " << dist[e.remaining] << "\n";
            }
        }
        unvisited.erase(u);
        if (u == to)
            break;
        u = r::min_element(dist % f::where([&](auto &x) {
                               return unvisited.count(x.first);
                           }),
                           less<>())
                ->first;
    }
    for (auto u = from; u != to;) {
        auto set1 = u;
        u = r::min_element(graph.at(u), less<>())->remaining;
        auto set2 = u;
        cout << *r::mismatch(set1, set2).first;
    }
    cout << "\n";
    return dist.at(to);
}

void build_subset_graph(map<coord, char> const &tiles, coord from,
                        set<char> remaining, map<set<char>, set<edge>> &r,
                        int l = 0) {
    if (remaining.empty())
        return;
    cout << l << ": build " << tiles.at(from) << " ";
    for (auto c : remaining)
        cout << c;
    cout << "\n";
    auto reachable = reachable_without(tiles, from, remaining);
    for (auto &[c, d] : reachable) {
        auto new_rem = remaining % f::where([key = tiles.at(c)](char x) {
                           return x != key;
                       });
        if (!r.count(new_rem))
            r[new_rem] = {};
        r[remaining].insert({.taken = tiles.at(c),
                             .weight = d,
                             .remaining = r.find(new_rem)->first});
        build_subset_graph(tiles, c, move(new_rem), r, l + 1);
    }
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
    auto start_coord =
        r::find_if(tiles, [](auto x) { return x.second == '@'; })->first;
    auto testing = reachable_without(tiles, start_coord, {'c'});
    for (auto &[c, d] : testing)
        cout << tiles.at(c) << ": " << d << "\n";
    set<char> keys;
    for (auto &[coord, c] : tiles)
        if (islower(c))
            keys.insert(c);
    map<set<char>, set<edge>> graph;
    auto keys_with_start =
        keys % f::append(set<char>{'@'}) % f::to(set<char>());
    auto closest_to_start =
        *r::min_element(reachable_without(tiles, start_coord, keys),
                        [](auto x, auto y) { return x.second < y.second; });
    graph[keys_with_start] = {edge{
        .taken = '@', .weight = closest_to_start.second, .remaining = keys}};
    build_subset_graph(tiles, start_coord, keys, graph);
    for (auto &[rem, e] : graph) {
        for (auto c : rem)
            cout << c;
        cout << " : ";
        for (auto &[c, w, rem2] : e) {
            for (auto c2 : rem2)
                cout << c2;
            cout << " ";
        }
        cout << "\n";
    }
    auto path = shortest_path(tiles, graph, keys_with_start,
                              {*r::max_element(keys, less<>())});
    cout << "Steps: " << closest_to_start.second + path << "\n";
}
