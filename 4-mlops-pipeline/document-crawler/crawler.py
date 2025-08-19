#!/usr/bin/env python3
"""
Production Document Crawler
Scalable web crawler for document ingestion with cloud integration
"""

import asyncio
import json
import logging
import os
import time
from datetime import datetime
from typing import Dict, List, Optional, Set
from urllib.parse import urljoin, urlparse
import hashlib
import aiohttp
import boto3
from botocore.exceptions import ClientError
from playwright.async_api import async_playwright, Browser, Page
import yaml
from dataclasses import dataclass
from pathlib import Path

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

@dataclass
class CrawlConfig:
    """Configuration for crawler instance"""
    name: str
    start_urls: List[str]
    allowed_domains: List[str]
    max_depth: int = 3
    max_pages: int = 1000
    delay_between_requests: float = 1.0
    concurrent_requests: int = 10
    document_extensions: List[str] = None
    exclude_patterns: List[str] = None
    s3_bucket: str = None
    sqs_queue_url: str = None
    
    def __post_init__(self):
        if self.document_extensions is None:
            self.document_extensions = ['.pdf', '.docx', '.doc', '.txt', '.md', '.html']
        if self.exclude_patterns is None:
            self.exclude_patterns = ['login', 'admin', 'auth', 'private']

class DocumentCrawler:
    """Production-ready document crawler with cloud integration"""
    
    def __init__(self, config: CrawlConfig):
        self.config = config
        self.visited_urls: Set[str] = set()
        self.processed_documents: Set[str] = set()
        self.failed_urls: Set[str] = set()
        self.session: Optional[aiohttp.ClientSession] = None
        self.browser: Optional[Browser] = None
        self.page: Optional[Page] = None
        
        # AWS clients
        self.s3_client = boto3.client('s3')
        self.sqs_client = boto3.client('sqs')
        self.cloudwatch = boto3.client('cloudwatch')
        
        # Metrics
        self.start_time = time.time()
        self.pages_crawled = 0
        self.documents_found = 0
        self.documents_processed = 0
        self.errors_count = 0
        
    async def __aenter__(self):
        """Async context manager entry"""
        await self.initialize()
        return self
        
    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """Async context manager exit"""
        await self.cleanup()
        
    async def initialize(self):
        """Initialize crawler resources"""
        logger.info(f"Initializing crawler for {self.config.name}")
        
        # Initialize HTTP session
        timeout = aiohttp.ClientTimeout(total=30)
        self.session = aiohttp.ClientSession(timeout=timeout)
        
        # Initialize Playwright browser
        playwright = await async_playwright().start()
        self.browser = await playwright.chromium.launch(
            headless=True,
            args=[
                '--no-sandbox',
                '--disable-dev-shm-usage',
                '--disable-gpu',
                '--disable-features=VizDisplayCompositor'
            ]
        )
        
        # Create a persistent page
        self.page = await self.browser.new_page()
        await self.page.set_extra_http_headers({
            'User-Agent': 'DocumentCrawler/1.0 (+https://example.com/bot)'
        })
        
        logger.info("Crawler initialized successfully")
        
    async def cleanup(self):
        """Clean up resources"""
        logger.info("Cleaning up crawler resources")
        
        if self.session:
            await self.session.close()
            
        if self.page:
            await self.page.close()
            
        if self.browser:
            await self.browser.close()
            
        # Publish final metrics
        await self.publish_metrics()
        
    async def crawl(self) -> Dict:
        """Main crawling method"""
        logger.info(f"Starting crawl for {self.config.name}")
        
        try:
            # Process each start URL
            tasks = []
            for url in self.config.start_urls:
                task = asyncio.create_task(
                    self.crawl_url(url, depth=0)
                )
                tasks.append(task)
                
            # Wait for all tasks to complete
            await asyncio.gather(*tasks, return_exceptions=True)
            
            # Generate summary report
            summary = await self.generate_summary()
            logger.info(f"Crawl completed: {summary}")
            
            return summary
            
        except Exception as e:
            logger.error(f"Crawl failed: {str(e)}")
            self.errors_count += 1
            raise
            
    async def crawl_url(self, url: str, depth: int = 0):
        """Crawl a single URL and extract documents/links"""
        
        # Check depth and visited status
        if depth > self.config.max_depth:
            return
            
        if url in self.visited_urls:
            return
            
        # Check if we've reached max pages
        if len(self.visited_urls) >= self.config.max_pages:
            return
            
        # Skip excluded patterns
        if any(pattern in url.lower() for pattern in self.config.exclude_patterns):
            logger.debug(f"Skipping excluded URL: {url}")
            return
            
        # Check domain restrictions
        parsed_url = urlparse(url)
        if not any(domain in parsed_url.netloc for domain in self.config.allowed_domains):
            logger.debug(f"Skipping URL outside allowed domains: {url}")
            return
            
        self.visited_urls.add(url)
        logger.info(f"Crawling URL (depth {depth}): {url}")
        
        try:
            # Navigate to page with Playwright
            await self.page.goto(url, wait_until='networkidle', timeout=30000)
            self.pages_crawled += 1
            
            # Extract document links
            document_links = await self.extract_document_links()
            for doc_link in document_links:
                absolute_url = urljoin(url, doc_link)
                await self.process_document(absolute_url)
                
            # Extract page links for further crawling
            if depth < self.config.max_depth:
                page_links = await self.extract_page_links()
                
                # Create tasks for concurrent crawling
                tasks = []
                for link in page_links[:self.config.concurrent_requests]:
                    absolute_url = urljoin(url, link)
                    task = asyncio.create_task(
                        self.crawl_url(absolute_url, depth + 1)
                    )
                    tasks.append(task)
                    
                # Wait between batches
                await asyncio.sleep(self.config.delay_between_requests)
                
                # Process batch
                if tasks:
                    await asyncio.gather(*tasks, return_exceptions=True)
                    
        except Exception as e:
            logger.error(f"Error crawling {url}: {str(e)}")
            self.failed_urls.add(url)
            self.errors_count += 1
            
    async def extract_document_links(self) -> List[str]:
        """Extract document links from current page"""
        try:
            # Get all links with document extensions
            links = []
            
            # Extract from href attributes
            href_links = await self.page.evaluate('''
                () => {
                    const links = Array.from(document.querySelectorAll('a[href]'));
                    return links.map(link => link.href);
                }
            ''')
            
            # Filter for document extensions
            for link in href_links:
                if any(link.lower().endswith(ext) for ext in self.config.document_extensions):
                    links.append(link)
                    
            # Extract from embedded documents (iframes, objects, etc.)
            embedded_docs = await self.page.evaluate('''
                () => {
                    const elements = Array.from(document.querySelectorAll('iframe[src], object[data], embed[src]'));
                    return elements.map(el => el.src || el.data);
                }
            ''')
            
            for doc in embedded_docs:
                if doc and any(doc.lower().endswith(ext) for ext in self.config.document_extensions):
                    links.append(doc)
                    
            self.documents_found += len(links)
            logger.debug(f"Found {len(links)} document links")
            
            return links
            
        except Exception as e:
            logger.error(f"Error extracting document links: {str(e)}")
            return []
            
    async def extract_page_links(self) -> List[str]:
        """Extract page links for further crawling"""
        try:
            links = await self.page.evaluate('''
                () => {
                    const links = Array.from(document.querySelectorAll('a[href]'));
                    return links
                        .map(link => link.href)
                        .filter(href => href && !href.startsWith('mailto:') && !href.startsWith('tel:'))
                        .slice(0, 50); // Limit to prevent memory issues
                }
            ''')
            
            logger.debug(f"Found {len(links)} page links")
            return links
            
        except Exception as e:
            logger.error(f"Error extracting page links: {str(e)}")
            return []
            
    async def process_document(self, url: str):
        """Process a document URL - download and queue for processing"""
        
        if url in self.processed_documents:
            return
            
        self.processed_documents.add(url)
        logger.info(f"Processing document: {url}")
        
        try:
            # Generate unique key for document
            url_hash = hashlib.md5(url.encode()).hexdigest()
            document_key = f"documents/{self.config.name}/{url_hash}"
            
            # Download document content
            async with self.session.get(url) as response:
                if response.status == 200:
                    content = await response.read()
                    content_type = response.headers.get('content-type', 'application/octet-stream')
                    
                    # Upload to S3 if configured
                    if self.config.s3_bucket:
                        await self.upload_to_s3(
                            content, 
                            document_key, 
                            content_type,
                            url
                        )
                        
                    # Send processing message to SQS if configured
                    if self.config.sqs_queue_url:
                        await self.send_processing_message({
                            'document_key': document_key,
                            'source_url': url,
                            'content_type': content_type,
                            'size': len(content),
                            'crawler_name': self.config.name,
                            'timestamp': datetime.now().isoformat()
                        })
                        
                    self.documents_processed += 1
                    logger.info(f"Successfully processed document: {url}")
                    
                else:
                    logger.warning(f"Failed to download document {url}: HTTP {response.status}")
                    
        except Exception as e:
            logger.error(f"Error processing document {url}: {str(e)}")
            self.errors_count += 1
            
    async def upload_to_s3(self, content: bytes, key: str, content_type: str, source_url: str):
        """Upload document content to S3"""
        try:
            self.s3_client.put_object(
                Bucket=self.config.s3_bucket,
                Key=key,
                Body=content,
                ContentType=content_type,
                Metadata={
                    'source-url': source_url,
                    'crawler-name': self.config.name,
                    'upload-timestamp': datetime.now().isoformat()
                },
                ServerSideEncryption='AES256'
            )
            logger.debug(f"Uploaded to S3: s3://{self.config.s3_bucket}/{key}")
            
        except ClientError as e:
            logger.error(f"Failed to upload to S3: {str(e)}")
            raise
            
    async def send_processing_message(self, message: Dict):
        """Send message to SQS queue for document processing"""
        try:
            self.sqs_client.send_message(
                QueueUrl=self.config.sqs_queue_url,
                MessageBody=json.dumps(message),
                MessageAttributes={
                    'crawler_name': {
                        'StringValue': self.config.name,
                        'DataType': 'String'
                    },
                    'document_type': {
                        'StringValue': message.get('content_type', 'unknown'),
                        'DataType': 'String'
                    }
                }
            )
            logger.debug(f"Sent SQS message for document: {message['document_key']}")
            
        except ClientError as e:
            logger.error(f"Failed to send SQS message: {str(e)}")
            raise
            
    async def publish_metrics(self):
        """Publish metrics to CloudWatch"""
        try:
            runtime = time.time() - self.start_time
            
            metrics = [
                {
                    'MetricName': 'Pagescrawled',
                    'Value': self.pages_crawled,
                    'Unit': 'Count',
                    'Dimensions': [
                        {'Name': 'CrawlerName', 'Value': self.config.name}
                    ]
                },
                {
                    'MetricName': 'DocumentsFound',
                    'Value': self.documents_found,
                    'Unit': 'Count',
                    'Dimensions': [
                        {'Name': 'CrawlerName', 'Value': self.config.name}
                    ]
                },
                {
                    'MetricName': 'DocumentsProcessed',
                    'Value': self.documents_processed,
                    'Unit': 'Count',
                    'Dimensions': [
                        {'Name': 'CrawlerName', 'Value': self.config.name}
                    ]
                },
                {
                    'MetricName': 'ErrorsCount',
                    'Value': self.errors_count,
                    'Unit': 'Count',
                    'Dimensions': [
                        {'Name': 'CrawlerName', 'Value': self.config.name}
                    ]
                },
                {
                    'MetricName': 'CrawlDuration',
                    'Value': runtime,
                    'Unit': 'Seconds',
                    'Dimensions': [
                        {'Name': 'CrawlerName', 'Value': self.config.name}
                    ]
                }
            ]
            
            self.cloudwatch.put_metric_data(
                Namespace='MLOps/DocumentCrawler',
                MetricData=metrics
            )
            
            logger.info("Published metrics to CloudWatch")
            
        except Exception as e:
            logger.error(f"Failed to publish metrics: {str(e)}")
            
    async def generate_summary(self) -> Dict:
        """Generate crawl summary report"""
        runtime = time.time() - self.start_time
        
        return {
            'crawler_name': self.config.name,
            'start_time': datetime.fromtimestamp(self.start_time).isoformat(),
            'end_time': datetime.now().isoformat(),
            'runtime_seconds': round(runtime, 2),
            'pages_crawled': self.pages_crawled,
            'documents_found': self.documents_found,
            'documents_processed': self.documents_processed,
            'errors_count': self.errors_count,
            'failed_urls': list(self.failed_urls),
            'success_rate': round((self.documents_processed / max(self.documents_found, 1)) * 100, 2)
        }

def load_config(config_path: str) -> CrawlConfig:
    """Load crawler configuration from YAML file"""
    try:
        with open(config_path, 'r') as f:
            config_data = yaml.safe_load(f)
            
        return CrawlConfig(**config_data)
        
    except Exception as e:
        logger.error(f"Failed to load config: {str(e)}")
        raise

async def main():
    """Main entry point for crawler"""
    import argparse
    
    parser = argparse.ArgumentParser(description='Production Document Crawler')
    parser.add_argument('--config', required=True, help='Path to configuration file')
    parser.add_argument('--log-level', default='INFO', help='Logging level')
    
    args = parser.parse_args()
    
    # Set log level
    logging.getLogger().setLevel(getattr(logging, args.log_level.upper()))
    
    # Load configuration
    config = load_config(args.config)
    
    # Run crawler
    async with DocumentCrawler(config) as crawler:
        summary = await crawler.crawl()
        
        # Print summary
        print("\n" + "="*50)
        print("CRAWL SUMMARY")
        print("="*50)
        for key, value in summary.items():
            print(f"{key}: {value}")
        print("="*50)

if __name__ == "__main__":
    asyncio.run(main()) 