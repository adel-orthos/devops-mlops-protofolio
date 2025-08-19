# Multi-stage build for ML crawler with Python and browser automation
FROM python:3.12-slim as base

# Set environment variables
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# Install system dependencies in one layer
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
    # Document processing
    poppler-utils \
    # Build tools (removed in final stage)
    gcc \
    g++ \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# Create non-root user
RUN groupadd -r crawler && useradd -r -g crawler -u 1000 crawler

# Set working directory
WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Install Playwright browsers (only Chrome for optimization)
RUN playwright install chrome && \
    playwright install-deps chrome

# ================================
# Production stage
# ================================
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
    # Browser configuration
    CHROME_BIN=/usr/bin/chromium \
    CHROME_PATH=/usr/bin/chromium \
    # Security
    PLAYWRIGHT_BROWSERS_PATH=/home/crawler/.cache/ms-playwright

# Create non-root user
RUN groupadd -r crawler && useradd -r -g crawler -u 1000 crawler

# Set working directory
WORKDIR /app

# Copy Python packages from base stage
COPY --from=base /usr/local/lib/python3.12/site-packages/ /usr/local/lib/python3.12/site-packages/
COPY --from=base /usr/local/bin/ /usr/local/bin/

# Copy Playwright browsers
COPY --from=base /root/.cache/ms-playwright/ /home/crawler/.cache/ms-playwright/

# Copy application code
COPY --chown=crawler:crawler . .

# Create necessary directories
RUN mkdir -p /app/logs /app/temp /home/crawler/.cache && \
    chown -R crawler:crawler /app /home/crawler/.cache

# Switch to non-root user
USER crawler

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD python -c "import requests; requests.get('http://localhost:8080/health', timeout=5)" || exit 1

# Expose port
EXPOSE 8080

# Default command
CMD ["python", "main.py"]

# ================================
# Development stage
# ================================
FROM production as development

USER root

# Install development dependencies
RUN apt-get update && apt-get install -y \
    curl \
    vim \
    htop \
    && rm -rf /var/lib/apt/lists/*

# Install development Python packages
COPY requirements-dev.txt .
RUN pip install --no-cache-dir -r requirements-dev.txt

USER crawler

# Override command for development
CMD ["python", "-m", "debugpy", "--listen", "0.0.0.0:5678", "--wait-for-client", "main.py"] 