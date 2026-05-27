#nullable enable

using Azure.Messaging.ServiceBus;
using Azure.Messaging.ServiceBus.Administration;
using EPiServer.Azure.Events.Internal;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace AlloyAspireScaffold;

// Workaround for https://github.com/dotnet/aspire/issues/14041
//
// Aspire's RunAsEmulator() exposes the Service Bus emulator's management port (5300)
// as a separate endpoint ("emulatorhealth") but injects only the AMQP-port connection
// string via WithReference(). EPiServer.Azure's DefaultServiceBusSetup uses that single
// connection string for ServiceBusAdministrationClient, which then tries HTTP on the
// AMQP listener and fails with "The response ended prematurely".
//
// This replacement uses a SECOND connection string (from
// EPiServer:Cms:AzureEventProvider:AdminConnectionString, set by the AppHost) for the
// admin client only. AMQP send/receive continues to use the stock connection string
// via DefaultServiceBusEventProvider, untouched.
//
// Delete this class and the AppHost env-var block when Aspire #14041 ships.
public sealed class SplitConnectionServiceBusSetup : IServiceBusSetup
{
    private const string AdminConnectionStringKey = "EPiServer:Cms:AzureEventProvider:AdminConnectionString";
    private static readonly TimeSpan AutoDeleteOnIdle = TimeSpan.FromMinutes(30);
    private static readonly TimeSpan EntityActivationTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan EntityPollInterval = TimeSpan.FromSeconds(1);

    private readonly string _adminConnectionString;
    private readonly ILogger<SplitConnectionServiceBusSetup> _logger;

    public SplitConnectionServiceBusSetup(IConfiguration configuration, ILogger<SplitConnectionServiceBusSetup> logger)
    {
        _adminConnectionString = configuration[AdminConnectionStringKey]
            ?? throw new InvalidOperationException(
                $"Configuration value '{AdminConnectionStringKey}' is required when SplitConnectionServiceBusSetup is registered. " +
                "Have the Aspire AppHost set it to the Service Bus emulator's admin endpoint (port 5300).");
        _logger = logger;
    }

    private ServiceBusAdministrationClient Admin() => new(_adminConnectionString);

    public async Task CreateTopicAsync(string topicName, int topicSize, bool enableExpress, bool enablePartitioning, CancellationToken cancellationToken)
    {
        var admin = Admin();
        TopicProperties? existing = null;

        try
        {
            existing = (await admin.GetTopicAsync(topicName, cancellationToken)).Value;
            if (existing.Status == EntityStatus.Active)
            {
                return;
            }
        }
        catch (ServiceBusException ex) when (ex.Reason == ServiceBusFailureReason.MessagingEntityNotFound)
        {
        }

        if (existing is null)
        {
            try
            {
                await admin.CreateTopicAsync(new CreateTopicOptions(topicName)
                {
                    EnablePartitioning = enablePartitioning,
                    MaxSizeInMegabytes = topicSize
                }, cancellationToken);
                _logger.LogInformation("Created Service Bus topic '{TopicName}'", topicName);
            }
            catch (ServiceBusException ex) when (ex.Reason == ServiceBusFailureReason.MessagingEntityAlreadyExists)
            {
                _logger.LogDebug("Service Bus topic '{TopicName}' already exists", topicName);
            }
        }

        await WaitForActive(
            async () => (await admin.GetTopicAsync(topicName, CancellationToken.None)).Value.Status,
            topicName,
            cancellationToken);
    }

    public async Task CreateSubscriptionAsync(string topicName, string subscriptionName, string filterProperty, CancellationToken cancellationToken)
    {
        var admin = Admin();
        var filter = new SqlRuleFilter($"sys.label!='{subscriptionName}'");
        var subscriptionOptions = new CreateSubscriptionOptions(topicName, subscriptionName)
        {
            AutoDeleteOnIdle = AutoDeleteOnIdle
        };
        var ruleOptions = new CreateRuleOptions { Filter = filter };

        try
        {
            await admin.CreateSubscriptionAsync(subscriptionOptions, ruleOptions, cancellationToken);
            _logger.LogInformation("Created Service Bus subscription '{SubscriptionName}' on topic '{TopicName}'", subscriptionName, topicName);
        }
        catch (ServiceBusException ex) when (ex.Reason == ServiceBusFailureReason.MessagingEntityAlreadyExists)
        {
            _logger.LogDebug("Service Bus subscription '{SubscriptionName}' already exists", subscriptionName);
        }

        await WaitForActive(
            async () => (await admin.GetSubscriptionAsync(topicName, subscriptionName, CancellationToken.None)).Value.Status,
            $"{topicName}/{subscriptionName}",
            cancellationToken);
    }

    public async Task DeleteSubscriptionAsync(string topicPath, string subscriptionName)
    {
        await Admin().DeleteSubscriptionAsync(topicPath, subscriptionName);
        _logger.LogInformation("Deleted Service Bus subscription '{SubscriptionName}'", subscriptionName);
    }

    private static async Task WaitForActive(Func<Task<EntityStatus>> getStatus, string entityName, CancellationToken cancellationToken)
    {
        var deadline = DateTime.UtcNow + EntityActivationTimeout;
        EntityStatus status;

        while ((status = await getStatus()) != EntityStatus.Active)
        {
            if (DateTime.UtcNow > deadline)
            {
                throw new TimeoutException($"Failed waiting for Service Bus entity '{entityName}' to become Active; current status: {status}");
            }

            if (cancellationToken.WaitHandle.WaitOne(EntityPollInterval))
            {
                cancellationToken.ThrowIfCancellationRequested();
            }
        }
    }
}
