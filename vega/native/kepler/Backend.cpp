#include "Core.h"
#include "Relay.h"
#include <algorithm>
#include <chrono>
#include <cmath>
#include <curl/curl.h>
#include <limits>
#include <mbedtls/pkcs5.h>
#include <mbedtls/platform_util.h>
#include <stdexcept>

namespace mediavault {
namespace {
uint64_t decimal(const std::string &value) {
  if (value.empty() || value.size() > 20 ||
      !std::all_of(value.begin(), value.end(),
                   [](unsigned char c) { return c >= '0' && c <= '9'; }))
    throw UserError("Invalid media byte range.");
  size_t used = 0;
  auto result = std::stoull(value, &used);
  if (used != value.size())
    throw UserError("Invalid media byte range.");
  return result;
}
void validatePIN(const std::string &pin) {
  if (pin.size() < 6 || pin.size() > 12 ||
      !std::all_of(pin.begin(), pin.end(),
                   [](unsigned char c) { return c >= '0' && c <= '9'; }))
    throw UserError("Use a PIN with six to twelve digits.");
}
Bytes derive(std::string &pin, const Bytes &salt) {
  Bytes result(32);
  int error = mbedtls_pkcs5_pbkdf2_hmac_ext(
      MBEDTLS_MD_SHA256, reinterpret_cast<const uint8_t *>(pin.data()),
      pin.size(), salt.data(), salt.size(), 300000, result.size(),
      result.data());
  mbedtls_platform_zeroize(pin.data(), pin.size());
  if (error)
    throw UserError("Could not protect this PIN.");
  return result;
}
int64_t nowSeconds() {
  return std::chrono::duration_cast<std::chrono::seconds>(
             std::chrono::system_clock::now().time_since_epoch())
      .count();
}
std::string mimeFor(const std::string &path) {
  auto dot = path.find_last_of('.');
  auto ext = dot == std::string::npos ? "" : path.substr(dot + 1);
  std::transform(ext.begin(), ext.end(), ext.begin(),
                 [](unsigned char c) { return std::tolower(c); });
  if (ext == "jpg" || ext == "jpeg")
    return "image/jpeg";
  if (ext == "png")
    return "image/png";
  if (ext == "webp")
    return "image/webp";
  if (ext == "gif")
    return "image/gif";
  if (ext == "heic")
    return "image/heic";
  if (ext == "avif")
    return "image/avif";
  if (ext == "mp4" || ext == "m4v" || ext == "mov")
    return "video/mp4";
  if (ext == "mkv")
    return "video/x-matroska";
  if (ext == "webm")
    return "video/webm";
  if (ext == "mp3")
    return "audio/mpeg";
  if (ext == "flac")
    return "audio/flac";
  if (ext == "vtt")
    return "text/vtt";
  return "application/octet-stream";
}
void ensureHTTP(int status) {
  if (status == 401 || status == 403)
    throw UserError("The server rejected this account or file permission. "
                    "Reconnect the source.");
  if (status < 200 || status >= 300)
    throw UserError("This server file is unavailable.");
}
} // namespace
struct Backend::Impl {
  struct Entry {
    Source source;
    std::shared_ptr<SMB> smb;
  };
  Backend &owner;
  std::mutex mutex, pinMutex;
  std::unique_ptr<Vault> vault;
  std::unique_ptr<Relay> relay;
  std::map<std::string, std::shared_ptr<Entry>> sources;
  std::shared_ptr<std::atomic<size_t>> retainedImageBytes =
      std::make_shared<std::atomic<size_t>>(0);
  explicit Impl(Backend &value) : owner(value) {}
  Vault &secrets() {
    if (!vault)
      vault = std::make_unique<Vault>();
    return *vault;
  }
  void check(uint64_t epoch) {
    if (owner.generation.load() != epoch)
      throw UserError(
          "The active profile or source changed. Please try again.");
  }
  std::shared_ptr<Entry> source(const std::string &id, uint64_t epoch) {
    std::lock_guard<std::mutex> lock(mutex);
    check(epoch);
    safeID(id);
    auto found = sources.find(id);
    if (found != sources.end())
      return found->second;
    auto stored = secrets().read("source_" + id);
    if (stored.is_null())
      throw UserError("Reconnect this source to restore its sign-in.");
    check(epoch);
    auto entry = std::make_shared<Entry>();
    entry->source = Source::parse(stored);
    sources[id] = entry;
    return entry;
  }
  std::shared_ptr<SMB> smb(const std::shared_ptr<Entry> &entry,
                           uint64_t epoch) {
    std::lock_guard<std::mutex> lock(mutex);
    if (!entry->smb)
      entry->smb =
          std::make_shared<SMB>(entry->source, [this, epoch] { check(epoch); });
    return entry->smb;
  }
  JSON stat(const std::shared_ptr<Entry> &entry, const std::string &path,
            const JSON &query, uint64_t epoch) {
    check(epoch);
    JSON result;
    if (entry->source.kind == "smb")
      result = smb(entry, epoch)->stat(path);
    else {
      auto response = http(entry->source,
                           {{"path", path},
                            {"query", query},
                            {"method", "HEAD"},
                            {"maximumBytes", 0}},
                           [this, epoch] { check(epoch); });
      ensureHTTP(response.status);
      auto found = response.headers.find("content-length");
      if (found == response.headers.end())
        throw UserError("The server did not provide the media length.");
      auto size = decimal(found->second);
      if (size > 9007199254740991ULL)
        throw UserError("This media file is too large.");
      result = {{"size", size}, {"directory", false}};
      auto mime = response.headers.find("content-type");
      if (mime != response.headers.end())
        result["mime"] = mime->second;
    }
    check(epoch);
    return result;
  }
  Bytes read(const std::shared_ptr<Entry> &entry, const std::string &path,
             const JSON &query, uint64_t offset, size_t length,
             uint64_t epoch) {
    check(epoch);
    Bytes bytes;
    if (entry->source.kind == "smb")
      bytes = smb(entry, epoch)->read(path, offset, length);
    else {
      if (!length || offset > std::numeric_limits<uint64_t>::max() - length)
        throw UserError("Invalid byte range.");
      auto response =
          http(entry->source,
               {{"path", path},
                {"query", query},
                {"method", "GET"},
                {"maximumBytes", length},
                {"headers",
                 {{"Range", "bytes=" + std::to_string(offset) + "-" +
                                std::to_string(offset + length - 1)}}}},
               [this, epoch] { check(epoch); });
      ensureHTTP(response.status);
      auto range = response.headers.find("content-range");
      if (response.status != 206 || range == response.headers.end())
        throw UserError("This server does not support safe media seeking.");
      auto expected = "bytes " + std::to_string(offset) + "-";
      if (range->second.compare(0, expected.size(), expected) != 0)
        throw UserError("The server returned the wrong media range.");
      auto slash = range->second.find('/', expected.size());
      if (slash == std::string::npos)
        throw UserError("Invalid media range response.");
      auto last = decimal(
               range->second.substr(expected.size(), slash - expected.size())),
           total = decimal(range->second.substr(slash + 1));
      if (last < offset || last - offset + 1 != response.body.size() ||
          last >= total || response.body.size() > length)
        throw UserError("The server returned an incomplete media range.");
      bytes = std::move(response.body);
    }
    check(epoch);
    return bytes;
  }
};
Backend::Backend() : impl(std::make_unique<Impl>(*this)) {
  static const auto initialized = curl_global_init(CURL_GLOBAL_DEFAULT);
  if (initialized)
    throw UserError("Could not initialize secure connections.");
}
Backend::~Backend() { revoke(); }
std::string Backend::configure(const std::string &json, std::string username,
                               std::string password, bool jellyfin,
                               uint64_t epoch) {
  if (json.size() > 128 * 1024 || username.size() > 1024 ||
      password.size() > 4096 || username.find('\0') != std::string::npos ||
      password.find('\0') != std::string::npos)
    throw UserError("Source details are invalid.");
  Source source = Source::parse(JSON::parse(json));
  source.username = std::move(username);
  source.password = std::move(password);
  source.token.clear();
  if (jellyfin != (source.kind == "jellyfin"))
    throw UserError("Invalid source sign-in.");
  JSON account = JSON::object();
  std::shared_ptr<SMB> smb;
  if (source.kind == "smb") {
    smb = std::make_shared<SMB>(source, [this, epoch] { impl->check(epoch); });
    if (!smb->stat(source.root).at("directory").get<bool>())
      throw UserError("Select a NAS folder.");
  } else if (jellyfin) {
    auto response = http(
        source,
        {{"path", "Users/AuthenticateByName"},
         {"method", "POST"},
         {"maximumBytes", 1024 * 1024},
         {"headers", {{"Content-Type", "application/json"}}},
         {"body",
          JSON{{"Username", source.username}, {"Pw", source.password}}.dump()}},
        [this, epoch] { impl->check(epoch); });
    ensureHTTP(response.status);
    auto result = JSON::parse(response.body.begin(), response.body.end());
    source.token = result.at("AccessToken").get<std::string>();
    source.userID = safeID(result.at("User").at("Id").get<std::string>());
    if (source.token.empty() || source.token.size() > 4096 ||
        std::any_of(source.token.begin(), source.token.end(),
                    [](unsigned char c) { return c < 33 || c > 126; }))
      throw UserError("The server returned an invalid sign-in.");
    account = {{"userId", source.userID},
               {"userName", result.at("User").value("Name", source.username)}};
    mbedtls_platform_zeroize(source.password.data(), source.password.size());
    source.password.clear();
  } else {
    auto response = http(
        source,
        {{"path", source.root},
         {"method", "PROPFIND"},
         {"maximumBytes", 1024 * 1024},
         {"headers", {{"Depth", "0"}, {"Content-Type", "application/xml"}}},
         {"body",
          "<d:propfind "
          "xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>"}},
        [this, epoch] { impl->check(epoch); });
    if (response.status != 207) {
      ensureHTTP(response.status);
      throw UserError("This address did not return a WebDAV folder.");
    }
  }
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->check(epoch);
  impl->secrets().write("source_" + source.id, source.serialized(),
                        [this, epoch] { impl->check(epoch); });
  impl->check(epoch);
  auto entry = std::make_shared<Impl::Entry>();
  entry->source = std::move(source);
  entry->smb = std::move(smb);
  impl->sources[entry->source.id] = entry;
  generation.fetch_add(1);
  if (impl->relay)
    impl->relay->revokeAll();
  return account.dump();
}
void Backend::updateSource(const std::string &json, uint64_t epoch) {
  if (json.size() > 128 * 1024)
    throw UserError("Source settings are too large.");
  auto requested = Source::parse(JSON::parse(json));
  auto existing = impl->source(requested.id, epoch);
  if (requested.kind != existing->source.kind ||
      requested.endpoint != existing->source.endpoint)
    throw UserError("Reconnect after changing the server address.");
  requested.username = existing->source.username;
  requested.password = existing->source.password;
  requested.token = existing->source.token;
  requested.userID = existing->source.userID;
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->check(epoch);
  impl->secrets().write("source_" + requested.id, requested.serialized(),
                        [this, epoch] { impl->check(epoch); });
  impl->check(epoch);
  auto entry = std::make_shared<Impl::Entry>();
  entry->source = std::move(requested);
  entry->smb = existing->smb;
  impl->sources[entry->source.id] = entry;
  generation.fetch_add(1);
  if (impl->relay)
    impl->relay->revokeAll();
}
void Backend::removeSource(const std::string &id, uint64_t epoch) {
  safeID(id);
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->check(epoch);
  impl->secrets().write("source_" + id, nullptr,
                        [this, epoch] { impl->check(epoch); });
  impl->check(epoch);
  impl->sources.erase(id);
  generation.fetch_add(1);
  if (impl->relay)
    impl->relay->revokeAll();
}
std::string Backend::list(const std::string &id, const std::string &path,
                          uint64_t epoch) {
  auto entry = impl->source(id, epoch);
  entry->source.authorize(path, true);
  if (entry->source.kind != "smb")
    throw UserError("Use the protocol folder browser.");
  auto list = impl->smb(entry, epoch)->list(path);
  impl->check(epoch);
  JSON result = JSON::array();
  for (const auto &item : list) {
    try {
      entry->source.authorize(item.at("path"), item.at("directory"));
      result.push_back(item);
    } catch (...) {
    }
  }
  return result.dump();
}
std::string Backend::stat(const std::string &id, const std::string &path,
                          uint64_t epoch) {
  auto entry = impl->source(id, epoch);
  if (entry->source.kind == "jellyfin")
    throw UserError("Use a protected Jellyfin media item.");
  entry->source.authorize(path);
  return impl->stat(entry, path, JSON::object(), epoch).dump();
}
std::string Backend::read(const std::string &id, const std::string &path,
                          const std::string &offset, double length,
                          uint64_t epoch) {
  if (!std::isfinite(length) || length < 0 || length > 1024 * 1024 ||
      std::floor(length) != length)
    throw UserError("Invalid media read length.");
  auto entry = impl->source(id, epoch);
  if (entry->source.kind == "jellyfin")
    throw UserError("Use a protected Jellyfin media item.");
  entry->source.authorize(path);
  return base64(impl->read(entry, path, JSON::object(), decimal(offset),
                           size_t(length), epoch));
}
std::string Backend::request(const std::string &id, const std::string &json,
                             uint64_t epoch) {
  if (json.size() > 2 * 1024 * 1024)
    throw UserError("Request is too large.");
  auto request = JSON::parse(json);
  auto entry = impl->source(id, epoch);
  auto path = safePath(request.at("path"));
  if (request.at("maximumBytes").get<int64_t>() > 8 * 1024 * 1024)
    throw UserError("This request is too large.");
  if (entry->source.kind == "webdav") {
    const auto method = request.at("method").get<std::string>();
    if (method != "GET" && method != "HEAD" && method != "PROPFIND")
      throw UserError("This source allows browsing and reading media only.");
    entry->source.authorize(path, request.at("method") == "PROPFIND");
  } else if (entry->source.kind == "jellyfin") {
    entry->source.authorizeJellyfinCatalog(
        path, request.at("method"), request.value("query", JSON::object()));
    if (!request.value("body", "").empty())
      throw UserError("Jellyfin browsing requests cannot include a body.");
  } else
    throw UserError("Use the NAS file browser.");
  try {
    auto result =
        http(entry->source, request, [this, epoch] { impl->check(epoch); });
    return textResponse(result);
  } catch (const ResponseLimitError &) {
    impl->check(epoch);
    return JSON{{"error",
                 {{"code", "text-too-large"},
                  {"message", "This metadata or subtitle file exceeds the "
                              "supported size limit."}}}}
        .dump();
  }
}
std::string Backend::ticket(const std::string &id, const std::string &path,
                            const std::string &queryJSON, uint64_t epoch) {
  safePath(path);
  auto entry = impl->source(id, epoch);
  if (entry->source.kind != "jellyfin")
    entry->source.authorize(path);
  auto query = JSON::parse(queryJSON);
  if (!query.is_object() || query.size() > 30)
    throw UserError("Invalid media parameters.");
  if (entry->source.kind == "jellyfin")
    entry->source.authorizeJellyfinResource(path, false, query);
  auto metadata = impl->stat(entry, path, query, epoch);
  auto size = metadata.at("size").get<uint64_t>();
  auto mime = metadata.value("mime", mimeFor(path));
  auto weak = weak_from_this();
  Relay::Resource resource;
  resource.check = [weak, epoch] {
    auto owner = weak.lock();
    if (!owner)
      throw UserError("Playback closed.");
    owner->impl->check(epoch);
  };
  resource.size = [size] { return size; };
  resource.mime = mime;
  resource.read = [weak, entry, path, query, epoch](uint64_t offset,
                                                    size_t length) {
    auto owner = weak.lock();
    if (!owner)
      throw UserError("Playback closed.");
    return owner->impl->read(entry, path, query, offset, length, epoch);
  };
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->check(epoch);
  if (!impl->relay)
    impl->relay = std::make_unique<Relay>();
  auto bytes = impl->secrets().random(32);
  std::string token;
  const char *hex = "0123456789abcdef";
  for (auto b : bytes) {
    token += hex[b >> 4];
    token += hex[b & 15];
  }
  return JSON{{"uri", impl->relay->add(token, std::move(resource))},
              {"mime", mime}}
      .dump();
}
std::string Backend::imageTicket(const std::string &id, const std::string &path,
                                 const std::string &queryJSON, uint64_t epoch) {
  safePath(path);
  auto entry = impl->source(id, epoch);
  if (entry->source.kind != "jellyfin")
    entry->source.authorize(path);
  auto query = JSON::parse(queryJSON);
  if (!query.is_object() || query.size() > 30)
    throw UserError("Invalid image parameters.");
  if (entry->source.kind == "jellyfin")
    entry->source.authorizeJellyfinResource(path, true, query);
  Bytes bytes;
  std::string mime = mimeFor(path);
  if (entry->source.kind == "smb") {
    auto size =
        impl->stat(entry, path, query, epoch).at("size").get<uint64_t>();
    if (size > 16 * 1024 * 1024)
      throw UserError("This image exceeds the 16 MB viewer limit.");
    while (bytes.size() < size) {
      auto part = impl->read(
          entry, path, query, bytes.size(),
          size_t(std::min<uint64_t>(1024 * 1024, size - bytes.size())), epoch);
      if (part.empty())
        throw UserError("The image ended unexpectedly.");
      bytes.insert(bytes.end(), part.begin(), part.end());
    }
  } else {
    auto response = http(entry->source,
                         {{"path", path},
                          {"query", query},
                          {"method", "GET"},
                          {"maximumBytes", 16 * 1024 * 1024}},
                         [this, epoch] { impl->check(epoch); });
    ensureHTTP(response.status);
    auto type = response.headers.find("content-type");
    if (type != response.headers.end())
      mime = type->second;
    bytes = std::move(response.body);
  }
  auto semicolon = mime.find(';');
  if (semicolon != std::string::npos)
    mime.resize(semicolon);
  if (bytes.empty() ||
      (mime != "image/jpeg" && mime != "image/png" && mime != "image/webp" &&
       mime != "image/gif" && mime != "image/heic" && mime != "image/avif"))
    throw UserError("The source did not return a supported photo.");
  auto total = impl->retainedImageBytes;
  auto count = bytes.size();
  if (total->fetch_add(count) + count > 64 * 1024 * 1024) {
    total->fetch_sub(count);
    throw UserError(
        "Close an image preview before opening another large photo.");
  }
  auto retained = std::shared_ptr<Bytes>(new Bytes(std::move(bytes)),
                                         [total, count](Bytes *value) {
                                           delete value;
                                           total->fetch_sub(count);
                                         });
  auto weak = weak_from_this();
  Relay::Resource resource;
  resource.mime = mime;
  resource.check = [weak, epoch] {
    auto owner = weak.lock();
    if (!owner)
      throw UserError("Image closed.");
    owner->impl->check(epoch);
  };
  resource.size = [retained] { return retained->size(); };
  resource.read = [retained](uint64_t offset, size_t length) {
    if (offset > retained->size())
      throw UserError("Invalid image range.");
    auto end = std::min<uint64_t>(retained->size(), offset + length);
    return Bytes(retained->begin() + offset, retained->begin() + end);
  };
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->check(epoch);
  if (!impl->relay)
    impl->relay = std::make_unique<Relay>();
  auto random = impl->secrets().random(32);
  std::string token;
  const char *hex = "0123456789abcdef";
  for (auto b : random) {
    token += hex[b >> 4];
    token += hex[b & 15];
  }
  return JSON{{"uri", impl->relay->add(token, std::move(resource))},
              {"mime", mime}}
      .dump();
}
void Backend::revoke() {
  generation.fetch_add(1);
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (impl->relay)
    impl->relay->revokeAll();
}
void Backend::revokeResource(const std::string &uri) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  if (impl->relay)
    impl->relay->revoke(uri);
}
bool Backend::hasPIN(const std::string &id, uint64_t epoch) {
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->check(epoch);
  const auto present = !impl->secrets().read("pin_" + safeID(id)).is_null();
  impl->check(epoch);
  return present;
}
void Backend::setPIN(const std::string &id, std::string pin, uint64_t epoch) {
  validatePIN(pin);
  safeID(id);
  std::lock_guard<std::mutex> pinLock(impl->pinMutex);
  Bytes salt;
  {
    std::lock_guard<std::mutex> lock(impl->mutex);
    impl->check(epoch);
    salt = impl->secrets().random(16);
  }
  auto hash = derive(pin, salt);
  {
    std::lock_guard<std::mutex> lock(impl->mutex);
    impl->check(epoch);
    impl->secrets().write("pin_" + id,
                          {{"salt", base64(salt)},
                           {"hash", base64(hash)},
                           {"failures", 0},
                           {"nextAttempt", 0}},
                          [this, epoch] { impl->check(epoch); });
  }
  mbedtls_platform_zeroize(hash.data(), hash.size());
  impl->check(epoch);
  revoke();
}
bool Backend::verifyPIN(const std::string &id, std::string pin,
                        uint64_t epoch) {
  validatePIN(pin);
  safeID(id);
  std::lock_guard<std::mutex> pinLock(impl->pinMutex);
  JSON record;
  {
    std::lock_guard<std::mutex> lock(impl->mutex);
    impl->check(epoch);
    record = impl->secrets().read("pin_" + id);
    impl->check(epoch);
  }
  if (record.is_null())
    throw UserError("This profile has no saved PIN.");
  auto now = nowSeconds();
  if (now < record.at("nextAttempt").get<int64_t>())
    throw UserError("Too many PIN attempts. Wait before trying again.");
  auto salt = unbase64(record.at("salt")),
       expected = unbase64(record.at("hash"));
  if (salt.size() != 16 || expected.size() != 32)
    throw UserError("The protected PIN data is damaged.");
  auto actual = derive(pin, salt);
  uint8_t difference = 0;
  for (size_t i = 0; i < 32; ++i)
    difference |= actual[i] ^ expected[i];
  bool valid = difference == 0;
  int failures = valid ? 0 : std::min(30, record.at("failures").get<int>() + 1);
  record["failures"] = failures;
  record["nextAttempt"] =
      failures < 5 ? 0
                   : now + std::min(900, 30 * (1 << std::min(5, failures - 5)));
  {
    std::lock_guard<std::mutex> lock(impl->mutex);
    impl->check(epoch);
    impl->secrets().write("pin_" + id, record,
                          [this, epoch] { impl->check(epoch); });
  }
  mbedtls_platform_zeroize(actual.data(), actual.size());
  impl->check(epoch);
  return valid;
}
void Backend::removePIN(const std::string &id, uint64_t epoch) {
  std::lock_guard<std::mutex> pinLock(impl->pinMutex);
  std::lock_guard<std::mutex> lock(impl->mutex);
  impl->check(epoch);
  impl->secrets().write("pin_" + safeID(id), nullptr,
                        [this, epoch] { impl->check(epoch); });
  impl->check(epoch);
  generation.fetch_add(1);
  if (impl->relay)
    impl->relay->revokeAll();
}
} // namespace mediavault
