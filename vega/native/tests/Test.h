#pragma once
#include "Core.h"
#include <functional>
#include <map>
#include <sstream>
#include <stdexcept>

namespace test {
using Case = std::function<void()>;
std::map<std::string, Case>& cases();
struct Register {
    Register(const char* name, Case run) { cases().emplace(name, std::move(run)); }
};
inline void check(bool ok, const char* expression, const char* file, int line) {
    if (!ok) {
        std::ostringstream message;
        message << file << ':' << line << ": " << expression;
        throw std::runtime_error(message.str());
    }
}
template<class F> void rejected(F&& operation) {
    try { operation(); } catch (const mediavault::UserError&) { return; }
    throw std::runtime_error("Expected a user-safe rejection");
}
}
#define CHECK(expression) test::check(bool(expression), #expression, __FILE__, __LINE__)
#define CASE(name) static void name(); static test::Register registration_##name(#name, name); static void name()
