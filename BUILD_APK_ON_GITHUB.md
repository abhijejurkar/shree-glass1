# Build the Shree Glass APK on GitHub

1. Upload/commit this complete project to the root of your GitHub repository, keeping `lib/`, `test/`, `pubspec.yaml`, and `.github/workflows/build-apk.yml` at the repository root.
2. Open the repository's **Actions** tab.
3. Select **Build Shree Glass Android APK**.
4. Click **Run workflow**, select the `main` branch, then click **Run workflow**.
5. Open the newest run. If all steps show green checks, scroll to **Artifacts** and download `shree-glass-release-apk`.
6. Extract the artifact ZIP to get `app-release.apk`.

A push to `main` or `master` also starts the workflow automatically. The workflow runs dependency resolution, Dart analysis, unit tests, release APK compilation, and artifact upload. If it fails, open the first red step and inspect the actual error lines.
