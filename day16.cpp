#include "_main.hpp"
#include <iterator>

vector<char> apply_fft(vector<char> input, int phases) {
    vector<char> phase_in = move(input);
    decltype(phase_in) phase_out(phase_in.size());
    for (auto i_phase : v::iota(0, phases)) {
        cout << "Phase " << i_phase << "\n";
        // cout << "IN: ";
        // for (auto a : phase_in)
        //     cout << char(a + '0');
        // cout << "\n";
        for (auto i_out : v::iota(0_s, phase_in.size())) {
            auto spread = i_out + 1;

            auto sum = 0;
            auto i_step = i_out;
            while (i_step < phase_in.size()) {
                for (auto a = i_step; a < min(phase_in.size(), i_step + spread);
                     a++) {
                    // cout << "+" << char(phase_in[a] + '0') << " ";
                    sum += phase_in[a];
                }
                for (auto a = i_step + 2 * spread;
                     a < min(phase_in.size(), i_step + 3 * spread); a++) {
                    // cout << "-" << char(phase_in[a] + '0') << " ";
                    sum -= phase_in[a];
                }
                i_step += 4 * spread;
            }

            auto output = abs(sum) % 10;
            // cout << "= " << output << ";  ";
            phase_out[i_out] = output;
        }
        // cout << "OUT: ";
        // for (auto a : phase_out)
        //    cout << char(a + '0');
        // cout << "\n";
        swap(phase_in, phase_out);
    }
    return move(phase_in);
}

int main(int argc, char **argv) {
    if (argc < 2)
        return 99;
    ifstream in(argv[1]);
    vector<char> const pattern = {0, 1, 0, -1};
    string input;
    in >> input;
    auto numeric_input = input %
                         f::transform([](char x) -> char { return x - '0'; }) %
                         f::to_vector();

    cout << apply_fft(numeric_input, 100) % f::take_first(8) %
                f::transform([](char x) -> char { return x + '0'; }) %
                f::to(string())
         << "\n";

    auto const offset = stoi(input.substr(0, 7));
    auto const input_size = numeric_input.size() * 10'000;
    if (offset <= input_size / 2)
        throw "ERROR: offset not in upper half\n";
    cout << numeric_input.size() << "->" << input_size << "\n";

    vector<char> buffer;
    while (buffer.size() < input_size)
        copy(begin(numeric_input), end(numeric_input), back_inserter(buffer));

    for (auto i_phase : v::iota(0, 100)) {
        for (auto i_num = input_size - 2; i_num >= offset; i_num--) {
            buffer[i_num] += buffer[i_num + 1];
            buffer[i_num] = abs(buffer[i_num]) % 10;
        }
    }

    auto result = buffer % f::drop_first(offset) % f::take_first(8) %
                  f::transform([](char x) -> char { return x + '0'; }) %
                  f::to(string());
    cout << ">>> " << result << "\n";
}
