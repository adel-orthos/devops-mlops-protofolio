# Multi-stage build for optimized production image
FROM python:3.12-slim as base

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install system dependencies for Playwright and document processing
RUN apt-get update && apt-get install -y \
    # Browser dependencies
    chromium \
    chromium-driver \
    libnss3 \
    libnspr4 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libcups2 \
    libdrm2 \
    libdbus-1-3 \
    libxkbcommon0 \
    libatspi2.0-0 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libgbm1 \
    libpango-1.0-0 \
    libcairo2 \
    libasound2 \
    # Document processing tools
    poppler-utils \
    # Build tools
    gcc \
    g++ \
    # Utilities
    curl \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Create non-root user for security
RUN groupadd -r crawler && useradd -r -g crawler -u 1000 crawler

# Set working directory
WORKDIR /app

# Copy requirements first to leverage Docker cache
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Install Playwright browsers
RUN playwright install chrome && \
    playwright install chromium && \
    playwright install-deps chrome

# Production stage
FROM python:3.12-slim as production

# Copy system dependencies from base stage
COPY --from=base /usr/bin/chromium* /usr/bin/
COPY --from=base /usr/lib/x86_64-linux-gnu/ /usr/lib/x86_64-linux-gnu/
COPY --from=base /usr/share/chromium/ /usr/share/chromium/
COPY --from=base /usr/bin/poppler* /usr/bin/

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/home/crawler/.local/bin:$PATH" \
    CHROME_BIN=/usr/bin/chromium \
    CHROME_PATH=/usr/bin/chromium \
    PLAYWRIGHT_BROWSERS_PATH=/home/crawler/.cache/ms-playwright

# Create non-root user
RUN groupadd -r crawler && useradd -r -g crawler -u 1000 crawler

# Set working directory
WORKDIR /app

# Copy Python dependencies from base stage
COPY --from=base /usr/local/lib/python3.12/site-packages/ /usr/local/lib/python3.12/site-packages/
COPY --from=base /usr/local/bin/ /usr/local/bin/

# Copy Playwright browsers
COPY --from=base /root/.cache/ms-playwright/ /home/crawler/.cache/ms-playwright/

# Copy application code
COPY --chown=crawler:crawler . .

# Create necessary directories and set permissions
RUN mkdir -p /app/logs /app/temp /home/crawler/.cache && \
    chown -R crawler:crawler /app /home/crawler/.cache

# Switch to non-root user
USER crawler

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "import asyncio; print('Crawler container healthy')" || exit 1

# Default command
CMD ["python", "crawler.py", "--config", "config/prod.yaml"]

# Development stage with debugging tools
FROM production as development

USER root

# Install development dependencies
RUN apt-get update && apt-get install -y \
    vim \
    curl \
    htop \
    && rm -rf /var/lib/apt/lists/*

# Install development Python packages
COPY requirements-dev.txt .
RUN pip install --no-cache-dir -r requirements-dev.txt

USER crawler

# Development command with debugging
CMD ["python", "-m", "debugpy", "--listen", "0.0.0.0:5678", "--wait-for-client", "crawler.py", "--config", "config/dev.yaml"] 