#pragma once
#include "_main.hpp"

class graph {
    using s = vector<int>::size_type;
    vector<vector<int>> adj_;

  public:
    graph(int n) : adj_(s(n)) {}
    graph(vector<vector<int>> adj) : adj_(move(adj)) {}

    void add_vertex() { adj_.push_back({}); }
    void add_adjacency(int u, int v, bool both_ways = true) {
        adj_.at(s(u)).push_back(v);
        if (both_ways)
            adj_.at(s(v)).push_back(u);
    }
    /**
     * Adds vertices of degree 1 between u and u.head(k).
     * This is a cheap way to accomplish weighted edges in combination with
     * DFS/BFS.
     * @param w added weight for the adjacency <u,k> (w=0: no added weight)
     */
    void add_weight(int u, int k, int w);

    int deg(int u) const { return int(adj(u).size()); }
    int order() const { return int(adj_.size()); }
    vector<int> const &adj(int u) const { return adj_.at(s(u)); }
    int head(int u, int k) const { return adj(u).at(s(k)); }
    int &head(int u, int k) { return adj_.at(s(u)).at(s(k)); }
};

void graph::add_weight(int u, int k, int w) {
    if (w < 1)
        return;
    int v = head(u, k);
    for (int a = 0; a < w; a++) {
        adj_.push_back({-1});
        head(u, k) = order() - 1;
        u = order() - 1;
        k = 0;
    }
    head(u, k) = v;
}

ostream &operator<<(ostream &o, graph const &g) {
    for (int u = 0; u < g.order(); u++) {
        o << u << ": ";
        for (int v : g.adj(u))
            o << v << " ";
        o << "\n";
    }
    return o;
}

class bfs {
    using s = vector<int>::size_type;
    graph const &g_;
    vector<int> parent_;
    queue<int> q_;

  public:
    bfs(graph const &g) : g_(g), parent_(s(g_.order()), -1) {}
    /// Returns the path in reverse order: {to,parent(to),...,from}
    optional<vector<int>> path(int from, int to);
};

optional<vector<int>> bfs::path(int from, int to) {
    q_.push(from);
    vector<int> r;
    while (!q_.empty()) {
        auto u = q_.front();
        q_.pop();
        if (u == to) {
            for (auto a = to; a != from; a = parent_[s(a)]) {
                r.push_back(a);
            }
            r.push_back(from);
            return r;
        }
        for (int v : g_.adj(u)) {
            if (parent_[s(v)] >= 0)
                continue;
            parent_[s(v)] = u;
            q_.push(v);
        }
    }
    return {};
}

class dfs {
    using s = vector<char>::size_type;
    struct dfs_elem {
        int u, k;
    };
    enum color : char { WHITE = 0, GRAY, BLACK };
    graph const &g_;
    vector<char> c_;
    vector<dfs_elem> s_;

  public:
    enum class time_types { discover, finish };
    dfs(graph const &g) : g_(g), c_(s(g_.order()), WHITE) {}
    optional<int> time(int from, int to,
                       time_types type = time_types::discover) {
        int t = 0;
        s_.push_back({from, 0});
        c_[s(from)] = GRAY;
        while (!s_.empty()) {
            auto [u, k] = s_.back();
            s_.pop_back();
            if (u == to && k == 0 && type == time_types::discover)
                return t;
            if (u == to && k == g_.deg(u) && type == time_types::finish)
                return t;

            if (k == g_.deg(u)) {
                c_[u] = BLACK;
                continue;
            }
            s_.push_back({u, k + 1});
            if (int v = g_.head(u, k); c_[s(v)] == WHITE) {
                s_.push_back({v, 0});
                c_[s(v)] = GRAY;
                t++;
            }
        }
        return {};
    }
};
