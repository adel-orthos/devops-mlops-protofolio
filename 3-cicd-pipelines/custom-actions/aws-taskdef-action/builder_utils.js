const core = require("@actions/core");

/**
 * Inject Builder container as a sidecar into ECS task definition
 * @param {string} serviceName - Name of the service
 * @param {string} environment - Deployment environment
 * @param {string} region - AWS region
 * @param {object} taskDefContents - Task definition object to modify
 * @param {object} builderConfig - Builder configuration object
 */
function injectBuilderConfig(serviceName, environment, region, taskDefContents, builderConfig) {
  if (!builderConfig) {
    core.warning("Builder configuration not provided, skipping builder container injection");
    return;
  }

  const builderName = `${serviceName}-builder`;
  
  // Default builder configuration
  const defaultConfig = {
    image: `${process.env.AWS_ACCOUNT_ID || 'ACCOUNT_ID'}.dkr.ecr.${region}.amazonaws.com/utility-builder:latest`,
    essential: false,
    memoryReservation: 128,
    cpu: 0,
    environment: [],
    mountPoints: [],
    volumesFrom: []
  };

  // Merge with provided configuration
  const config = { ...defaultConfig, ...builderConfig };

  // Build environment variables for builder container
  const environment = [
    { name: "ENVIRONMENT", value: environment },
    { name: "SERVICE_NAME", value: serviceName },
    { name: "AWS_DEFAULT_REGION", value: region },
    { name: "BUILDER_MODE", value: "sidecar" }
  ];

  // Add custom environment variables from config
  if (config.environment && Array.isArray(config.environment)) {
    environment.push(...config.environment);
  }

  // Create builder container definition
  const builderContainer = {
    name: builderName,
    image: config.image,
    cpu: config.cpu,
    memoryReservation: config.memoryReservation,
    essential: config.essential,
    environment: environment,
    mountPoints: config.mountPoints || [],
    volumesFrom: config.volumesFrom || [],
    logConfiguration: {
      logDriver: "awslogs",
      options: {
        "awslogs-group": `/ecs/${serviceName}-builder`,
        "awslogs-region": region,
        "awslogs-stream-prefix": "builder",
        "awslogs-create-group": "true"
      }
    }
  };

  // Add health check if specified
  if (config.healthCheck) {
    builderContainer.healthCheck = {
      command: config.healthCheck.command || ["CMD-SHELL", "echo 'Builder container healthy'"],
      interval: config.healthCheck.interval || 30,
      timeout: config.healthCheck.timeout || 5,
      retries: config.healthCheck.retries || 3,
      startPeriod: config.healthCheck.startPeriod || 30
    };
  }

  // Add port mappings if specified
  if (config.portMappings && Array.isArray(config.portMappings)) {
    builderContainer.portMappings = config.portMappings;
  }

  // Add secrets if specified
  if (config.secrets && Array.isArray(config.secrets)) {
    builderContainer.secrets = config.secrets;
  }

  // Add working directory if specified
  if (config.workingDirectory) {
    builderContainer.workingDirectory = config.workingDirectory;
  }

  // Add user if specified
  if (config.user) {
    builderContainer.user = config.user;
  }

  // Add entry point and command if specified
  if (config.entryPoint && Array.isArray(config.entryPoint)) {
    builderContainer.entryPoint = config.entryPoint;
  }

  if (config.command && Array.isArray(config.command)) {
    builderContainer.command = config.command;
  }

  // Add depends on relationships if specified
  if (config.dependsOn && Array.isArray(config.dependsOn)) {
    builderContainer.dependsOn = config.dependsOn;
  }

  // Add links if specified (for legacy compatibility)
  if (config.links && Array.isArray(config.links)) {
    builderContainer.links = config.links;
  }

  // Add system controls if specified
  if (config.systemControls && Array.isArray(config.systemControls)) {
    builderContainer.systemControls = config.systemControls;
  }

  // Add resource requirements if specified
  if (config.resourceRequirements && Array.isArray(config.resourceRequirements)) {
    builderContainer.resourceRequirements = config.resourceRequirements;
  }

  // Add the builder container to task definition
  taskDefContents.containerDefinitions.push(builderContainer);

  // Add any required volumes for the builder container
  if (config.volumes && Array.isArray(config.volumes)) {
    taskDefContents.volumes = taskDefContents.volumes || [];
    config.volumes.forEach(volume => {
      // Check if volume already exists
      const existingVolume = taskDefContents.volumes.find(v => v.name === volume.name);
      if (!existingVolume) {
        taskDefContents.volumes.push(volume);
      }
    });
  }

  // Update main application containers to depend on builder if specified
  if (config.makeMainContainerDependent) {
    taskDefContents.containerDefinitions.forEach((container) => {
      if (container.name !== builderName && container.essential) {
        container.dependsOn = container.dependsOn || [];
        
        // Check if dependency already exists
        const existingDependency = container.dependsOn.find(dep => dep.containerName === builderName);
        if (!existingDependency) {
          container.dependsOn.push({
            containerName: builderName,
            condition: "SUCCESS"
          });
        }
      }
    });
  }

  core.info(`Builder container '${builderName}' injected successfully`);
  core.debug(`Builder configuration: ${JSON.stringify(config, null, 2)}`);
}

module.exports = { injectBuilderConfig }; 