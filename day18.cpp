#include "_main.hpp"
#include <limits>

struct coord {
    int x, y;
    bool operator<(coord const &p) const {
        return x < p.x || (x == p.x && y < p.y);
    }
    bool operator==(coord const &p) const { return x == p.x && y == p.y; }
};
ostream &operator<<(ostream &o, coord const &p) {
    o << p.x << "," << p.y;
    return o;
}

map<coord, vector<coord>> build_adj(map<coord, char> const &tiles, coord pos,
                                    char last_key) {
    deque<coord> q;
    map<coord, vector<coord>> adj;
    map<coord, coord> parent;
    char next_key = 'a';
    q.push_front(pos);
    while (!q.empty()) {
        auto u = q.front();
        cout << u << ": " << tiles.at(u) << "\n";
        q.pop_front();
        vector<coord> neighbors = {
            {u.x, u.y + 1}, {u.x, u.y - 1}, {u.x + 1, u.y}, {u.x - 1, u.y}};
        for (coord &v : neighbors) {
            if (tiles.find(v) == tiles.end() || tiles.at(v) == '#')
                continue;
            if (isupper(tiles.at(v)) && tolower(tiles.at(v)) >= next_key) {
                adj[v].push_back(u);
                continue;
            }
            if (parent.find(v) != parent.end())
                continue;
            parent[v] = u;
            if (r::find(adj[u], v) == adj[u].end()) {
                adj[u].push_back(v);
            }
            q.push_back(v);
            if (tiles.at(v) == next_key) {
                auto opened_door = r::find_if(tiles, [next_key](auto &x) {
                                       return x.second == toupper(next_key);
                                   })->first;
                q.push_back(opened_door);
                cout << "pushing " << opened_door << "\n";
                next_key++;
            }
        }
    }
    return adj;
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
    auto starting_pos =
        r::find_if(tiles, [](auto &x) { return x.second == '@'; })->first;
    auto num_keys =
        r::count_if(tiles, [](auto &x) { return islower(x.second); });
    vector<char> keys;
    for (char a = 'a'; a < char('a' + num_keys); a++) {
        keys.push_back(a);
    }
    auto adj = build_adj(tiles, starting_pos, keys.back());
    map<coord, int> vertices;
    auto i_vert = 0;
    for (auto &[u, a] : adj) {
        vertices[u] = i_vert++;
    }
    graph g(i_vert);
    for (auto &[u, a] : adj) {
        for (auto &v : a) {
            g.add_adjacency(vertices.at(u), vertices.at(v), true);
        }
    }
    cout << g;
    for (char a : keys)
        cout << a << ": "
             << vertices.at(
                    r::find_if(tiles, [a](auto &x) { return x.second == a; })
                        ->first)
             << "\n";
    auto desired_key = r::find_if(tiles, [&keys](auto &x) {
                           return x.second == keys.back();
                       })->first;
    auto from = vertices.at(starting_pos), to = vertices.at(desired_key);
    auto min_steps = bfs(g).path(from, to).value();
    cout << "Minimum steps from " << from << " to " << to << ": "
         << min_steps.size() << "\n";
}
