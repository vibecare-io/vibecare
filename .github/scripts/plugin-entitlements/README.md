# Per-plugin entitlements

One `<id>.entitlements` file per plugin that needs entitlements of its own.
`.github/actions/sign-plugins` picks them up **by filename alone** — a plugin
named `foo` gets `foo.entitlements` if it exists, and no entitlements if it
does not. Adding one for a new plugin is a file, not a code change.

## Keep these files bare

No comments. No prose. Just the dict.

Entitlements are parsed by AMFI's `AMFIUnserializeXML`, a restricted XML
parser, not by the forgiving one behind `plutil`. Anything it dislikes fails
the signing step with a bare line number and nothing else:

```
Failed to parse entitlements: AMFIUnserializeXML: syntax error near line 7
```

That is exactly how the `v0.8.16.26` release died. The file carried an
explanatory comment, and the comment contained the string `--` (it mentioned
codesign's `--options runtime` flag). XML forbids a double hyphen inside a
comment, so the file was genuinely malformed — but `plutil -lint` reported
`OK`, because CoreFoundation tolerates what AMFI rejects. Use
`xmllint --noout` if you want a parser that agrees with AMFI; `sign-plugins`
now runs it on every file here before signing, so this fails with a readable
message instead of a line number.

Rationale for a given entitlement belongs here, in Markdown, where `--` is
just a hyphen.

## Why vision needs `com.apple.security.device.camera`

`plugins/vision` is the one process that opens the camera. Release builds
sign plugins with the hardened runtime, which denies camera access to any
process that does not hold this entitlement — and denies it **silently**. The
symptom is "vision publishes no frames", which reads as a broken plugin
rather than as a signing problem, so nothing points you back here.

This is separate from the TCC grant, and does not replace it. That grant is
keyed to the *spawning* process (`vibecare-server`), not to this binary, so
nothing here re-prompts the user. The entitlement only stops the hardened
runtime from refusing the capture the grant already allows.

## Guards

`sign-plugins` fails the build if a file in this directory matches no plugin
it signed. A typo or a plugin rename would otherwise mean the entitlements
are silently skipped — vision would ship with the hardened runtime and no
camera entitlement, and the failure would surface as a dead camera on a
user's machine rather than as a red CI run. It also reads the entitlements
back off each signed binary to confirm they actually landed.
