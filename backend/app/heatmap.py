"""
heatmap.py — generates heatmap locally and generates compliance

TODO: add more description
"""

from datetime import datetime, timedelta, timezone
import pandas as pd
import altair as alt
import numpy as np
from typing import Optional

from database.database import DB


def generate_participant_heatmap(db: DB, external_id: str) -> Optional[str]:
    """Generate and return heatmap HTML for a single participant."""
    
    df_health = pd.DataFrame(db.get_table("ingestion_health"))
    df_parts = pd.DataFrame(db.get_table("participants"))
    
    if df_health.empty or df_parts.empty:
        return None
    
    # Add readable participant external ID
    df_health = df_health.merge(
        df_parts[["id", "external_id"]],
        left_on="participant_id",
        right_on="id",
        how="left"
    )
    
    # Filter to just this participant
    df_health = df_health[df_health["external_id"] == external_id]
    
    if df_health.empty:
        return None
    
    # Normalize timestamps and extract day + 15-minute slot index
    df_health["window_start"] = pd.to_datetime(df_health["window_start"])
    df_health["day"] = df_health["window_start"].dt.date
    df_health["slot_index"] = (
        df_health["window_start"].dt.hour * 4 +
        df_health["window_start"].dt.minute // 15
    ).astype(int)  # 0–95
    
    # Threshold for marking slot as "usable"
    GOOD_THRESHOLD = 80  # % expected
    df_health["good_window"] = df_health["pct_expected"] >= GOOD_THRESHOLD
    
    # build 96 slot grid
    participants = df_health["external_id"].unique()
    modalities = df_health["modality"].unique()
    days = df_health["day"].unique()
    slots = np.arange(96, dtype=int)
    
    base_grid = (
        pd.MultiIndex.from_product(
            [participants, modalities, days, slots],
            names=["external_id", "modality", "day", "slot_index"]
        )
        .to_frame(index=False)
    )
    
    # Actual ingestion windows aggregated to slots
    slot_data = (
        df_health
        .groupby(["external_id", "modality", "day", "slot_index"], as_index=False)
        .agg(
            good=("good_window", "max"),      # was there any good window in this slot?
            pct=("pct_expected", "mean")      # mean pct_expected for tooltip
        )
    )
    
    grid = base_grid.merge(
        slot_data,
        how="left",
        on=["external_id", "modality", "day", "slot_index"]
    )
    
    grid["good"] = grid["good"].fillna(False) # will be deprecated soon
    grid["pct"] = grid["pct"].fillna(0.0)
    
    # Convert day to datetime for Altair
    grid["day"] = pd.to_datetime(grid["day"])
    
    # Chart
    base_chart = (
        alt.Chart(grid)
        .mark_rect()
        .encode(
            x=alt.X(
                "slot_index:O",
                title="15-min Slots (0–95)",
                axis=alt.Axis(
                    labelAngle=0,
                    # Only label every 8th slot (~2 hours) to avoid clutter
                    labelExpr="datum.value % 8 == 0 ? datum.value : ''"
                )
            ),
            y=alt.Y("external_id:N", title="Participant"),
            color=alt.Color(
                "good:N",
                title="Good window",
                scale=alt.Scale(
                    domain=[False, True],
                    range=["#440154", "#FDE725"]  # purple = missing, yellow = good
                )
            ),
            tooltip=[
                "external_id",
                "modality",
                alt.Tooltip("day:T", title="Date"),
                alt.Tooltip("slot_index:Q", title="Slot (0–95)"),
                alt.Tooltip("good:N", title="Usable?"),
                alt.Tooltip("pct:Q", title="% expected", format=".1f")
            ]
        )
    ).properties(
        width=600,
        height=60
    )
    
    # ------------------------------
    # Facet by modality and day
    # ------------------------------
    heatmap = base_chart.facet(
        row=alt.Row("modality:N", title="Modality"),
        column=alt.Column("day:T", title="Day")
    ).properties(
        title=f"Valid Data for: {external_id}"
    )
    html = heatmap.to_html()
    stats = get_participant_compliance_stats(db, external_id)

    if stats:
        stats_html = f"""
        <div style="font-family: sans-serif; padding: 20px; background: #f5f5f5; margin-bottom: 20px;">
            <h2>Compliance Stats - {external_id} (Last 7 Days)</h2>
            <p><strong>Overall:</strong> {stats['percentage']}% ({stats['total_good_slots']} / {stats['total_possible_slots']} slots)</p>
            <ul>
        """
        for mod, data in stats['by_modality'].items():
            stats_html += f"<li><strong>{mod}:</strong> {data['percentage']}% ({data['good_slots']} / {data['total_slots']} slots)</li>"
        stats_html += "</ul></div>"
        
        html = html.replace("<body>", f"<body>{stats_html}")
    
    return html


# check logic!!
def get_participant_compliance_stats(db: DB, external_id: str) -> Optional[dict]:
    """Calculate upload compliance stats for last 7 days."""
    
    df_health = pd.DataFrame(db.get_table("ingestion_health"))
    df_parts = pd.DataFrame(db.get_table("participants"))
    
    if df_health.empty or df_parts.empty:
        return None
    
    df_health = df_health.merge(
        df_parts[["id", "external_id"]],
        left_on="participant_id",
        right_on="id",
        how="left"
    )
    
    df_health = df_health[df_health["external_id"] == external_id]
    
    if df_health.empty:
        return None
    
    df_health["window_start"] = pd.to_datetime(df_health["window_start"])
    df_health["day"] = df_health["window_start"].dt.date
    df_health["slot_index"] = (
        df_health["window_start"].dt.hour * 4 +
        df_health["window_start"].dt.minute // 15
    ).astype(int)
    
    # Filter to last 7 days
    from datetime import datetime, timedelta
    today = datetime.now().date()
    week_ago = today - timedelta(days=6)
    df_week = df_health[df_health["day"] >= week_ago]
    
    if df_week.empty:
        return {
            "external_id": external_id,
            "total_possible_slots": 7 * 96,
            "total_good_slots": 0,
            "percentage": 0.0,
            "by_modality": {}
        }
    
    GOOD_THRESHOLD = 80
    df_week["good_window"] = df_week["pct_expected"] >= GOOD_THRESHOLD
    
    modalities = df_week["modality"].unique()
    
    # Total possible = 7 days * 96 slots per day * number of modalities
    total_possible_per_modality = 7 * 96
    total_possible = total_possible_per_modality * len(modalities)
    
    # Count unique (day, slot, modality) combos with good data
    good_slots = df_week[df_week["good_window"]].groupby(
        ["modality", "day", "slot_index"]
    ).size().reset_index(name="count")
    
    total_good = len(good_slots)
    overall_pct = (total_good / total_possible * 100) if total_possible > 0 else 0
    
    # Per modality breakdown
    by_modality = {}
    for mod in modalities:
        mod_good = len(good_slots[good_slots["modality"] == mod])
        mod_pct = (mod_good / total_possible_per_modality * 100)
        by_modality[mod] = {
            "good_slots": mod_good,
            "total_slots": total_possible_per_modality,
            "percentage": round(mod_pct, 1)
        }
    
    return {
        "external_id": external_id,
        "total_possible_slots": total_possible,
        "total_good_slots": total_good,
        "percentage": round(overall_pct, 1),
        "by_modality": by_modality
    }

def generate_compliance_report(
    db: DB,
    external_id: Optional[str] = None,
    lookback_days: int = 100
) -> str:
    """
    Generate an HTML compliance report showing adherence data.
    
    If external_id is provided, generates a detailed report for that participant.
    If external_id is None, generates a summary table for all participants.
    
    Shows:
    - Total days enrolled
    - Data uploads in last X days
    - Last upload timestamp  
    - Visual strip: | for upload days, - for missing days
    - Compliance percentage by modality (accel, gyro, hr, survey)
    
    Args:
        db: Database instance
        external_id: Participant ID for individual report, or None for summary
        lookback_days: Number of days to look back for compliance calculation
    
    Returns:
        HTML string for the report
    """
    
    participants_df = pd.DataFrame(db.get_table("participants"))
    if participants_df.empty:
        return "<html><body><p>No participants found.</p></body></html>"
    
    today = datetime.now(timezone.utc).date()
    start_date = today - timedelta(days=lookback_days - 1)
    
    # Helper: get upload days for a participant/modality
    def get_upload_days(ext_id: str, modality: str) -> set:
        table_map = {"accel": "accelerometer", "gyro": "gyroscope", "hr": "heart_rate", "survey": "daily_survey"}
        table_name = table_map.get(modality)
        if not table_name:
            return set()
        
        pid = db.get_participant_id_if_exists(ext_id)
        if pid is None:
            return set()
        
        if modality == "survey":
            query = "SELECT DISTINCT survey_date::date as day FROM daily_survey WHERE participant_id = %s"
        else:
            query = f"SELECT DISTINCT ts::date as day FROM {table_name} WHERE participant_id = %s AND ts > '1970-01-02'"
        
        with db.temporary_database_connection() as conn, conn.cursor() as cur:
            cur.execute(query, (pid,))
            return {row[0] for row in cur.fetchall()}
    
    # Helper: get first/last upload timestamps
    def get_upload_bounds(ext_id: str) -> tuple:
        pid = db.get_participant_id_if_exists(ext_id)
        if pid is None:
            return None, None
        
        query = """
            SELECT MIN(first_ts), MAX(last_ts) FROM (
                SELECT MIN(ts) as first_ts, MAX(ts) as last_ts FROM accelerometer WHERE participant_id = %s AND ts > '1970-01-02'
                UNION ALL SELECT MIN(ts), MAX(ts) FROM gyroscope WHERE participant_id = %s AND ts > '1970-01-02'
                UNION ALL SELECT MIN(ts), MAX(ts) FROM heart_rate WHERE participant_id = %s AND ts > '1970-01-02'
                UNION ALL SELECT MIN(survey_date::timestamp with time zone), MAX(survey_date::timestamp with time zone) FROM daily_survey WHERE participant_id = %s
            ) sub
        """
        with db.temporary_database_connection() as conn, conn.cursor() as cur:
            cur.execute(query, (pid, pid, pid, pid))
            row = cur.fetchone()
            return (row[0], row[1]) if row else (None, None)
    
    # Helper: generate strip string
    def make_strip(upload_days: set) -> str:
        strip = []
        current = start_date
        while current <= today:
            strip.append("|" if current in upload_days else "-")
            current += timedelta(days=1)
        return "".join(strip)
    
    # Helper: format strip as colored HTML
    def strip_to_html(strip: str) -> str:
        return "".join(
            f'<span style="color:#28a745;font-weight:bold;">|</span>' if c == "|" 
            else f'<span style="color:#dc3545;">-</span>' 
            for c in strip
        )
    
    # Helper: calculate stats
    def calc_stats(upload_days: set) -> dict:
        total = lookback_days
        with_data = sum(1 for d in upload_days if start_date <= d <= today)
        pct = (with_data / total * 100) if total > 0 else 0
        return {"days": with_data, "total": total, "pct": round(pct, 1), "frac": f"{with_data}/{total} ({pct:.1f}%)"}
    
    # Helper: color based on percentage
    def pct_color(pct: float) -> str:
        if pct >= 80: return "#28a745"
        if pct >= 50: return "#ffc107"
        return "#dc3545"
    
    modalities = ["accel", "gyro", "hr", "survey"]
    mod_labels = {"accel": "Accelerometer", "gyro": "Gyroscope", "hr": "Heart Rate", "survey": "Survey"}
    
    # === INDIVIDUAL PARTICIPANT REPORT ===
    if external_id:
        if db.get_participant_id_if_exists(external_id) is None:
            return f"<html><body><p>Participant {external_id} not found.</p></body></html>"
        
        first_upload, last_upload = get_upload_bounds(external_id)
        total_enrolled = (today - first_upload.date()).days + 1 if first_upload else 0
        last_seen = last_upload.strftime("%b %d %Y") if last_upload else "Never"
        
        # Get data per modality
        mod_data = {}
        all_days = set()
        for mod in modalities:
            days = get_upload_days(external_id, mod)
            all_days.update(days)
            mod_data[mod] = {"days": days, "stats": calc_stats(days), "strip": make_strip(days)}
        
        combined_stats = calc_stats(all_days)
        combined_strip = make_strip(all_days)
        
        # Build modality rows
        mod_rows = ""
        for mod in modalities:
            d = mod_data[mod]
            color = pct_color(d["stats"]["pct"])
            mod_rows += f"""
            <tr>
                <td style="padding:8px;border:1px solid #ddd;">{mod_labels[mod]}</td>
                <td style="padding:8px;border:1px solid #ddd;color:{color};font-weight:bold;">{d["stats"]["frac"]}</td>
                <td style="padding:8px;border:1px solid #ddd;font-family:monospace;font-size:12px;letter-spacing:1px;">{strip_to_html(d["strip"])}</td>
            </tr>"""
        
        comb_color = pct_color(combined_stats["pct"])
        
        return f"""
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Compliance Report - {external_id}</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin:0; padding:20px; background:#f5f5f5; }}
        .container {{ max-width:900px; margin:0 auto; background:white; padding:30px; border-radius:8px; box-shadow:0 2px 4px rgba(0,0,0,0.1); }}
        h1 {{ color:#333; margin-bottom:5px; }}
        .subtitle {{ color:#666; margin-bottom:20px; }}
        .summary-grid {{ display:grid; grid-template-columns:repeat(4,1fr); gap:15px; margin-bottom:30px; }}
        .summary-card {{ background:#f8f9fa; padding:15px; border-radius:6px; text-align:center; }}
        .summary-card .value {{ font-size:24px; font-weight:bold; color:#333; }}
        .summary-card .label {{ font-size:12px; color:#666; margin-top:5px; }}
        table {{ width:100%; border-collapse:collapse; margin-top:20px; }}
        th {{ background:#e9ecef; padding:12px 8px; text-align:left; border:1px solid #ddd; font-weight:600; }}
        .legend {{ margin-top:20px; padding:15px; background:#f8f9fa; border-radius:6px; }}
        .footer {{ margin-top:30px; padding-top:20px; border-top:1px solid #eee; color:#666; font-size:12px; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>Adherence Report: {external_id}</h1>
        <p class="subtitle">Last {lookback_days} Days ({start_date.isoformat()} to {today.isoformat()})</p>
        
        <div class="summary-grid">
            <div class="summary-card"><div class="value">{total_enrolled}</div><div class="label">Total Days Enrolled</div></div>
            <div class="summary-card"><div class="value" style="color:{comb_color};">{combined_stats["pct"]}%</div><div class="label">Last {lookback_days} Days Compliance</div></div>
            <div class="summary-card"><div class="value">{combined_stats["days"]}/{combined_stats["total"]}</div><div class="label">Days with Any Data</div></div>
            <div class="summary-card"><div class="value" style="font-size:16px;">{last_seen}</div><div class="label">Last Seen</div></div>
        </div>
        
        <h2>Compliance by Modality</h2>
        <table>
            <thead>
                <tr>
                    <th style="width:150px;">Modality</th>
                    <th style="width:150px;">Last {lookback_days} Days</th>
                    <th>Upload Pattern (<span style="color:#28a745;">|</span> = data, <span style="color:#dc3545;">-</span> = missing)</th>
                </tr>
            </thead>
            <tbody>
                {mod_rows}
                <tr style="background:#f8f9fa;font-weight:bold;">
                    <td style="padding:8px;border:1px solid #ddd;">Combined (Any)</td>
                    <td style="padding:8px;border:1px solid #ddd;color:{comb_color};">{combined_stats["frac"]}</td>
                    <td style="padding:8px;border:1px solid #ddd;font-family:monospace;font-size:12px;letter-spacing:1px;">{strip_to_html(combined_strip)}</td>
                </tr>
            </tbody>
        </table>
        
        <div class="legend">
            <strong>Legend:</strong>
            <span style="color:#28a745;font-weight:bold;">|</span> = Data uploaded
            <span style="color:#dc3545;">-</span> = No data
            | Reading: Left = oldest day, Right = today
        </div>
        
        <div class="footer">
            <p>Report generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}</p>
            <p>First upload: {first_upload.isoformat() if first_upload else 'N/A'} | Last upload: {last_upload.isoformat() if last_upload else 'N/A'}</p>
        </div>
    </div>
</body>
</html>"""
    
    # === ALL PARTICIPANTS SUMMARY ===
    rows_html = ""
    for _, p in participants_df.iterrows():
        ext_id = p["external_id"]
        first_upload, last_upload = get_upload_bounds(ext_id)
        total_enrolled = (today - first_upload.date()).days + 1 if first_upload else 0
        last_seen = last_upload.strftime("%b %d %Y") if last_upload else "Never"
        
        all_days = set()
        for mod in modalities:
            all_days.update(get_upload_days(ext_id, mod))
        
        stats = calc_stats(all_days)
        strip = make_strip(all_days)
        color = pct_color(stats["pct"])
        
        rows_html += f"""
        <tr>
            <td style="padding:8px;border:1px solid #ddd;"><a href="?participant={ext_id}">{ext_id}</a></td>
            <td style="padding:8px;border:1px solid #ddd;text-align:center;">{total_enrolled}</td>
            <td style="padding:8px;border:1px solid #ddd;text-align:center;color:{color};font-weight:bold;">{stats["frac"]}</td>
            <td style="padding:8px;border:1px solid #ddd;text-align:center;">{last_seen}</td>
            <td style="padding:8px;border:1px solid #ddd;font-family:monospace;font-size:11px;letter-spacing:1px;">{strip_to_html(strip)}</td>
        </tr>"""
    
    return f"""
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Adherence Update - All Participants</title>
    <style>
        body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin:0; padding:20px; background:#f5f5f5; }}
        .container {{ max-width:1000px; margin:0 auto; background:white; padding:30px; border-radius:8px; box-shadow:0 2px 4px rgba(0,0,0,0.1); }}
        h1 {{ color:#333; margin-bottom:5px; }}
        .subtitle {{ color:#666; margin-bottom:20px; }}
        table {{ width:100%; border-collapse:collapse; }}
        th {{ background:#dc3545; color:white; padding:12px 8px; text-align:left; border:1px solid #c82333; }}
        tr:nth-child(even) {{ background:#f8f9fa; }}
        a {{ color:#007bff; text-decoration:none; }}
        a:hover {{ text-decoration:underline; }}
        .legend {{ margin-top:20px; padding:15px; background:#f8f9fa; border-radius:6px; }}
    </style>
</head>
<body>
    <div class="container">
        <h1>Adherence Update</h1>
        <p class="subtitle">Generated: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}</p>
        
        <table>
            <thead>
                <tr>
                    <th>ID</th>
                    <th style="text-align:center;">Total Days</th>
                    <th style="text-align:center;">Last {lookback_days} Days</th>
                    <th style="text-align:center;">Last Seen</th>
                    <th>Logging Pattern (<span style="color:#90EE90;">|</span>=yes, <span style="color:#FFB6C1;">-</span>=no)</th>
                </tr>
            </thead>
            <tbody>
                {rows_html}
            </tbody>
        </table>
        
        <div class="legend">
            <strong>Legend:</strong> 
            <span style="color:#28a745;font-weight:bold;">|</span> = Data uploaded |
            <span style="color:#dc3545;">-</span> = No data |
            Pattern reads left (oldest) to right (today)
        </div>
    </div>
</body>
</html>"""