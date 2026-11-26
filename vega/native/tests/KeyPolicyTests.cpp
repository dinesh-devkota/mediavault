#include "Test.h"
#include "KeyPolicy.h"
using namespace mediavault;

CASE(key_existing) {
    int creations = 0;
    for (bool records : {false, true}) for (bool save : {false, true})
        requireVaultKey(true, records, save, [&] { ++creations; });
    CHECK(creations == 0);
}
CASE(key_missing_read) {
    int creations = 0;
    for (bool records : {false, true})
        test::rejected([&] { requireVaultKey(false, records, false, [&] { ++creations; }); });
    CHECK(creations == 0);
}
CASE(key_missing_records) {
    int creations = 0;
    test::rejected([&] { requireVaultKey(false, true, true, [&] { ++creations; }); });
    CHECK(creations == 0); // A lost device key must never silently overwrite protected records.
}
CASE(key_fresh_save) {
    int creations = 0;
    requireVaultKey(false, false, true, [&] { ++creations; });
    CHECK(creations == 1);
}
CASE(key_creation_failure) {
    int creations = 0;
    test::rejected([&] { requireVaultKey(false, false, true, [&] { ++creations; throw UserError("keystore unavailable"); }); });
    CHECK(creations == 1);
}
