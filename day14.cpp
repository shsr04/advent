#include "_main.hpp"
#include <iterator>
#include <ratio>

struct reagens {
    string name;
    uint64_t amount;
    reagens(string _name, uint64_t _amount) : name(_name), amount(_amount) {}
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

auto ore_needed_to_satisfy(map<reagens, vector<reagens>> const &reactions,
                           map<string, uint64_t> required) {
    bool DEBUG = false;
    map<string, uint64_t> storage;
    auto ore = uint64_t(0);
    while (!required.empty()) {
        auto [material, target_amount] = *required.begin();
        required.erase(required.begin());
        /// If the requested material has already been produced by an earlier
        /// reaction, possible leftovers will be found in the storage.
        /// The storage may even have enough of the material to eliminate the
        /// need for the current reaction. In this case, we continue with the
        /// next requested material.
        if (storage[material] > 0) {
            auto reduction = min(storage[material], target_amount);
            storage[material] -= reduction;
            target_amount -= reduction;
            if (target_amount == 0)
                continue;
        }

        /// The reaction is looked up by the product name. This is possible
        /// because each product is produced by exactly one reaction. To find
        /// the quantifier for the reaction, we use the following equation:
        ///     x A -> y B      | target: z B
        ///     n x A = z B
        ///     n x A = z (x/y A)
        ///     n = ceil{z/y}
        /// Thus, the quantifier is ceil{z/y} (i.e. the target product amount
        /// divided by a single reaction's product yield).
        auto reaction = *r::find_if(reactions, [name = material](auto &x) {
            return x.first.name == name;
        });
        auto product = reaction.first;
        auto educts = reaction.second;
        auto factor = ceil(double(target_amount) / double(product.amount));
        product.amount *= factor;
        for (auto &e : educts)
            e.amount *= factor;

        /// The reaction produces n*y product. Any excess product (exceeding the
        /// target amount) is stored in the storage unit.
        if (DEBUG)
            cout << "reaction: ",
                copy(begin(educts), end(educts),
                     ostream_iterator<reagens>(cout, " ")),
                cout << "-> " << product << "\n";
        auto rest = product.amount - target_amount;
        storage[product.name] += rest;
        if (storage[product.name] > 0)
            if (DEBUG)
                cout << "Storage : " << product.amount << "x" << product.name
                     << "\n";

        /// The educts of the reaction must be themselves produced by subsequent
        /// reactions. Therefore, we add them to the requirement list. The ORE
        /// material is the exception because it cannot be produced.
        /// Incidentally, we want to obtain the amount of required ore. So, if
        /// any ORE is listed as educt of the reaction, we add the amount to our
        /// ORE counter.
        for (auto &[e_name, e_amount] : educts)
            if (e_name == "ORE")
                ore += e_amount;
            else
                required[e_name] += e_amount;
    }
    return ore;
}

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    string line;
    map<reagens, vector<reagens>> reactions;
    while (getline(in, line)) {
        stringstream s(line);
        vector<reagens> educts;
        reagens reag("", 0);
        while (s >> reag) {
            educts.push_back(reag);
            if (s.peek() == ',')
                s.ignore();
        }
        s.clear();
        string arrow;
        s >> arrow;
        s >> reag;
        reactions[reag] = educts;
    }
    auto ore = ore_needed_to_satisfy(reactions, {{"FUEL", 1}});
    cout << "Required ore for 1 fuel: " << ore << "\n";

    auto ore_collected = uint64_t(1'000'000'000'000);
    auto left = uint64_t(0), right = ore_collected;
    while (left <= right) {
        auto mid = (left + right) / 2;
        auto required_ore = ore_needed_to_satisfy(reactions, {{"FUEL", mid}});
        if (required_ore < ore_collected)
            left = mid + 1;
        else if (required_ore > ore_collected)
            right = mid - 1;
        else
            cout << "Direct hit! ---> " << mid << " fuel\n";
    }
    cout << "Fuel with " << ore_collected << " ore: " << (left-1) << "\n";
}
