#include <fstream>
#include <iostream>
#include <map>
#include <string>
#include <vector>
using namespace std;

enum class opcode : int {
    add = 1,
    mul = 2,
    in = 3,
    out = 4,
    jnz = 5,
    jz = 6,
    lt = 7,
    eq = 8,
    crel = 9,
    halt = 99,
};

using memory = vector<ssize_t>;
using mem_val = memory::value_type;
using mem_index = int;
using param_modes = string;

string const SPECIFIER_POSITION_MODE = "P", SPECIFIER_RELATIVE_MODE = "R";

map<string, opcode> opcode_names = {
    {
        "add",
        opcode::add,
    },
    {
        "mul",
        opcode::mul,
    },
    {
        "in",
        opcode::in,
    },
    {
        "out",
        opcode::out,
    },
    {
        "jnz",
        opcode::jnz,
    },
    {
        "jz",
        opcode::jz,
    },
    {
        "lt",
        opcode::lt,
    },
    {
        "eq",
        opcode::eq,
    },
    {
        "cr",
        opcode::crel,
    },
    {
        "halt",
        opcode::halt,
    },
};

struct state {
    string line;
    int i_line = 0;
};

map<string, int> labels;

int main(int argc, char **argv) {
    auto s = string();
    if (argc < 3) {
        cerr << "Usage: asm <input> <output>";
        return 99;
    }
    auto i_line = 1, i_tok = 0;
    ifstream in(argv[1]);
    ofstream out(argv[2]);
    while (in >> s) {
        if (s.back() == ':') {
            labels[s.substr(0, s.size() - 1)] = i_tok;
            //cout << "label " << s.substr(0, s.size() - 1) << " at " << i_tok
            //     << "\n";
            in >> s;
        }
        auto op_name = s;
        i_tok++;
        if (opcode_names.find(op_name) == opcode_names.end())
            return cerr << "invalid opcode '" << op_name << "' in line "
                        << i_line << "\n",
                   99;
        auto op_number = static_cast<int>(opcode_names.at(op_name));
        auto modes = param_modes();
        auto params = vector<mem_val>();
        while (in >> s) {
            auto colon = s.find(':');
            auto spec = s.substr(0, colon);
            if (colon == string::npos)
                modes.push_back('1');
            else if (spec == SPECIFIER_POSITION_MODE)
                modes.push_back('0');
            else if (spec == SPECIFIER_RELATIVE_MODE)
                modes.push_back('2');
            else
                return cerr << "invalid mode specifier '" << spec
                            << "' in line " << i_line << "\n",
                       99;

            auto val = colon == string::npos ? s : s.substr(colon + 1);
            if (val.front() == '*') {
                if (labels.find(val.substr(1)) == labels.end())
                    return cerr << "unknown label '" << val.substr(1)
                                << "' in line " << i_line << "\n",
                           99;
                val = to_string(labels.at(val.substr(1)));
            }
            try {
                params.push_back(stoll(val));
            } catch (...) {
                cerr << "invalid parameter value '" << val << "' in line "
                     << i_line << "\n(did mean: '*" << val << "'?)\n";
                return 99;
            }
            i_tok++;
            if (in.peek() == '\n') {
                in.ignore();
                break;
            }
        }
        auto full_opcode = to_string(op_number);
        if (full_opcode.size() == 1)
            full_opcode = '0' + full_opcode;
        for (auto a : modes)
            full_opcode = a + full_opcode;
        while (full_opcode.front() == '0')
            full_opcode.erase(full_opcode.begin());

        if (i_line != 1)
            out << ",";
        out << full_opcode;
        for (auto p : params) {
            out << "," << p;
        }
        i_line++;
    }
}
