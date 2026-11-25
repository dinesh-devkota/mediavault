#include "Test.h"
#include <iostream>

std::map<std::string, test::Case>& test::cases() {
    static std::map<std::string, Case> all;
    return all;
}
int main(int argc, char** argv) {
    if (argc != 2 || !test::cases().count(argv[1])) {
        std::cerr << "Choose a registered native test case\n";
        return 2;
    }
    try {
        test::cases().at(argv[1])();
        std::cout << argv[1] << " passed\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << argv[1] << " failed: " << error.what() << '\n';
        return 1;
    }
}
