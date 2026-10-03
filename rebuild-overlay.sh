#!/usr/bin/env bash
#
# Rebuild the LDAP wildcard overlay jar for a given OpenMetadata version.
#
#   ./rebuild-overlay.sh 1.13.6
#   ./rebuild-overlay.sh 1.13.6 --image openmetadata/server
#
# Produces dist/ldap-wildcard-overlay-<version>.jar containing only the patched
# LdapAuthenticator classes. Drop that jar next to your deployment and point the
# CLASSPATH environment variable at it -- the shipped image is never modified.
#
# Requires: docker, curl, patch. Java and Maven are NOT needed on the host;
# compilation runs in a container against the target version's own jars.

set -euo pipefail

# Git Bash rewrites container-side paths such as /src into Windows paths. Scope
# the opt-out to docker only: applying it globally would break curl, which is a
# native Windows binary and needs a real Windows path for -o.
dock() { MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' docker "$@"; }

VERSION="${1:-}"
IMAGE_REPO="docker.getcollate.io/openmetadata/server"
JDK_IMAGE="eclipse-temurin:21-jdk"

SRC_PATH="openmetadata-service/src/main/java/org/openmetadata/service/security/auth/LdapAuthenticator.java"
CLASS_GLOB="org/openmetadata/service/security/auth/LdapAuthenticator*.class"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# On Git Bash, pwd yields /c/Users/... but Docker needs C:/Users/... for host-side
# volume and cp paths. cygpath -m gives a form both bash and Docker accept.
if command -v cygpath >/dev/null 2>&1; then HERE="$(cygpath -m "$HERE")"; fi
PATCH_FILE="$HERE/patches/ldap-wildcard-group-mapping.patch"
DIST="$HERE/dist"
WORK="$HERE/.build"

shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE_REPO="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "usage: $(basename "$0") <openmetadata-version> [--image <repo>]" >&2
  echo "   eg: $(basename "$0") 1.13.6" >&2
  exit 2
fi

for c in docker curl patch; do
  command -v "$c" >/dev/null || { echo "$c is required" >&2; exit 1; }
done
[ -f "$PATCH_FILE" ] || { echo "patch not found: $PATCH_FILE" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK" "$DIST"
trap 'rm -rf "$WORK"' EXIT

echo "==> OpenMetadata $VERSION"

# ---------------------------------------------------------------- 1. source
echo "==> Fetching upstream LdapAuthenticator.java"
mkdir -p "$WORK/src/$(dirname "$SRC_PATH")"
RAW="https://raw.githubusercontent.com/open-metadata/OpenMetadata/${VERSION}-release/$SRC_PATH"
if ! curl -sfL --retry 4 --retry-delay 2 "$RAW" -o "$WORK/src/$SRC_PATH"; then
  echo "ERROR: could not fetch $RAW" >&2
  echo "       check that tag ${VERSION}-release exists upstream." >&2
  exit 1
fi
echo "    md5 $(md5sum "$WORK/src/$SRC_PATH" | cut -d' ' -f1)  ($(wc -l < "$WORK/src/$SRC_PATH") lines)"

# openmetadata-service/lombok.config sets `lombok.log.fieldName = LOG`. Without it
# @Slf4j generates a field called `log` and every LOG.* reference fails to compile.
LOMBOK_CFG="openmetadata-service/lombok.config"
if ! curl -sfL --retry 4 --retry-delay 2 \
     "https://raw.githubusercontent.com/open-metadata/OpenMetadata/${VERSION}-release/$LOMBOK_CFG" \
     -o "$WORK/src/$LOMBOK_CFG"; then
  echo "ERROR: could not fetch $LOMBOK_CFG" >&2
  exit 1
fi
echo "    lombok.config: $(tr '\n' ' ' < "$WORK/src/$LOMBOK_CFG")"

# ---------------------------------------------------------------- 2. patch
# A clean apply is the real compatibility signal. If upstream reworked this file
# the patch refuses here, rather than yielding a jar that breaks at login time.
echo "==> Applying patch"
if ! ( cd "$WORK/src" && patch -p1 --no-backup-if-mismatch -s < "$PATCH_FILE" ); then
  echo "" >&2
  echo "ERROR: patch did not apply cleanly to $VERSION." >&2
  echo "       Upstream changed LdapAuthenticator.java. Re-create the patch against" >&2
  echo "       this version by hand, then re-run. Do NOT reuse an older overlay jar:" >&2
  echo "       it silently replaces the new class and can fail at login time." >&2
  exit 1
fi
echo "    applied cleanly"

# ---------------------------------------------------------------- 3. deps
echo "==> Extracting dependency jars from $IMAGE_REPO:$VERSION"
dock pull -q "$IMAGE_REPO:$VERSION" >/dev/null
CID="$(dock create "$IMAGE_REPO:$VERSION")"
dock cp "$CID:/opt/openmetadata/libs" "$WORK/libs" >/dev/null
dock rm -f "$CID" >/dev/null
echo "    $(find "$WORK/libs" -name '*.jar' | wc -l) jars"

# ---------------------------------------------------------------- 4. compile
echo "==> Compiling against $VERSION dependencies"
mkdir -p "$WORK/out"
dock run --rm \
  -v "$WORK/src:/src:ro" -v "$WORK/libs:/libs:ro" -v "$WORK/out:/out" \
  --entrypoint sh "$JDK_IMAGE" -c \
  "cd /src && javac -nowarn -encoding UTF-8 -d /out -cp '/libs/*' ./$SRC_PATH"

COUNT="$(find "$WORK/out" -name 'LdapAuthenticator*.class' | wc -l)"
[ "$COUNT" -gt 0 ] || { echo "ERROR: no classes produced" >&2; exit 1; }
echo "    $COUNT class files"

# ---------------------------------------------------------------- 5. jar
JAR_NAME="ldap-wildcard-overlay-$VERSION.jar"
dock run --rm -v "$WORK/out:/out" -v "$DIST:/dist" \
  --entrypoint sh "$JDK_IMAGE" -c \
  "cd /out && jar cf /dist/$JAR_NAME $CLASS_GLOB"

# ---------------------------------------------------------------- 6. verify
echo "==> Verifying"
dock run --rm -v "$DIST:/dist:ro" -v "$WORK/libs:/libs:ro" \
  --entrypoint sh "$JDK_IMAGE" -c \
  "cd /dist && javap -p -cp '$JAR_NAME:/libs/*' org.openmetadata.service.security.auth.LdapAuthenticator \
     | grep -qE 'createGroupAttributeFilter|resolveMappedRoles'" \
  || { echo "ERROR: patched methods missing from jar" >&2; exit 1; }
echo "    patched methods present"

echo ""
echo "Built: $DIST/$JAR_NAME  ($(stat -c%s "$DIST/$JAR_NAME" 2>/dev/null || stat -f%z "$DIST/$JAR_NAME") bytes)"
echo ""
echo "Deploy by mounting it and seeding CLASSPATH. The start script appends the"
echo "shipped jars after it, so your class wins:"
echo ""
echo "  volumes:"
echo "    - ./patch:/patch:ro"
echo "  environment:"
echo "    CLASSPATH: /patch/$JAR_NAME"
echo "    OPENMETADATA_LDAP_REQUIRE_GROUP: \"true\"   # optional login gate"
