#!/bin/bash

SCRIPT_DIR="/home/ubuntu/SpineSurgeryAI/backend/background_notification/notification_script"
VENV_PATH="/home/ubuntu/SpineSurgeryAI/.venv"
PYTHON_SCRIPT="$SCRIPT_DIR/sendAPNSNotification2.py"

cd "$SCRIPT_DIR"
echo "Current working directory: $(pwd)"

source "$VENV_PATH/bin/activate"
python "$PYTHON_SCRIPT"
deactivate