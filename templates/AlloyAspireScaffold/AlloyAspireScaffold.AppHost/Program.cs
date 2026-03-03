using Aspire.Hosting.Yarp;
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

        yarp.AddRoute("/{**catchall}", cluster);
    })
//#if (useHttps)
    .WithHostPort(5001);
//#else
    .WithHostPort(5000);
//#endif

builder.Build().Run();
