#pragma once
#include "Core.h"

namespace mediavault {
// Test-only transport boundary. Exact strings deliberately reject DNS names,
// aliases, encoded paths, redirected endpoints and every real account.
inline void requireFixtureSource(const Source &source) {
  const bool endpoint =
      source.endpoint == "smb://127.0.0.1:1445/MEDIALIBRARY" ||
      source.endpoint == "smb://127.0.0.1:1445/FORMATPLAYBACK" ||
      source.endpoint == "smb://127.0.0.1:1445/MEDIAPLAYBACK";
  if (source.kind != "smb" || !endpoint || source.username != "cinevault" ||
      source.password != "fixture-only" || !source.token.empty() ||
      !source.userID.empty())
    throw UserError("This simulator test build accepts only its synthetic NAS "
                    "and fixture sign-in.");
}

[[noreturn]] inline void rejectFixtureHTTP() {
  throw UserError("External servers are disabled in the simulator test build.");
}
} // namespace mediavault
