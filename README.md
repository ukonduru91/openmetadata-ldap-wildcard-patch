# OpenMetadata LDAP wildcard group patch

Adds wildcard (glob) support to OpenMetadata's LDAP group handling, plus an optional
group-based login gate. Delivered as a small **classpath overlay jar** — the official
OpenMetadata image is never modified or rebuilt.

## Why

Stock OpenMetadata builds its LDAP group filter with
`Filter.createEqualityFilter(groupAttributeName, groupAttributeValue)`. The UnboundID SDK
escapes the assertion value per RFC 4515, so a configured value of `LGRP-PROD-BD-*` goes on
the wire as:

```
(cn=LGRP-PROD-BD-\2a)
```

which matches only a group literally named with an asterisk. There is no code path that
accepts a raw filter, so no configuration can produce a prefix match. Roles are separately
resolved with `roleMapping.containsKey(entry.getDN())` — an exact, case-sensitive full-DN
match — so every group must be enumerated by hand.

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

## Build

```sh
./rebuild-overlay.sh 1.13.6
```

Requires `docker`, `curl` and `patch`. Java and Maven are **not** needed on the host —
compilation runs in a container against the target version's own dependency jars, pulled
straight from that version's image.

Output: `dist/ldap-wildcard-overlay-<version>.jar` (~14 KB).

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

## Version compatibility

The overlay replaces the whole class, so it must be built from the matching upstream source.
`LdapAuthenticator.java` changes rarely:

| Versions | Source | Overlay |
|---|---|---|
| 1.12.5 – 1.12.14 | identical | one jar covers them |
| 1.13.1 – 1.13.6 | identical | one jar covers them |
| 2.0.x | changed per release | rebuild |

1.12.x and 1.13.x differ: five method signatures dropped `TemplateException`. A 1.13 jar on a
1.12 server resolves against the wrong signatures and fails at **login time**, not startup —
so do not mix lines.

Before upgrading, compare the file against what you built from:

```sh
curl -sfL "https://raw.githubusercontent.com/open-metadata/OpenMetadata/<tag>-release/openmetadata-service/src/main/java/org/openmetadata/service/security/auth/LdapAuthenticator.java" | md5sum
```

Same hash means reuse the jar. Different means re-run `rebuild-overlay.sh`, which refuses to
build if the patch no longer applies cleanly rather than emitting a jar that breaks at runtime.

## Caveats

- Unsupported local patch — re-apply on upgrade and smoke-test login each time.
- Shadowing replaces the entire class, so any upstream fix to `LdapAuthenticator` in a newer
  release is lost until you rebuild.
- Change 1 drops the `objectClass=group` constraint when the value contains `*`; the member
  clause keeps results correct, but a non-group object with a `member` attribute and a
  matching `cn` would also match.
