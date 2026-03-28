#!/bin/bash

# run_fitbit_scraper.sh
# chmod +x run_scrap_fitbit_data.sh
# crontab -e
# 0 */12 * * * /home/ubuntu/code/sma-fitbit/run_scrap_fitbit_data.sh

cd "/home/ubuntu/code/scripts/"
echo "Current working directory: $(pwd)"

# Define the path to your virtual environment
VENV_PATH="/home/ubuntu/code/SpineSurveyVenv" # Assuming 'venv' is in the same directory as the script

# Define the path to your Python script
PYTHON_SCRIPT="/home/ubuntu/code/scripts/sendAPNSNotification2.py" # Replace with your actual script name

# Activate the virtual environment
source "$VENV_PATH/bin/activate"

# pip install -r requirements.txt

# Run the Python script using the virtual environment's Python interpreter
python "$PYTHON_SCRIPT"

# Deactivate the virtual environment (optional, but good practice if not exiting the shell)
deactivate

cd ~