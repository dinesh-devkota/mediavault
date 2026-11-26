#include "Test.h"
#include "PlatformErrorCategory.h"
using namespace mediavault;

CASE(platform_error_exact) {
    CHECK(std::string_view(platformErrorCategory("com.amazon.kepler.keystore.NoSuchKeystoreError")) == "no-keystore");
    CHECK(std::string_view(platformErrorCategory("com.amazon.apmf.SecurityError")) == "security");
    CHECK(std::string_view(platformErrorCategory("com.amazon.apmf.NotSupportedError")) == "not-supported");
    CHECK(std::string_view(platformErrorCategory("")) == "platform");
    CHECK(std::string_view(platformErrorCategory("vendor.UnknownError")) == "platform");
}

CASE(platform_error_spoofed) {
    const std::string type = "com.amazon.kepler.keystore.NoSuchKeystoreError";
    for (const auto& supplied : {"prefix." + type, type + "Suffix", " " + type,
            type + " ", type + ": message", type + ";com.amazon.apmf.BaseError",
            type + std::string("\0hidden", 7)})
        CHECK(std::string_view(platformErrorCategory(supplied)) == "platform");
    CHECK(std::string_view(platformErrorCategory("vendor.UnknownError," + type)) == "no-keystore");
}

CASE(platform_error_precedence) {
    // getTypes() contains an exception hierarchy; derived access denial must
    // remain distinguishable from its security base regardless of list order.
    for (auto types : {"com.amazon.apmf.AccessDeniedError,com.amazon.apmf.SecurityError",
            "com.amazon.apmf.SecurityError,com.amazon.apmf.AccessDeniedError",
            "vendor.ChildError,com.amazon.apmf.SecurityError,com.amazon.apmf.AccessDeniedError,com.amazon.apmf.BaseError"})
        CHECK(std::string_view(platformErrorCategory(types)) == "access-denied");
    for (auto types : {"com.amazon.apmf.SecurityError,com.amazon.kepler.keystore.NoSuchKeystoreError",
            "com.amazon.kepler.keystore.NoSuchKeystoreError,com.amazon.apmf.SecurityError"})
        CHECK(std::string_view(platformErrorCategory(types)) == "no-keystore");
}

CASE(platform_error_bound) {
    const std::string recognized = ",com.amazon.apmf.SecurityError";
    const auto boundary = std::string(2048 - recognized.size(), 'x') + recognized;
    CHECK(boundary.size() == 2048);
    CHECK(std::string_view(platformErrorCategory(boundary)) == "security");
    CHECK(std::string_view(platformErrorCategory("x" + boundary)) == "platform");
    // A recognized first item cannot circumvent the whole-input size bound.
    CHECK(std::string_view(platformErrorCategory("com.amazon.apmf.SecurityError," + std::string(2048, 'x'))) == "platform");
}

CASE(platform_error_private) {
    const std::string privateText = "password=fixture-private-text token=fixture-private-token host=private.invalid";
    CHECK(std::string_view(platformErrorCategory(privateText)) == "platform");
    CHECK(std::string_view(platformErrorCategory("com.amazon.apmf.SecurityError: " + privateText)) == "platform");
    const std::string categorized = platformErrorCategory(privateText + ",com.amazon.apmf.SecurityError");
    CHECK(categorized == "security");
    CHECK(categorized.find("fixture-private") == std::string::npos);
    CHECK(categorized.find("private.invalid") == std::string::npos);
}
