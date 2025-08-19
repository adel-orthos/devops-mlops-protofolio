#!/bin/bash

# EC2 AMI Creation and Cross-Account Sharing Script
# Production-ready script for creating AMIs from running instances and sharing across accounts
# Used in production environments for disaster recovery and account migrations

set -e  # Exit on any error

# Disable AWS CLI pager/prompts for automation
export AWS_PAGER=""
export AWS_CLI_AUTO_PROMPT=off

# Load central configuration if present
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.sh"
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
  echo "[INFO] Loaded config: $CONFIG_FILE" >&2
fi

# Configuration (can be overridden by config.sh or environment variables)
DESTINATION_ACCOUNT_IDS=${DESTINATION_ACCOUNT_IDS:-()}  # Array of destination account IDs
AWS_PROFILE=${AWS_PROFILE:-${AWS_PROFILE_SOURCE:-""}}  # AWS profile for source account
AWS_REGION=${AWS_REGION:-""}                           # AWS region (auto-detect if empty)
LOG_FILE="ami-creation-$(date +%Y%m%d-%H%M%S).log"
DRY_RUN=${DRY_RUN:-false}                             # Set to true for testing
PARALLEL_JOBS=${PARALLEL_JOBS:-3}                     # Number of parallel AMI creations
SKIP_INSTANCES=${SKIP_INSTANCES:-()}                   # Array of instance IDs to skip

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging functions (send to stderr to avoid contaminating JSON/stdout)
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" | tee -a "$LOG_FILE" >&2
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE" >&2
    exit 1
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE" >&2
}

info() {
    echo -e "${CYAN}[INFO]${NC} $1" | tee -a "$LOG_FILE" >&2
}

# Function to check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    # Check if AWS CLI is installed
    if ! command -v aws &> /dev/null; then
        error "AWS CLI is not installed. Please install it first."
    fi
    
    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        error "jq is not installed. Please install it first."
    fi
    
    # Set AWS profile if specified
    if [[ -n "$AWS_PROFILE" ]]; then
        export AWS_PROFILE="$AWS_PROFILE"
        log "Using AWS profile: $AWS_PROFILE"
    fi
    
    # Auto-detect region if not specified
    if [[ -z "$AWS_REGION" ]]; then
        AWS_REGION=$(aws configure get region 2>/dev/null || echo "")
        if [[ -z "$AWS_REGION" ]]; then
            error "AWS region not specified and cannot be auto-detected. Please set AWS_REGION variable."
        fi
    fi
    log "Using AWS region: $AWS_REGION"
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured or invalid."
    fi
    
    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text)
    log "Source account ID: $account_id"
    
    success "Prerequisites check completed"
}

# Function to validate destination accounts
validate_destination_accounts() {
    if [[ ${#DESTINATION_ACCOUNT_IDS[@]} -eq 0 ]]; then
        error "No destination account IDs specified. Please update DESTINATION_ACCOUNT_IDS array."
    fi
    
    log "Destination accounts to share AMIs with:"
    for account_id in "${DESTINATION_ACCOUNT_IDS[@]}"; do
        if [[ ! "$account_id" =~ ^[0-9]{12}$ ]]; then
            error "Invalid account ID format: $account_id (should be 12 digits)"
        fi
        info "  - $account_id"
    done
}

# Function to get all running EC2 instances
get_running_instances() {
    log "Fetching running EC2 instances..."
    
    local instances
    instances=$(aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0],InstanceType,Platform,LaunchTime]' \
        --output json 2>/dev/null)
    
    if [[ -z "$instances" || "$instances" == "[]" ]]; then
        warn "No running EC2 instances found"
        echo "[]"
        return 1
    fi
    
    # Filter out instances to skip
    if [[ ${#SKIP_INSTANCES[@]} -gt 0 ]]; then
        local filtered_instances="[]"
        while IFS= read -r instance; do
            local instance_id
            instance_id=$(echo "$instance" | jq -r '.[0]')
            
            # Check if instance should be skipped
            local skip=false
            for skip_id in "${SKIP_INSTANCES[@]}"; do
                if [[ "$instance_id" == "$skip_id" ]]; then
                    warn "Skipping instance $instance_id (in skip list)"
                    skip=true
                    break
                fi
            done
            
            if [[ "$skip" == "false" ]]; then
                filtered_instances=$(echo "$filtered_instances" | jq ". += [$instance]")
            fi
        done < <(echo "$instances" | jq -c '.[]')
        
        instances="$filtered_instances"
    fi
    
    echo "$instances"
}

# Function to create AMI from instance
create_ami() {
    local instance_id="$1"
    local instance_name="$2"
    local instance_type="$3"
    local platform="$4"
    local launch_time="$5"
    
    # Generate AMI name with sanitized instance name
    local sanitized_name
    sanitized_name=$(echo "${instance_name:-$instance_id}" | sed 's/[^a-zA-Z0-9-]/-/g' | cut -c1-50)
    local ami_name="AMI-${sanitized_name}-$(date +%Y%m%d-%H%M%S)"
    local ami_description="AMI created from $instance_id ($instance_name) - Automated backup for migration"
    
    log "Creating AMI for instance $instance_id ($instance_name)..."
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would create AMI: $ami_name"
        echo "ami-dryrun$(date +%s)"
        return 0
    fi
    
    # Create AMI with no-reboot for minimal downtime
    local ami_id
    ami_id=$(aws ec2 create-image \
        --region "$AWS_REGION" \
        --instance-id "$instance_id" \
        --name "$ami_name" \
        --description "$ami_description" \
        --no-reboot \
        --tag-specifications "ResourceType=image,Tags=[
            {Key=Name,Value=\"$ami_name\"},
            {Key=SourceInstance,Value=\"$instance_id\"},
            {Key=SourceInstanceName,Value=\"${instance_name:-Unknown}\"},
            {Key=CreatedBy,Value=\"AMI-Migration-Script\"},
            {Key=CreatedDate,Value=\"$(date +%Y-%m-%d)\"},
            {Key=CreatedTime,Value=\"$(date -Iseconds)\"},
            {Key=InstanceType,Value=\"$instance_type\"},
            {Key=Platform,Value=\"${platform:-Linux}\"},
            {Key=OriginalLaunchTime,Value=\"$launch_time\"},
            {Key=Environment,Value=\"production\"},
            {Key=Purpose,Value=\"disaster-recovery\"}
        ]" \
        --query 'ImageId' \
        --output text 2>/dev/null)
    
    if [[ -z "$ami_id" || "$ami_id" == "None" || "$ami_id" == "null" ]]; then
        error "Failed to create AMI for instance $instance_id"
    fi
    
    success "AMI created: $ami_id for instance $instance_id"
    echo "$ami_id"
}

# Function to wait for AMI to be available
wait_for_ami() {
    local ami_id="$1"
    local max_wait=3600  # 60 minutes
    local wait_time=0
    local check_interval=30
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would wait for AMI: $ami_id"
        return 0
    fi
    
    log "Waiting for AMI $ami_id to be available..."
    
    while [[ $wait_time -lt $max_wait ]]; do
        local state progress
        state=$(aws ec2 describe-images \
            --region "$AWS_REGION" \
            --image-ids "$ami_id" \
            --query 'Images[0].State' \
            --output text 2>/dev/null || echo "unknown")
        
        # Get progress if available
        progress=$(aws ec2 describe-images \
            --region "$AWS_REGION" \
            --image-ids "$ami_id" \
            --query 'Images[0].StateReason.Message' \
            --output text 2>/dev/null || echo "")
        
        case "$state" in
            "available")
                success "AMI $ami_id is now available"
                return 0
                ;;
            "pending")
                info "AMI $ami_id is still pending... (waited ${wait_time}s) - $progress"
                sleep $check_interval
                wait_time=$((wait_time + check_interval))
                ;;
            "failed")
                error "AMI $ami_id creation failed: $progress"
                ;;
            *)
                warn "AMI $ami_id has unexpected state: $state - $progress"
                sleep $check_interval
                wait_time=$((wait_time + check_interval))
                ;;
        esac
    done
    
    error "Timeout waiting for AMI $ami_id to be available (waited ${max_wait}s)"
}

# Function to share AMI with destination accounts
share_ami() {
    local ami_id="$1"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        info "[DRY RUN] Would share AMI $ami_id with accounts: ${DESTINATION_ACCOUNT_IDS[*]}"
        return 0
    fi
    
    log "Sharing AMI $ami_id with destination accounts..."
    
    for account_id in "${DESTINATION_ACCOUNT_IDS[@]}"; do
        info "Sharing AMI with account $account_id..."
        
        # Share AMI
        if aws ec2 modify-image-attribute \
            --region "$AWS_REGION" \
            --image-id "$ami_id" \
            --launch-permission "Add=[{UserId=$account_id}]" \
            --output text >/dev/null 2>&1; then
            success "AMI $ami_id shared with account $account_id"
        else
            error "Failed to share AMI $ami_id with account $account_id"
        fi
        
        # Share associated snapshots
        local snapshot_ids
        snapshot_ids=$(aws ec2 describe-images \
            --region "$AWS_REGION" \
            --image-ids "$ami_id" \
            --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' \
            --output text 2>/dev/null || echo "")
        
        for snapshot_id in $snapshot_ids; do
            if [[ "$snapshot_id" != "None" && -n "$snapshot_id" && "$snapshot_id" != "null" ]]; then
                info "Sharing snapshot $snapshot_id with account $account_id..."
                if aws ec2 modify-snapshot-attribute \
                    --region "$AWS_REGION" \
                    --snapshot-id "$snapshot_id" \
                    --attribute createVolumePermission \
                    --operation-type add \
                    --user-ids "$account_id" \
                    --output text >/dev/null 2>&1; then
                    success "Snapshot $snapshot_id shared with account $account_id"
                else
                    warn "Failed to share snapshot $snapshot_id with account $account_id"
                fi
            fi
        done
    done
}

# Function to save AMI information
save_ami_info() {
    local ami_info_file="ami-info-$(date +%Y%m%d-%H%M%S).json"
    local csv_file="ami-mapping-$(date +%Y%m%d-%H%M%S).csv"
    
    log "Saving AMI information to $ami_info_file..."
    
    # Create JSON output
    local ami_list="["
    local first=true
    
    for ami_data in "${created_amis[@]}"; do
        if [[ "$first" == "false" ]]; then
            ami_list+=",";
        fi
        ami_list+="$ami_data"
        first=false
    done
    ami_list+="]"
    
    echo "$ami_list" | jq '.' > "$ami_info_file"
    success "AMI information saved to $ami_info_file"
    
    # Create CSV for easy reference
    echo "InstanceId,InstanceName,InstanceType,AMI_ID,AMI_Name,Status,CreatedDate" > "$csv_file"
    
    echo "$ami_list" | jq -r '.[] | [.instance_id, .instance_name, .instance_type, .ami_id, .ami_name, .status, .created_date] | @csv' >> "$csv_file"
    success "AMI mapping saved to $csv_file"
}

# Process single instance (used for parallel processing)
process_instance() {
    local instance_data="$1"
    local instance_id instance_name instance_type platform launch_time
    
    instance_id=$(echo "$instance_data" | jq -r '.[0]')
    instance_name=$(echo "$instance_data" | jq -r '.[1] // "Unknown"')
    instance_type=$(echo "$instance_data" | jq -r '.[2]')
    platform=$(echo "$instance_data" | jq -r '.[3] // "Linux"')
    launch_time=$(echo "$instance_data" | jq -r '.[4] // ""')
    
    log "Processing instance: $instance_id ($instance_name)"
    
    # Create AMI
    local ami_id
    ami_id=$(create_ami "$instance_id" "$instance_name" "$instance_type" "$platform" "$launch_time")
    
    # Wait for AMI to be available
    wait_for_ami "$ami_id"
    
    # Share AMI with destination accounts
    share_ami "$ami_id"
    
    # Return AMI information
    jq -n \
        --arg instance_id "$instance_id" \
        --arg instance_name "$instance_name" \
        --arg instance_type "$instance_type" \
        --arg platform "$platform" \
        --arg launch_time "$launch_time" \
        --arg ami_id "$ami_id" \
        --arg ami_name "AMI-$(echo "${instance_name:-$instance_id}" | sed 's/[^a-zA-Z0-9-]/-/g' | cut -c1-50)-$(date +%Y%m%d-%H%M%S)" \
        --arg status "shared" \
        '{
            instance_id: $instance_id,
            instance_name: $instance_name,
            instance_type: $instance_type,
            platform: $platform,
            launch_time: $launch_time,
            ami_id: $ami_id,
            ami_name: $ami_name,
            status: $status,
            created_date: now | strftime("%Y-%m-%d %H:%M:%S")
        }'
}

# Main execution function
main() {
    log "Starting EC2 AMI creation and sharing process..."
    
    # Check prerequisites
    check_prerequisites
    
    # Validate destination accounts
    validate_destination_accounts
    
    # Get running instances
    local instances_json
    instances_json=$(get_running_instances 2>/dev/null || echo "[]")
    
    if [[ -z "$instances_json" || "$instances_json" == "[]" ]]; then
        warn "No instances to process"
        exit 0
    fi
    
    local instance_count
    instance_count=$(echo "$instances_json" | jq length)
    log "Found $instance_count running instances to process"
    
    # Array to store created AMI information
    created_amis=()
    
    # Process instances
    local processed=0
    while IFS= read -r instance; do
        ((processed++))
        log "Processing instance $processed/$instance_count"
        
        # Process instance and store result
        local ami_info
        ami_info=$(process_instance "$instance")
        created_amis+=("$ami_info")
        
    done < <(echo "$instances_json" | jq -c '.[]')
    
    # Save AMI information
    save_ami_info
    
    success "AMI creation and sharing completed successfully!"
    log "Total AMIs created and shared: ${#created_amis[@]}"
    log "Log file: $LOG_FILE"
    
    # Display summary
    echo
    log "=== SUMMARY ==="
    for ami_data in "${created_amis[@]}"; do
        local instance_id instance_name ami_id
        instance_id=$(echo "$ami_data" | jq -r '.instance_id')
        instance_name=$(echo "$ami_data" | jq -r '.instance_name')
        ami_id=$(echo "$ami_data" | jq -r '.ami_id')
        info "Instance: $instance_id ($instance_name) -> AMI: $ami_id"
    done
}

# Script usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

This script creates AMIs from all running EC2 instances and shares them with destination accounts.
Designed for production use with comprehensive error handling and logging.

Before running, please configure:
1. DESTINATION_ACCOUNT_IDS array with target account IDs
2. AWS_PROFILE (optional) for source account
3. AWS_REGION (optional, will auto-detect if not set)

Options:
  -d, --dry-run     Run in dry-run mode (no actual changes)
  -h, --help        Show this help message

Environment Variables:
  DESTINATION_ACCOUNT_IDS   Array of destination account IDs
  AWS_PROFILE              AWS profile for source account
  AWS_REGION               AWS region
  SKIP_INSTANCES           Array of instance IDs to skip
  PARALLEL_JOBS            Number of parallel operations (default: 3)

Examples:
  $0                       Run the script normally
  $0 --dry-run            Test run without making changes
  
  # With environment variables
  DESTINATION_ACCOUNT_IDS=("123456789012" "210987654321") $0
  SKIP_INSTANCES=("i-1234567890abcdef0") $0 --dry-run

Configuration required:
  export DESTINATION_ACCOUNT_IDS=("123456789012" "210987654321")
  export AWS_PROFILE="my-source-profile"  # Optional
  export AWS_REGION="us-east-1"          # Optional

EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--dry-run)
            DRY_RUN=true
            warn "Running in DRY RUN mode - no actual changes will be made"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1"
            ;;
    esac
done

# Configuration validation
if [[ ${#DESTINATION_ACCOUNT_IDS[@]} -eq 0 ]]; then
    echo
    error "Please configure DESTINATION_ACCOUNT_IDS before running.
    
Example configuration:
export DESTINATION_ACCOUNT_IDS=(\"123456789012\" \"210987654321\")

Then run: $0"
fi

# Run main function
main 