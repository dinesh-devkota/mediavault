#include "Test.h"
using namespace mediavault;

CASE(path_identifiers) {
    CHECK(safeID("profile-A_2") == "profile-A_2");
    CHECK(safeID(std::string(128, 'a')).size() == 128);
    for (const auto& value : std::vector<std::string>{std::string(), std::string(129, 'a'), "../source", "a/b", "a b", std::string("a\0b", 3)})
        test::rejected([&] { safeID(value); });
}
CASE(path_traversal) {
    CHECK(safePath("").empty());
    CHECK(safePath(u8"Movies/Amélie (2001)/Film.mkv") == u8"Movies/Amélie (2001)/Film.mkv");
    for (const std::string value : {"/Movies", "Movies/", "Movies//file", ".", "..", "Movies/../file", "Movies/./file",
            "Movies\\file", "Movies/%2e%2E/file", "Movies/%2Ffile", "Movies/%5cfile", "Movies/%00file", "Movies/\nfile"})
        test::rejected([&] { safePath(value); });
    test::rejected([] { safePath(std::string(4097, 'a')); });
    test::rejected([] { safePath(std::string("Movies/\0file", 12)); });
    CHECK(contains("Movies/Feature/file.mkv", "Movies/Feature"));
    CHECK(!contains("Movies/Featurette/file.mkv", "Movies/Feature"));
    CHECK(!contains("Movies/Feature", "Movies/Feature", false));
    CHECK(contains("Movies/Feature", ""));
}
CASE(path_encoding) {
    CHECK(percentEncode(u8"Amélie #1?.mkv") == "Am%C3%A9lie%20%231%3F.mkv");
    CHECK(percentEncode("Movies/A%20B.mkv") == "Movies%2FA%2520B.mkv");
    CHECK(percentEncode("Movies/A B.mkv", true) == "Movies/A%20B.mkv");
    Bytes binary{0, 1, 127, 128, 254, 255};
    CHECK(unbase64(base64(binary)) == binary);
    test::rejected([] { unbase64("not base64!"); });
    test::rejected([] { unbase64(std::string(256 * 1024 + 1, 'A')); });
}
static Source source(const std::string& kind = "webdav") {
    return Source::parse({{"id", "test-source"}, {"kind", kind}, {"endpoint", "https://fixture.invalid/media"},
        {"root", "Movies"}, {"ignoredFolders", {"Movies/Private"}}, {"ignoredFiles", {"Movies/hidden.mkv"}}});
}
CASE(source_boundaries) {
    auto s = source();
    s.authorize("Movies/Film.mkv");
    s.authorize("Movies", true);
    s.authorize("Movies/Private Trailer.mkv");
    test::rejected([&] { s.authorize("Movies/Private"); });
    test::rejected([&] { s.authorize("Movies/Private/Film.mkv"); });
    test::rejected([&] { s.authorize("Movies/hidden.mkv"); });
    test::rejected([&] { s.authorize("Movies2/Film.mkv"); });
    test::rejected([&] { s.authorize("Movies/../Other/Film.mkv"); });
    s.authorize("Movies/hidden.mkv", true); // File exclusion does not hide a same-named directory.
    s.root = ""; s.ignoredFolders = {""};
    test::rejected([&] { s.authorize("anything.mkv"); });
}
CASE(source_unicode_aliases) {
    auto smb = source("smb");
    smb.authorize("MOVIES/Feature.mkv");
    test::rejected([&] { smb.authorize("MOVIES/PRIVATE/Film.mkv"); });
    test::rejected([&] { smb.authorize("movies/HIDDEN.MKV"); });
    smb.ignoredFolders = {u8"Movies/Privé"};
    test::rejected([&] { smb.authorize(u8"MOVIES/PRIVÉ/Film.mkv"); });
    test::rejected([&] { smb.authorize(u8"Movies/Prive\u0301/Film.mkv"); });
    test::rejected([&] { smb.authorize(std::string("Movies/") + char(0xff)); });
    auto webdav = source();
    webdav.authorize("Movies/PRIVATE/Film.mkv"); // HTTP paths remain case-sensitive.
    test::rejected([&] { webdav.authorize("MOVIES/Film.mkv"); });
}
CASE(source_parse_limits) {
    auto config = source().serialized();
    CHECK(Source::parse(config).serialized() == config);
    for (const std::string kind : {"ftp", "file", "http"}) {
        config["kind"] = kind;
        test::rejected([&] { Source::parse(config); });
    }
    config = source().serialized(); config["endpoint"] = "";
    test::rejected([&] { Source::parse(config); });
    config["endpoint"] = std::string(4097, 'a');
    test::rejected([&] { Source::parse(config); });
    config = source().serialized(); config["ignoredFiles"] = std::vector<std::string>(10001, "Movies/a.mkv");
    test::rejected([&] { Source::parse(config); });
    config = source().serialized(); config["ignoredFolders"] = {"Movies/../Other"};
    test::rejected([&] { Source::parse(config); });
}
