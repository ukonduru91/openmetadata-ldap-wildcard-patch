# Code changes explained

Every change is in a single file:

```
openmetadata-service/src/main/java/org/openmetadata/service/security/auth/LdapAuthenticator.java
```

Seven hunks, three features. No other file in OpenMetadata is touched, and no JSON schema,
database table or UI component changes — which is why the patch can ship as a classpath
overlay jar rather than a rebuilt image.

---

## Background: the two root causes

Both bugs live in one method, `getRoleForLdap`, which runs **after** authentication has
already succeeded and decides what roles the user gets.

```java
Filter groupFilter =
    Filter.createEqualityFilter(
        ldapConfiguration.getGroupAttributeName(),
        ldapConfiguration.getGroupAttributeValue());
Filter groupMemberAttr =
    Filter.createEqualityFilter(ldapConfiguration.getGroupMemberAttributeName(), userDn);
Filter groupAndMemberFilter = Filter.createANDFilter(groupFilter, groupMemberAttr);
SearchRequest searchRequest =
    new SearchRequest(
        ldapConfiguration.getGroupBaseDN(),
        SearchScope.SUB,
        groupAndMemberFilter,
        ldapConfiguration.getAllAttributeName());
SearchResult searchResult = ldapLookupConnectionPool.search(searchRequest);
...
for (SearchResultEntry searchResultEntry : searchResult.getSearchEntries()) {
  String groupDN = searchResultEntry.getDN();
  if (roleMapping.containsKey(groupDN) && !CollectionUtils.isEmpty(roleMapping.get(groupDN))) {
    ...
  }
}
```

**Cause 1 — the wildcard is escaped away.** `Filter.createEqualityFilter` is the UnboundID
SDK's *equality* filter builder. It escapes the assertion value per RFC 4515, so `*` becomes
`\2a`. A configured value of `LGRP-PROD-BD-*` is sent as:

```
(cn=LGRP-PROD-BD-\2a)
```

That matches only a group literally named with an asterisk. Nothing in the codebase accepts a
raw filter string, so **no configuration value can ever produce a prefix match**.

**Cause 2 — role lookup is an exact string compare.** `roleMapping.containsKey(groupDN)` is a
plain Java `HashMap` lookup against `entry.getDN()`. It is exact and case-sensitive, so every
group must be enumerated by hand, with the DN spelled exactly as the directory returns it.

There is also no group check anywhere on the login path — only a bind and a user lookup by
mail attribute — so group membership cannot restrict who may sign in.

---

## Change 1 — glob support in the group search filter

**Hunk `@@ -394,7 +443,7 @@`** — one line in `getRoleForLdap`:

```diff
       Filter groupFilter =
-          Filter.createEqualityFilter(
+          createGroupAttributeFilter(
               ldapConfiguration.getGroupAttributeName(),
               ldapConfiguration.getGroupAttributeValue());
```

**Hunk `@@ -474,6 +519,74 @@`** adds the helper:

```java
private static Filter createGroupAttributeFilter(String attributeName, String attributeValue) {
  if (attributeValue == null || attributeValue.indexOf('*') < 0) {
    return Filter.createEqualityFilter(attributeName, attributeValue);
  }
  String[] parts = attributeValue.split("\\*", -1);
  String subInitial = parts[0].isEmpty() ? null : parts[0];
  String subFinal = parts[parts.length - 1].isEmpty() ? null : parts[parts.length - 1];
  List<String> subAny = new ArrayList<>();
  for (int i = 1; i < parts.length - 1; i++) {
    if (!parts[i].isEmpty()) {
      subAny.add(parts[i]);
    }
  }
  if (subInitial == null && subFinal == null && subAny.isEmpty()) {
    return Filter.createPresenceFilter(attributeName);
  }
  return Filter.createSubstringFilter(
      attributeName, subInitial, subAny.toArray(new String[0]), subFinal);
}
```

**Why a substring filter instead of building a filter string.** The obvious fix —
`Filter.create("(" + attr + "=" + value + ")")` — would work, and would also hand anyone who
can edit the LDAP settings an injection point into the directory query.
`createSubstringFilter` takes the literal segments as *data* and still escapes each one; only
the `*` becomes structure. So `A(B)*` is sent as `(cn=A\28B\29*)` — parentheses escaped, the
asterisk honoured. **No new injection surface.**

**Why the null/no-`*` early return.** Any value without an asterisk takes the original
`createEqualityFilter` path, byte-for-byte the stock behaviour. Existing deployments see no
change until someone deliberately types a `*`.

**Why the presence-filter special case.** A bare `"*"` splits into two empty parts, which
would leave `createSubstringFilter` with nothing to match on and make it throw. `(cn=*)` —
presence — is the correct reading of "any value".

How the parsing maps to LDAP:

| Configured value | Parts | Resulting filter |
|---|---|---|
| `LGRP-PROD-BD-*` | initial only | `(cn=LGRP-PROD-BD-*)` |
| `*BD*` | one "any" | `(cn=*BD*)` |
| `a*b*c` | initial, any, final | `(cn=a*b*c)` |
| `*` | nothing | `(cn=*)` presence |
| `group` | no `*` | `(objectClass=group)` unchanged |

**Side effect to be aware of:** pointing Group Attribute Name at `cn` replaces the
`objectClass=group` constraint. The `member=<userDn>` clause still keeps results correct, but
a non-group object carrying a `member` attribute and a matching `cn` would also match.

---

## Change 2 — glob support in the role mapping keys

**Hunk `@@ -427,25 +476,21 @@`** replaces the lookup inside the result loop:

```diff
       for (SearchResultEntry searchResultEntry : searchResult.getSearchEntries()) {
         String groupDN = searchResultEntry.getDN();
-        if (roleMapping.containsKey(groupDN)
-            && !CollectionUtils.isEmpty(roleMapping.get(groupDN))) {
-          List<String> roles = roleMapping.get(groupDN);
-          for (String roleName : roles) {
-            if (ldapConfiguration.getRoleAdminName().equals(roleName)) {
+        for (String roleName : resolveMappedRoles(roleMapping, groupDN)) {
+          if (roleName.equals(ldapConfiguration.getRoleAdminName())) {
```

The body below it — the `roleRepository.getByName` lookup, the `EntityReference` build and
the `EntityNotFoundException` catch — is unchanged; it just loses one level of nesting.

**Note the flipped comparison.** `ldapConfiguration.getRoleAdminName().equals(roleName)` became
`roleName.equals(ldapConfiguration.getRoleAdminName())`. `roleName` always comes from the
mapping and is non-null, whereas **Role Admin Name** is frequently left blank — and when it
is, the original order throws a `NullPointerException` that aborts the entire mapping loop.
Since the line was being rewritten anyway, putting the non-null operand first makes it
null-safe at no cost.

**Hunk `@@ -474,6 +519,74 @@`** adds the two helpers:

```java
private static Set<String> resolveMappedRoles(
    Map<String, List<String>> roleMapping, String groupDN) {
  Set<String> roles = new LinkedHashSet<>();
  if (roleMapping == null) {
    return roles;
  }
  for (Map.Entry<String, List<String>> entry : roleMapping.entrySet()) {
    if (CollectionUtils.isEmpty(entry.getValue())) {
      continue;
    }
    String key = entry.getKey();
    boolean matched =
        key.indexOf('*') < 0
            ? key.equals(groupDN)
            : DN_PATTERN_CACHE
                .computeIfAbsent(key, LdapAuthenticator::compileDnPattern)
                .matcher(groupDN)
                .matches();
    if (matched) {
      roles.addAll(entry.getValue());
    }
  }
  return roles;
}

private static Pattern compileDnPattern(String dnGlob) {
  StringBuilder regex = new StringBuilder();
  int start = 0;
  for (int star = dnGlob.indexOf('*'); star >= 0; star = dnGlob.indexOf('*', start)) {
    if (star > start) {
      regex.append(Pattern.quote(dnGlob.substring(start, star)));
    }
    regex.append(".*");
    start = star + 1;
  }
  if (start < dnGlob.length()) {
    regex.append(Pattern.quote(dnGlob.substring(start)));
  }
  return Pattern.compile(regex.toString(), Pattern.CASE_INSENSITIVE);
}
```

**Why keys without `*` keep the exact path.** `key.equals(groupDN)` is identical to the old
`containsKey`, so every existing mapping behaves exactly as before. The glob support is purely
additive — this is what makes the patch safe to drop onto a running deployment.

**Why `Pattern.quote` on each literal segment.** DNs are full of regex metacharacters: the
dots in `DC=corp,DC=com`, plus `+`, `(`, `)`, `\` in escaped RDNs. Translating the glob by
hand would make `CN=a.b+c` match `CN=aXbPc`. Quoting every literal segment and joining with
`.*` means only the asterisk is ever treated as a metacharacter.

**Why case-insensitive for globs but not exact keys.** DN comparison is case-insensitive in
LDAP semantics, and being strict here is a common footgun — a lowercase `cn=` key silently
matching nothing. New glob keys get the forgiving behaviour; exact keys keep the old strict
behaviour so nothing changes under existing configs.

**Why a `Set` and union instead of first-match.** A group can now match several keys (say a
broad `*` plus a specific DN). Returning the union is the natural generalisation, and
`LinkedHashSet` keeps the order stable and collapses duplicates. The existing dedupe-by-name
downstream still runs.

**Why the pattern cache.** `compileDnPattern` runs per group per login. A
`ConcurrentHashMap` keyed on the glob string means each pattern is compiled once for the life
of the process. `computeIfAbsent` keeps it a single lookup and is safe under concurrent logins.

---

## Change 3 — optional group-based login gate

**Hunk `@@ -279,6 +288,7 @@`** — one line in `lookUserInProvider`:

```diff
     if (!nullOrEmpty(userDN)) {
       User dummy = getUserForLdap(email);
       validatePassword(userDN, pwd, dummy);
+      enforceGroupMembership(userDN, email);
       return checkAndCreateUser(userDN, email, dummy.getName());
     }
```

**Why here specifically.** It sits *after* `validatePassword`, so an unauthenticated caller
can never probe group membership, and *before* `checkAndCreateUser`, so a rejected user is
never provisioned an OpenMetadata account. Blocked login attempts leave no orphan records.

**Hunk `@@ -286,6 +296,45 @@`** adds the method:

```java
private void enforceGroupMembership(String userDn, String email) {
  if (!Boolean.parseBoolean(System.getenv(REQUIRE_GROUP_ENV))) {
    return;
  }
  int groupCount;
  try {
    Filter groupFilter =
        createGroupAttributeFilter(
            ldapConfiguration.getGroupAttributeName(),
            ldapConfiguration.getGroupAttributeValue());
    Filter groupMemberAttr =
        Filter.createEqualityFilter(ldapConfiguration.getGroupMemberAttributeName(), userDn);
    SearchRequest searchRequest =
        new SearchRequest(
            ldapConfiguration.getGroupBaseDN(),
            SearchScope.SUB,
            Filter.createANDFilter(groupFilter, groupMemberAttr),
            ldapConfiguration.getAllAttributeName());
    groupCount = ldapLookupConnectionPool.search(searchRequest).getSearchEntries().size();
  } catch (Exception ex) {
    LOG.error("[LDAP] Group membership check errored for {}; denying login", email, ex);
    throw new CustomExceptionMessage(FORBIDDEN, INVALID_USER_OR_PASSWORD, INVALID_EMAIL_PASSWORD);
  }
  if (groupCount == 0) {
    LOG.info("[LDAP] Login denied for {}: no group matches the configured group filter", email);
    throw new CustomExceptionMessage(FORBIDDEN, INVALID_USER_OR_PASSWORD, INVALID_EMAIL_PASSWORD);
  }
}
```

**Why an environment variable rather than a config field.** OpenMetadata persists auth config
to the database, and the UI edits that copy. A security gate stored there could be switched
off from the UI by anyone with settings access. Reading it from the process environment means
it can only be changed by someone who can redeploy. It also avoids touching
`ldapConfiguration.json`, which would mean regenerating the schema POJO and turn a one-file
patch into a multi-module build.

**Why it defaults to off.** `Boolean.parseBoolean(null)` is `false`, so an unset variable
means the method returns immediately and behaviour is exactly stock. The jar alone changes
nothing about who can log in.

**Why it fails closed on exception.** The bind has already succeeded at this point, so the
directory is demonstrably reachable; an error in the group search is not evidence that the
user should be let in. Logged at ERROR so the cause is visible.

**Why the error message is deliberately vague.** Both paths return the generic
`INVALID_EMAIL_PASSWORD`, so an unauthenticated caller cannot tell "wrong password" from "not
in the group" and use the login form to enumerate group membership. The real reason is written
to the server log — which is where support needs to look when a user reports being locked out.

**It reuses `createGroupAttributeFilter`**, so one setting — Group Attribute Value — governs
both who may log in and which roles they receive. One place to change, no second filter to
keep in sync.

---

## Supporting changes

**Hunk `@@ -39,12 +39,16 @@`** — four imports, all JDK:

```diff
 import java.util.LinkedHashMap;
+import java.util.LinkedHashSet;
 import java.util.List;
 ...
 import java.util.UUID;
+import java.util.concurrent.ConcurrentHashMap;
+import java.util.concurrent.ConcurrentMap;
 import java.util.function.Function;
+import java.util.regex.Pattern;
```

Kept in the file's existing alphabetical order so `mvn spotless:apply` is a no-op. No new
third-party dependency is introduced — which matters, because the overlay jar carries only
these classes and must resolve everything else from the shipped libs.

**Hunk `@@ -91,6 +95,11 @@`** — two fields:

```java
private static final ConcurrentMap<String, Pattern> DN_PATTERN_CACHE = new ConcurrentHashMap<>();
private static final String REQUIRE_GROUP_ENV = "OPENMETADATA_LDAP_REQUIRE_GROUP";
```

---

## What was deliberately not changed

- **No paged search.** The group query is already AND-ed with `member=<userDn>`, so it returns
  only one user's groups — a handful, never near Active Directory's 1000-entry `MaxPageSize`.
  Adding `SimplePagedResultsControl` would be dead code. If you hit a size-limit error, the
  cause is an unset **Group Member Attribute Name** leaving the search unscoped, not a missing
  paging control.
- **No nested-group resolution.** Supporting it would mean AD's
  `LDAP_MATCHING_RULE_IN_CHAIN` (`1.2.840.113556.1.4.1941`), which is AD-specific and would
  break other directories. Nested membership therefore still does not work: a user must be a
  direct `member` of a matching group.
- **No new schema fields.** Everything reuses the existing `ldapConfiguration` getters, so the
  UI needs no modification and the patch stays a single file.
- **The surrounding exception handling.** `getRoleForLdap` still wraps everything in one
  `catch (Exception)` that logs a warning and continues. That is upstream's design; widening
  the patch to fix it would make the diff harder to re-apply on each upgrade.

## Style note

The added code uses early returns and a broad `catch (Exception)`, matching the conventions of
the surrounding file. OpenMetadata's own `CLAUDE.md` asks for a single trailing return and
specific exception types, so this would need reshaping before being proposed upstream against
issue [#33785](https://github.com/open-metadata/OpenMetadata/issues/33785).
