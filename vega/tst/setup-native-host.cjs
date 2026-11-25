// The real URL polyfill only needs RN platform/blob hooks. Its URL parser is never mocked.
jest.mock('react-native', () => ({Platform: {OS: 'vega', Version: '2.0'}, NativeModules: {}}));
