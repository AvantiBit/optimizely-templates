# Optimizely Alloy Aspire Scaffold

A .NET template that adds [.NET Aspire 13](https://learn.microsoft.com/dotnet/aspire/) orchestration to an existing [Optimizely CMS](https://www.optimizely.com/) Alloy project. Run a production-like distributed CMS environment on your local machine with a single command.

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
- **Shared Azurite** blob storage (no Azure subscription required)
- **Azure Service Bus emulator** for cross-instance event/cache invalidation
- **SQL Server container** replacing LocalDB for multi-instance compatibility
- **.NET Aspire dashboard** showing health and status of all resources
- **Automatic CMS 12 to CMS 13 migration** of the Alloy project

## Prerequisites

- [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0) or later
- [Docker Desktop](https://www.docker.com/products/docker-desktop/) (or Podman) for container resources
- [Optimizely CMS templates](https://nuget.optimizely.com/): `dotnet new install EPiServer.Templates`

## Quick Start

### 1. Install the template

```bash
dotnet new install AvantiBit.Optimizely.Templates
```

### 2. Scaffold an Alloy project

```bash
mkdir MyProject && cd MyProject
dotnet new epi-alloy-mvc -n MyProject
```

### 3. Add Aspire orchestration

```bash
dotnet new alloy-aspire-scaffold -n MyProject
```

This generates AppHost, ServiceDefaults, and a solution file, then runs a post-action script that:
- Moves the Alloy project files into a `MyProject/` subdirectory for a clean solution layout
- Upgrades the Alloy project to CMS 13 (TFM, packages, API migrations)
- Adds Aspire service defaults integration
- Configures health check endpoints
- Removes the LocalDB connection string (replaced by Aspire SQL Server container)
- Moves `nuget.config` to the solution root
- Adds the Alloy project to the solution

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
3. **Configure the Application Model** (required for CMS 13):
   - Go to CMS Admin > Applications
   - Delete the default "Headless" application
   - Create a new **In Process** application
   - Set the start page to the Alloy start page
   - Set the hostname to the YARP gateway hostname (e.g., `localhost:5001`)

## Template Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `--name` / `-n` | string | AlloyAspireScaffold | Solution and project name prefix |
| `--instances` | int | 2 | Number of Alloy CMS replica instances |
| `--useHttps` | bool | true | Use HTTPS for the YARP gateway (port 5001 vs 5000) |
| `--lbStrategy` | choice | RoundRobin | YARP load balancing policy |
| `--skipPostAction` | bool | false | Skip the CMS 12-to-13 migration script |

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

# Skip auto-migration (infrastructure only)
dotnet new alloy-aspire-scaffold -n MyProject --skipPostAction
```

## Generated Solution Structure

```
MyProject/                              # Solution root (working directory)
  nuget.config                          # NuGet feed configuration
  MyProject.slnx                        # Solution file
  MyProject/                            # Alloy CMS project (moved into subdirectory)
    MyProject.csproj                    # Patched for CMS 13 + Aspire
    Program.cs, Startup.cs, ...         # Existing Alloy source
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

All connection strings are injected via Aspire's `WithReference()` - no hardcoded values.

### CMS 12 to CMS 13 Migration

The post-action script automatically applies these changes to the Alloy project:

- **TFM**: `net8.0` -> `net10.0`
- **Packages**: EPiServer.CMS `12.x` -> `13.0.0-preview3`, adds `EPiServer.CMS.UI.AspNetIdentity`
- **APIs**: `PageReference` -> `ContentReference`, `IContentTypeRepository<PageType>` -> `IContentTypeRepository`, `InitializationEngine.Locate` -> `context.Services`, `PageContext.Page` -> `PageContext.Content`
- **Configuration**: Adds `AddVisitorGroups()`, `DataAccessOptions.UpdateDatabaseCompatibilityLevel`, health check endpoints

See the `post-setup.ps1` script (generated alongside the template output) for the full list of automated changes.

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

### One replica crashes on first startup ("AspNetRoles already exists")
When running multiple Alloy replicas, all instances start simultaneously against a fresh SQL Server database. The first instance creates the ASP.NET Identity schema (`AspNetRoles`, `AspNetUsers`, etc.), but the second instance attempts the same `CREATE TABLE` and fails with:
```
There is already an object named 'AspNetRoles' in the database.
```
This is a one-time startup race condition. The Aspire orchestrator will automatically restart the failed replica, and it will succeed on retry since the tables already exist. No action is needed.

### Already-migrated project
The post-action script is idempotent. Each patch checks whether it has already been applied before making changes. It's safe to run multiple times.

## Compatibility

| Component | Version |
|-----------|---------|
| .NET SDK | 10.0+ |
| .NET Aspire | 13.1.0 |
| Optimizely CMS | 13.0.0-preview3 |
| EPiServer.Templates (input) | Latest (CMS 12) |
| Docker | Latest |

## License

Apache 2.0 - see [LICENSE](LICENSE) for details.

This template is designed to work with Optimizely CMS and the `epi-alloy-mvc` template, which are licensed under Apache 2.0 by Optimizely. This project is not affiliated with or endorsed by Optimizely. "Optimizely" and "Episerver" are trademarks of Optimizely, Inc.
