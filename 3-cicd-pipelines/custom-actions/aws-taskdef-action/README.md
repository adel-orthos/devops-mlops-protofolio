# Advanced ECS Task Definition Manager

A powerful GitHub Action for dynamically managing Amazon ECS task definitions with advanced features including automated SSM parameter injection, monitoring agent configuration, and multi-container orchestration.

## Features

- **🔐 Dynamic Secret Management**: Wildcard SSM parameter injection with automatic discovery
- **📊 Monitoring Integration**: Automated Datadog agent injection and configuration
- **🏗️ Multi-Container Support**: Builder containers and sidecar pattern management
- **🌍 Environment-Aware**: Environment-specific resource allocation and configuration
- **⚡ Production-Ready**: Used in production for 250K+ document processing workloads

## Usage

### Basic Example

```yaml
- name: Configure ECS Task Definition
  id: configure-task-def
  uses: ./custom-actions/aws-taskdef-action
  with:
    task-definition: task-definition.json
    container-name: web-app
    config-path: deployment-configs/web-app.yml
    environment: production
    aws-region: us-east-1

- name: Deploy to ECS
  uses: aws-actions/amazon-ecs-deploy-task-definition@v1
  with:
    task-definition: ${{ steps.configure-task-def.outputs.task-definition }}
    service: web-app-service
    cluster: production-cluster
```

### Multi-Container Example

For task definitions with multiple containers requiring different configurations:

```yaml
- name: Configure Main Container
  id: configure-main
  uses: ./custom-actions/aws-taskdef-action
  with:
    task-definition: task-definition.json
    container-name: web-app
    config-path: deployment-configs/web-app.yml
    environment: production

- name: Configure Sidecar Container
  id: configure-sidecar
  uses: ./custom-actions/aws-taskdef-action
  with:
    task-definition: ${{ steps.configure-main.outputs.task-definition }}
    container-name: log-processor
    config-path: deployment-configs/log-processor.yml
    environment: production

- name: Deploy to ECS
  uses: aws-actions/amazon-ecs-deploy-task-definition@v1
  with:
    task-definition: ${{ steps.configure-sidecar.outputs.task-definition }}
    service: web-app-service
    cluster: production-cluster
```

## Configuration File Format

Create a service configuration file (YAML) with the following structure:

```yaml
# deployment-configs/web-app.yml
serviceName: web-app
cpu: 512
memory: 1024

# Secrets management
secretsWildcard: /app/prod/web-app  # Inject all parameters under this path
reservedSecrets:
  - name: DATABASE_URL
    valueFrom: arn:aws:ssm:us-east-1:123456789012:parameter/shared/database-url

# Monitoring configuration
runDatadogAgent: true
datadogAgentConfig:
  apiKey: /app/prod/datadog/api-key
  site: datadoghq.com
  logLevel: info

# Builder container for utility tasks
builder: true
builderConfig:
  image: utility-builder:latest
  essential: false
  memoryReservation: 128

# Business unit for logging and tagging
bu: engineering
```

## Input Parameters

| Parameter | Description | Required | Default |
|-----------|-------------|----------|---------|
| `task-definition` | Path to the ECS task definition JSON file | ✅ | - |
| `container-name` | Name of the primary container to configure | ✅ | - |
| `config-path` | Path to the service configuration YAML file | ✅ | - |
| `environment` | Target environment (dev, staging, prod) | ✅ | - |
| `aws-region` | AWS region for deployment | ❌ | `us-east-1` |
| `aws-ssm-region` | AWS region for SSM parameters | ❌ | Same as `aws-region` |

## Output Parameters

| Parameter | Description |
|-----------|-------------|
| `task-definition` | Path to the modified task definition file |

## Key Features Explained

### 1. Wildcard SSM Parameter Injection

The action automatically discovers and injects all SSM parameters under a specified path:

```yaml
secretsWildcard: /app/prod/web-app
```

This will inject all parameters like:
- `/app/prod/web-app/DATABASE_URL`
- `/app/prod/web-app/API_KEY`
- `/app/prod/web-app/REDIS_URL`

### 2. Datadog Agent Integration

Automatically injects a Datadog monitoring agent as a sidecar container:

```yaml
runDatadogAgent: true
datadogAgentConfig:
  apiKey: /app/prod/datadog/api-key
  site: datadoghq.com
  logLevel: info
```

### 3. Builder Container Support

Adds utility containers for build-time operations:

```yaml
builder: true
builderConfig:
  image: utility-builder:latest
  essential: false
  memoryReservation: 128
```

### 4. Environment-Specific Resource Allocation

Automatically adjusts CPU and memory based on environment:

```yaml
cpu: 512      # Will be applied to task definition
memory: 1024  # Will be applied to task definition
```

### 5. Production Optimizations

For production deployments, the action automatically:
- Removes unnecessary metadata fields
- Optimizes resource allocation
- Applies production-specific configurations

## Security Considerations

- **IAM Permissions**: Ensure the GitHub Actions runner has appropriate SSM permissions
- **Parameter Encryption**: Use SecureString parameters for sensitive data
- **Least Privilege**: Grant minimal required permissions for parameter access
- **Cross-Region**: Support for parameters in different regions than deployment

## Required IAM Permissions

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ssm:GetParameter",
        "ssm:GetParameters",
        "ssm:GetParametersByPath"
      ],
      "Resource": [
        "arn:aws:ssm:*:*:parameter/app/*"
      ]
    }
  ]
}
```

## Error Handling

The action provides detailed error messages for common issues:
- Missing configuration files
- Invalid SSM parameter paths
- Insufficient permissions
- Malformed task definitions

## Performance Considerations

- **Caching**: Parameters are cached during execution
- **Batch Operations**: Multiple parameters are fetched in batches
- **Minimal Overhead**: Only modifies necessary task definition fields

## Examples in Production

This action is used in production environments for:
- **Document Processing**: 250K+ documents with dynamic scaling
- **Multi-Tenant Applications**: Environment-specific configurations
- **Microservices**: Complex multi-container deployments
- **ML Workloads**: GPU-enabled containers with specialized configurations

## Troubleshooting

### Common Issues

1. **Permission Denied**: Check IAM permissions for SSM access
2. **Parameter Not Found**: Verify parameter paths and regions
3. **Invalid Configuration**: Validate YAML syntax in config file
4. **Container Not Found**: Ensure container name matches task definition

### Debug Mode

Enable debug logging in GitHub Actions:

```yaml
env:
  ACTIONS_STEP_DEBUG: true
```

## Contributing

This action is part of a larger DevOps portfolio demonstrating production-ready CI/CD practices. It showcases:
- Advanced ECS orchestration patterns
- Security-first secret management
- Production-scale automation
- Multi-environment deployment strategies 