# Optimizely Alloy Aspire Scaffold

A .NET template that adds [.NET Aspire 13](https://learn.microsoft.com/dotnet/aspire/) orchestration to an existing [Optimizely CMS 13](https://www.optimizely.com/) Alloy project. Run a production-like distributed CMS environment on your local machine with a single command.

## What You Get

```
Developer Browser
       |
       v
  YARP (container)        <-- single entry point, load balanced
    +--+--+
    v  v  v
  Alloy Alloy Alloy       <-- N CMS instances (configurable)
    |   |   |
    +---+---+
    v   v   v
  Azurite  Service Bus  SQL Server
  (shared)  (shared)    (shared)
```

- **Multiple Alloy CMS 13 instances** behind a YARP reverse proxy
- **Shared Azurite** blob storage with distributed media via `EPiServer.Azure`
- **Azure Service Bus emulator** for cross-instance event/cache invalidation
- **SQL Server container** replacing LocalDB for multi-instance compatibility
- **.NET Aspire 13.3 dashboard** showing health and status of all resources
- **Pure overlay** — the scaffold adds Aspire on top of upstream Alloy; it does not rewrite Alloy source

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) or later
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (or Podman) for container resources
- [Optimizely CMS templates](https://nuget.optimizely.com/) (`>= 2.0.1`, CMS 13 GA):
  ```
  dotnet new install EPiServer.Templates
  ```

## Quick Start

### 1. Install the template

```bash
dotnet new install AvantiBit.Optimizely.Templates
```

### 2. Scaffold an Alloy project (CMS 13 GA)

```bash
mkdir MyProject && cd MyProject
dotnet new epi-alloy-mvc -n MyProject
```

This produces a CMS 13 Alloy project targeting `net10.0`.

### 3. Add Aspire orchestration

```bash
dotnet new alloy-aspire-scaffold -n MyProject
```

This generates AppHost, ServiceDefaults, and a solution file, then runs a post-action script that:
- Validates the project is CMS 13 (fails fast if a CMS 12 project is detected)
- Moves the Alloy project files into a `MyProject/` subdirectory for a clean solution layout
- Adds the `ServiceDefaults` project reference and `.AddServiceDefaults()` call
- Maps `/health` and `/alive` health check endpoints
- Removes the LocalDB connection string (replaced by Aspire SQL Server container)
- Adds `EPiServer.Azure` for distributed blob storage and event propagation
- Moves `nuget.config` to the solution root
- Adds the Alloy project to the solution

Every step is idempotent — re-running the script is safe.

### 4. Run

```bash
cd MyProject.AppHost
dotnet run
```

Or using the [Aspire CLI](https://learn.microsoft.com/dotnet/aspire/aspire-cli) (if installed):

```bash
aspire run
```

Open the Aspire dashboard URL shown in the console output to see all resources and their health.

### 5. First-time CMS setup

1. Navigate to the YARP gateway URL (default: `https://localhost:5001` or `http://localhost:5000`)
2. Register an admin user on first access

The CMS 13 Application Model is set up automatically by upstream Alloy — no manual admin steps are required.

## Template Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `--name` / `-n` | string | AlloyAspireScaffold | Solution and project name prefix |
| `--instances` | int | 2 | Number of Alloy CMS replica instances |
| `--useHttps` | bool | true | Use HTTPS for the YARP gateway (port 5001 vs 5000) |
| `--lbStrategy` | choice | RoundRobin | YARP load balancing policy |
| `--skipPostAction` | bool | false | Skip the post-setup overlay script |

### Load Balancing Strategies

- `RoundRobin` - Distribute requests evenly across instances
- `Random` - Randomly select an instance
- `PowerOfTwoChoices` - Pick the least-loaded of two random instances
- `LeastRequests` - Route to the instance with fewest active requests
- `FirstAlphabetical` - Route to first alphabetically ordered instance

### Examples

```bash
# 3 instances with random load balancing
dotnet new alloy-aspire-scaffold -n MyProject --instances 3 --lbStrategy Random

# HTTP-only gateway
dotnet new alloy-aspire-scaffold -n MyProject --useHttps false

# Skip the overlay script (infrastructure projects only)
dotnet new alloy-aspire-scaffold -n MyProject --skipPostAction
```

## Generated Solution Structure

```
MyProject/                              # Solution root (working directory)
  nuget.config                          # NuGet feed configuration
  MyProject.slnx                        # Solution file
  MyProject/                            # Alloy CMS project (moved into subdirectory)
    MyProject.csproj                    # Patched with ServiceDefaults reference + EPiServer.Azure
    Program.cs, Startup.cs, ...         # Upstream Alloy source (not rewritten)
  MyProject.AppHost/                    # Aspire orchestration
    MyProject.AppHost.csproj
    Program.cs                          # Central resource wiring
    Properties/launchSettings.json      # Aspire dashboard configuration
  MyProject.ServiceDefaults/            # Shared Aspire service defaults
    MyProject.ServiceDefaults.csproj
    Extensions.cs                       # OpenTelemetry, health checks, resilience
```

## Architecture

### AppHost Resource Wiring

The AppHost `Program.cs` orchestrates all resources:

1. **SQL Server** - Container database replacing LocalDB; schema auto-created on first startup
2. **Azurite** - Blob storage emulator for shared media across instances
3. **Azure Service Bus** - Emulator for cache invalidation events between instances
4. **Alloy CMS** - Registered as N replicas with references to all shared resources
5. **YARP** - Reverse proxy container as the single entry point with health-check-aware routing

All connection strings are injected via Aspire's `WithReference()` — no hardcoded values.

### Distributed Providers

`EPiServer.Azure 13.0.2` is added to the Alloy project to make multi-replica behavior correct:

- **Blob storage** — media uploaded via any replica is stored in shared Azurite and visible from every other replica.
- **Event propagation** — content edits on any replica broadcast cache invalidation events through Service Bus, so all replicas see the change without a restart.

Without these providers, replicas behave as independent sites; with them, they behave as one logical CMS.

## Testing Distributed Behavior

The whole point of this scaffold is to exercise multi-replica behavior — blob sharing, event/cache propagation across replicas, etc. But YARP is configured with cookie-based session affinity (required so SignalR-driven editor features work; see Troubleshooting). That means **a single browser session always lands on the same replica**, which hides the distributed nature from your day-to-day clicking.

To deliberately exercise cross-replica behavior, use one of:

### 1. Multiple browser sessions

Open a regular browser window AND an incognito/private window. Each gets its own cookie jar and therefore its own `.Yarp.Affinity` cookie, and YARP's load-balancing policy will likely route them to different replicas (with default `RoundRobin`, they will).

- **Blob sharing test:** upload a media asset in window A, view it in window B. If the asset renders in B, blob storage is genuinely shared.
- **Event propagation test:** edit a page in window A, navigate to that page in window B (clear-cache or use the public path that won't be served from B's render cache). If B shows the updated content within a few seconds, the Service Bus event channel is wired and `EPiServer.Azure` is doing its job.

### 2. Direct-to-replica URLs (bypass YARP entirely)

The Aspire dashboard lists every replica with its own URL. Click on `alloy-<id>` in the dashboard and you'll see a `https://localhost:<port>` link that goes **directly** to that specific replica, no YARP, no affinity. This is the cleanest way to verify that, e.g., replica B can read a blob that replica A wrote.

### 3. `curl` without cookies

```bash
# Each request is fresh, so YARP routes by load-balancing policy.
for i in 1 2 3 4 5 6; do
  curl -ks https://localhost:5001/api/episerver/v3.0/site -o /dev/null -w "%{http_code} %{remote_ip}:%{remote_port}\n"
done
```

If you watch the Aspire dashboard's per-replica request counters while running this, you'll see traffic distributed across both replicas. (Replace the URL with whatever endpoint you want to probe.)

### 4. Stop a replica to verify failover

In the dashboard, hit the stop (■) button next to one replica. YARP's active health check will mark it unhealthy within ~10 seconds and stop routing to it. Traffic should keep working through the surviving replicas — that's your high-availability story.

---

## Troubleshooting

### Docker not running
All container resources (SQL Server, Azurite, Service Bus emulator, YARP) require Docker. Ensure Docker Desktop is running before `dotnet run`.

### Port conflicts
The YARP gateway binds to port 5001 (HTTPS) or 5000 (HTTP) by default. If these ports are in use, the Aspire dashboard will show the gateway as unhealthy. Stop conflicting services or modify the port in the AppHost `Program.cs`.

### SQL Server container startup
The AppHost uses `WaitFor(sql)` to ensure SQL Server is healthy before starting Alloy instances. If you see database connection errors, check the Aspire dashboard for SQL Server resource health.

### Service Bus emulator
The Azure Service Bus emulator runs locally via Docker. No Azure subscription is needed. If Optimizely event propagation isn't working, verify the Service Bus resource is healthy in the Aspire dashboard.

### Post-action script didn't run
If `pwsh` (PowerShell Core) is not installed, the post-action script will be skipped. You'll see manual instructions in the console output. Install [PowerShell Core](https://github.com/PowerShell/PowerShell) and re-run:
```bash
pwsh -File post-setup.ps1
```

### "Not a CMS 13 project" validation failure
The overlay script fails fast if it detects CMS 12 packages or an `EPiServer.Templates` output older than `2.0.1`. Upgrade your input project to CMS 13 GA before applying the overlay. The scaffold does not migrate CMS 12 code — that responsibility belongs to upstream Optimizely tooling.

### Login redirect goes to `https://aspire.dev.internal:...` instead of the gateway URL
ASP.NET Core builds absolute redirect URLs (login, return URLs, OAuth callbacks, etc.) from `Request.Host` and `Request.Scheme`. Behind YARP, the `Host` header on the proxied request defaults to the internal Aspire-allocated address (`aspire.dev.internal:<port>`), which leaks into those redirects. The AppHost configures the route with `.WithTransformUseOriginalHostHeader()` so YARP forwards the original client `Host` header (e.g. `localhost:5001`) to the backend instead. `.WithTransformXForwarded()` is also applied so standard `X-Forwarded-*` headers are populated for any other consumer.

### CMS edit mode shows "A real-time connection could not be established"
The CMS UI uses SignalR over WebSockets for real-time updates in edit mode. Behind YARP, SignalR's two-step handshake (negotiate → connect) must land on the same replica — otherwise the connect step finds no session and the dialog appears. The AppHost configures the YARP cluster with cookie-based session affinity (`.WithSessionAffinityConfig(... Policy = "Cookie" ...)`) to pin each browser session to one replica. If you're seeing the dialog anyway, check that your browser is accepting the `.Yarp.Affinity` cookie and that you aren't bouncing between gateway URLs (e.g. `localhost:5000` vs `127.0.0.1:5000` produce separate cookie jars).

### One replica crashes on first startup ("AspNetRoles already exists")
On the very first boot, all Alloy replicas start in parallel against a fresh SQL Server database. The first replica creates the ASP.NET Identity schema (`AspNetRoles`, `AspNetUsers`, etc.); any other replica that hits `CREATE TABLE [AspNetRoles]` simultaneously crashes with `There is already an object named 'AspNetRoles' in the database.` and lands in the `Finished` state.

**This is a one-time, first-run race condition.** Recover by clicking the play (▶) button next to the failed replica in the Aspire dashboard — it will succeed on retry now that the schema exists. Subsequent boots have no race because the schema is already in place.

A clean fix that serializes first-run schema creation is on the v1.1 roadmap; for v1.0 the manual restart is the documented workaround.

### Already-overlaid project
The post-action script is idempotent. Each step checks whether it has already been applied before making changes. It's safe to run multiple times and reports `[skip]` or `[apply]` for each step.

## Compatibility

| Component | Version |
|-----------|---------|
| .NET SDK | 10.0+ |
| .NET Aspire | 13.3.5 |
| Optimizely CMS | 13.0.0+ (GA) |
| `EPiServer.Templates` (input) | `>= 2.0.1` |
| `EPiServer.Azure` | 13.0.2 |
| Docker | Latest |

See [docs/version-matrix.md](docs/version-matrix.md) for the full pinned dependency matrix.

## License

Apache 2.0 - see [LICENSE](LICENSE) for details.

This template is designed to work with Optimizely CMS and the `epi-alloy-mvc` template, which are licensed under Apache 2.0 by Optimizely. This project is not affiliated with or endorsed by Optimizely. "Optimizely" and "Episerver" are trademarks of Optimizely, Inc.
