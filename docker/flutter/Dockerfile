FROM ghcr.io/cirruslabs/flutter:3.22.3

WORKDIR /app

# Accept Android SDK licenses non-interactively.
RUN yes | sdkmanager --licenses || true

# Copy pubspec files first so that the flutter pub get layer is cached
# independently of application source changes.
COPY app/pubspec.yaml app/pubspec.lock ./

RUN flutter pub get

# Copy the rest of the application source.
COPY app/ .

# Create local.properties with the container's SDK paths.
# Written AFTER COPY app/ so it cannot be overwritten by the host file
# (which is excluded from the build context via .dockerignore because
# it contains Windows-specific absolute paths).
# Flutter SDK path is derived from the flutter binary on PATH to avoid
# relying on a specific env var name that may vary across image versions.
RUN FLUTTER_SDK=$(dirname $(dirname $(which flutter))) && \
    echo "sdk.dir=${ANDROID_SDK_ROOT}" > android/local.properties && \
    echo "flutter.sdk=${FLUTTER_SDK}" >> android/local.properties && \
    echo "flutter.buildMode=release" >> android/local.properties

# Default command: build a release APK.
CMD ["flutter", "build", "apk", "--release"]
