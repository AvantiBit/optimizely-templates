# Changelog

All notable changes to `AvantiBit.Optimizely.Templates` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] — 2026-05-25

**CMS 13 GA baseline release.** First stable release; supersedes preview-era prototypes.

### Added
- Aspire overlay scaffold (`alloy-aspire-scaffold`) producing AppHost + ServiceDefaults + `.slnx` around an existing CMS 13 Alloy project.
- `EPiServer.Azure 13.0.2` wiring for distributed blob storage and event propagation across replicas. The overlay script registers `AddAzureBlobProvider` and `AddAzureEventProvider` in `Startup.cs`, with connection strings read from Aspire's injected `ConnectionStrings:blobs` and `ConnectionStrings:messaging`.
- Fast-fail validation gate: the post-action script refuses to overlay a CMS 12 project and prints upgrade guidance.
- `eng/smoke-test.ps1` for end-to-end boot + gateway probe validation.
- CI matrix coverage for default + custom parameter scenarios across ubuntu/windows/macos, plus dedicated jobs for CMS 12 rejection and `--skipPostAction`.
- Robust Alloy csproj discovery in `post-setup.ps1`. The script now locates the project regardless of layout (flat, in canonical subdir, or nested) and recovers gracefully from partial state left by an interrupted prior run.
- Cookie-based session affinity on the YARP cluster. SignalR (used by CMS edit-mode real-time updates) requires the negotiate + connect handshake to land on the same backend; without sticky sessions, the admin UI shows "A real-time connection could not be established with the server." Affinity cookie is `.Yarp.Affinity`.
- YARP route transforms `WithTransformUseOriginalHostHeader()` + `WithTransformXForwarded()`. The first stops absolute redirect URLs (login, return URLs) from leaking the internal `aspire.dev.internal:<port>` hostname; the second emits standard `X-Forwarded-*` headers for any downstream consumer.

### Known issue
- On the very first boot, one Alloy replica may crash with `There is already an object named 'AspNetRoles' in the database.` because replicas race to create the ASP.NET Identity schema. Workaround: click the play (▶) button on the failed replica in the Aspire dashboard. Subsequent boots are unaffected. A serialized-startup fix is tracked for v1.1.

### Changed
- **Input contract:** the template now requires `EPiServer.Templates >= 2.0.1` (CMS 13 GA). The two-step flow is `dotnet new epi-alloy-mvc -n MyProject` then `dotnet new alloy-aspire-scaffold -n MyProject`. The `--prerelease` flag is no longer needed.
- **Aspire packages** pinned uniformly at `13.3.5` across the whole suite.
- **EPiServer patch policy:** the scaffold no longer rewrites any `EPiServer.*` package versions. Whatever `epi-alloy-mvc` emits is what ships.
- `post-setup.ps1` rewritten as a pure overlay: every step is idempotent and reports `[apply]` or `[skip]` with a final applied/skipped tally.

### Removed
- All CMS 12 → CMS 13 source-code migrations (PageReference, IContentTypeRepository, InitializationEngine.Locate, PageContext.Page, etc.) — upstream Optimizely tooling now owns this responsibility.
- TFM bump (`net8.0 → net10.0`) — `epi-alloy-mvc 2.0.1+` already targets `net10.0`.
- Forced `Wangkanai.Detection` version bump — upstream's choice is preserved.
- Manual Application Model setup instructions from the README — `epi-alloy-mvc 2.0.1+` configures this automatically.
- `docs/cms12-to-cms13-migration-delta.md` and the preview-era implementation plan moved to `docs/history/` with archived banners.

### Documentation
- New plan of record: `IMPLEMENTATION_PLAN_CMS13_GA.md` (gitignored; tracked locally as working doc).
- `docs/version-matrix.md` rewritten around CMS 13 GA + Aspire 13.3.5 with explicit policy notes for Aspire pinning, EPiServer "preserve upstream" patches, and `EPiServer.Azure` pinning.
- `PRD.md` updated: FR-27 now requires validation (not migration); FR-28 removed; risks refreshed.
- `README.md` rewritten: preview language gone, two-step quickstart, distributed-providers architecture section added.
