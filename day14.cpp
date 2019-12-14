#include "_main.hpp"
#include <ratio>

struct reagens {
    int amount;
    string name;
    reagens(int _amount, string _name) : amount(_amount), name(_name) {}
    bool operator<(reagens const &p) const {
        return name < p.name || (name == p.name && amount < p.amount);
    }
};
istream &operator>>(istream &i, reagens &p) {
    i >> p.amount;
    while (isblank(char(i.peek())))
        i.ignore();
    p.name.erase();
    while (isalpha(char(i.peek())))
        p.name.push_back(i.get());
    return i;
}
ostream &operator<<(ostream &o, reagens const &p) {
    o << p.amount << "x" << p.name;
    return o;
}

using reaction = pair<reagens, map<string, int>>;

reaction compute_reaction(map<reagens, map<string, int>> const &reactions,
                          reagens const &t) {
    auto [prod, educts] = *r::find_if(
        reactions, [&t](auto &x) { return x.first.name == t.name; });
    auto produced_amount = prod.amount;
    auto factor = ceil(double(t.amount) / double(produced_amount));
    if (produced_amount < t.amount) {
        for (auto &[e_n, e_a] : educts)
            e_a *= factor;
        produced_amount *= factor;
    }

    cout << "reaction ";
    for (auto &[e_n, e_a] : educts) {
        cout << e_a << "x" << e_n << " ";
    }
    cout << "-> " << produced_amount << " " << t.name << "\n";
    return reaction{{produced_amount, t.name}, educts};
}

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    string line;
    map<reagens, map<string, int>> reactions;
    while (getline(in, line)) {
        stringstream s(line);
        map<string, int> educts;
        reagens reag(0, "");
        while (s >> reag) {
            educts[reag.name] = reag.amount;
            if (s.peek() == ',')
                s.ignore();
        }
        s.clear();
        string arrow;
        s >> arrow;
        s >> reag;
        reactions[reag] = educts;
    }
    auto fuel =
        *r::find_if(reactions, [](auto &x) { return x.first.name == "FUEL"; });
    auto products = fuel.second;
    auto total_needed = map<string, int>();
    while (!products.empty()) {
        for (auto &[e_n, e_a] : products)
            cout << e_a << "x" << e_n << " ";
        cout << " FROM\n";
        map<string, int> educts;
        for (auto &t : products) {
            auto [prod, partial_educts] =
                compute_reaction(reactions, {t.second, t.first});
            total_needed[t.first] += t.second;
            for (auto &[e_n, e_a] : partial_educts)
                educts[e_n] += e_a;
        }
        products = move(educts);
        for (auto &[e_n, e_a] : products) {
            cout << e_a << "x" << e_n << " ";
        }
        cout << ".\n";
        products.erase("ORE");
    }

    cout << "Needed:\n";
    for (auto &[r_n, r_a] : total_needed)
        cout << "- " << r_a << " " << r_n << "\n";
    auto ore = 0;
    for (auto &[t_n, t_a] : total_needed) {
        auto [prod, packed] = compute_reaction(reactions, {t_a, t_n});
        for (auto &[r_n, r_a] : packed) {
            if (r_n == "ORE")
                ore += r_a;
        }
    }
    cout << "Required ore: " << ore << "\n";
}
