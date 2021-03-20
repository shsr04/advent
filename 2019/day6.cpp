#include "_main.hpp"

int main(int argc, char **argv) {
    vector<string> vertices;
    graph g(0);
    auto const vertex_index = [&vertices, &g](auto &x) {
        if (auto i = r::find(vertices, x); i == end(vertices)) {
            vertices.push_back(x);
            g.add_vertex();
        }
        return distance(begin(vertices), r::find(vertices, x));
    };

    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    string name_a, name_b;
    while (getline(in, name_a, ')') && getline(in, name_b)) {
        auto i_a = vertex_index(name_a), i_b = vertex_index(name_b);
        g.add_adjacency(i_a, i_b);
    }

    auto sum = 0_s;
    auto i_com = distance(begin(vertices), r::find(vertices, "COM"));
    for (auto v : nums(0_s, vertices.size())) {
        auto length = 0_s;
        if (auto p = bfs(g).path(i_com, v); p)
            length = p->size() - 1;
        sum += length;
    }
    cout << "total orbits: " << sum << "\n";

    auto i_you = distance(begin(vertices), r::find(vertices, "YOU")),
         i_san = distance(begin(vertices), r::find(vertices, "SAN"));
    cout << "YOU->SAN: " << bfs(g).path(i_you, i_san)->size() - 3
         << " transfers\n";
}
