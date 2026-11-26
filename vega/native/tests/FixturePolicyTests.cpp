#include "Test.h"
#include "FixturePolicy.h"
using namespace mediavault;

namespace {
Source fixture() {
    Source source;
    source.id = "isolated-fixture";
    source.kind = "smb";
    source.endpoint = "smb://127.0.0.1:1445/MEDIALIBRARY";
    source.username = "cinevault";
    source.password = "fixture-only";
    return source;
}
}

CASE(fixture_source_allowed) {
    for (const auto share : {"MEDIALIBRARY", "FORMATPLAYBACK", "MEDIAPLAYBACK"}) {
        auto source = fixture();
        source.endpoint = std::string("smb://127.0.0.1:1445/") + share;
        requireFixtureSource(source);
    }
    auto source = fixture();
    source.root = "Movies";
    source.ignoredFolders = {"Movies/Excluded"};
    source.ignoredFiles = {"Movies/Excluded.mp4"};
    requireFixtureSource(source); // Normal path restrictions stay usable on the fixture share.
}

CASE(fixture_source_endpoint) {
    for (const auto endpoint : {"smb://localhost:1445/MEDIALIBRARY", "smb://127.0.0.2:1445/MEDIALIBRARY",
            "smb://127.1:1445/MEDIALIBRARY", "smb://2130706433:1445/MEDIALIBRARY",
            "smb://0x7f000001:1445/MEDIALIBRARY", "smb://[::1]:1445/MEDIALIBRARY",
            "smb://192.168.1.1:1445/MEDIALIBRARY", "smb://127.0.0.1:445/MEDIALIBRARY",
            "smb://127.0.0.1/MEDIALIBRARY", "smb://127.0.0.1:01445/MEDIALIBRARY",
            "smb://127.0.0.1:1445/PRIVATE", "smb://127.0.0.1:1445/medialibrary",
            "smb://127.0.0.1:1445/MEDIALIBRARY/", "smb://127.0.0.1:1445/MEDIALIBRARY/folder",
            "smb://127.0.0.1:1445/MEDIALIBRARY?query=value", "smb://127.0.0.1:1445/MEDIALIBRARY#fragment",
            "smb://127.0.0.1:1445/MEDIA%4cIBRARY", "smb://127.0.0.1:1445/MEDIALIBRARY/../PRIVATE",
            "smb://cinevault:fixture-only@127.0.0.1:1445/MEDIALIBRARY", "smb://127.0.0.1:1445@external.invalid/MEDIALIBRARY"}) {
        auto source = fixture();
        source.endpoint = endpoint;
        test::rejected([&] { requireFixtureSource(source); });
    }
    auto source = fixture();
    source.endpoint += std::string("\0/private", 9);
    test::rejected([&] { requireFixtureSource(source); });
}

CASE(fixture_source_credentials) {
    for (const auto value : {"", "guest", "CineVault", "cinevault "}) {
        auto source = fixture(); source.username = value;
        test::rejected([&] { requireFixtureSource(source); });
    }
    for (const auto value : {"", "fixture-only ", "wrong", "FIXTURE-ONLY"}) {
        auto source = fixture(); source.password = value;
        test::rejected([&] { requireFixtureSource(source); });
    }
    auto source = fixture(); source.token = "fixture-token";
    test::rejected([&] { requireFixtureSource(source); });
    source = fixture(); source.userID = "fixture-user-id";
    test::rejected([&] { requireFixtureSource(source); });
    source = fixture(); source.password += std::string("\0suffix", 7);
    test::rejected([&] { requireFixtureSource(source); });
}

CASE(fixture_source_protocol) {
    for (const auto kind : {"webdav", "jellyfin", "http", "https", "SMB", ""}) {
        auto source = fixture(); source.kind = kind;
        test::rejected([&] { requireFixtureSource(source); });
    }
    for (const auto endpoint : {"https://127.0.0.1:1445/MEDIALIBRARY", "http://127.0.0.1:1445/MEDIALIBRARY"}) {
        auto source = fixture(); source.endpoint = endpoint;
        test::rejected([&] { requireFixtureSource(source); });
    }
    test::rejected([] { rejectFixtureHTTP(); });
}
