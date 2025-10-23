# SpineSurgeryProject 

A modular Flask + Postgres application for managing biomedical/clinical study data.  
The system is designed with **clean architecture**, **scalability**, and **future‑proofing** in mind.  

It includes:
- A **Flask API** for ingesting and serving data.
- A **Postgres schema manager** (`db_runner.py`) for initializing and refreshing compliance views.
- A **database abstraction layer** (`database.py`) for programmatic inserts and queries.

---

## Project Structure
SpineSurgeryProject/
│
├── app.py                # Flask entry point (app factory)
├── config.py             # Centralized configuration
├── requirements.txt      # Python dependencies
├── .gitignore            # Files to exclude from Git
│
├── /routes               # API endpoints (blueprints)
│   └── upload.py
│
├── /services             # Business logic layer
│   ├── s3_service.py     # AWS S3 upload logic
│   └── db_service.py     # Database insert logic
│
├── /models               # Database schema (ORM models for Flask)
│   └── data_record.py
│
├── db_runner.py          # One‑file Postgres manager (CLI for schema, refresh, dashboard)
└── database.py           # Connection‑pooled DB abstraction class (programmatic inserts/queries)


---

## Key Components

### **1. `app.py`**
- Application factory (`create_app()`).
- Loads config, initializes DB, registers blueprints.
- Defines root route (`/`) and runs the app.

### **2. `config.py`**
- Centralized configuration.
- Reads environment variables for DB URI, AWS credentials, S3 bucket.

### **3. `/routes/upload.py`**
- Defines `/api/upload` endpoint.
- Accepts JSON payload (`filename`, `content`).
- Calls services to upload to S3 and save metadata in DB.
- Returns JSON response with success + S3 link.

### **4. `/services/s3_service.py`**
- Handles AWS S3 uploads via `boto3`.
- `upload_to_s3(content, filename)` returns S3 URL.

### **5. `/services/db_service.py`**
- Handles DB interactions.
- `save_record(filename, s3_link)` inserts metadata into DB.

### **6. `/models/data_record.py`**
- Defines SQLAlchemy model `DataRecord`.
- Columns: `id`, `filename`, `s3_link`.

---

## Database Utilities

### **7. `db_runner.py` (CLI Manager)**
A one‑file Postgres manager for schema + compliance dashboards.

**Commands:**
- `init` → Create tables, indexes, materialized views, compliance views.
- `refresh` → Refresh presence materialized views.
- `seed` → Insert demo participants (`P0001`, `P0002`).
- `insert-demo` → Insert random demo time‑series data for last 7 days.
- `dashboard` → Print compliance dashboard (`v_compliance_dashboard`).
- `exec-file <path>` → Run arbitrary `.sql` file.

**Schema Includes:**
- Tables: `participants`, `daily_survey`, `accelerometer`, `gyroscope`, `heart_rate`. (insert more after)
- Materialized views: `mv_*_daily_presence`.
- Compliance views: `v_*_compliance`.
- Dashboard: `v_compliance_dashboard`.


Intended Data Flow
- Client → Flask API (/api/upload).
- Route → Services (S3 + DB).
- Services → Models (DataRecord).
- Database → Postgres (raw tables).
- db_runner.py manages schema + compliance views.
- database.py provides programmatic access for inserts/queries.

Setup Instructions
# 1. Clone the repository
git clone https://github.com/<your-username>/SpineSurgeryProject.git
cd SpineSurgeryProject

# 2. Create and activate a virtual environment
python -m venv venv

# On Mac/Linux:
source venv/bin/activate

# On Windows (PowerShell):
venv\Scripts\Activate.ps1

# 3. Install dependencies
pip install -r requirements.txt

# 4. Set environment variables (recommended: create a .env file in project root)
# Example .env contents:
# DATABASE_URL=postgresql://user:pass@localhost:5432/spine_study
# AWS_ACCESS_KEY_ID=your_key
# AWS_SECRET_ACCESS_KEY=your_secret
# S3_BUCKET=your_bucket

# 5. Initialize the database schema
python db_runner.py init

# 6. (Optional) Seed demo participants
python db_runner.py seed

# 7. (Optional) Insert demo data and refresh materialized views
python db_runner.py insert-demo

# 8. Run the Flask app
python app.py

# 9. Test the upload endpoint
curl -X POST http://127.0.0.1:5000/api/upload \
     -H "Content-Type: application/json" \
     -d '{"filename": "scan123.json", "content": "example data"}'