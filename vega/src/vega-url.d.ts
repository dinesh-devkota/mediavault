// The pinned SDK's src/types/globals.d.ts omits these runtime URL properties.
// Vega 0.83 documents the complete global URL API; no native bridge or polyfill
// is required: https://developer.amazon.com/docs/react-native-vega/0.83/global-URL
export {};
declare global {
  interface URL {
    readonly origin: string;
    protocol: string;
    username: string;
    password: string;
    hostname: string;
    port: string;
    pathname: string;
    search: string;
    hash: string;
  }
}
