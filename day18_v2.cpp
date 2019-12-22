#include "_main.hpp"
#include "fn.hpp"
#include <algorithm>
#include <iterator>
#include <limits>
#include <queue>

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

coord key_coord(map<coord, char> const &tiles, char sym) {
    return r::find_if(tiles, [sym](auto &x) { return x.second == sym; })->first;
}

template<class T>
ostream& operator<<(ostream&o, set<T> const&p) {
    r::copy(p,ostream_iterator<T>(o));
    return o;
}

optional<pair<int, set<char>>>
distance_and_requirements(map<coord, char> const &tiles, char from, char to) {
    static map<set<char>, pair<int, set<char>>> memory;
    if (memory.count({from, to}))
        return memory[{from, to}];
    map<coord, coord> parent;
    deque<pair<coord, int>> q;
    q.push_back({key_coord(tiles, from), 0});
    while (!q.empty()) {
        auto [u, dist] = q.front();
        q.pop_front();
        if (u == key_coord(tiles, to)) {
            set<char> required;
            for (auto a = key_coord(tiles, to); a != key_coord(tiles, from);
                 a = parent.at(a)) {
                if (isupper(tiles.at(a)))
                    required.insert(tolower(tiles.at(a)));
            }
            memory[{from, to}] = {dist, required};
            return {{dist, move(required)}};
        }

        vector<coord> neighbors = {
            {u.x, u.y + 1}, {u.x, u.y - 1}, {u.x + 1, u.y}, {u.x - 1, u.y}};
        for (coord &v : neighbors) {
            if (tiles.find(v) == tiles.end() || tiles.at(v) == '#')
                continue;
            if (parent.count(v))
                continue;

            parent[v] = u;
            q.push_back({v, dist + 1});
        }
    }
    return {};
}

struct edge {
    char taken;
    int weight;
    set<char> remaining, required;
    bool operator<(edge const &p) const {
        return taken < p.taken || weight < p.weight || remaining < p.remaining;
    }
};

int shortest_path(map<coord, char> const &tiles,
                  map<set<char>, set<edge>> const &graph, set<char> from,
                  set<char> to) {
    // struct elem {
    //    set<char> vertex;
    //    int dist;
    //};
    // auto compare = [](auto x, auto y) { return x.dist > y.dist; };
    // priority_queue<elem, vector<elem>, decltype(compare)> q(compare);
    set<set<char>> unvisited;
    map<set<char>, int> dist;
    for (auto &[v, e] : graph)
        unvisited.insert(v), dist[v] = 999'999;
    map<set<char>, set<char>> parent;
    dist[from] = 0;
    // TODO: also consider vertex coordinates, not just remaining sets!!!
    while (!unvisited.empty()) {
        auto u = *r::min_element(
            unvisited, [&dist](auto x, auto y) { return dist[x] < dist[y]; });
        // for (auto c : u)
        //   cout << c;
        // cout << " " <<dist[u]<<"\n";
        unvisited.erase(u);
        for (auto &e : graph.at(u)) {
            if (!unvisited.count(e.remaining))
                continue;
            if (dist.at(e.remaining) > dist.at(u) + e.weight) {
                dist[e.remaining] = dist[u] + e.weight;
                parent[e.remaining] = u;
                cout << " w(";
                for (auto a : u)
                    cout << a;
                cout << "->";
                for (auto a : e.remaining)
                    cout << a;
                cout << ") = " << e.weight << "\n";
            }
        }
    }
    for (auto u = to;; u = parent.at(u)) {
        r::copy(u, ostream_iterator<char>(cout)),
            cout << " " << dist[u] << "\n";
            if(u==from) break;
    }
    return dist.at(to);
}

void build_subset_graph(map<coord, char> const &tiles, char from,
                        set<char> remaining, set<char> required,
                        map<set<char>, set<edge>> &r, int l = 0) {
    if (remaining.empty())
        return;
    // cout << l << ": build " << from << " ",
    //   r::copy(remaining, ostream_iterator<char>(cout)), cout << "\n";
    for (auto c : remaining) {
        auto [dist, req] = distance_and_requirements(tiles, from, c).value();
        if (r::find_first_of(remaining, req) != remaining.end())
            continue;
        auto new_rem = remaining % f::where([c](auto x) { return x != c; });
        cout << remaining << "->" << new_rem << ": " << dist << " ",
          r::copy(req, ostream_iterator<char>(cout)), cout << "\n";
        for (auto r : req)
            required.insert(r);
        r[remaining].insert({.taken = c,
                             .weight = dist,
                             .remaining = new_rem,
                             .required = {}});
        build_subset_graph(tiles, c, move(new_rem), move(required), r, l + 1);
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
    auto testing = distance_and_requirements(tiles, '@', 'e').value();
    cout << "@->c: " << testing.first << ", req: ";
    for (auto r : testing.second)
        cout << r;
    cout << "\n";

    set<char> keys;
    for (auto &[coord, c] : tiles)
        if (islower(c))
            keys.insert(c);
    auto keys_with_start =
        keys % f::append(set<char>{'@'}) % f::to(set<char>());
    pair<char, int> closest_to_start = {'?', 99999};
    for (auto k : keys)
        if (auto [dist, req] = distance_and_requirements(tiles, '@', k).value();
            dist < closest_to_start.second && req.empty())
            closest_to_start = {k, dist};
    cout << "Closest to @: " << closest_to_start.first << " with "
         << closest_to_start.second << "\n";

    map<set<char>, set<edge>> graph;
    //graph[keys_with_start] = {edge{.taken = '@',
    //                               .weight = closest_to_start.second,
    //                               .remaining = keys,
    //                               .required = {}}};
    build_subset_graph(tiles, '@', keys, {}, graph);
    /*
    for (auto &[rem, e] : graph) {
        for (auto c : rem)
            cout << c;
        cout << " : ";
        for (auto &[c, w, rem2, req2] : e) {
            for (auto c2 : rem2)
                cout << c2;
            cout << " ";
        }
        cout << "\n";
    }
    */

    auto path = shortest_path(tiles, graph, keys,
                              {*r::max_element(keys, less<>())});
    cout << "Steps: " << path << "\n";
}
