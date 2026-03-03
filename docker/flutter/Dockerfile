FROM ghcr.io/cirruslabs/flutter:3.41.3

WORKDIR /app

# Accept Android SDK licenses non-interactively.
RUN yes | sdkmanager --licenses || true

# Create local.properties with Linux SDK paths.
# This file is excluded from the Docker build context via .dockerignore because
# the host copy contains Windows-specific paths (C:\Users\...). The container
# uses the SDK paths baked into the cirruslabs/flutter image instead.
RUN echo "sdk.dir=${ANDROID_SDK_ROOT}" > android/local.properties && \
    echo "flutter.sdk=${FLUTTER_ROOT}" >> android/local.properties && \
    echo "flutter.buildMode=release" >> android/local.properties && \
    echo "flutter.versionName=1.0.0" >> android/local.properties && \
    echo "flutter.versionCode=1" >> android/local.properties

# Copy pubspec files first so that the dependency-fetch layer is cached
# independently of application source changes.
COPY app/pubspec.yaml app/pubspec.lock* ./

RUN flutter pub get

# Copy the rest of the application source after dependencies are resolved.
COPY app/ .

# Default command: build a release APK.
CMD ["flutter", "build", "apk", "--release"]
