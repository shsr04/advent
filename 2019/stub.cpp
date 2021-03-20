#include "_main.hpp"

int main() {
    graph g({{1, 2}, {2}, {3}, {2}});
    auto p = *bfs(g).path(0, 3);
    copy(p.rbegin(), p.rend(), ostream_iterator<int>(cout, " "));
}
