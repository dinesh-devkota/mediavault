#pragma once
#include <string_view>

namespace mediavault {
// IError::getTypes() is SDK type metadata, not its message. Emit only an exact
// allowlisted category; unknown types and all message contents stay private.
inline const char *platformErrorCategory(std::string_view types) noexcept {
  if (types.size() > 2048)
    return "platform";
  struct Category {
    std::string_view type;
    const char *label;
  };
  constexpr Category categories[] = {
      {"com.amazon.kepler.keystore.NoSuchKeystoreError", "no-keystore"},
      {"com.amazon.apmf.AccessDeniedError", "access-denied"},
      {"com.amazon.apmf.SecurityError", "security"},
      {"com.amazon.apmf.NotSupportedError", "not-supported"},
      {"com.amazon.apmf.NoSuchComponentError", "missing-component"},
      {"com.amazon.apmf.NoSuchInterfaceError", "missing-interface"},
      {"com.amazon.apmf.AbiBreakError", "abi"},
      {"com.amazon.apmf.TimeoutError", "timeout"},
      {"com.amazon.apmf.DeviceError", "device"},
      {"com.amazon.apmf.IoError", "io"},
      {"com.amazon.apmf.InvalidArgumentError", "argument"},
      {"com.amazon.apmf.InvalidOperationError", "operation"},
      {"com.amazon.apmf.ForeignRuntimeError", "foreign-runtime"},
      {"com.amazon.apmf.ApmfInternalError", "platform-internal"},
  };
  for (const auto &category : categories) {
    auto remaining = types;
    while (!remaining.empty()) {
      const auto delimiter = remaining.find(',');
      if (remaining.substr(0, delimiter) == category.type)
        return category.label;
      if (delimiter == std::string_view::npos)
        break;
      remaining.remove_prefix(delimiter + 1);
    }
  }
  return "platform";
}
} // namespace mediavault
