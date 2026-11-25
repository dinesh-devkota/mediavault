#include "Core.h"
#include "TrustRoots.h"
#include <algorithm>
#include <cctype>
#include <curl/curl.h>
#include <stdexcept>

namespace mediavault {
namespace {
struct Transfer {
  HTTPResult result{0, {}, {}};
  size_t limit = 0, headerBytes = 0;
  std::function<void()> check;
  bool invalid = false;
};
size_t bodyCallback(char *bytes, size_t size, size_t count, void *opaque) {
  auto &t = *static_cast<Transfer *>(opaque);
  try {
    t.check();
    if (size && count > (t.limit - t.result.body.size()) / size) {
      t.invalid = true;
      return 0;
    }
    t.result.body.insert(t.result.body.end(), bytes, bytes + size * count);
    t.check();
    return size * count;
  } catch (...) {
    t.invalid = true;
    return 0;
  }
}
size_t headerCallback(char *bytes, size_t size, size_t count, void *opaque) {
  auto &t = *static_cast<Transfer *>(opaque);
  if (size && count > (32768 - t.headerBytes) / size) {
    t.invalid = true;
    return 0;
  }
  size_t length = size * count;
  t.headerBytes += length;
  std::string line(bytes, length);
  auto colon = line.find(':');
  if (colon != std::string::npos) {
    auto name = line.substr(0, colon), value = line.substr(colon + 1);
    std::transform(name.begin(), name.end(), name.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    while (!value.empty() &&
           std::isspace(static_cast<unsigned char>(value.back())))
      value.pop_back();
    value.erase(0, value.find_first_not_of(" \t"));
    if (name.find('\0') != std::string::npos ||
        value.find('\0') != std::string::npos ||
        value.find_first_of("\r\n") != std::string::npos) {
      t.invalid = true;
      return 0;
    }
    if (name == "content-length" || name == "content-range" ||
        name == "content-type" || name == "etag") {
      if (t.result.headers.count(name) && t.result.headers[name] != value) {
        t.invalid = true;
        return 0;
      }
      t.result.headers[name] = value;
    }
  }
  return length;
}
int progressCallback(void *opaque, curl_off_t, curl_off_t, curl_off_t,
                     curl_off_t) {
  try {
    static_cast<Transfer *>(opaque)->check();
    return 0;
  } catch (...) {
    return 1;
  }
}
std::string part(CURLU *url, CURLUPart component, unsigned flags = 0) {
  char *raw = nullptr;
  if (curl_url_get(url, component, &raw, flags))
    return {};
  std::string result(raw);
  curl_free(raw);
  return result;
}
} // namespace
HTTPResult http(const Source &source, const JSON &request,
                const std::function<void()> &assertCurrent) {
  assertCurrent();
  if (source.endpoint.size() > 4096 ||
      source.endpoint.find('\0') != std::string::npos ||
      source.username.size() > 1024 || source.password.size() > 4096 ||
      source.username.find('\0') != std::string::npos ||
      source.password.find('\0') != std::string::npos ||
      source.token.size() > 4096 ||
      std::any_of(source.token.begin(), source.token.end(),
                  [](unsigned char c) { return c < 33 || c > 126; }))
    throw UserError("The protected source credentials or address are invalid. "
                    "Reconnect this source.");
  std::unique_ptr<CURLU, decltype(&curl_url_cleanup)> address(curl_url(),
                                                              curl_url_cleanup);
  if (!address ||
      curl_url_set(address.get(), CURLUPART_URL, source.endpoint.c_str(), 0) ||
      part(address.get(), CURLUPART_SCHEME) != "https" ||
      part(address.get(), CURLUPART_HOST).empty() ||
      !part(address.get(), CURLUPART_USER).empty() ||
      !part(address.get(), CURLUPART_PASSWORD).empty() ||
      !part(address.get(), CURLUPART_QUERY).empty() ||
      !part(address.get(), CURLUPART_FRAGMENT).empty())
    throw UserError("Enter an HTTPS server address without credentials or "
                    "query parameters.");
  auto base = part(address.get(), CURLUPART_PATH, CURLU_URLDECODE);
  if (!base.empty() && base.front() == '/')
    base.erase(0, 1);
  if (!base.empty() && base.back() == '/')
    base.pop_back();
  safePath(base);
  auto relative = safePath(request.at("path").get<std::string>());
  auto path = "/" + percentEncode(
                        base.empty() ? relative : base + "/" + relative, true);
  if (request.value("method", "") == "PROPFIND" && path.back() != '/')
    path += '/';
  if (curl_url_set(address.get(), CURLUPART_PATH, path.c_str(), 0))
    throw UserError("Invalid server path.");
  auto query = request.value("query", JSON::object());
  std::string encodedQuery;
  if (!query.is_object() || query.size() > 30)
    throw UserError("Invalid request parameters.");
  for (auto it = query.begin(); it != query.end(); ++it) {
    auto value = it.value().get<std::string>();
    if (it.key().size() > 128 || value.size() > 4096 || it.key() == "api_key" ||
        it.key() == "AccessToken")
      throw UserError("Invalid request parameters.");
    if (!encodedQuery.empty())
      encodedQuery += '&';
    encodedQuery += percentEncode(it.key()) + "=" + percentEncode(value);
  }
  if (!encodedQuery.empty())
    curl_url_set(address.get(), CURLUPART_QUERY, encodedQuery.c_str(), 0);
  const auto url = part(address.get(), CURLUPART_URL);
  const auto method = request.at("method").get<std::string>();
  if (method != "GET" && method != "HEAD" && method != "POST" &&
      method != "PROPFIND")
    throw UserError("Unsupported server request.");
  auto body = request.value("body", "");
  const auto maximum = request.at("maximumBytes").get<int64_t>();
  if (maximum < 0 || maximum > 16 * 1024 * 1024 || body.size() > 1024 * 1024)
    throw UserError("Server request exceeds the safety limit.");
  Transfer t;
  t.limit = size_t(maximum);
  t.check = assertCurrent;
  std::unique_ptr<CURL, decltype(&curl_easy_cleanup)> handle(curl_easy_init(),
                                                             curl_easy_cleanup);
  if (!handle)
    throw UserError("Could not start a server request.");
  std::unique_ptr<curl_slist, decltype(&curl_slist_free_all)> headers(
      nullptr, curl_slist_free_all);
  auto addHeader = [&](const std::string &value) {
    if (value.find_first_of("\r\n") != std::string::npos ||
        value.find('\0') != std::string::npos)
      throw UserError("Invalid protected request header.");
    auto next = curl_slist_append(headers.get(), value.c_str());
    if (!next)
      throw std::bad_alloc();
    headers.release();
    headers.reset(next);
  };
  auto suppliedHeaders = request.value("headers", JSON::object());
  if (!suppliedHeaders.is_object() || suppliedHeaders.size() > 8)
    throw UserError("Invalid request headers.");
  for (auto it : suppliedHeaders.items()) {
    auto name = it.key(), value = it.value().get<std::string>();
    std::transform(name.begin(), name.end(), name.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    if (name != "depth" && name != "content-type" && name != "range" &&
        name != "accept")
      throw UserError("Unsupported request header.");
    if (value.find_first_of("\r\n") != std::string::npos ||
        value.find('\0') != std::string::npos || value.size() > 512)
      throw UserError("Invalid request header.");
    addHeader(name + ": " + value);
  }
  if (source.kind == "jellyfin") {
    addHeader(
        "Authorization: MediaBrowser Client=\"MediaVault\", Device=\"Fire "
        "TV\", DeviceId=\"mediavault-vega\", Version=\"1.5.0\"");
    if (!source.token.empty())
      addHeader("X-Emby-Token: " + source.token);
  } else {
    curl_easy_setopt(handle.get(), CURLOPT_USERNAME, source.username.c_str());
    curl_easy_setopt(handle.get(), CURLOPT_PASSWORD, source.password.c_str());
    curl_easy_setopt(handle.get(), CURLOPT_HTTPAUTH, CURLAUTH_BASIC);
  }
  curl_blob trust{const_cast<char *>(trustRoots), sizeof(trustRoots) - 1,
                  CURL_BLOB_COPY};
  curl_easy_setopt(handle.get(), CURLOPT_CAINFO_BLOB, &trust);
  curl_easy_setopt(handle.get(), CURLOPT_SSL_VERIFYPEER, 1L);
  curl_easy_setopt(handle.get(), CURLOPT_SSL_VERIFYHOST, 2L);
  curl_easy_setopt(handle.get(), CURLOPT_URL, url.c_str());
  curl_easy_setopt(handle.get(), CURLOPT_PROTOCOLS_STR, "https");
  curl_easy_setopt(handle.get(), CURLOPT_FOLLOWLOCATION, 0L);
  curl_easy_setopt(handle.get(), CURLOPT_MAXREDIRS, 0L);
  curl_easy_setopt(handle.get(), CURLOPT_PROXY, "");
  curl_easy_setopt(handle.get(), CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(handle.get(), CURLOPT_CONNECTTIMEOUT_MS, 5000L);
  curl_easy_setopt(handle.get(), CURLOPT_TIMEOUT_MS, 15000L);
  curl_easy_setopt(handle.get(), CURLOPT_HTTPHEADER, headers.get());
  curl_easy_setopt(handle.get(), CURLOPT_CUSTOMREQUEST, method.c_str());
  if (method == "HEAD")
    curl_easy_setopt(handle.get(), CURLOPT_NOBODY, 1L);
  if (!body.empty()) {
    curl_easy_setopt(handle.get(), CURLOPT_POSTFIELDS, body.data());
    curl_easy_setopt(handle.get(), CURLOPT_POSTFIELDSIZE_LARGE,
                     curl_off_t(body.size()));
  }
  curl_easy_setopt(handle.get(), CURLOPT_WRITEFUNCTION, bodyCallback);
  curl_easy_setopt(handle.get(), CURLOPT_WRITEDATA, &t);
  curl_easy_setopt(handle.get(), CURLOPT_HEADERFUNCTION, headerCallback);
  curl_easy_setopt(handle.get(), CURLOPT_HEADERDATA, &t);
  curl_easy_setopt(handle.get(), CURLOPT_NOPROGRESS, 0L);
  curl_easy_setopt(handle.get(), CURLOPT_XFERINFOFUNCTION, progressCallback);
  curl_easy_setopt(handle.get(), CURLOPT_XFERINFODATA, &t);
  auto result = curl_easy_perform(handle.get());
  assertCurrent();
  if (result != CURLE_OK || t.invalid)
    throw UserError("The secure server request failed or exceeded its limit. "
                    "Check its address and certificate.");
  long status = 0;
  curl_easy_getinfo(handle.get(), CURLINFO_RESPONSE_CODE, &status);
  t.result.status = int(status);
  if (status >= 300 && status < 400)
    throw UserError("Enter the final server address. Redirects are blocked to "
                    "protect your sign-in.");
  return std::move(t.result);
}
} // namespace mediavault
