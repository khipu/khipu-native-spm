# KhipuNative (SPM distribution mirror)

Read-only mirror assembled from [khipu/khipu-native](https://github.com/khipu/khipu-native) by
`scripts/spm-mirror-assemble.sh` (Story 7.3 D2). Do not push or send PRs here — the monorepo is the
source of truth; `release.yml` stage 2b overwrites this repo's content on every release.

**No versions are published yet** (GA pending — see `docs/RELEASE-RUNBOOK.md` in the monorepo).
Once GA ships:

```swift
.package(url: "https://github.com/khipu/khipu-native-spm", from: "x.y.z")
```
