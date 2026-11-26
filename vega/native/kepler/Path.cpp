#include "Core.h"
#include <algorithm>
#include <cctype>
#include <mbedtls/base64.h>
#include <stdexcept>
#include <utf8proc.h>

namespace mediavault {
std::string safeID(const std::string &value) {
  if (value.empty() || value.size() > 128 ||
      !std::all_of(value.begin(), value.end(), [](unsigned char c) {
        return std::isalnum(c) || c == '-' || c == '_';
      }))
    throw UserError("Invalid source or profile identifier.");
  return value;
}
std::string safePath(const std::string &value) {
  if (value.size() > 4096)
    throw UserError("The file path is too long.");
  size_t begin = 0;
  while (begin < value.size()) {
    auto end = value.find('/', begin);
    auto part =
        value.substr(begin, end == std::string::npos ? end : end - begin);
    if (part.empty() || part == "." || part == "..")
      throw UserError("Choose a path inside this source.");
    for (unsigned char c : part)
      if (c < 32 || c == 127 || c == '\\')
        throw UserError("Invalid file path.");
    std::string lower = part;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    for (auto escaped : {"%2e", "%2f", "%5c", "%00"})
      if (lower.find(escaped) != std::string::npos)
        throw UserError("Invalid encoded file path.");
    if (end == std::string::npos)
      break;
    begin = end + 1;
    if (begin == value.size())
      throw UserError("Invalid empty path component.");
  }
  return value;
}
bool contains(const std::string &path, const std::string &root,
              bool includeRoot) {
  safePath(path);
  safePath(root);
  return (includeRoot && path == root) ||
         (path != root &&
          (root.empty() || path.compare(0, root.size() + 1, root + "/") == 0));
}
std::string base64(const Bytes &bytes) {
  std::string out(((bytes.size() + 2) / 3) * 4 + 1, '\0');
  size_t written = 0;
  if (mbedtls_base64_encode(reinterpret_cast<unsigned char *>(out.data()),
                            out.size(), &written, bytes.data(), bytes.size()))
    throw UserError("Could not encode media bytes.");
  out.resize(written);
  return out;
}
Bytes unbase64(const std::string &text) {
  if (text.size() > 256 * 1024)
    throw UserError("Protected data is too large.");
  Bytes out(text.size());
  size_t written = 0;
  if (mbedtls_base64_decode(
          out.data(), out.size(), &written,
          reinterpret_cast<const unsigned char *>(text.data()), text.size()))
    throw UserError("Protected data is damaged.");
  out.resize(written);
  return out;
}
std::string percentEncode(const std::string &value, bool keepSlash) {
  const char *hex = "0123456789ABCDEF";
  std::string out;
  for (unsigned char c : value) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' ||
        c == '~' || (keepSlash && c == '/'))
      out += char(c);
    else {
      out += '%';
      out += hex[c >> 4];
      out += hex[c & 15];
    }
  }
  return out;
}
Source Source::parse(const JSON &j) {
  Source s;
  s.id = safeID(j.at("id").get<std::string>());
  s.kind = j.at("kind");
  s.endpoint = j.at("endpoint");
  s.root = safePath(j.value("root", ""));
  s.revision = j.value("revision", uint64_t(1));
  if (s.kind != "smb" && s.kind != "webdav" && s.kind != "jellyfin")
    throw UserError("Unsupported source type.");
  if (s.endpoint.empty() || s.endpoint.size() > 4096 ||
      s.endpoint.find('\0') != std::string::npos)
    throw UserError("Invalid server address.");
  s.username = j.value("username", "");
  s.password = j.value("password", "");
  s.token = j.value("token", "");
  s.userID = j.value("userId", "");
  if (s.username.size() > 1024 || s.password.size() > 4096 ||
      s.token.size() > 4096 || s.username.find('\0') != std::string::npos ||
      s.password.find('\0') != std::string::npos ||
      std::any_of(s.token.begin(), s.token.end(),
                  [](unsigned char c) { return c < 33 || c > 126; }))
    throw UserError(
        "Stored source credentials are invalid. Reconnect this source.");
  if (!s.userID.empty())
    safeID(s.userID);
  s.ignoredFolders = j.value("ignoredFolders", std::vector<std::string>{});
  s.ignoredFiles = j.value("ignoredFiles", std::vector<std::string>{});
  if (s.ignoredFolders.size() + s.ignoredFiles.size() > 10000)
    throw UserError("Too many excluded paths.");
  for (const auto &path : s.ignoredFolders)
    safePath(path);
  for (const auto &path : s.ignoredFiles)
    safePath(path);
  return s;
}
JSON Source::serialized() const {
  return {{"id", id},
          {"kind", kind},
          {"endpoint", endpoint},
          {"root", root},
          {"revision", revision},
          {"username", username},
          {"password", password},
          {"token", token},
          {"userId", userID},
          {"ignoredFolders", ignoredFolders},
          {"ignoredFiles", ignoredFiles}};
}
void Source::authorize(const std::string &path, bool listing) const {
  const auto normalized = [this](const std::string &value) {
    safePath(value);
    if (kind != "smb")
      return value;
    // SMB servers commonly compare Unicode names without case. Apply the
    // same conservative comparison to both selected and excluded paths.
    utf8proc_uint8_t *output = nullptr;
    auto size =
        utf8proc_map(reinterpret_cast<const utf8proc_uint8_t *>(value.data()),
                     value.size(), &output,
                     utf8proc_option_t(UTF8PROC_CASEFOLD | UTF8PROC_COMPOSE |
                                       UTF8PROC_STABLE));
    if (size < 0)
      throw UserError("The NAS returned an invalid Unicode path.");
    std::string result(reinterpret_cast<const char *>(output), size);
    free(output);
    return result;
  };
  auto candidate = normalized(path);
  if (!contains(candidate, normalized(root)))
    throw UserError("This path is outside the selected source folder.");
  for (const auto &folder : ignoredFolders)
    if (contains(candidate, normalized(folder)))
      throw UserError("This folder is excluded.");
  if (!listing)
    for (const auto &file : ignoredFiles)
      if (candidate == normalized(file))
        throw UserError("This file is excluded.");
}
void Source::authorizeJellyfinCatalog(const std::string &path,
                                      const std::string &method,
                                      const JSON &query) const {
  if (kind != "jellyfin" || userID.empty() || method != "GET" ||
      safePath(path) != "Users/" + safeID(userID) + "/Items" ||
      !query.is_object())
    throw UserError("Use the protected Jellyfin library browser.");
  for (auto it = query.begin(); it != query.end(); ++it) {
    const std::string fields[] = {
        "Recursive", "IncludeItemTypes", "Fields",    "StartIndex",
        "Limit",     "SortBy",           "SortOrder", "ParentId"};
    if (std::find(std::begin(fields), std::end(fields), it.key()) ==
            std::end(fields) ||
        !it.value().is_string() ||
        it.value().get_ref<const std::string &>().size() > 4096)
      throw UserError("Unsupported Jellyfin library parameters.");
  }
  if (!root.empty() && query.value("ParentId", "") != safeID(root))
    throw UserError("This request is outside the selected Jellyfin library.");
}
void Source::authorizeJellyfinResource(const std::string &path, bool image,
                                       const JSON &query) const {
  safePath(path);
  if (kind != "jellyfin" || userID.empty() || !query.is_object())
    throw UserError("Use a protected Jellyfin media item.");
  const auto prefix = image ? std::string("Items/")
                      : path.compare(0, 7, "Videos/") == 0
                          ? std::string("Videos/")
                          : std::string("Audio/");
  const auto suffix =
      image ? std::string("/Images/Primary") : std::string("/stream");
  if (path.size() <= prefix.size() + suffix.size() ||
      path.compare(0, prefix.size(), prefix) != 0 ||
      path.compare(path.size() - suffix.size(), suffix.size(), suffix) != 0)
    throw UserError("Unsupported Jellyfin media endpoint.");
  safeID(
      path.substr(prefix.size(), path.size() - prefix.size() - suffix.size()));
  if (image) {
    if (query.size() > 1 || (!query.empty() && !query.contains("maxWidth")))
      throw UserError("Unsupported Jellyfin image parameters.");
    if (query.contains("maxWidth")) {
      const auto width = query.at("maxWidth").get<std::string>();
      if (width.empty() || width.size() > 4 ||
          !std::all_of(width.begin(), width.end(),
                       [](unsigned char c) { return c >= '0' && c <= '9'; }) ||
          std::stoi(width) < 1 || std::stoi(width) > 2560)
        throw UserError("Unsupported Jellyfin image size.");
    }
  } else if (query.size() != 1 || query.value("static", "") != "true") {
    throw UserError("Use the protected direct-play Jellyfin stream.");
  }
}
} // namespace mediavault
