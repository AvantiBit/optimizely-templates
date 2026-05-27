using Aspire.Hosting.Yarp;
using Aspire.Hosting.Yarp.Transforms;
using Yarp.ReverseProxy.Configuration;

var builder = DistributedApplication.CreateBuilder(args);

// Infrastructure resources
var sql = builder.AddSqlServer("sql")
    .AddDatabase("EPiServerDB");

var storageAccount = builder.AddAzureStorage("storage")
    .RunAsEmulator();
var blobs = storageAccount.AddBlobs("blobs");

var serviceBus = builder.AddAzureServiceBus("messaging")
    .RunAsEmulator();

// Alloy CMS web application.
//
// EPiServer.Azure's blob + event providers auto-bind their options from
// the EPiServer:Cms:AzureBlobProvider and EPiServer:Cms:AzureEventProvider
// configuration sections. We map the Aspire-allocated connection strings
// into those sections here so Startup.cs needs no Aspire-specific code.
var alloy = builder.AddProject<Projects.AlloyAspireScaffold>("alloy")
    .WithReference(sql)
    .WaitFor(sql)
    .WithReference(blobs)
    .WithReference(serviceBus)
    .WithEnvironment("EPiServer__Cms__AzureBlobProvider__ConnectionString", blobs)
    .WithEnvironment("EPiServer__Cms__AzureBlobProvider__ContainerName", "mediablobs")
    .WithEnvironment("EPiServer__Cms__AzureEventProvider__ConnectionString", serviceBus)
    .WithEnvironment("EPiServer__Cms__AzureEventProvider__TopicName", "cms-events")
    // Workaround for https://github.com/dotnet/aspire/issues/14041 — the connection
    // string injected via WithReference(serviceBus) uses the AMQP endpoint, which
    // ServiceBusAdministrationClient cannot use. Inject a second connection string
    // built from the emulatorhealth endpoint (the emulator's HTTP management port,
    // container 5300). SplitConnectionServiceBusSetup consumes this for admin
    // operations only; AMQP send/receive continues to use the stock connection
    // string above. Delete this block when aspire#14041 ships.
    .WithEnvironment(ctx =>
    {
        var health = serviceBus.Resource.GetEndpoint("emulatorhealth");
        ctx.EnvironmentVariables["EPiServer__Cms__AzureEventProvider__AdminConnectionString"] =
            $"Endpoint=sb://{health.Host}:{health.Port};" +
            "SharedAccessKeyName=RootManageSharedAccessKey;" +
            "SharedAccessKey=SAS_KEY_VALUE;" +
            "UseDevelopmentEmulator=true;";
    })
    .WithReplicas(INSTANCE_COUNT);

// YARP reverse proxy as the single entry point
builder.AddYarp("gateway")
    .WithConfiguration(yarp =>
    {
        var cluster = yarp.AddCluster(alloy)
            .WithLoadBalancingPolicy("LB_STRATEGY_VALUE")
            // Sticky sessions are required so SignalR (CMS edit-mode real-time
            // updates) keeps its negotiate + connect on the same replica.
            // Without this, the CMS admin UI shows "A real-time connection
            // could not be established with the server."
            .WithSessionAffinityConfig(new SessionAffinityConfig
            {
                Enabled = true,
                Policy = "Cookie",
                FailurePolicy = "Redistribute",
                AffinityKeyName = ".Yarp.Affinity"
            })
            .WithHealthCheckConfig(new HealthCheckConfig
            {
                Active = new ActiveHealthCheckConfig
                {
                    Enabled = true,
                    Interval = TimeSpan.FromSeconds(10),
                    Timeout = TimeSpan.FromSeconds(5),
                    Path = "/health"
                }
            });

        // Pass the original client Host header through to the backend so Optimizely
        // builds absolute redirect URLs (login, return URLs, etc.) using the public
        // gateway hostname instead of the internal Aspire address. Also emit standard
        // X-Forwarded-* headers for any downstream code that reads them.
        yarp.AddRoute("/{**catchall}", cluster)
            .WithTransformUseOriginalHostHeader()
            .WithTransformXForwarded();
    })
//#if (useHttps)
    .WithHostPort(5001);
//#else
    .WithHostPort(5000);
//#endif

builder.Build().Run();
