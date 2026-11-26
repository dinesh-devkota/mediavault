import { AppRegistry, LogBox } from 'react-native';
import { App } from './src/App';
import { BUILD_CONFIG } from './src/generated/buildConfig';
import { name as appName } from './app.json';

// Match the SDK template's notification workaround only in the isolated
// simulator fixture. Console logs and uncaught-error screens remain enabled.
if (__DEV__ && BUILD_CONFIG.fixtureVault) {
  LogBox.ignoreAllLogs();
}

AppRegistry.registerComponent(appName, () => App);
