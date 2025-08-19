const path = require("path");
const core = require("@actions/core");
const aws = require("aws-sdk");
const tmp = require("tmp");
const fs = require("fs");
const yaml = require("js-yaml");
const { injectDDConfig } = require("./datadog_utils");
const { injectFirelensConfig, logConfigGenerator } = require("./firelens_utils");
const { injectBuilderConfig } = require("./builder_utils");

// Get All Parameter Store under path
const recursiveGetParametersByPath = async (path, ssmRegion = null) => {
  const ssm = new aws.SSM({
    apiVersion: "2014–11–06",
    region: ssmRegion
  });

  try {
    let allParameter = [];
    const params = {
      Path: path,
      ParameterFilters: [],
      Recursive: true,
      WithDecryption: false,
    };
    let results = await ssm.getParametersByPath(params).promise();
    if (results.Parameters.length == 0) {
      console.log(`Error result is empty for path: ${path}`);
      return [];
    }
    allParameter = allParameter.concat(results.Parameters);
    while (results.NextToken) {
      params.NextToken = results.NextToken;
      results = await ssm.getParametersByPath(params).promise();
      allParameter = allParameter.concat(results.Parameters);
    }
    return allParameter;
  } catch (error) {
    console.error("ERROR GET SSM PARAMETER:", JSON.stringify(error));
    return error;
  }
};

// Parse the config file
async function readConfigFile(configPath, envChoosen) {
  const configFilePath = path.isAbsolute(configPath) ? configPath : path.join(process.env.GITHUB_WORKSPACE, configPath);

  if (!fs.existsSync(configFilePath)) {
    throw new Error(`Config file not found: ${configFilePath}`);
  }

  const configFileContents = fs.readFileSync(configFilePath, "utf8");
  const configData = yaml.load(configFileContents);
  
  // Apply environment-specific overrides
  if (configData.environments && configData.environments[envChoosen]) {
    const envConfig = configData.environments[envChoosen];
    return { ...configData, ...envConfig };
  }
  
  return configData;
}

async function run() {
  try {
    // Get inputs from GitHub Actions
    const taskDefinitionFile = core.getInput("task-definition", { required: true });
    const containerName = core.getInput("container-name", { required: true });
    const configPath = core.getInput("config-path", { required: true });
    const environment = core.getInput("environment", { required: true });
    const region = core.getInput("aws-region") || process.env.AWS_DEFAULT_REGION || "us-east-1";
    const ssmRegion = core.getInput("aws-ssm-region") || region;

    // Validate inputs
    if (!taskDefinitionFile) {
      throw new Error("Task definition file path is required");
    }
    if (!containerName) {
      throw new Error("Container name is required");
    }
    if (!environment) {
      throw new Error("Environment is required");
    }

    // Read task definition file
    const taskDefPath = path.isAbsolute(taskDefinitionFile) 
      ? taskDefinitionFile 
      : path.join(process.env.GITHUB_WORKSPACE, taskDefinitionFile);
    
    if (!fs.existsSync(taskDefPath)) {
      throw new Error(`Task definition file not found: ${taskDefPath}`);
    }

    const taskDefContents = JSON.parse(fs.readFileSync(taskDefPath, "utf8"));
    core.debug(`Task definition loaded: ${JSON.stringify(taskDefContents, null, 2)}`);

    // Find the container definition
    const containerDef = taskDefContents.containerDefinitions.find(
      (containerDef) => containerDef.name === containerName
    );

    if (!containerDef) {
      throw new Error(
        `Could not find container definition with name ${containerName}`
      );
    }

    // Read configuration file
    const configContents = await readConfigFile(configPath, environment);
    core.debug(`Configuration loaded: ${JSON.stringify(configContents, null, 2)}`);

    const serviceName = configContents.serviceName;
    if (!serviceName) {
      throw new Error("Please provide serviceName in the configuration file.");
    }

    // Start Datadog Agent Injection
    const isDDNeeded = configContents.runDatadogAgent;
    
    // Remove existing DD Container if any
    taskDefContents.containerDefinitions = taskDefContents.containerDefinitions.filter((element) => {
      return element.name != `${serviceName}-dd-agent`;
    });

    if (isDDNeeded) {
      await injectDDConfig(serviceName, taskDefContents, configContents.datadogAgentConfig, ssmRegion);
    }
    // End Datadog Agent Injection

    // Start Firelens Agent Injection (optional - commented out for production)
    // This section can be enabled for advanced logging configurations
    /*
    if (environment.startsWith('dev')) {
      // Remove firelens Container if any
      taskDefContents.containerDefinitions = taskDefContents.containerDefinitions.filter((element) => {
        return element.name != "log_router";
      });

      injectFirelensConfig(containerName, environment, region, taskDefContents);

      // Start change logs config
      const bu = configContents.bu;
      if (bu === undefined) {
        throw new Error("Please add bu name in configuration file!");
      }
      const logConfig = logConfigGenerator(containerName, environment, bu);
      containerDef.logConfiguration = logConfig;
      // End change logs config
    }
    */
    // End Firelens Agent Injection

    // Start Builder Container Injection
    const useBuilder = configContents.builder === true;
    if (useBuilder) {
      injectBuilderConfig(serviceName, environment, region, taskDefContents, configContents.builderConfig);
    }
    // End Builder Container Injection

    // Start secrets injection
    let aliasedSecrets = [];
    if (configContents.secretsWildcard) {
      core.info(`Fetching SSM parameters from path: ${configContents.secretsWildcard}`);
      const ssmSecrets = await recursiveGetParametersByPath(configContents.secretsWildcard, ssmRegion);

      aliasedSecrets = ssmSecrets.map((item) => {
        const name = item.Name;
        return {
          name: name.substring(name.lastIndexOf("/") + 1, name.length),
          valueFrom: item.ARN,
        };
      });

      core.debug(`Wildcard secrets found: ${JSON.stringify(aliasedSecrets)}`);
    }
    
    // Add reserved secrets if specified
    if (configContents.reservedSecrets) {
      configContents.reservedSecrets.forEach((secret) => {
        aliasedSecrets.push(secret);
      });
    }

    // Apply secrets to container
    containerDef.secrets = aliasedSecrets;
    core.info(`Applied ${aliasedSecrets.length} secrets to container ${containerName}`);
    // End secrets injection

    // Apply resource configuration
    if (configContents.cpu) {
      taskDefContents.cpu = String(configContents.cpu);
    }
    if (configContents.memory) {
      taskDefContents.memory = String(configContents.memory);
    }

    // Apply health check configuration if specified
    if (configContents.healthCheck && configContents.healthCheck.enabled) {
      const healthCheck = configContents.healthCheck;
      containerDef.healthCheck = {
        command: ["CMD-SHELL", `curl -f http://localhost:${containerDef.portMappings?.[0]?.containerPort || 8080}${healthCheck.path || '/health'} || exit 1`],
        interval: healthCheck.interval || 30,
        timeout: healthCheck.timeout || 5,
        retries: healthCheck.retries || 3,
        startPeriod: healthCheck.startPeriod || 60
      };
    }

    // Apply logging configuration if specified
    if (configContents.logging) {
      containerDef.logConfiguration = {
        logDriver: configContents.logging.driver || "awslogs",
        options: configContents.logging.options || {
          "awslogs-group": `/ecs/${serviceName}`,
          "awslogs-region": region,
          "awslogs-stream-prefix": containerName,
          "awslogs-create-group": "true"
        }
      };
    }

    // Apply additional task definition overrides if specified
    if (configContents.taskDefinitionOverrides) {
      const overrides = configContents.taskDefinitionOverrides;
      
      if (overrides.volumes) {
        taskDefContents.volumes = overrides.volumes;
      }
      
      if (overrides.placementConstraints) {
        taskDefContents.placementConstraints = overrides.placementConstraints;
      }
      
      if (overrides.networkMode) {
        taskDefContents.networkMode = overrides.networkMode;
      }
      
      if (overrides.requiresCompatibilities) {
        taskDefContents.requiresCompatibilities = overrides.requiresCompatibilities;
      }
    }

    // Apply tags if specified
    if (configContents.tags) {
      const tags = Object.entries(configContents.tags).map(([key, value]) => ({
        key,
        value: String(value)
      }));
      taskDefContents.tags = tags;
    }

    // Write out a new task definition file
    var updatedTaskDefFile = tmp.fileSync({
      tmpdir: process.env.RUNNER_TEMP,
      prefix: "task-definition-",
      postfix: ".json",
      keep: true,
      discardDescriptor: true,
    });

    // Clean up task definition for production deployment
    if (environment === "prod") {
      delete taskDefContents.status;
      delete taskDefContents.compatibilities;
      delete taskDefContents.taskDefinitionArn;
      delete taskDefContents.requiresAttributes;
      delete taskDefContents.revision;
      delete taskDefContents.registeredAt;
      delete taskDefContents.registeredBy;
    }

    const newTaskDefContents = JSON.stringify(taskDefContents, null, 2);

    fs.writeFileSync(updatedTaskDefFile.name, newTaskDefContents);
    core.setOutput("task-definition", updatedTaskDefFile.name);
    
    core.info(`Task definition updated successfully for ${serviceName} in ${environment} environment`);
    core.info(`Output file: ${updatedTaskDefFile.name}`);
    core.debug(`Updated task definition: ${newTaskDefContents}`);
    
  } catch (error) {
    console.error(`ERROR:`, error.message);
    core.setFailed(error.message);
  }
}

module.exports = run;

/* istanbul ignore next */
if (require.main === module) {
  run();
} 