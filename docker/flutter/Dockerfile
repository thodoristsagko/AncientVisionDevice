FROM ghcr.io/cirruslabs/flutter:3.22.3

# The image ships with an empty /etc/passwd, which causes any user-name
# lookup (including Docker BuildKit's own startup) to fail with
# "unable to find user root".  Switch to numeric UID 0 (no name lookup
# required) and populate /etc/passwd so that subsequent tools work.
USER 0
RUN printf 'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534::/nonexistent:/usr/sbin/nologin\n' > /etc/passwd \
 && printf 'root:x:0:\nnobody:x:65534:\n' > /etc/group

WORKDIR /app

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
