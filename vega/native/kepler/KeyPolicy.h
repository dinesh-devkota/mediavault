#pragma once
#include "Core.h"

namespace mediavault {
// Reads are side-effect free. A missing key alongside encrypted data is a
// recovery condition, never permission to replace the device key silently.
template <class CreateKey>
void requireVaultKey(bool keyPresent, bool encryptedRecordsPresent,
                     bool explicitSave, CreateKey &&create) {
  if (keyPresent)
    return;
  if (!explicitSave || encryptedRecordsPresent)
    throw UserError(
        "The device key for your protected settings is unavailable. Restore "
        "the device key or reset protected settings.");
  create();
}
} // namespace mediavault
