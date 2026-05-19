const { getDefaultConfig } = require('expo/metro-config');
const path = require('path');

const projectRoot = __dirname;
const moduleRoot = path.resolve(projectRoot, '..');

const config = getDefaultConfig(projectRoot);

config.watchFolders = [moduleRoot];

config.resolver.nodeModulesPaths = [
  path.resolve(projectRoot, 'node_modules'),
  path.resolve(moduleRoot, 'node_modules'),
];

// Avoid Metro recursing into the parent module's example/ (which is this app),
// and prefer a single copy of react/react-native from example/node_modules.
config.resolver.blockList = [
  // The package symlink at example/node_modules/react-native-nitro-rtmp-publisher
  // points back to ../.. which contains this example/. Prevent Metro from
  // recursing through that symlink into its own example folder.
  new RegExp(
    `${projectRoot}/node_modules/react-native-nitro-rtmp-publisher/example/.*`
  ),
  new RegExp(`${moduleRoot}/node_modules/react/.*`),
  new RegExp(`${moduleRoot}/node_modules/react-native/.*`),
  new RegExp(`${moduleRoot}/node_modules/react-native-nitro-modules/.*`),
];

config.resolver.extraNodeModules = {
  react: path.resolve(projectRoot, 'node_modules/react'),
  'react-native': path.resolve(projectRoot, 'node_modules/react-native'),
  'react-native-nitro-modules': path.resolve(
    projectRoot,
    'node_modules/react-native-nitro-modules'
  ),
};

module.exports = config;
