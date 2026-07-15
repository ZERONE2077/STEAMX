# STEAMX

STEAMX is licensed under the MIT License. See [LICENSE](LICENSE).

This repository does not package third-party binaries by default. It may
reference, download, or interoperate with upstream projects such as
OpenSteamTool and CloudRedirect. Those projects keep their own license terms;
see [NOTICE](NOTICE) for details.

When downloading the latest OpenSteamTool GitHub release, STEAMX tries the
configured download URL templates in order. The default uses `ghfast.top` first.
If the mirror is unavailable or does not contain the release asset, the
official GitHub release URL is used as the final fallback.

The downloaded ZIP is verified against the SHA-256 digest in GitHub release
metadata when one is available. If the upstream release does not provide a
digest, a mirror download is compared with the official asset by SHA-256 before
it is extracted.

All download settings are embedded in `main.ps1`; no extra configuration file
is required. Add or reorder the `downloadUrlTemplates` array in
`New-DefaultConfig`:

```json
{
  "ost": {
    "downloadUrlTemplates": [
      "https://ghfast.top/{official}",
      "https://mirror.example/{repo}/releases/download/{tag}/{asset}",
      "https://mirror-b.example/{repo}/releases/download/{tag}/{asset}",
      "{official}"
    ]
  }
}
```

Supported placeholders are `{repo}`, `{tag}`, `{asset}`, and `{official}`.
