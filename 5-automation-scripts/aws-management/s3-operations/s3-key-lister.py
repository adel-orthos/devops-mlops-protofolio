#!/usr/bin/env python3
"""
S3 Key Lister - Production S3 Object Discovery Tool
Efficiently list and filter S3 objects based on various criteria
Used for large-scale S3 auditing and data management operations
"""

import boto3
import json
import csv
import argparse
import logging
from datetime import datetime, timedelta
from typing import List, Dict, Optional, Generator
from botocore.exceptions import ClientError, NoCredentialsError
import sys
import os

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class S3KeyLister:
    """Production-ready S3 object lister with filtering and export capabilities"""
    
    def __init__(self, region: str = 'us-east-1', profile: Optional[str] = None):
        """Initialize S3 client with optional profile"""
        try:
            session = boto3.Session(profile_name=profile) if profile else boto3.Session()
            self.s3_client = session.client('s3', region_name=region)
            self.region = region
            self.profile = profile
            
            # Test credentials
            self.s3_client.list_buckets()
            logger.info(f"Initialized S3 client for region: {region}")
            if profile:
                logger.info(f"Using AWS profile: {profile}")
                
        except NoCredentialsError:
            logger.error("AWS credentials not found or invalid")
            sys.exit(1)
        except ClientError as e:
            logger.error(f"Failed to initialize S3 client: {e}")
            sys.exit(1)
    
    def list_objects_by_date_range(
        self, 
        bucket_name: str, 
        start_year: int, 
        end_year: int,
        prefix: str = "",
        extensions: Optional[List[str]] = None
    ) -> List[Dict]:
        """
        List S3 objects filtered by date range in path structure
        Optimized for large buckets with year-based organization
        """
        logger.info(f"Listing objects from {bucket_name} for years {start_year}-{end_year}")
        
        if extensions is None:
            extensions = ['.pdf', '.docx', '.txt', '.json', '.csv']
        
        objects = []
        
        try:
            # Use paginator for efficient handling of large buckets
            paginator = self.s3_client.get_paginator('list_objects_v2')
            
            for year in range(start_year, end_year + 1):
                year_prefix = f"{prefix}{year}/" if prefix else f"{year}/"
                logger.info(f"Processing year: {year}")
                
                page_iterator = paginator.paginate(
                    Bucket=bucket_name,
                    Prefix=year_prefix
                )
                
                year_count = 0
                for page in page_iterator:
                    if 'Contents' not in page:
                        continue
                        
                    for obj in page['Contents']:
                        key = obj['Key']
                        
                        # Parse path structure to extract year
                        path_parts = key.split('/')
                        if len(path_parts) > 1 and path_parts[-2].isdigit():
                            object_year = int(path_parts[-2])
                            if start_year <= object_year <= end_year:
                                # Filter by extensions if specified
                                if not extensions or any(key.lower().endswith(ext.lower()) for ext in extensions):
                                    objects.append({
                                        'Key': key,
                                        'Size': obj['Size'],
                                        'LastModified': obj['LastModified'],
                                        'StorageClass': obj.get('StorageClass', 'STANDARD'),
                                        'Year': object_year,
                                        'Extension': self._get_file_extension(key)
                                    })
                                    year_count += 1
                
                logger.info(f"Found {year_count} objects for year {year}")
        
        except ClientError as e:
            logger.error(f"Error listing objects from bucket {bucket_name}: {e}")
            raise
        
        logger.info(f"Total objects found: {len(objects)}")
        return objects
    
    def list_objects_by_prefix_pattern(
        self,
        bucket_name: str,
        prefix_pattern: str,
        max_objects: Optional[int] = None
    ) -> Generator[Dict, None, None]:
        """
        Generator function to efficiently list objects by prefix pattern
        Useful for processing large datasets without loading everything into memory
        """
        logger.info(f"Listing objects from {bucket_name} with prefix: {prefix_pattern}")
        
        try:
            paginator = self.s3_client.get_paginator('list_objects_v2')
            page_iterator = paginator.paginate(
                Bucket=bucket_name,
                Prefix=prefix_pattern
            )
            
            object_count = 0
            for page in page_iterator:
                if 'Contents' not in page:
                    continue
                    
                for obj in page['Contents']:
                    if max_objects and object_count >= max_objects:
                        logger.info(f"Reached maximum object limit: {max_objects}")
                        return
                    
                    yield {
                        'Key': obj['Key'],
                        'Size': obj['Size'],
                        'LastModified': obj['LastModified'],
                        'StorageClass': obj.get('StorageClass', 'STANDARD'),
                        'ETag': obj['ETag'].strip('"'),
                        'Extension': self._get_file_extension(obj['Key'])
                    }
                    object_count += 1
            
            logger.info(f"Processed {object_count} objects")
            
        except ClientError as e:
            logger.error(f"Error listing objects: {e}")
            raise
    
    def get_bucket_statistics(self, bucket_name: str, prefix: str = "") -> Dict:
        """
        Generate comprehensive bucket statistics
        Useful for capacity planning and cost analysis
        """
        logger.info(f"Generating statistics for bucket: {bucket_name}")
        
        stats = {
            'bucket_name': bucket_name,
            'prefix': prefix,
            'total_objects': 0,
            'total_size_bytes': 0,
            'storage_classes': {},
            'extensions': {},
            'size_distribution': {
                'small_files': 0,      # < 1MB
                'medium_files': 0,     # 1MB - 100MB
                'large_files': 0       # > 100MB
            },
            'oldest_object': None,
            'newest_object': None,
            'generated_at': datetime.now().isoformat()
        }
        
        try:
            paginator = self.s3_client.get_paginator('list_objects_v2')
            page_iterator = paginator.paginate(
                Bucket=bucket_name,
                Prefix=prefix
            )
            
            for page in page_iterator:
                if 'Contents' not in page:
                    continue
                    
                for obj in page['Contents']:
                    stats['total_objects'] += 1
                    size = obj['Size']
                    stats['total_size_bytes'] += size
                    
                    # Storage class distribution
                    storage_class = obj.get('StorageClass', 'STANDARD')
                    stats['storage_classes'][storage_class] = stats['storage_classes'].get(storage_class, 0) + 1
                    
                    # Extension distribution
                    ext = self._get_file_extension(obj['Key'])
                    stats['extensions'][ext] = stats['extensions'].get(ext, 0) + 1
                    
                    # Size distribution
                    if size < 1024 * 1024:  # < 1MB
                        stats['size_distribution']['small_files'] += 1
                    elif size < 100 * 1024 * 1024:  # < 100MB
                        stats['size_distribution']['medium_files'] += 1
                    else:
                        stats['size_distribution']['large_files'] += 1
                    
                    # Track oldest and newest objects
                    last_modified = obj['LastModified']
                    if stats['oldest_object'] is None or last_modified < stats['oldest_object']:
                        stats['oldest_object'] = last_modified
                    if stats['newest_object'] is None or last_modified > stats['newest_object']:
                        stats['newest_object'] = last_modified
            
            # Convert datetime objects to ISO format for JSON serialization
            if stats['oldest_object']:
                stats['oldest_object'] = stats['oldest_object'].isoformat()
            if stats['newest_object']:
                stats['newest_object'] = stats['newest_object'].isoformat()
            
            # Calculate human-readable sizes
            stats['total_size_human'] = self._format_bytes(stats['total_size_bytes'])
            
            logger.info(f"Statistics generated: {stats['total_objects']} objects, {stats['total_size_human']}")
            return stats
            
        except ClientError as e:
            logger.error(f"Error generating statistics: {e}")
            raise
    
    def export_to_csv(self, objects: List[Dict], filename: str):
        """Export object list to CSV file"""
        logger.info(f"Exporting {len(objects)} objects to CSV: {filename}")
        
        if not objects:
            logger.warning("No objects to export")
            return
        
        fieldnames = ['Key', 'Size', 'LastModified', 'StorageClass', 'Extension']
        if 'Year' in objects[0]:
            fieldnames.append('Year')
        
        try:
            with open(filename, 'w', newline='', encoding='utf-8') as csvfile:
                writer = csv.DictWriter(csvfile, fieldnames=fieldnames)
                writer.writeheader()
                
                for obj in objects:
                    # Format datetime for CSV
                    if isinstance(obj.get('LastModified'), datetime):
                        obj['LastModified'] = obj['LastModified'].isoformat()
                    writer.writerow(obj)
            
            logger.info(f"CSV export completed: {filename}")
            
        except Exception as e:
            logger.error(f"Error exporting to CSV: {e}")
            raise
    
    def export_to_json(self, data: Dict, filename: str):
        """Export data to JSON file with pretty formatting"""
        logger.info(f"Exporting data to JSON: {filename}")
        
        try:
            with open(filename, 'w', encoding='utf-8') as jsonfile:
                json.dump(data, jsonfile, indent=2, default=str)
            
            logger.info(f"JSON export completed: {filename}")
            
        except Exception as e:
            logger.error(f"Error exporting to JSON: {e}")
            raise
    
    def find_duplicate_objects(self, bucket_name: str, prefix: str = "") -> Dict[str, List[str]]:
        """
        Find potential duplicate objects based on size and ETag
        Useful for storage optimization and deduplication
        """
        logger.info(f"Finding duplicate objects in bucket: {bucket_name}")
        
        objects_by_etag = {}
        duplicates = {}
        
        try:
            for obj in self.list_objects_by_prefix_pattern(bucket_name, prefix):
                etag = obj['ETag']
                size = obj['Size']
                key = obj['Key']
                
                # Use ETag + Size as duplicate identifier
                duplicate_key = f"{etag}:{size}"
                
                if duplicate_key not in objects_by_etag:
                    objects_by_etag[duplicate_key] = []
                
                objects_by_etag[duplicate_key].append(key)
            
            # Find actual duplicates (more than one object with same ETag+Size)
            for duplicate_key, keys in objects_by_etag.items():
                if len(keys) > 1:
                    duplicates[duplicate_key] = keys
            
            logger.info(f"Found {len(duplicates)} sets of potential duplicates")
            return duplicates
            
        except ClientError as e:
            logger.error(f"Error finding duplicates: {e}")
            raise
    
    def _get_file_extension(self, key: str) -> str:
        """Extract file extension from S3 key"""
        if '.' in key:
            return '.' + key.split('.')[-1].lower()
        return 'no_extension'
    
    def _format_bytes(self, bytes_value: int) -> str:
        """Format bytes into human-readable format"""
        for unit in ['B', 'KB', 'MB', 'GB', 'TB']:
            if bytes_value < 1024.0:
                return f"{bytes_value:.2f} {unit}"
            bytes_value /= 1024.0
        return f"{bytes_value:.2f} PB"

def main():
    """Main CLI interface"""
    parser = argparse.ArgumentParser(
        description="S3 Key Lister - Production S3 object discovery and analysis tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # List PDFs from specific years
  %(prog)s --bucket my-bucket --start-year 1995 --end-year 2000 --extensions .pdf

  # Generate bucket statistics
  %(prog)s --bucket my-bucket --stats-only --output-json stats.json

  # Find duplicates
  %(prog)s --bucket my-bucket --find-duplicates --prefix documents/

  # Export to CSV with custom prefix
  %(prog)s --bucket my-bucket --prefix UNDANG-UNDANG/ --output-csv objects.csv
        """
    )
    
    parser.add_argument('--bucket', required=True, help='S3 bucket name')
    parser.add_argument('--prefix', default='', help='S3 key prefix to filter objects')
    parser.add_argument('--start-year', type=int, help='Start year for date range filtering')
    parser.add_argument('--end-year', type=int, help='End year for date range filtering')
    parser.add_argument('--extensions', nargs='+', help='File extensions to include (e.g., .pdf .docx)')
    parser.add_argument('--max-objects', type=int, help='Maximum number of objects to process')
    parser.add_argument('--region', default='us-east-1', help='AWS region')
    parser.add_argument('--profile', help='AWS profile to use')
    parser.add_argument('--output-csv', help='Export results to CSV file')
    parser.add_argument('--output-json', help='Export results to JSON file')
    parser.add_argument('--stats-only', action='store_true', help='Generate bucket statistics only')
    parser.add_argument('--find-duplicates', action='store_true', help='Find duplicate objects')
    parser.add_argument('--verbose', '-v', action='store_true', help='Enable verbose logging')
    
    args = parser.parse_args()
    
    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)
    
    # Initialize S3 lister
    lister = S3KeyLister(region=args.region, profile=args.profile)
    
    try:
        if args.stats_only:
            # Generate statistics only
            stats = lister.get_bucket_statistics(args.bucket, args.prefix)
            
            if args.output_json:
                lister.export_to_json(stats, args.output_json)
            else:
                print(json.dumps(stats, indent=2, default=str))
        
        elif args.find_duplicates:
            # Find duplicate objects
            duplicates = lister.find_duplicate_objects(args.bucket, args.prefix)
            
            if duplicates:
                print(f"Found {len(duplicates)} sets of potential duplicates:")
                for duplicate_key, keys in duplicates.items():
                    print(f"\nDuplicate set ({duplicate_key}):")
                    for key in keys:
                        print(f"  - {key}")
            else:
                print("No duplicates found")
        
        elif args.start_year and args.end_year:
            # List objects by date range
            objects = lister.list_objects_by_date_range(
                args.bucket, 
                args.start_year, 
                args.end_year,
                args.prefix,
                args.extensions
            )
            
            if args.output_csv:
                lister.export_to_csv(objects, args.output_csv)
            elif args.output_json:
                lister.export_to_json({'objects': objects}, args.output_json)
            else:
                for obj in objects:
                    print(obj['Key'])
        
        else:
            # List objects by prefix pattern
            objects = list(lister.list_objects_by_prefix_pattern(
                args.bucket, 
                args.prefix, 
                args.max_objects
            ))
            
            if args.output_csv:
                lister.export_to_csv(objects, args.output_csv)
            elif args.output_json:
                lister.export_to_json({'objects': objects}, args.output_json)
            else:
                for obj in objects:
                    print(obj['Key'])
    
    except KeyboardInterrupt:
        logger.info("Operation cancelled by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Operation failed: {e}")
        sys.exit(1)

if __name__ == "__main__":
    main() 