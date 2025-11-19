from flask import Blueprint, render_template

dashboard_page = Blueprint("dashboard_page", __name__)

@dashboard_page.route("/dashboard")
def dashboard():
    # You can pass variables into the template if needed
    
    return render_template("dashboard.html")
