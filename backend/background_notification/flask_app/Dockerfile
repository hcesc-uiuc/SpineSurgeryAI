# Use a slim Python base image
FROM python:3.9-slim-buster

# Set the working directory in the container
WORKDIR /app

# Copy the requirements file and install dependencies
COPY requirements.txt .
RUN pip install -r requirements.txt

# Copy the Flask application code
COPY . .

# Expose the port your Flask app runs on
EXPOSE 5000

# Command to run the Flask application when the container starts
CMD ["python", "app.py"]