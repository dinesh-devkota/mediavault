// Production defaults. Only the isolated Debug/x86_64 fixture staging build replaces this file.
// This is bundled build metadata, never a runtime preference or credential-storage switch.
export const BUILD_CONFIG = {
  fixtureVault: false,
  packageId: 'com.dineshdevkota.cinevault',
} as const;
