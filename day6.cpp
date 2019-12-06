#include "_main.hpp"

int main(int argc, char **argv) {
    vector<string> vertices;
    graph g(0);
    auto const insert_vertex = [&vertices, &g](auto &x) {
        if (auto i = r::find(vertices, x); i == r::end(vertices)) {
            vertices.push_back(x);
            g.add_vertex();
        }
        return distance(vertices.begin(), r::find(vertices, x));
    };

    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    string name_a, name_b;
    while (getline(in, name_a, ')') && getline(in, name_b)) {
        auto i_a = insert_vertex(name_a), i_b = insert_vertex(name_b);
        g.add_adjacency(i_a, i_b);
    }

    auto sum = 0;
    auto i_com = distance(r::begin(vertices), r::find(vertices, "COM"));
    for (auto v : v::iota(0UL, vertices.size())) {
        auto length = 0;
        if (auto p = bfs(g).path(i_com, v); p)
            length = p->size() - 1;
        // cout << "orbits " << vertices[i_com] << "->" << vertices[v] << ": "
        //     << length << "\n";
        sum += length;
    }
    cout << "total orbits: " << sum << "\n";
    
    auto i_you = distance(begin(vertices), r::find(vertices, "YOU")),
         i_san = distance(begin(vertices), r::find(vertices, "SAN"));
    cout << "YOU->SAN: " << bfs(g).path(i_you, i_san)->size() - 3
         << " transfers\n";
}
