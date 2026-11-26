#include "Test.h"
using namespace mediavault;

namespace {
JSON sourceRecord() {
    return {{"id", "synthetic"}, {"kind", "smb"},
        {"endpoint", "smb://127.0.0.1:1445/MEDIALIBRARY"},
        {"username", "cinevault"}, {"password", "fixture-only"}};
}
}

CASE(fixture_vault_transient) {
    const JSON original = {{"hash", "synthetic-hash"}, {"rounds", 210000}};
    {
        Vault first;
        CHECK(first.read("pin_adult").is_null());
        first.write("pin_adult", original);
        CHECK(first.read("pin_adult") == original);
        Vault independent;
        CHECK(independent.read("pin_adult").is_null());
        first.write("pin_adult", {{"hash", "replacement"}});
        CHECK(first.read("pin_adult").at("hash") == "replacement");
        first.remove("pin_adult");
        first.remove("pin_adult");
        CHECK(first.read("pin_adult").is_null());
        first.write("pin_adult", original);
    }
    Vault restarted;
    CHECK(restarted.read("pin_adult").is_null());
}

CASE(fixture_vault_source_scope) {
    Vault vault;
    const auto allowed = sourceRecord();
    vault.write("source_synthetic", allowed);
    CHECK(vault.read("source_synthetic") == allowed);
    test::rejected([&] { vault.write("source_different", allowed); });
    for (auto forbidden : {"arbitrary", "source_", "pin_", "../source_synthetic"}) {
        test::rejected([&] { vault.read(forbidden); });
        test::rejected([&] { vault.write(forbidden, allowed); });
        test::rejected([&] { vault.remove(forbidden); });
    }
    for (auto field : {"endpoint", "kind", "username", "password", "token", "userId"}) {
        auto changed = allowed; changed[field] = "outside-fixture";
        test::rejected([&] { vault.write("source_synthetic", changed); });
        CHECK(vault.read("source_synthetic") == allowed);
    }
}

CASE(fixture_vault_cancel) {
    Vault vault;
    const JSON original = {{"hash", "original"}};
    vault.write("pin_existing", original);
    for (const auto id : {"pin_existing", "pin_new"}) {
        for (int failureAt : {1, 2}) {
            int calls = 0;
            test::rejected([&] {
                vault.write(id, {{"hash", "cancelled"}}, [&] {
                    if (++calls == failureAt) throw UserError("Fixture profile changed");
                });
            });
            CHECK(calls == failureAt);
            CHECK(vault.read("pin_existing") == original);
            CHECK(vault.read("pin_new").is_null());
        }
    }
}

CASE(fixture_vault_bounds) {
    Vault vault;
    vault.write("pin_original", "preserve");
    test::rejected([&] { vault.write("pin_original", std::string(128 * 1024, 'x')); });
    CHECK(vault.read("pin_original") == "preserve");
    for (int n = 0; n < 127; ++n) vault.write("pin_" + std::to_string(n), n);
    test::rejected([&] { vault.write("pin_overflow", 1); });
    CHECK(vault.read("pin_overflow").is_null());
    vault.write("pin_original", "updated");
    CHECK(vault.read("pin_original") == "updated");
    vault.remove("pin_0");
    vault.write("pin_reused", 1);
    Vault bytes;
    const std::string block(128 * 1024 - 2, 'x'); // JSON string adds two quotes.
    for (int n = 0; n < 32; ++n) bytes.write("pin_" + std::to_string(n), block);
    test::rejected([&] { bytes.write("pin_excess", "x"); });
    CHECK(bytes.read("pin_excess").is_null());
    CHECK(bytes.read("pin_31") == block);
}

CASE(fixture_vault_random) {
    Vault vault;
    CHECK(vault.random(1).size() == 1);
    const auto first = vault.random(64);
    CHECK(first.size() == 64);
    CHECK(first != vault.random(64));
    test::rejected([&] { vault.random(0); });
    test::rejected([&] { vault.random(65); });
}
