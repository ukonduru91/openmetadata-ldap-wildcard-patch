# OpenMetadata LDAP wildcard group patch

Adds wildcard (glob) support to OpenMetadata's LDAP group handling, plus an optional
group-based login gate. Delivered as a small **classpath overlay jar** — the official
OpenMetadata image is never modified or rebuilt.

---

## Quick start

```sh
git clone https://github.com/ukonduru91/openmetadata-ldap-wildcard-patch.git
cd openmetadata-ldap-wildcard-patch
./rebuild-overlay.sh 1.13.6
```

Produces `dist/ldap-wildcard-overlay-1.13.6.jar` (~14 KB). Mount that jar into your
OpenMetadata container and point `CLASSPATH` at it — see [Deploy](#deploy).

---

## Prerequisites

| Requirement | Why | Check |
|---|---|---|
| **docker** | pulls the target image and runs the compiler in a container | `docker --version` |
| **curl** | fetches the upstream source for the version you name | `curl --version` |
| **patch** (GNU) | applies the patch to that source | `patch --version` |
| **bash** | the script is bash, not POSIX sh | `bash --version` |
| Network access to **github.com** and your **container registry** | source + image download | |
| ~2 GB free disk | the OpenMetadata image is ~1 GB, pulled once per version | |

**Java and Maven are NOT required on the host.** Compilation happens inside an
`eclipse-temurin:21-jdk` container, against the dependency jars extracted from the exact
OpenMetadata version you are building for. Nothing is installed on your machine.

Works on Linux, macOS, and Windows under Git Bash or WSL. On Git Bash the script handles
path translation itself (`cygpath`), so no extra setup is needed. It does **not** run in
PowerShell or `cmd.exe` — use Git Bash or WSL there.

The first run for a given version downloads that image and takes a few minutes; later runs
for the same version are fast.

---

## Input and usage

```
./rebuild-overlay.sh <openmetadata-version> [--image <registry/repo>]
```

| Argument | Required | Description | Example |
|---|---|---|---|
| `<openmetadata-version>` | **yes** | The OpenMetadata version you are running, exactly as upstream tags it — digits and dots only, **no** `v` prefix and no `-release` suffix. The script appends `-release` itself when fetching the source. | `1.13.6` |
| `--image <registry/repo>` | no | Image repository to pull dependency jars from. Defaults to `docker.getcollate.io/openmetadata/server`. Use this for Docker Hub or an internal mirror. | `--image openmetadata/server` |

Examples:

```sh
./rebuild-overlay.sh 1.13.6                                  # default registry
./rebuild-overlay.sh 1.13.6 --image openmetadata/server      # Docker Hub
./rebuild-overlay.sh 2.0.3  --image registry.corp.com/om/server   # internal mirror
```

Find your version in the OpenMetadata UI footer, or:

```sh
docker inspect <your-container> --format '{{.Config.Image}}'
```

**Output:** `dist/ldap-wildcard-overlay-<version>.jar`

### What it does

1. Fetches `LdapAuthenticator.java` for that tag from GitHub.
2. Fetches `openmetadata-service/lombok.config` — it sets `lombok.log.fieldName = LOG`, and
   without it `@Slf4j` generates `log` instead and the build fails on every `LOG.*` call.
3. Applies `patches/ldap-wildcard-group-mapping.patch`. **Stops here if it does not apply
   cleanly**, rather than producing a jar that would break at login time.
4. Extracts `/opt/openmetadata/libs` from that version's image.
5. Compiles the single file in a container against those jars.
6. Packages the resulting classes and verifies the patched methods are present.

Exit code is `0` on success, non-zero on any failure.

---

## Version compatibility

The overlay replaces the whole class, so it must be built from the **matching** upstream
source. Always rebuild for the version you are deploying.

Tested on 2026-10-03:

| Version | Patch applies | Builds | Dependency jars | Runtime verified |
|---|---|---|---|---|
| 1.11.8 | yes | not built | – | no |
| 1.12.5 | yes | **yes** | 568 | no |
| 1.12.14 | yes | not built | – | no |
| 1.13.1 | yes | not built | – | no |
| **1.13.3** | yes | **yes** | 558 | **yes — full end-to-end** |
| 1.13.6 | yes | **yes** | 569 | no |
| 2.0.0 | yes | not built | – | no |
| 2.0.3 | yes | **yes** | 584 | no |

So in practice: **the script works with any OpenMetadata version whose source the patch still
applies to**, and that currently covers every release tested from 1.11.8 through 2.0.3. If a
future release reworks `LdapAuthenticator.java`, the script fails loudly at step 3 and the
patch needs updating by hand.

Only **1.13.3** has been verified end-to-end against a live server (login, roles, and the
gate). The others compile and package correctly but were not run — smoke-test login after
deploying any of them.

### Never reuse a jar across minor lines

1.12.x and 1.13.x differ: five methods dropped `throws TemplateException`. A 1.13 jar on a
1.12 server resolves against the wrong signatures and fails at **login time**, not at
startup — a healthy-looking server that rejects every sign-in. Rebuild per version.

To check whether an upgrade needs a rebuild:

```sh
curl -sfL "https://raw.githubusercontent.com/open-metadata/OpenMetadata/<tag>-release/openmetadata-service/src/main/java/org/openmetadata/service/security/auth/LdapAuthenticator.java" | md5sum
```

Same hash as the version you built from means the existing jar is byte-compatible.
Different means re-run the script.

---

## Why this patch exists

Stock OpenMetadata builds its LDAP group filter with
`Filter.createEqualityFilter(groupAttributeName, groupAttributeValue)`. The UnboundID SDK
escapes the assertion value per RFC 4515, so a configured value of `LGRP-PROD-BD-*` goes on
the wire as:

```
(cn=LGRP-PROD-BD-\2a)
```

which matches only a group literally named with an asterisk. No code path accepts a raw
filter, so no configuration can produce a prefix match. Roles are separately resolved with
`roleMapping.containsKey(entry.getDN())` — an exact, case-sensitive full-DN match — so every
group must be enumerated by hand.

Upstream issue [#33785](https://github.com/open-metadata/OpenMetadata/issues/33785) requests
a configurable LDAP search filter; it is still open.

## What the patch changes

One file: `openmetadata-service/.../security/auth/LdapAuthenticator.java`.

1. **Glob in the group filter** — a `*` in **Group Attribute Value** compiles to an LDAP
   substring filter (`Filter.createSubstringFilter`); a bare `*` becomes a presence filter.
   Literal segments are still escaped by the SDK, so this adds no LDAP injection surface.
   Values without `*` keep the original equality behaviour exactly.
2. **Glob in the role mapping** — keys in **LDAP Group Mapping** may contain `*`, matched
   case-insensitively against the full DN. Keys without `*` stay exact and case-sensitive,
   so existing configs are unaffected. A group matching several keys gets the union.
3. **Optional login gate** — with `OPENMETADATA_LDAP_REQUIRE_GROUP=true`, a user who matches
   no group is refused login even though their bind succeeded. Off by default.

Nothing environment-specific is hardcoded; every value still comes from the LDAP
configuration you set in the UI.

---

## Deploy

Mount the jar and seed `CLASSPATH`:

```yaml
services:
  openmetadata-server:
    image: docker.getcollate.io/openmetadata/server:1.13.6   # stock, unmodified
    volumes:
      - ./patch:/patch:ro
    environment:
      CLASSPATH: /patch/ldap-wildcard-overlay-1.13.6.jar
      OPENMETADATA_LDAP_REQUIRE_GROUP: "true"    # optional login gate
```

`openmetadata-server-start.sh` builds its classpath with `CLASSPATH=$CLASSPATH:$file` in a
loop **without clearing `CLASSPATH` first**, so whatever you put in the environment variable
lands ahead of the ~550 shipped jars. Java is first-match-wins, so your class shadows the one
inside `openmetadata-service-<version>.jar`.

Pass only your own jar(s) — the `:$file` part belongs to the script's loop. Do **not** use
`EXT_CLASSPATH`: that one is appended at the end, too late to shadow anything.

Bare metal: `export CLASSPATH=/path/to/overlay.jar` before running the start script.

Kubernetes: mount the jar from a ConfigMap or an init-container and set the same two
environment variables on the server container.

---

## Configuration

All set in the OpenMetadata UI under the LDAP settings.

| Field | Example | Purpose |
|---|---|---|
| Group Attribute Name | `cn` | attribute to match on |
| Group Attribute Value | `LGRP-PROD-BD-*` | **the group pattern** — gates login when the env var is on |
| Group Base DN | `OU=Groups,DC=corp,DC=com` | subtree searched (`SUB` scope) |
| Group Member Attribute Name | `member` | scopes the search to the one user |
| Role Admin Name | `Admin` | a mapped role with this name grants admin instead of a role |
| LDAP Group Mapping | `CN=…,OU=…` → `DataSteward` | group DN (or glob) to role |
| Auth Reassign Roles | `[DataConsumer, DataSteward, Admin]` | roles re-evaluated each login |

The effective search is:

```
(&(<Group Attribute Name>=<Group Attribute Value>)(<Group Member Attribute Name>=<user DN>))
  under <Group Base DN>, scope SUB
```

### Gotchas worth knowing

- **The UI is authoritative, not YAML.** OpenMetadata persists auth config to the database
  (`openmetadata_settings`, row `authenticationConfiguration`). `openmetadata.yaml` and the
  `AUTHENTICATION_*` env vars only *seed* it on first boot; after that the DB wins and edits
  to YAML are silently ignored. `OPENMETADATA_LDAP_REQUIRE_GROUP` is read directly from the
  environment on purpose, so the login gate cannot be switched off from the UI.
- **Every mapped role must be listed in Auth Reassign Roles**, including `Admin`. Otherwise
  `getReassignRoles` never calls `setIsAdmin()` / strips the role, and it silently never
  applies — with nothing in the logs.
- **Roles must already exist** in OpenMetadata before first login, or you get
  `Role {} does not exist in OM Database` and the role is skipped.
- **Role changes do not persist on an ordinary re-login.** `getRoleForLdap` is called with
  `reAssign=false` on the normal login path, so it computes roles without saving them.
- **Lockout risk.** Enabling the gate with a pattern that excludes your admins locks everyone
  out, and there is no local-login fallback when the provider is LDAP. Verify every admin and
  service account matches the filter first, and keep one account in
  `AUTHORIZER_ADMIN_PRINCIPALS` as a break-glass path.
- **Nested groups are not resolved.** The filter needs `member=<userDn>` directly on the
  group; AD stores only direct members and there is no `LDAP_MATCHING_RULE_IN_CHAIN`.

### Verifying your filter before deploying

```sh
ldapsearch -x -H ldaps://<dc>:636 -D "<bind-dn>" -W \
  -b "OU=Groups,DC=corp,DC=com" \
  "(&(cn=LGRP-PROD-BD-*)(member=CN=jdoe,OU=Users,DC=corp,DC=com))" dn
```

Wildcards work fine in `ldapsearch` — the limitation is only in OpenMetadata's filter builder.
If this returns the groups you expect, the patched server will too.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `patch did not apply cleanly` | upstream changed `LdapAuthenticator.java`; the patch needs reworking for that version |
| `could not fetch ... check that tag exists` | wrong version string — use `1.13.6`, not `v1.13.6` or `1.13.6-release` |
| `cannot find symbol: variable LOG` | `lombok.config` missing from the build tree; the script fetches it, so this means that fetch failed |
| Login works but no roles | role missing from **Auth Reassign Roles**, or the role does not exist in OpenMetadata yet |
| Admin flag never applies | `Admin` not listed in **Auth Reassign Roles** |
| Everyone denied after enabling the gate | filter matches nobody — check Group Base DN and Group Member Attribute Name |
| Nothing changes after editing YAML | the DB copy wins; change it in the UI instead |

Every failure in the group lookup is swallowed into a single server-log line, so check:

```
[LDAP] Login denied for <email>: no group matches the configured group filter
Failed to get user's groups from LDAP server using the DN of the user
```

---

## Caveats

- Unsupported local patch — re-apply on upgrade and smoke-test login each time.
- Shadowing replaces the entire class, so any upstream fix to `LdapAuthenticator` in a newer
  release is lost until you rebuild.
- Change 1 drops the `objectClass=group` constraint when the value contains `*`; the member
  clause keeps results correct, but a non-group object with a `member` attribute and a
  matching `cn` would also match.
