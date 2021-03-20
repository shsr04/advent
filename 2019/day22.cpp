#include "_main.hpp"
#include <iterator>

struct command {
    enum type { REVERSE, CUT, INTERSPERSE };
    type type;
    big_int amount;
};

big_int const DECK_SIZE = 10007;
bool const DEBUG = false;

big_int apply_moves(vector<command> const &moves, big_int card) {
    for (auto &[t, n] : moves) {
        switch (t) {
        case command::REVERSE: // reverse cards => flip card index
            if (DEBUG)
                cout << "reversing\n";
            card = DECK_SIZE - card - 1;
            break;
        case command::CUT: // rotate cards to the left
            if (DEBUG)
                cout << "cutting " << n << " cards\n";
            if (card - n < 0)
                card += DECK_SIZE;
            card -= n;
            break;
        case command::INTERSPERSE: // reinsert at modulo
            if (DEBUG)
                cout << "dealing " << n << " with increment\n";
            card = (card * n) % DECK_SIZE;
            break;
        }
    }
    return card;
}

template <class F, class T> size_t cycle_length(F &&f, T x0) {
    auto slow = f(x0), fast = f(f(x0));
    while (slow != fast)
        slow = f(slow), fast = f(f(fast));
    cout << "cycle found: ";
    // find position of first recurring x
    auto pos = 0_s;
    slow = x0;
    while (slow != fast)
        slow = f(slow), fast = f(fast), pos++;
    cout << "at " << pos << " ";
    // find cycle length starting from pos
    auto len = 1_s;
    fast = f(slow);
    while (slow != fast)
        fast = f(fast), len++;
    cout << "of length " << len << "\n";
    return len;
}

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    string line;
    vector<command> moves;
    while (getline(in, line)) {
        if (line == "deal into new stack") {
            moves.push_back({command::REVERSE});
        } else if (line.find("cut") != string::npos) {
            auto first_space = line.find(' '),
                 second_space = line.find(' ', first_space + 1);
            big_int n = stoi(line.substr(first_space, second_space));
            if (n < 0)
                n += DECK_SIZE;
            moves.push_back({command::CUT, n});
        } else if (line.find("deal with increment") != string::npos) {
            auto last_space = line.find_last_of(' ');
            auto n = stoi(line.substr(last_space));
            moves.push_back({command::INTERSPERSE, n});
        } else {
            cerr << "unknown command '" << line << "'\n";
            return 1;
        }
    }

    auto card_pos = apply_moves(moves, 2019);
    cout << "Card 2019 at: " << card_pos << "\n";
}
