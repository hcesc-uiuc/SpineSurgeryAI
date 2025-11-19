# =====================================================
#   SpineSurgeryAI Full Production Image (Flask + Jupyter)
# =====================================================
FROM python:3.12-slim

# Prevent Python from buffering stdout/stderr
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# -----------------------------------------------------
# 1. Install OS-level build tools and libraries
# -----------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    libpq-dev \
    python3-dev \
    pandoc \
    git \
    texlive-xetex \
 && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------
# 2. Create non-root user and working directory
# -----------------------------------------------------
RUN useradd -m appuser
WORKDIR /app

# -----------------------------------------------------
# 3. Install dependencies
# -----------------------------------------------------
COPY requirements.txt .

# Make sure pip and wheel are current, then install everything
RUN pip install --upgrade pip setuptools wheel \
 && pip install --no-cache-dir -r requirements.txt \
 && pip install --no-cache-dir gunicorn

# -----------------------------------------------------
# 4. Copy application code
# -----------------------------------------------------
COPY . .

# -----------------------------------------------------
# 5. Switch to non-root user for safety
# -----------------------------------------------------
USER appuser

# -----------------------------------------------------
# 6. Expose port and healthcheck
# -----------------------------------------------------
EXPOSE 5000
HEALTHCHECK --interval=30s --timeout=5s --retries=5 \
  CMD curl -fsS http://localhost:5000/health || exit 1

CMD ["gunicorn", "-b", "0.0.0.0:5000", "-w", "2", "-k", "gthread", "--threads", "4", "wsgi:app"]
