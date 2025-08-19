const core = require("@actions/core");

/**
 * Inject FireLens log router container into ECS task definition
 * @param {string} containerName - Name of the main container
 * @param {string} environment - Deployment environment
 * @param {string} region - AWS region
 * @param {object} taskDefContents - Task definition object to modify
 */
function injectFirelensConfig(containerName, environment, region, taskDefContents) {
  const firelensName = "log_router";
  
  // FireLens container configuration
  const firelensContainer = {
    name: firelensName,
    image: "public.ecr.aws/aws-observability/aws-for-fluent-bit:stable",
    cpu: 0,
    memoryReservation: 50,
    essential: true,
    firelensConfiguration: {
      type: "fluentbit",
      options: {
        "enable-ecs-log-metadata": "true",
        "config-file-type": "file",
        "config-file-value": "/fluent-bit/configs/parse-json.conf"
      }
    },
    logConfiguration: {
      logDriver: "awslogs",
      options: {
        "awslogs-group": `/ecs/${environment}-firelens`,
        "awslogs-region": region,
        "awslogs-stream-prefix": "firelens",
        "awslogs-create-group": "true"
      }
    },
    environment: [
      {
        name: "FLB_LOG_LEVEL",
        value: environment === "prod" ? "info" : "debug"
      }
    ]
  };

  // Add the FireLens container to task definition
  taskDefContents.containerDefinitions.push(firelensContainer);

  core.info(`FireLens log router '${firelensName}' injected successfully`);
}

/**
 * Generate log configuration for application containers using FireLens
 * @param {string} containerName - Name of the container
 * @param {string} environment - Deployment environment
 * @param {string} bu - Business unit for log organization
 * @returns {object} Log configuration object
 */
function logConfigGenerator(containerName, environment, bu) {
  const logConfig = {
    logDriver: "awsfirelens",
    options: {
      "Name": "cloudwatch_logs",
      "region": process.env.AWS_DEFAULT_REGION || "us-east-1",
      "log_group_name": `/ecs/${environment}-${containerName}`,
      "log_stream_prefix": `${bu}-`,
      "auto_create_group": "true",
      "log_format": "json/emf",
      "log_key": "log",
      "remove_log_keys": "container_id,container_name,source",
      "dimensions": `Environment,${environment},Service,${containerName},BusinessUnit,${bu}`
    }
  };

  // Add additional options for different environments
  if (environment === "prod") {
    logConfig.options["log_retention_days"] = "30";
    logConfig.options["metric_namespace"] = `ECS/${bu}`;
    logConfig.options["metric_dimensions"] = `Environment:${environment},Service:${containerName}`;
  } else {
    logConfig.options["log_retention_days"] = "7";
  }

  return logConfig;
}

/**
 * Generate enhanced log configuration with structured logging
 * @param {string} serviceName - Name of the service
 * @param {string} environment - Deployment environment
 * @param {object} options - Additional logging options
 * @returns {object} Enhanced log configuration
 */
function enhancedLogConfigGenerator(serviceName, environment, options = {}) {
  const defaultOptions = {
    logLevel: environment === "prod" ? "info" : "debug",
    includeMetrics: environment === "prod",
    retentionDays: environment === "prod" ? 30 : 7,
    structuredLogging: true,
    logSampling: environment === "prod" ? 0.1 : 1.0
  };

  const config = { ...defaultOptions, ...options };

  const logConfig = {
    logDriver: "awsfirelens",
    options: {
      "Name": "cloudwatch_logs",
      "region": process.env.AWS_DEFAULT_REGION || "us-east-1",
      "log_group_name": `/ecs/${environment}/${serviceName}`,
      "log_stream_prefix": `${serviceName}-`,
      "auto_create_group": "true",
      "log_retention_days": String(config.retentionDays)
    }
  };

  // Add structured logging configuration
  if (config.structuredLogging) {
    logConfig.options["log_format"] = "json/emf";
    logConfig.options["log_key"] = "message";
    logConfig.options["remove_log_keys"] = "container_id,container_name,source,partial_id,partial_ordinal,partial_last";
  }

  // Add metrics configuration for production
  if (config.includeMetrics) {
    logConfig.options["metric_namespace"] = `ECS/${serviceName}`;
    logConfig.options["metric_dimensions"] = `Environment:${environment},Service:${serviceName}`;
    logConfig.options["default_dimensions"] = `{\"Environment\":\"${environment}\",\"Service\":\"${serviceName}\"}`;
  }

  // Add log sampling for high-volume environments
  if (config.logSampling < 1.0) {
    logConfig.options["log_sampling_rate"] = String(config.logSampling);
  }

  // Add custom dimensions if provided
  if (options.customDimensions) {
    const dimensionsStr = Object.entries(options.customDimensions)
      .map(([key, value]) => `${key}:${value}`)
      .join(",");
    logConfig.options["dimensions"] = dimensionsStr;
  }

  // Add filters for sensitive data
  if (options.sensitiveDataFilters) {
    logConfig.options["filters"] = JSON.stringify(options.sensitiveDataFilters);
  }

  return logConfig;
}

/**
 * Create FireLens configuration for multi-destination logging
 * @param {string} serviceName - Name of the service
 * @param {string} environment - Deployment environment
 * @param {Array} destinations - Array of log destinations
 * @returns {object} Multi-destination log configuration
 */
function multiDestinationLogConfig(serviceName, environment, destinations = []) {
  const configs = [];

  destinations.forEach((dest, index) => {
    let config = {};

    switch (dest.type) {
      case "cloudwatch":
        config = {
          logDriver: "awsfirelens",
          options: {
            "Name": "cloudwatch_logs",
            "region": dest.region || process.env.AWS_DEFAULT_REGION || "us-east-1",
            "log_group_name": dest.logGroup || `/ecs/${environment}/${serviceName}`,
            "log_stream_prefix": dest.streamPrefix || serviceName,
            "auto_create_group": "true"
          }
        };
        break;

      case "s3":
        config = {
          logDriver: "awsfirelens",
          options: {
            "Name": "s3",
            "region": dest.region || process.env.AWS_DEFAULT_REGION || "us-east-1",
            "bucket": dest.bucket,
            "s3_key_format": dest.keyFormat || `/logs/${environment}/${serviceName}/%Y/%m/%d/%H/%M/%S`,
            "total_file_size": dest.fileSize || "50M",
            "upload_timeout": dest.uploadTimeout || "10m",
            "compression": dest.compression || "gzip"
          }
        };
        break;

      case "elasticsearch":
        config = {
          logDriver: "awsfirelens",
          options: {
            "Name": "es",
            "Host": dest.host,
            "Port": String(dest.port || 443),
            "Index": dest.index || `${environment}-${serviceName}`,
            "Type": dest.docType || "_doc",
            "AWS_Auth": "On",
            "AWS_Region": dest.region || process.env.AWS_DEFAULT_REGION || "us-east-1",
            "tls": "On",
            "Suppress_Type_Name": "On"
          }
        };
        break;

      case "kinesis":
        config = {
          logDriver: "awsfirelens",
          options: {
            "Name": "kinesis_firehose",
            "region": dest.region || process.env.AWS_DEFAULT_REGION || "us-east-1",
            "delivery_stream": dest.deliveryStream,
            "time_key": "timestamp",
            "time_key_format": "%Y-%m-%dT%H:%M:%S.%3NZ"
          }
        };
        break;

      default:
        core.warning(`Unsupported log destination type: ${dest.type}`);
        return;
    }

    // Add common options
    if (dest.bufferSize) {
      config.options["buffer_size"] = dest.bufferSize;
    }
    if (dest.flushInterval) {
      config.options["flush_interval"] = String(dest.flushInterval);
    }

    configs.push(config);
  });

  return configs.length === 1 ? configs[0] : configs;
}

module.exports = { 
  injectFirelensConfig, 
  logConfigGenerator, 
  enhancedLogConfigGenerator,
  multiDestinationLogConfig 
}; 