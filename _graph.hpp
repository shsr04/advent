class graph {
    vector<vector<int>> adj_;

  public:
    graph(int n) : adj_(n) {}
    graph(vector<vector<int>> adj) : adj_(move(adj)) {}

    void add_vertex() { adj_.push_back({}); }
    void add_adjacency(int u, int v) { adj_.at(u).push_back(v); }
    /**
     * Adds vertices of degree 1 between u and u.head(k).
     * This is a cheap way to accomplish weighted edges in combination with BFS.
     * @param w weight for the adjacency <u,k> (w=1: no added weight)
     */
    void set_weight(int u, int k, int w = 1);

    int deg(int u) const { return adj_.at(u).size(); }
    int order() const { return adj_.size(); }
    vector<int> const &adj(int u) const { return adj_.at(u); }
    int head(int u, int k) const { return adj_.at(u).at(k); }
};

void graph::set_weight(int u, int k, int w) {
    if (w < 2)
        return;
    int u0 = u, v = head(u, k);
    for (int a = 0; a < w - 1; a++) {
        adj_.push_back({-1});
        adj_.at(u).at(k) = adj_.size() - 1;
        u = adj_.size() - 1;
        k = 0;
    }
    adj_.at(u).at(k) = v;
}

auto operator<<(ostream &o, graph const &g) {
    for (int u = 0; u < g.order(); u++) {
        o << u << ": ";
        for (int v : g.adj(u))
            o << v << " ";
        o << "\n";
    }
}

class bfs {
    struct bfs_elem {
        int u, dist;
    };
    graph const &g_;
    vector<bool> used_;
    queue<bfs_elem> q_;

  public:
    bfs(graph const &g) : g_(g), used_(g_.order()) {}
    optional<int> distance(int from, int to) {
        q_.push({from, 0});
        used_[from] = true;
        while (!q_.empty()) {
            auto [u, d] = q_.front();
            if (u == to)
                return d;
            q_.pop();
            for (int v : g_.adj(u)) {
                if (used_[v])
                    continue;
                q_.push({v, d + 1});
            }
        }
        return {};
    }
};

class dfs {
    struct dfs_elem {
        int u, k;
    };
    enum color : char { WHITE = 0, GRAY, BLACK };
    graph const &g_;
    vector<char> c_;
    vector<dfs_elem> s_;

  public:
    enum class time_types { discover, finish };
    dfs(graph const &g) : g_(g), c_(g_.order()) {}
    optional<int> time(int from, int to,
                       time_types type = time_types::discover) {
        int t = 0;
        s_.push_back({from, 0});
        c_[from] = GRAY;
        while (!s_.empty()) {
            auto [u, k] = s_.back();
            s_.pop_back();
            if (u == to && k == 0 && type == time_types::discover)
                return t;
            if (u == to && k == g_.deg(u) && type == time_types::finish)
                return t;

            if (k == g_.deg(u))
                continue;
            s_.push_back({u, k + 1});
            if (int v = g_.head(u, k); c_[v] == WHITE) {
                s_.push_back({v, 0});
                c_[v] = GRAY;
                t++;
            }
        }
        return {};
    }
};
