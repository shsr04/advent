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

template <class T> ostream &operator<<(ostream &o, set<T> const &p) {
    r::copy(p, ostream_iterator<T>(o));
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

struct vertex {
    char name;
    set<char> req;
    vertex() : name(0), req() {}
    vertex(char n, set<char> r) : name(n), req(r) {}
    void add_req(set<char> p) {
        for (auto c : p)
            req.insert(c);
    }
    bool operator<(vertex const &p) const { return name < p.name; }
    bool operator==(vertex const &p) const { return name == p.name; }
};
ostream &operator<<(ostream &o, vertex const &p) {
    o << p.name << "[", r::copy(p.req, ostream_iterator<char>(o)), cout << "]";
    return o;
}

struct edge {
    vertex target;
    int weight;
    edge(vertex t, int w) : target(t), weight(w) {}
    bool operator<(edge const &p) const {
        return target < p.target || weight < p.weight;
    }
};

int shortest_path(map<coord, char> const &tiles,
                  map<vertex, set<edge>> const &graph, vertex from) {
    // struct elem {
    //    set<char> vertex;
    //    int dist;
    //};
    // auto compare = [](auto x, auto y) { return x.dist > y.dist; };
    // priority_queue<elem, vector<elem>, decltype(compare)> q(compare);
    set<vertex> unvisited;
    map<vertex, int> dist;
    for (auto &[v, e] : graph)
        unvisited.insert(v);
    map<vertex, vertex> parent;
    dist[from] = 0;
    unvisited.erase(from);
    parent[from] = {'0', {}};
    auto u = from, to = from;
    while (!unvisited.empty()) {
        for (auto &[v, e] : graph)
            if (unvisited.count(v))
                dist[v] = 999'999;
        cout << u << " " << dist[u] << "\n";
        auto min_edge = optional<edge>();
        bool dist_ok = false;
        for (auto &e : graph.at(u)) {
            if (!unvisited.count(e.target))
                continue;
            if (r::find_first_of(unvisited, e.target.req, [](auto x, auto y) {
                    return x.name == y;
                }) != unvisited.end())
                continue;
            // if (dist.at(e.target) > dist.at(u) + e.weight &&
            //    (!min_edge || e.weight < min_edge->weight))
            //    min_edge = e;
            if (dist.at(e.target) > dist.at(u) + e.weight) {
                dist_ok = true;
                dist[e.target] = dist[u] + e.weight;
                parent[e.target] = u;
                cout << " w(" << u << "->" << e.target << ") = " << e.weight
                     << "\n";
            } else if (!min_edge || e.weight < min_edge->weight) {
                min_edge = e;
            }
        }

        u = *r::min_element(
            unvisited, [&dist](auto x, auto y) { return dist[x] < dist[y]; });
        unvisited.erase(u);
        to = u;
        if (graph.at(u).empty())
            continue;
        // if (min_edge) {
        //    cout << u << "->" << min_edge->target << "\n";
        //    dist[min_edge->target] = dist[u] + min_edge->weight;
        //    parent[min_edge->target] = u;
        //}
    }
    for (auto u = to; u.name != '0'; u = parent.at(u)) {
        cout << "= " << u << " " << dist[u] << "\n";
    }
    return dist.at(to);
}

void build_subset_graph(map<coord, char> const &tiles, vertex from,
                        set<char> remaining, map<vertex, set<edge>> &r,
                        int l = 0) {
    if (remaining.empty()) {
        r[from].insert({});
        return;
    }
    // cout << l << ": build " << from << " ",
    //   r::copy(remaining, ostream_iterator<char>(cout)), cout << "\n";
    for (auto c : remaining) {
        auto [dist, req] =
            distance_and_requirements(tiles, from.name, c).value();
        if (r::find_first_of(remaining, req) != remaining.end())
            continue;
        auto new_rem = remaining % f::where([c](auto x) { return x != c; });
        // cout << remaining << "->" << new_rem << ": " << dist << " ",
        //   r::copy(req, ostream_iterator<char>(cout)), cout << "\n";
        auto to = vertex{c, req};
        to.add_req(from.req);
        r[from].insert({to, dist});
        build_subset_graph(tiles, move(to), move(new_rem), r, l + 1);
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
    cout << "@->e: " << testing.first << ", req: ";
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

    map<vertex, set<edge>> graph;
    build_subset_graph(tiles, {'@', {}}, keys, graph);
    // graph[keys_with_start] = {edge{.from = '@',
    //                               .to = '@',
    //                               .weight = 0,
    //                               .remaining = keys,
    //                               .required = {}}};

    for (auto &[u, e] : graph) {
        cout << u << " : ";
        for (auto &[t, w] : e) {
            cout << t << "(" << w << ") ";
        }
        cout << "\n";
    }

    auto path = shortest_path(tiles, graph, {'@', {}});
    cout << "Steps: " << path << "\n";
}
