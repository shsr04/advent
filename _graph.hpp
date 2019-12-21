#pragma once
#include "_main.hpp"
#include <limits>
#include <queue>

template <class T> class graph {
    using s = typename vector<T>::size_type;
    map<T, vector<T>> adj_;
    map<pair<T, int>, int> weights_;

  public:
    graph() : adj_() {}
    graph(map<T, vector<T>> adj) : adj_(move(adj)) {}

    void add_vertex(T u) { adj_[u] = {}; }
    void add_adjacency(T u, T v, bool both_ways = true) {
        adj_.at(u).push_back(v);
        if (both_ways)
            adj_.at(v).push_back(u);
    }
    /**
     * Adds vertices of degree 1 between u and u.head(k).
     * This is a cheap way to accomplish weighted edges in combination with
     * DFS/BFS.
     * @param w added weight for the adjacency <u,k> (w=0: no added weight)
     */
    void add_weight(T u, int k, int w) { weights_[{u, k}] = w; }
    int weight(T u, int k) {
        if (weights_.find({u, k}) == weights_.end())
            return 1;
        else
            return weights_[{u, k}] + 1;
    }

    int deg(T u) const { return int(adj(u).size()); }
    int order() const { return int(adj_.size()); }
    vector<T> &adj(T u) { return adj_.at(u); }
    vector<T> const &adj(T u) const { return adj_.at(u); }
    auto const &vertices() const { return adj_; }
    T head(T u, int k) const { return adj(u).at(s(k)); }
    T &head(T u, int k) { return adj_.at(u).at(s(k)); }
    template <class U> friend ostream &operator<<(ostream &, graph<U> const &);
};

template <class T> ostream &operator<<(ostream &o, graph<T> const &g) {
    for (auto &[u, adj] : g.adj_) {
        o << u << ": ";
        for (auto v : adj)
            o << v << " ";
        o << "\n";
    }
    return o;
}

template <class T> class bfs {
    using s = vector<int>::size_type;
    graph<T> const &g_;
    map<T, T> parent_;
    map<T, char> color_;
    queue<T> q_;
    enum : char { WHITE, GRAY, BLACK };

  public:
    bfs(graph<T> const &g) : g_(g), parent_() {}
    /// Returns the path in reverse order: {to,parent(to),...,from}
    optional<vector<T>> path(T from, T to);
};

template <class T> optional<vector<T>> bfs<T>::path(T from, T to) {
    vector<T> r;
    q_.push(from);
    color_[from] = GRAY;
    while (!q_.empty()) {
        auto u = q_.front();
        q_.pop();
        if (u == to) {
            for (auto a = to; a != from; a = parent_[a]) {
                r.push_back(a);
            }
            r.push_back(from);
            return r;
        }
        for (auto v : g_.adj(u)) {
            if (color_.find(v) == color_.end())
                color_[v] = WHITE;
            if (color_[v] != WHITE)
                continue;
            color_[v] = GRAY;
            parent_[v] = u;
            q_.push(v);
        }
    }
    return {};
}

template <class T> class dfs {
    using s = vector<char>::size_type;
    struct dfs_elem {
        int u, k;
    };
    enum color : char { WHITE = 0, GRAY, BLACK };
    graph<T> const &g_;
    vector<char> c_;
    vector<dfs_elem> s_;

  public:
    enum class time_types { discover, finish };
    dfs(graph<T> const &g) : g_(g), c_(s(g_.order()), WHITE) {}
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

template <class T> class dijkstra {
    graph<T> const &g_;
    map<T, int> dist_;
    map<T, pair<T, int>> edge_to_;
    static auto const compare = [](auto x, auto y) {
        return x.second > y.second;
    };
    priority_queue<pair<T, int>, vector<pair<T, int>>, decltype(compare)> q_;

    void relax(T v) {
        for (auto k : nums(0, g_.deg(v))) {
            auto w = g_.head(v, k);
            if (dist_.at(w) > dist_.at(v).g_.weight(v, k)) {
                dist_.at(w) = dist_.at(v).g_.weight(v, k);
                edge_to_[w] = {v, k};
            }
        }
    }

  public:
    dijkstra(graph<T> const &g) : g_(g) {
        for (auto &[v, adj] : g.vertices())
            dist_[v] = numeric_limits<int>::max();
    }

    int shortest(T from, T to) {
        dist_[from] = 0;
        q_.push({from, 0});
        relax();
    }
};
