@dashboard_api.route("/presence/accel/<external_id>")
def presence_accel(external_id):
    db = current_app.config["DB"]
    data = db.get_presence_counts("mv_accel_daily_presence", external_id, 7)
    return jsonify([{"day": d, "count": c} for d, c in data])

@dashboard_api.route("/presence/gyro/<external_id>")
def presence_gyro(external_id):
    db = current_app.config["DB"]
    data = db.get_presence_counts("mv_gyro_daily_presence", external_id, 7)
    return jsonify([{"day": d, "count": c} for d, c in data])

@dashboard_api.route("/presence/hr/<external_id>")
def presence_hr(external_id):
    db = current_app.config["DB"]
    data = db.get_presence_counts("mv_hr_daily_presence", external_id, 7)
    return jsonify([{"day": d, "count": c} for d, c in data])

@dashboard_api.route("/presence/survey/<external_id>")
def presence_survey(external_id):
    db = current_app.config["DB"]
    data = db.get_presence_counts("mv_survey_daily_presence", external_id, 7)
    return jsonify([{"day": d, "count": c} for d, c in data])
