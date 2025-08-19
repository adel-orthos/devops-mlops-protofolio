const core = require("@actions/core");

/**
 * Inject Datadog Agent as a sidecar container into ECS task definition
 * @param {string} serviceName - Name of the service
 * @param {object} taskDefContents - Task definition object to modify
 * @param {object} datadogConfig - Datadog configuration object
 * @param {string} ssmRegion - AWS region for SSM parameters
 */
async function injectDDConfig(serviceName, taskDefContents, datadogConfig, ssmRegion = 'us-east-1') {
  if (!datadogConfig) {
    core.warning("Datadog configuration not provided, skipping Datadog agent injection");
    return;
  }

  const ddAgentName = `${serviceName}-dd-agent`;
  
  // Default Datadog configuration
  const defaultConfig = {
    image: "public.ecr.aws/datadog/agent:latest",
    logLevel: "info",
    site: "datadoghq.com",
    apmEnabled: true,
    logCollection: true,
    processCollection: false,
    networkMonitoring: false,
    tags: []
  };

  // Merge with provided configuration
  const config = { ...defaultConfig, ...datadogConfig };

  // Build environment variables for Datadog agent
  const environment = [
    { name: "DD_SITE", value: config.site },
    { name: "DD_LOG_LEVEL", value: config.logLevel },
    { name: "DD_APM_ENABLED", value: String(config.apmEnabled) },
    { name: "DD_LOGS_ENABLED", value: String(config.logCollection) },
    { name: "DD_PROCESS_AGENT_ENABLED", value: String(config.processCollection) },
    { name: "DD_SYSTEM_PROBE_ENABLED", value: String(config.networkMonitoring) },
    { name: "DD_APM_NON_LOCAL_TRAFFIC", value: "true" },
    { name: "DD_DOGSTATSD_NON_LOCAL_TRAFFIC", value: "true" },
    { name: "ECS_FARGATE", value: "true" }
  ];

  // Add tags if provided
  if (config.tags && config.tags.length > 0) {
    environment.push({
      name: "DD_TAGS",
      value: config.tags.join(",")
    });
  }

  // Build secrets array for API key
  const secrets = [];
  if (config.apiKey) {
    if (config.apiKey.startsWith('arn:aws:ssm:')) {
      // Direct ARN provided
      secrets.push({
        name: "DD_API_KEY",
        valueFrom: config.apiKey
      });
    } else {
      // SSM parameter path provided
      secrets.push({
        name: "DD_API_KEY",
        valueFrom: `arn:aws:ssm:${ssmRegion}:*:parameter${config.apiKey}`
      });
    }
  }

  // Create Datadog agent container definition
  const ddAgentContainer = {
    name: ddAgentName,
    image: config.image,
    cpu: 128,
    memoryReservation: 128,
    essential: false,
    environment: environment,
    secrets: secrets,
    logConfiguration: {
      logDriver: "awslogs",
      options: {
        "awslogs-group": `/ecs/${serviceName}-datadog`,
        "awslogs-region": ssmRegion,
        "awslogs-stream-prefix": "datadog-agent",
        "awslogs-create-group": "true"
      }
    },
    healthCheck: {
      command: ["CMD-SHELL", "agent health"],
      interval: 30,
      timeout: 5,
      retries: 3,
      startPeriod: 60
    }
  };

  // Add port mappings for APM and DogStatsD if enabled
  if (config.apmEnabled) {
    ddAgentContainer.portMappings = ddAgentContainer.portMappings || [];
    ddAgentContainer.portMappings.push({
      containerPort: 8126,
      protocol: "tcp",
      name: "dd-apm"
    });
  }

  // Add DogStatsD port
  ddAgentContainer.portMappings = ddAgentContainer.portMappings || [];
  ddAgentContainer.portMappings.push({
    containerPort: 8125,
    protocol: "udp",
    name: "dd-dogstatsd"
  });

  // Add the Datadog agent container to task definition
  taskDefContents.containerDefinitions.push(ddAgentContainer);

  // Update existing containers to send metrics to Datadog agent
  taskDefContents.containerDefinitions.forEach((container) => {
    if (container.name !== ddAgentName) {
      // Add Datadog environment variables to application containers
      container.environment = container.environment || [];
      
      // Add DD_AGENT_HOST pointing to localhost (same task network)
      const ddAgentHostExists = container.environment.find(env => env.name === "DD_AGENT_HOST");
      if (!ddAgentHostExists) {
        container.environment.push({
          name: "DD_AGENT_HOST",
          value: "localhost"
        });
      }

      // Add DD_TRACE_AGENT_PORT for APM
      if (config.apmEnabled) {
        const ddTracePortExists = container.environment.find(env => env.name === "DD_TRACE_AGENT_PORT");
        if (!ddTracePortExists) {
          container.environment.push({
            name: "DD_TRACE_AGENT_PORT",
            value: "8126"
          });
        }
      }

      // Add DD_DOGSTATSD_PORT for metrics
      const ddStatsPortExists = container.environment.find(env => env.name === "DD_DOGSTATSD_PORT");
      if (!ddStatsPortExists) {
        container.environment.push({
          name: "DD_DOGSTATSD_PORT",
          value: "8125"
        });
      }

      // Add service and version tags
      const ddServiceExists = container.environment.find(env => env.name === "DD_SERVICE");
      if (!ddServiceExists) {
        container.environment.push({
          name: "DD_SERVICE",
          value: serviceName
        });
      }

      const ddVersionExists = container.environment.find(env => env.name === "DD_VERSION");
      if (!ddVersionExists && config.version) {
        container.environment.push({
          name: "DD_VERSION",
          value: config.version
        });
      }
    }
  });

  core.info(`Datadog agent container '${ddAgentName}' injected successfully`);
  core.debug(`Datadog configuration: ${JSON.stringify(config, null, 2)}`);
}

module.exports = { injectDDConfig }; 