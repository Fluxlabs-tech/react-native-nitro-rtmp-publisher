// Re-exports the Expo config plugin from `plugin/withRtmpPublisher.js`.
// Expo's `expo prebuild` looks up `app.plugin.js` at the package root when a
// user lists "react-native-nitro-rtmp-publisher" in their `expo.plugins`.
module.exports = require('./plugin/withRtmpPublisher');
