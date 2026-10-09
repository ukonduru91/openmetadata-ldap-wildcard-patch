# Prebuilt overlay jars

Each jar contains only the patched `LdapAuthenticator` classes and must match the
OpenMetadata version it was built against.

| Jar | For OpenMetadata | Also covers |
|---|---|---|
| `ldap-wildcard-overlay-1.12.5.jar` | 1.12.5 | 1.12.x (source identical across that line) |
| `ldap-wildcard-overlay-1.13.3.jar` | 1.13.3 | 1.13.1 - 1.13.6 (source identical) |
| `ldap-wildcard-overlay-1.13.6.jar` | 1.13.6 | same bytes as the 1.13.3 jar |
| `ldap-wildcard-overlay-2.0.3.jar` | 2.0.3 | 2.0.3 only - rebuild for other 2.0.x |

**Never mix minor lines.** A 1.13 jar on a 1.12 server resolves against the wrong
method signatures and fails at login time, not at startup. See the version table in
the top-level README.

Only the 1.13.3 jar has been verified end-to-end against a running server. The others
compile and package correctly but were not run — smoke-test login after deploying.

Rebuild any of these with `./rebuild-overlay.sh <version>` from the repository root.
