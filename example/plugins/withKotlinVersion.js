// Builds the example's Android project with a Kotlin 2.2 compiler.
//
// RootEncoder 2.8 brings in a Kotlin 2.3 standard library, which a compiler
// older than 2.2 can't read. Expo SDK 57's template takes Kotlin 2.1.20 from
// React Native 0.86 and has no setting to change it, so this pins the Kotlin
// Gradle plugin in the generated root build.gradle. Delete this plugin once
// the example is on Expo SDK 58 (React Native 0.88 ships Kotlin 2.2).
const { withProjectBuildGradle } = require('@expo/config-plugins');

const KOTLIN_VERSION = '2.2.0';
const UNPINNED = "classpath('org.jetbrains.kotlin:kotlin-gradle-plugin')";
const PINNED = `classpath('org.jetbrains.kotlin:kotlin-gradle-plugin:${KOTLIN_VERSION}')`;

module.exports = function withKotlinVersion(config) {
  return withProjectBuildGradle(config, (config) => {
    const { contents } = config.modResults;
    if (contents.includes(PINNED)) {
      return config;
    }
    if (!contents.includes(UNPINNED)) {
      throw new Error(
        "[withKotlinVersion] android/build.gradle no longer declares the Kotlin Gradle plugin the way this plugin expects. If the template now sets a Kotlin version itself, delete this plugin."
      );
    }
    config.modResults.contents = contents.replace(UNPINNED, PINNED);
    return config;
  });
};
