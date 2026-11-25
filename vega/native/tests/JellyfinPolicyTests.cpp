#include "Test.h"
using namespace mediavault;
namespace {
Source jellyfin() {
    return Source::parse({{"id", "jellyfin-fixture"}, {"kind", "jellyfin"},
        {"endpoint", "https://fixture.invalid"}, {"userId", "household-user"}, {"root", "library-123"}});
}
}
CASE(jellyfin_catalog_allowed) {
    auto source = jellyfin();
    source.authorizeJellyfinCatalog("Users/household-user/Items", "GET", {
        {"ParentId", "library-123"}, {"Recursive", "true"}, {"IncludeItemTypes", "Movie,Episode"},
        {"Fields", "Path,Genres"}, {"StartIndex", "0"}, {"Limit", "200"}, {"SortBy", "SortName"}, {"SortOrder", "Ascending"}});
    source.root = "";
    source.authorizeJellyfinCatalog("Users/household-user/Items", "GET", JSON::object());
}
CASE(jellyfin_catalog_scope) {
    auto source = jellyfin(); const JSON query = {{"ParentId", "library-123"}};
    for (const std::string path : {"Users/other-user/Items", "Users/household-user", "Users/household-user/Items/item-1",
            "System/Info", "Users/household-user/../admin/Items", "Users/household-user/Items/"})
        test::rejected([&] { source.authorizeJellyfinCatalog(path, "GET", query); });
    for (const std::string method : {"POST", "DELETE", "PROPFIND", "HEAD"})
        test::rejected([&] { source.authorizeJellyfinCatalog("Users/household-user/Items", method, query); });
    test::rejected([&] { source.authorizeJellyfinCatalog("Users/household-user/Items", "GET", JSON::object()); });
    test::rejected([&] { source.authorizeJellyfinCatalog("Users/household-user/Items", "GET", {{"ParentId", "another-library"}}); });
    source.kind = "webdav";
    test::rejected([&] { source.authorizeJellyfinCatalog("Users/household-user/Items", "GET", query); });
    source = jellyfin(); source.userID = "";
    test::rejected([&] { source.authorizeJellyfinCatalog("Users/household-user/Items", "GET", query); });
}
CASE(jellyfin_catalog_parameters) {
    auto source = jellyfin();
    for (const std::string key : {"UserId", "api_key", "AccessToken", "IsAdministrator", "parentid"}) {
        JSON query = {{"ParentId", "library-123"}, {key, "other-user"}};
        test::rejected([&] { source.authorizeJellyfinCatalog("Users/household-user/Items", "GET", query); });
    }
    test::rejected([&] { source.authorizeJellyfinCatalog("Users/household-user/Items", "GET", JSON::array()); });
    test::rejected([&] { source.authorizeJellyfinCatalog("Users/household-user/Items", "GET", {{"ParentId", "library-123"}, {"Limit", 200}}); });
    test::rejected([&] { source.authorizeJellyfinCatalog("Users/household-user/Items", "GET", {{"ParentId", "library-123"}, {"Fields", std::string(4097, 'a')}}); });
}
CASE(jellyfin_resources_allowed) {
    auto source = jellyfin();
    for (const std::string path : {"Videos/movie-123/stream", "Audio/track_456/stream"})
        source.authorizeJellyfinResource(path, false, {{"static", "true"}});
    source.authorizeJellyfinResource("Items/movie-123/Images/Primary", true, JSON::object());
    for (const std::string width : {"1", "640", "2560"})
        source.authorizeJellyfinResource("Items/movie-123/Images/Primary", true, {{"maxWidth", width}});
}
CASE(jellyfin_resource_routes) {
    auto source = jellyfin();
    for (const std::string path : {"Users/household-user", "Items/movie-123/Download", "Videos/movie-123/live.m3u8",
            "Videos/movie-123/../other/stream", "Videos/a/b/stream", "Videos//stream", "Videos/a%2fb/stream", "Videos/movie-123/stream/"})
        test::rejected([&] { source.authorizeJellyfinResource(path, false, {{"static", "true"}}); });
    for (const std::string path : {"Items/movie-123/Images/Backdrop", "Items/movie-123/Images/Primary/0", "Items/a/b/Images/Primary", "Videos/movie-123/stream"})
        test::rejected([&] { source.authorizeJellyfinResource(path, true, JSON::object()); });
    source.kind = "smb";
    test::rejected([&] { source.authorizeJellyfinResource("Videos/movie-123/stream", false, {{"static", "true"}}); });
}
CASE(jellyfin_resource_parameters) {
    auto source = jellyfin();
    for (const JSON& query : std::vector<JSON>{JSON::object(), {{"static", "false"}}, {{"Static", "true"}},
            {{"static", "true"}, {"api_key", "secret"}}, {{"static", "true"}, {"UserId", "other-user"}}})
        test::rejected([&] { source.authorizeJellyfinResource("Videos/movie-123/stream", false, query); });
    for (const std::string width : {"0", "2561", "10000", "-1", "1.5", "huge", ""})
        test::rejected([&] { source.authorizeJellyfinResource("Items/movie-123/Images/Primary", true, {{"maxWidth", width}}); });
    test::rejected([&] { source.authorizeJellyfinResource("Items/movie-123/Images/Primary", true, {{"maxWidth", "640"}, {"api_key", "secret"}}); });
    test::rejected([&] { source.authorizeJellyfinResource("Items/movie-123/Images/Primary", true, {{"width", "640"}}); });
}
