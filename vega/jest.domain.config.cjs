module.exports = {
  testEnvironment: 'node',
  testMatch: ['<rootDir>/tst/**/*.test.ts'],
  setupFiles: ['<rootDir>/tst/setup-native-host.cjs'],
  transformIgnorePatterns: ['/node_modules/(?!react-native-url-polyfill/)'],
  transform: {
    '^.+\\.tsx?$': ['ts-jest', {tsconfig: {target: 'ES2022', module: 'CommonJS', esModuleInterop: true, strict: true}}],
    '^.+\\.js$': ['babel-jest', {configFile: false, babelrc: false, plugins: ['@babel/plugin-transform-modules-commonjs']}],
  },
};
