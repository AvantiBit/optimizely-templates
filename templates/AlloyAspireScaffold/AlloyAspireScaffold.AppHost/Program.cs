using Aspire.Hosting.Yarp;
using Aspire.Hosting.Yarp.Transforms;
using Yarp.ReverseProxy.Configuration;

var builder = DistributedApplication.CreateBuilder(args);

// Infrastructure resources
var sql = builder.AddSqlServer("sql")
    .AddDatabase("EPiServerDB");

var storage = builder.AddAzureStorage("storage")
    .RunAsEmulator()
    .AddBlobs("blobs");

var serviceBus = builder.AddAzureServiceBus("messaging")
    .RunAsEmulator();

// Alloy CMS web application
var alloy = builder.AddProject<Projects.AlloyAspireScaffold>("alloy")
    .WithReference(sql)
    .WaitFor(sql)
    .WithReference(storage)
    .WithReference(serviceBus)
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
